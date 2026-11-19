import Foundation
import os

private let codexLog = Logger(subsystem: "com.jlmxstudio.pocketcode", category: "codex")

/// The embedded Codex agent (OpenAI's Codex app-server, linked in-process).
///
/// Runs the real Codex engine on the device: it talks to the model over the
/// network, but the agent, its state, and every shell/Python tool call stay on
/// the phone. Started once per process; the `codex` terminal command drives it
/// through an interactive session.
enum CodexRuntime {
    /// Wired into the shell as the `codex` and `pocode` commands (see ShellServices.runCodex).
    static let shellCommand: (@Sendable (ShellContext) async -> Int32)? = { ctx in await session(ctx) }

    private static let lock = NSLock()
    private static var started = false
    private static var client: CodexProtocolClient?
    private static var socketPath: String?
    /// The code_mode the engine was actually started with. The engine reads its
    /// config once at boot and there is no clean restart (no pc_stop), so a
    /// backend switch mid-session requires an app restart.
    private static var engineCodeMode: Bool?

    /// The CODEX_HOME directory (config.toml, skills/, credentials).
    static var home: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("codex-home", isDirectory: true)
    }

    /// A dedicated protocol connection for the settings UI (skills list, MCP
    /// management). Boots the engine if needed. Returns nil with a message on failure.
    static func managementClient() -> (CodexProtocolClient?, String?) {
        if let error = ensureStarted(codeMode: false) { return (nil, error) }
        lock.lock(); let sock = socketPath; lock.unlock()
        guard let sock else { return (nil, "engine socket unknown") }
        let c = CodexProtocolClient(socketPath: sock)
        guard c.connect() else { return (nil, "could not connect to the engine") }
        c.initialize()
        return (c, nil)
    }

    /// Boots the app-server and connects. Returns an error string on failure;
    /// failures aren't sticky — the next `codex` tries again.
    private static func ensureStarted(codeMode: Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        if started { return nil }

        let home = Self.home
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Crash forensics: V8 FATALs and Rust panics print their reason to stderr
        // right before trapping. Point stderr at a file so a device crash leaves
        // the exact message behind (surfaced by `codex` on the next launch).
        // Unbuffered is essential: freopen to a regular file makes stderr fully
        // buffered, and a FATAL that traps right after printing would die with
        // its message still in the buffer — exactly what happened on build 16.
        freopen(home.appendingPathComponent("engine-stderr.log").path, "a", stderr)
        setvbuf(stderr, nil, _IONBF, 0)
        ensureIOSFeatureDefaults(home: home, codeMode: codeMode)
        engineCodeMode = codeMode
        // Tokens for MCP bearer_token_env_var live in the Keychain and are
        // exported into the process environment before the engine reads them.
        McpTokenStore.exportAllToEnvironment()
        // The local-model provider must exist in config before the engine reads it.
        LocalModelBackend.registerProviderIfNeeded(home: home)
        let engineLog = home.appendingPathComponent("engine.log")
        try? FileManager.default.removeItem(at: engineLog)

        // sockaddr_un caps paths near 104 bytes. The device container's tmp
        // fits; the simulator's host-side path doesn't, so use the host /tmp.
        #if targetEnvironment(simulator)
        // The engine chmods the socket's parent to 0700, so it must be a
        // directory we own (not /private/tmp itself, which is root's), short
        // enough for sockaddr_un, and per-process so a lingering test-host
        // app's startup flock can't block us.
        let dir = "/private/tmp/pocketcode-\(getuid())"
        mkdir(dir, 0o700)
        let sock = dir + "/cx-\(getpid()).sock"
        #else
        let sock = NSTemporaryDirectory() + "codex.sock"
        #endif
        unlink(sock)

        var err: UnsafeMutablePointer<CChar>?
        let rc = pc_start(sock, home.path, &err)
        if rc != 0 {
            let message = err.map { String(cString: $0) } ?? "codex failed to start"
            if let err { pc_free(err) }
            codexLog.error("pc_start failed: \(message, privacy: .public)")
            return message
        }

        let c = CodexProtocolClient(socketPath: sock)
        guard c.connect() else {
            // The engine thread wrote why it died (if it did) to engine.log.
            let detail = (try? String(contentsOf: engineLog, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = "could not connect to the codex engine"
                + (detail.map { "\r\n  engine: \($0)" } ?? "")
            codexLog.error("\(message, privacy: .public)")
            return message
        }
        c.initialize()
        client = c
        socketPath = sock
        started = true
        codexLog.info("codex engine started")
        return nil
    }

    /// `code_mode` toggles with the active backend. Cloud gpt-6 drives tools
    /// through the in-process V8 host (code-mode: the model writes JavaScript
    /// that orchestrates tools). Local models can't emit code-mode JS, so forcing
    /// them into code-mode stalls the turn — the model stream never completes and
    /// codex loops on "Reconnecting… waiting for network". Local models must use
    /// the classic/Direct tool path (plain function calls), which is what the
    /// `code_mode = false` default gives a model with no explicit tool_mode.
    /// `code_mode_host` (the V8 service) stays enabled regardless — cloud uses it.
    private static func ensureIOSFeatureDefaults(home: URL, codeMode: Bool) {
        let config = home.appendingPathComponent("config.toml")
        var text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        let cm = codeMode ? "true" : "false"
        text = text.replacingOccurrences(of: "code_mode = true", with: "code_mode = \(cm)")
        text = text.replacingOccurrences(of: "code_mode = false", with: "code_mode = \(cm)")
        text = text.replacingOccurrences(of: "code_mode_host = false", with: "code_mode_host = true")
        if !text.contains("code_mode =") {
            let hostLine = text.contains("code_mode_host") ? "" : "code_mode_host = true\n"
            let lines = "code_mode = \(cm)\n" + hostLine
            if let range = text.range(of: "[features]") {
                text.insert(contentsOf: "\n" + lines, at: range.upperBound)
                text = text.replacingOccurrences(of: "[features]\n\n", with: "[features]\n")
            } else {
                if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                text += "\n[features]\n" + lines
            }
        } else if !text.contains("code_mode_host"), let range = text.range(of: "[features]") {
            text.insert(contentsOf: "\ncode_mode_host = true", at: range.upperBound)
        }
        try? text.write(to: config, atomically: true, encoding: .utf8)
    }

    /// One interactive `codex` session bound to this terminal.
    static func session(_ ctx: ShellContext) async -> Int32 {
        guard let input = ctx.terminalInput else {
            return ctx.fail("this agent needs an interactive terminal", status: 1)
        }

        // BOTH backends use Pocode's own tools (write_file/run_command routed
        // through the sandboxed shell) via dynamicTools + Direct mode. iOS can't
        // run codex's code-mode gRPC host (connection refused) or its unified
        // exec (real fork/exec is "Operation not permitted"), so code_mode stays
        // off everywhere and the model never touches those fragile paths.
        let wantLocal = ctx.args.first == "pocode"
        if wantLocal {
            let hasSelection = await MainActor.run { ModelStore.shared.activeModelID != nil }
            guard hasSelection else {
                return ctx.fail("Select an installed model in Settings → Models before running pocode.", status: 1)
            }
        }
        guard CodexHostBridge.beginSession(root: ctx.state.sandbox.root) else {
            return ctx.fail("A pocode or codex session is already open. Resume its terminal or exit it before starting another.", status: 1)
        }
        defer { CodexHostBridge.endSession() }
        if let error = ensureStarted(codeMode: false) { return ctx.fail(error, status: 127) }
        guard let client else { return ctx.fail("could not connect to the coding agent", status: 1) }

        func out(_ s: String) { ctx.stdout.write(s) }
        let agentName = wantLocal ? "Local AI" : "Codex"
        let promptName = wantLocal ? "pocode" : "codex"
        out("\u{1B}[1m\(agentName)\u{1B}[0m — on-device AI coding agent. Type \u{1B}[2m/exit\u{1B}[0m to leave.\r\n")
        // If the previous run died mid-turn, its stderr (V8 FATAL / Rust panic)
        // names the reason — show the tail once, then clear it.
        let stderrLog = Self.home.appendingPathComponent("engine-stderr.log")
        if let data = try? Data(contentsOf: stderrLog), !data.isEmpty {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let tail = text.split(separator: "\n").suffix(14).joined(separator: "\r\n  ")
                out("\u{1B}[33mPrevious engine crash log:\u{1B}[0m\r\n  \(tail)\r\n")
            }
            try? Data().write(to: stderrLog)
        }

        // A local model, if the user picked one, serves the turn offline — no sign-in.
        let local = wantLocal ? await LocalModelBackend.ensureRunning(out: out) : nil
        if wantLocal && local == nil {
            return ctx.fail("Could not start the selected local model. Check Models in Settings and try again.", status: 1)
        }

        if local == nil {
            // Cloud Codex: sign in.
            if !client.isLoggedIn {
                if !(await login(client, ctx: ctx, input: input, out: out)) {
                    out("Sign-in cancelled.\r\n")
                    return 1
                }
            } else {
                out("Signed in (\(client.authMode ?? "ok")).\r\n")
            }
        }

        let cwd = ctx.state.cwd.path
        let threadId: String?
        if let local {
            threadId = client.startThread(cwd: cwd, model: local.model, provider: local.provider, local: true)
        } else {
            // Cloud gpt uses the SAME Pocode tools path (dynamicTools, no code-mode).
            threadId = client.startThread(cwd: cwd, local: true)
        }
        guard let threadId else {
            return ctx.fail("could not start a codex thread", status: 1)
        }

        out("\r\nAsk \(agentName) to build or change something in \u{1B}[2m\(ctx.state.sandbox.display(ctx.state.cwd))\u{1B}[0m.\r\n")
        while true {
            out("\r\n\u{1B}[36m\(promptName)›\u{1B}[0m ")
            guard let line = input.readLine() else { break }
            let prompt = line.trimmingCharacters(in: .whitespaces)
            if prompt.isEmpty { continue }
            if prompt == "/exit" || prompt == "exit" || prompt == "/quit" { break }
            if !wantLocal && prompt == "/logout" { client.logout(); out("Signed out.\r\n"); continue }

            ctx.interruptHandler = { client.interruptTurn(threadId: threadId) }
            // Both backends use Pocode's dynamicTools now, so every turn needs
            // the workspace context that executes write_file/run_command.
            client.runTurn(threadId: threadId, prompt: prompt, localWorkspace: ctx, out: out)
            ctx.interruptHandler = nil
        }
        out("\r\nLeaving \(agentName).\r\n")
        return 0
    }

    /// Thread-safe cancellation flag for the sign-in wait (set by Ctrl-C).
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func login(_ client: CodexProtocolClient, ctx: ShellContext, input: ShellInput,
                              out: @escaping (String) -> Void) async -> Bool {
        out("\r\nSign in:\r\n  [1] ChatGPT account (subscription)\r\n  [2] OpenAI API key\r\n")
        while true {
            out("choose 1 or 2› ")
            guard let choice = input.readLine()?.trimmingCharacters(in: .whitespaces) else { return false }
            switch choice {
            case "1":
                guard let url = client.startChatGPTLogin() else { out("Could not begin ChatGPT login.\r\n"); return false }
                out("Opening the sign-in page… finish there; you'll come back automatically.\r\n")
                CodexHostBridge.openURL(url)
                out("Waiting for sign-in (Ctrl-C to cancel)…\r\n")
                let cancelled = Flag()
                ctx.interruptHandler = { cancelled.set() }
                let ok = client.waitForLogin(isCancelled: { cancelled.isSet })
                ctx.interruptHandler = nil
                CodexHostBridge.dismissBrowser()
                if ok { out("\u{1B}[32m✓ Signed in.\u{1B}[0m\r\n") }
                return ok
            case "2":
                out("paste API key (sk-…)› ")
                guard let key = input.readLine()?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { return false }
                return client.loginAPIKey(key)
            default:
                out("Please type 1 or 2.\r\n")
            }
        }
    }
}
