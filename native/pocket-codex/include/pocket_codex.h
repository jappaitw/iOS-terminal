// Minimal C interface between Swift and the embedded Codex app-server
// (pocket-codex Rust staticlib). Swift talks to the server over the unix
// socket using the app-server JSON-RPC protocol; this header only starts it.
#ifndef POCKET_CODEX_H
#define POCKET_CODEX_H

/// Start the Codex app-server on a unix socket inside the app container.
/// `codex_home` becomes CODEX_HOME (config + credentials, kept in the sandbox).
/// Returns 0 on success (server thread running), non-zero on failure with
/// *error set (free with pc_free). One server per process.
int pc_start(const char *socket_path, const char *codex_home, char **error);

/// Free a string returned through pc_start's error out-parameter.
void pc_free(char *s);

/// Route every Codex shell tool call to the host. `run` gets a JSON request
/// ({"command":[...],"cwd":"..."}) and returns a malloc'ed JSON response
/// ({"exit_code":...,"stdout":"...","stderr":"...","timed_out":false}); `free`
/// releases that response. Register before the first turn runs.
typedef char *(*pc_exec_run_fn)(const char *request_json);
typedef void (*pc_exec_free_fn)(char *response);
void pc_set_exec_handler(pc_exec_run_fn run, pc_exec_free_fn free);

/// FFI contract version (bump on breaking changes).
int pc_abi_version(void);

#endif
int pc_v8_smoketest(char **error_out);
