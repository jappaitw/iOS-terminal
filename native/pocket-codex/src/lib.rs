//! Runs the Codex app-server inside the PocketCode process, listening on a unix
//! socket in the app container. Swift connects to that socket and speaks the
//! app-server JSON-RPC protocol (the same one the VS Code extension uses), so the
//! FFI surface stays this small.

use std::ffi::{c_char, c_int, CStr, CString};
use std::sync::Mutex;

use codex_app_server::{
    run_main_with_transport_options, AppServerRuntimeOptions, AppServerTransport,
    CodeModeHostTransport, PluginStartupTasks,
};
use codex_arg0::Arg0DispatchPaths;
use codex_config::LoaderOverrides;
use codex_protocol::protocol::SessionSource;
use codex_utils_absolute_path::AbsolutePathBuf;
use codex_utils_cli::CliConfigOverrides;
use codex_websocket_auth::WebsocketAuthSettings;

static STARTED: Mutex<bool> = Mutex::new(false);

fn c_str(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok().map(String::from)
}

fn out_err(error_out: *mut *mut c_char, message: &str) {
    if !error_out.is_null() {
        let c = CString::new(message).unwrap_or_default();
        unsafe { *error_out = c.into_raw() };
    }
}

/// Starts the app-server on `socket_path` with `CODEX_HOME` set to `codex_home`.
/// Returns 0 on success (server thread running), non-zero with `*error_out` set
/// otherwise. One server per process; a second call is an error.
///
/// # Safety
/// `socket_path` and `codex_home` must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn pc_start(
    socket_path: *const c_char,
    codex_home: *const c_char,
    error_out: *mut *mut c_char,
) -> c_int {
    let Some(socket) = c_str(socket_path) else {
        out_err(error_out, "socket_path is not valid UTF-8");
        return 1;
    };
    let Some(home) = c_str(codex_home) else {
        out_err(error_out, "codex_home is not valid UTF-8");
        return 1;
    };

    let mut started = STARTED.lock().unwrap();
    if *started {
        out_err(error_out, "the codex server is already running");
        return 2;
    }

    let socket = match AbsolutePathBuf::try_from(socket.as_str()) {
        Ok(p) => p,
        Err(e) => {
            out_err(error_out, &format!("bad socket path: {e}"));
            return 1;
        }
    };

    // The config loader and credential store resolve everything under CODEX_HOME;
    // pointing it into the app container keeps all state inside the sandbox.
    std::env::set_var("CODEX_HOME", &home);

    // Device consoles are invisible: the engine's fate lands in a log file the
    // host can read back, and a dead server allows another pc_start.
    let log_path = std::path::Path::new(&home).join("engine.log");
    // Route the process's stderr (tracing output, eprintln breadcrumbs) there too.
    if let Ok(f) = std::fs::OpenOptions::new().create(true).append(true).open(&log_path) {
        use std::os::fd::AsRawFd;
        unsafe { libc::dup2(f.as_raw_fd(), 2) };
        std::mem::forget(f);
    }
    let log = move |msg: &str| {
        let line = format!("{msg}\n");
        let _ = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
            .map(|mut f| std::io::Write::write_all(&mut f, line.as_bytes()));
    };

    let build = std::thread::Builder::new()
        .name("PocketCode.Codex".into())
        .spawn(move || {
            let finish = |msg: String| {
                eprintln!("pocket-codex: {msg}");
                log(&msg);
                *STARTED.lock().unwrap() = false;
            };
            let rt = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    finish(format!("tokio runtime failed: {e}"));
                    return;
                }
            };
            // The exec-server options insist on a self-exe path at startup even
            // though it is only used when spawning shell tools (impossible on
            // iOS; replaced by LocalShell routing). The app binary satisfies it.
            let arg0 = Arg0DispatchPaths {
                codex_self_exe: std::env::current_exe().ok(),
                ..Default::default()
            };
            // iOS cannot spawn the code-mode host binary, so the host (V8
            // orchestration isolate) runs in-process on a loopback gRPC port
            // and the app-server connects to it like a remote.
            const CODE_MODE_PORT: u16 = 18777;
            rt.spawn(async {
                if let Err(e) =
                    codex_code_mode_host::run_main(&format!("grpc://127.0.0.1:{CODE_MODE_PORT}")).await
                {
                    eprintln!("pocket-codex: code-mode host exited: {e:#}");
                }
            });
            let code_mode_url = format!("http://127.0.0.1:{CODE_MODE_PORT}/")
                .parse()
                .expect("static code-mode URL");

            let result = rt.block_on(run_main_with_transport_options(
                arg0,
                CliConfigOverrides::default(),
                LoaderOverrides::default(),
                /* strict_config */ false,
                /* default_analytics_enabled */ false,
                AppServerTransport::UnixSocket { socket_path: socket },
                SessionSource::Custom("pocketcode".to_string()),
                WebsocketAuthSettings::default(),
                AppServerRuntimeOptions {
                    // We are a library inside an app: never install signal
                    // handlers or behave like a managed daemon.
                    install_shutdown_signal_handler: false,
                    managed_daemon: false,
                    plugin_startup_tasks: PluginStartupTasks::Skip,
                    code_mode_host_transport: CodeModeHostTransport::Grpc(code_mode_url),
                    ..Default::default()
                },
            ));
            match result {
                Ok(_) => finish("server exited cleanly".to_string()),
                Err(e) => finish(format!("server exited: {e}")),
            }
        });

    match build {
        Ok(_handle) => {
            *started = true;
            0
        }
        Err(e) => {
            out_err(error_out, &format!("could not spawn server thread: {e}"));
            1
        }
    }
}

/// Routes every Codex shell tool call to the host. `run` receives a JSON
/// request ({"command":[…],"cwd":"…"}) and returns a malloc'ed JSON response
/// ({"exit_code":…,"stdout":…,"stderr":…,"timed_out":…}); `free` releases it.
/// Register before the first turn runs.
#[no_mangle]
pub extern "C" fn pc_set_exec_handler(
    run: codex_core::host_exec::HostRunFn,
    free: codex_core::host_exec::HostFreeFn,
) {
    codex_core::host_exec::register(run, free);
}

/// Frees a string returned through `error_out`.
///
/// # Safety
/// `s` must have come from this library and not been freed already.
#[no_mangle]
pub unsafe extern "C" fn pc_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

#[no_mangle]
pub extern "C" fn pc_abi_version() -> c_int {
    1
}

/// Exercises apply-patch's tree-sitter bash query with a heredoc invocation —
/// the exact path that died on device when Runestone's older tree_sitter_bash
/// grammar shadowed ours at link time (query wants `heredoc_end`, old grammar
/// lacks it, LazyLock poisoned, every file-save tool call failed). Returns 0
/// when the patched (symbol-renamed) grammar parses it.
///
/// # Safety
/// `error_out` may be null; if set, the caller frees the string with pc_free.
#[no_mangle]
pub unsafe extern "C" fn pc_bash_tool_smoketest(error_out: *mut *mut c_char) -> c_int {
    let result = std::panic::catch_unwind(|| {
        let cwd = codex_utils_path_uri::PathUri::from_host_native_path("/tmp")
            .map_err(|e| format!("cwd: {e}"))?;
        // The canonical form codex emits (see invocation.rs tests): cd prefix,
        // PATCH delimiter, no trailing newline after the closing delimiter.
        let script = "cd . && apply_patch <<'PATCH'\n*** Begin Patch\n*** Add File: smoke.txt\n+hello\n*** End Patch\nPATCH";
        let argv = vec!["bash".to_string(), "-lc".to_string(), script.to_string()];
        match codex_apply_patch::maybe_parse_apply_patch(&argv, &cwd) {
            codex_apply_patch::MaybeApplyPatch::Body(_) => Ok(()),
            other => Err(format!("unexpected parse result: {other:?}")),
        }
    });
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(msg)) => {
            out_err(error_out, &format!("bash-tool: {msg}"));
            1
        }
        Err(_) => {
            out_err(error_out, "bash-tool panicked (tree-sitter bash query/grammar mismatch)");
            2
        }
    }
}

/// Isolated V8 smoke test: initialise the platform and create one isolate,
/// nothing else. Returns 0 if V8 lives on this device, non-zero (and a
/// message via `error_out`) if it can't — separating "the denoland iOS V8
/// prebuilt itself is broken" from "codex's usage trips it".
///
/// # Safety
/// `error_out` may be null; if set, the caller frees the string with pc_free.
#[no_mangle]
pub unsafe extern "C" fn pc_v8_smoketest(error_out: *mut *mut c_char) -> c_int {
    let result = std::panic::catch_unwind(|| {
        // On iOS this is coerced to Disabled (--jitless) — same as the real host.
        codex_code_mode_runtime::initialize_v8(codex_code_mode_runtime::V8JitMode::Enabled)
            .map_err(|e| format!("init: {e}"))?;
        // Isolate::new deserialises the read-only+startup snapshots; Context::new
        // deserialises the context snapshot; compile+run exercises the jitless
        // interpreter. Together these cover the first code-mode cell's crash
        // surface, not just platform init.
        let isolate = &mut v8::Isolate::new(v8::CreateParams::default());
        v8::scope!(let scope, isolate);
        let context = v8::Context::new(scope, Default::default());
        let scope = &mut v8::ContextScope::new(scope, context);
        let code = v8::String::new(scope, "(() => { const a = [3,1,2]; a.sort(); return JSON.stringify(a) + '/' + (6*7); })()")
            .ok_or("alloc source")?;
        let script = v8::Script::compile(scope, code, None).ok_or("compile failed")?;
        let value = script.run(scope).ok_or("run failed")?;
        let out = value.to_rust_string_lossy(scope);
        if out != "[1,2,3]/42" {
            return Err(format!("unexpected result: {out}"));
        }
        Ok::<(), String>(())
    });
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(msg)) => {
            out_err(error_out, &format!("v8: {msg}"));
            1
        }
        Err(_) => {
            out_err(error_out, "v8 panicked (snapshot magic mismatch at Isolate::new)");
            2
        }
    }
}

#[cfg(test)]
mod bash_tool_tests {
    #[test]
    fn canonical_heredoc_parses() {
        let cwd = codex_utils_path_uri::PathUri::from_host_native_path("/tmp").unwrap();
        let script = "cd . && apply_patch <<'PATCH'\n*** Begin Patch\n*** Add File: smoke.txt\n+hello\n*** End Patch\nPATCH";
        let argv = vec!["bash".to_string(), "-lc".to_string(), script.to_string()];
        let r = codex_apply_patch::maybe_parse_apply_patch(&argv, &cwd);
        match r {
            codex_apply_patch::MaybeApplyPatch::Body(_) => {}
            other => panic!("unexpected: {other:?}"),
        }
    }
}
