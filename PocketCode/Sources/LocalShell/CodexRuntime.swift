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
    /// Wired into the shell as the `codex` command (see ShellServices.runCodex).
    static let shellCommand: (@Sendable (ShellContext) async -> Int32)? = { ctx in await session(ctx) }

    private static let lock = NSLock()
    private static var started = false
    private static var client: CodexProtocolClient?
    private static var socketPath: String?

    /// The CODEX_HOME directory (config.toml, skills/, credentials).
    static var home: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("codex-home", isDirectory: true)
    }

    /// A dedicated protocol connection for the settings UI (skills list, MCP
    /// management). Boots the engine if needed. Returns nil with a message on failure.
    static func managementClient() -> (CodexProtocolClient?, String?) {
        if let error = ensureStarted() { return (nil, error) }
        lock.lock(); let sock = socketPath; lock.unlock()
        guard let sock else { return (nil, "engine socket unknown") }
        let c = CodexProtocolClient(socketPath: sock)
        guard c.connect() else { return (nil, "could not connect to the engine") }
        c.initialize()
        return (c, nil)
    }

    /// Boots the app-server and connects. Returns an error string on failure;
    /// failures aren't sticky — the next `codex` tries again.
    private static func ensureStarted() -> String? {
        lock.lock(); defer { lock.unlock() }
        if started { return nil }

        let home = Self.home
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Tokens for MCP bearer_token_env_var live in the Keychain and are
        // exported into the process environment before the engine reads them.
        McpTokenStore.exportAllToEnvironment()
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

    /// One interactive `codex` session bound to this terminal.
    static func session(_ ctx: ShellContext) async -> Int32 {
        // Tools the agent runs route back through this shell's workspace.
        CodexHostBridge.install(root: ctx.state.sandbox.root)

        if let error = ensureStarted() { return ctx.fail(error, status: 127) }
        guard let client, let input = ctx.terminalInput else {
            return ctx.fail("codex needs an interactive terminal", status: 1)
        }

        func out(_ s: String) { ctx.stdout.write(s) }
        out("\u{1B}[1mCodex\u{1B}[0m — on-device AI coding agent. Type \u{1B}[2m/exit\u{1B}[0m to leave.\r\n")

        // Login gate.
        if !client.isLoggedIn {
            if !(await login(client, ctx: ctx, input: input, out: out)) {
                out("Sign-in cancelled.\r\n")
                return 1
            }
        } else {
            out("Signed in (\(client.authMode ?? "ok")).\r\n")
        }

        let cwd = ctx.state.cwd.path
        guard let threadId = client.startThread(cwd: cwd) else {
            return ctx.fail("could not start a codex thread", status: 1)
        }

        out("\r\nAsk Codex to build or change something in \u{1B}[2m\(ctx.state.sandbox.display(ctx.state.cwd))\u{1B}[0m.\r\n")
        while true {
            out("\r\n\u{1B}[36mcodex›\u{1B}[0m ")
            guard let line = input.readLine() else { break }
            let prompt = line.trimmingCharacters(in: .whitespaces)
            if prompt.isEmpty { continue }
            if prompt == "/exit" || prompt == "exit" || prompt == "/quit" { break }
            if prompt == "/logout" { client.logout(); out("Signed out.\r\n"); continue }

            ctx.interruptHandler = { client.interruptTurn(threadId: threadId) }
            client.runTurn(threadId: threadId, prompt: prompt, out: out)
            ctx.interruptHandler = nil
        }
        out("\r\nLeaving Codex.\r\n")
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
