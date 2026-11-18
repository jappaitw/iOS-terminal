import Foundation
import Security

/// The Claude backend: a native agent loop against the Anthropic Messages API.
///
/// No Codex, no V8, no Node. Tool calls run through the very same sandboxed
/// shell as Codex (`CodexHostBridge.execScript`), so Claude can list, read,
/// write and run code in the workspace. The user brings their own Anthropic API
/// key — Anthropic's Commercial Terms require each end user to authenticate with
/// their own key, so Pocode stores it locally (Keychain) and never intermediates.
enum ClaudeRuntime {
    /// Wired into the shell as the `claude` command (see ShellServices.runClaude).
    static let shellCommand: (@Sendable (ShellContext) async -> Int32)? = { ctx in await session(ctx) }

    static let defaultModel = "claude-sonnet-5"
    private static let apiVersion = "2023-06-01"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// One interactive `claude` session bound to this terminal.
    static func session(_ ctx: ShellContext) async -> Int32 {
        // Tools the agent runs route back through this shell's sandboxed workspace.
        CodexHostBridge.install(root: ctx.state.sandbox.root)
        func out(_ s: String) { ctx.stdout.write(s) }
        guard let input = ctx.terminalInput else {
            return ctx.fail("claude needs an interactive terminal", status: 1)
        }
        out("\u{1B}[1mClaude\u{1B}[0m — on-device AI coding agent (Anthropic API). Type \u{1B}[2m/exit\u{1B}[0m to leave.\r\n")

        // API key: Keychain, or prompt once and store.
        var key = ClaudeCredentials.apiKey
        if key == nil {
            out("\r\nPaste your Anthropic API key (sk-ant-…). Get one at console.anthropic.com.\r\n")
            out("key› ")
            guard let entered = input.readLine()?.trimmingCharacters(in: .whitespaces), !entered.isEmpty else {
                out("No key entered.\r\n"); return 1
            }
            ClaudeCredentials.apiKey = entered
            key = entered
            out("\u{1B}[32m✓ Saved to Keychain.\u{1B}[0m (change later in Settings → AI)\r\n")
        }
        guard let apiKey = key else { return 1 }

        let model = ClaudeCredentials.model ?? defaultModel
        let cwd = ctx.state.cwd.path
        out("\r\nModel \u{1B}[2m\(model)\u{1B}[0m · ask Claude to build or change something in \u{1B}[2m\(ctx.state.sandbox.display(ctx.state.cwd))\u{1B}[0m.\r\n")
        out("\u{1B}[2m/reset clears context · /exit leaves\u{1B}[0m\r\n")

        var messages: [[String: Any]] = []
        let cancelled = InterruptFlag()
        while true {
            out("\r\n\u{1B}[35mclaude›\u{1B}[0m ")
            guard let line = input.readLine() else { break }
            let prompt = line.trimmingCharacters(in: .whitespaces)
            if prompt.isEmpty { continue }
            if ["/exit", "exit", "/quit"].contains(prompt) { break }
            if prompt == "/reset" { messages.removeAll(); out("Context cleared.\r\n"); continue }

            messages.append(["role": "user", "content": prompt])
            cancelled.clear()
            ctx.interruptHandler = { cancelled.set() }
            await runTurn(apiKey: apiKey, model: model, cwd: cwd, messages: &messages, out: out, cancelled: cancelled)
            ctx.interruptHandler = nil
        }
        out("\r\nLeaving Claude.\r\n")
        return 0
    }

    /// One user turn: call the API, run any tool_use it emits, loop until the
    /// model stops asking for tools (stop_reason != "tool_use").
    private static func runTurn(apiKey: String, model: String, cwd: String,
                                messages: inout [[String: Any]], out: (String) -> Void,
                                cancelled: InterruptFlag) async {
        let tools: [[String: Any]] = [[
            "name": "bash",
            "description": "Run a bash command in the project workspace. Use it to list, read and write files "
                + "(heredocs and python3 are available) and to run code. Returns stdout, stderr and the exit code.",
            "input_schema": [
                "type": "object",
                "properties": ["command": ["type": "string", "description": "The bash script to run."]],
                "required": ["command"],
            ],
        ]]
        let system = "You are Claude, a coding agent running on an iPhone inside the Pocode app. "
            + "You work in a sandboxed workspace rooted at \(cwd). Use the bash tool to inspect and modify files "
            + "and to run code; write files with heredocs or python3. Prefer small, verifiable steps and keep your "
            + "spoken replies concise — say what you changed, not long explanations."

        while true {
            if cancelled.isSet { out("\r\n\u{1B}[33m⏸ interrupted\u{1B}[0m\r\n"); return }
            let body: [String: Any] = [
                "model": model, "max_tokens": 8192, "system": system,
                "tools": tools, "messages": messages,
            ]
            guard let (reply, raw) = await call(apiKey: apiKey, body: body, out: out) else { return }
            messages.append(["role": "assistant", "content": reply])

            var toolUses: [[String: Any]] = []
            for block in reply {
                guard let type = block["type"] as? String else { continue }
                if type == "text", let text = block["text"] as? String {
                    out(crlf(text)); out("\r\n")
                } else if type == "tool_use" {
                    toolUses.append(block)
                }
            }
            if toolUses.isEmpty || (raw["stop_reason"] as? String) != "tool_use" { return }

            var results: [[String: Any]] = []
            for tu in toolUses {
                let id = tu["id"] as? String ?? ""
                let command = (tu["input"] as? [String: Any])?["command"] as? String ?? ""
                out("\r\n\u{1B}[2m$ \(crlf(command))\u{1B}[0m\r\n")
                let r = CodexHostBridge.execScript(command, cwd: cwd)
                var combined = r.stdout
                if !r.stderr.isEmpty { combined += (combined.isEmpty ? "" : "\n") + r.stderr }
                if combined.isEmpty { combined = "(exit \(r.code))" }
                let preview = combined.count > 2000 ? String(combined.prefix(2000)) + "\n…(truncated)" : combined
                out(crlf(preview)); out("\r\n")
                results.append([
                    "type": "tool_result", "tool_use_id": id,
                    "content": combined, "is_error": r.code != 0,
                ])
            }
            messages.append(["role": "user", "content": results])
        }
    }

    /// POST to the Messages API. Returns (content blocks, full json) or nil on error.
    private static func call(apiKey: String, body: [String: Any],
                            out: (String) -> Void) async -> ([[String: Any]], [String: Any])? {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        req.timeoutInterval = 120
        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
                out("\r\n\u{1B}[31mBad response from Anthropic.\u{1B}[0m\r\n"); return nil
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(http.statusCode)"
                out("\r\n\u{1B}[31mAnthropic error: \(msg)\u{1B}[0m\r\n")
                if http.statusCode == 401 {
                    ClaudeCredentials.apiKey = nil
                    out("Key cleared — run \u{1B}[1mclaude\u{1B}[0m again to re-enter.\r\n")
                }
                return nil
            }
            guard let content = obj["content"] as? [[String: Any]] else {
                out("\r\n\u{1B}[31mNo content in response.\u{1B}[0m\r\n"); return nil
            }
            return (content, obj)
        } catch {
            out("\r\n\u{1B}[31mNetwork error: \(error.localizedDescription)\u{1B}[0m\r\n")
            return nil
        }
    }

    /// Terminal wants CRLF; model text uses LF.
    private static func crlf(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\r\n") }

    final class InterruptFlag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        func clear() { lock.lock(); v = false; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }
}

/// Keychain-backed storage for the Anthropic API key, plus the chosen model
/// (a plain default). The key is sensitive, so it lives in the Keychain, not
/// UserDefaults.
enum ClaudeCredentials {
    private static let service = "com.jlmxstudio.pocketcode.claude"
    private static let account = "anthropic-api-key"

    static var apiKey: String? {
        get { keychainRead() }
        set { if let newValue { keychainWrite(newValue) } else { keychainDelete() } }
    }

    static var model: String? {
        get { UserDefaults.standard.string(forKey: "claude.model") }
        set { UserDefaults.standard.set(newValue, forKey: "claude.model") }
    }

    private static func keychainWrite(_ value: String) {
        keychainDelete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func keychainRead() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
