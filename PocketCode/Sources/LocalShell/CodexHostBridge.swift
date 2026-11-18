import Foundation
import SafariServices
import UIKit

/// Bridges the embedded Codex agent to the device: every shell tool call the
/// agent makes runs through PocketCode's own LocalShell (and embedded Python),
/// and sign-in URLs open in the system browser. The C callback registered with
/// pocket-codex can't capture context, so the workspace root lives here.
enum CodexHostBridge {
    private static let lock = NSLock()
    private static var workspaceRoot: URL?
    private static var installed = false

    static func install(root: URL) {
        lock.lock()
        workspaceRoot = root
        let needsRegister = !installed
        installed = true
        lock.unlock()
        guard needsRegister else { return }

        pc_set_exec_handler({ requestPtr in
            guard let requestPtr else { return nil }
            let request = String(cString: requestPtr)
            let response = CodexHostBridge.run(requestJSON: request)
            return strdup(response)
        }, { response in free(response) })
    }

    private static weak var browser: SFSafariViewController?

    /// Sign-in pages open in an in-app browser: the app stays foreground, so
    /// the embedded OAuth callback listener on 127.0.0.1 keeps running.
    /// (External Safari suspends the app and the redirect goes nowhere.)
    static func openURL(_ url: URL) {
        DispatchQueue.main.async {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            guard var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                UIApplication.shared.open(url)
                return
            }
            while let presented = top.presentedViewController { top = presented }
            let vc = SFSafariViewController(url: url)
            browser = vc
            top.present(vc, animated: true)
        }
    }

    static func dismissBrowser() {
        DispatchQueue.main.async { browser?.dismiss(animated: true) }
    }

    /// `{"command":[…],"cwd":"…"}` → `{"exit_code":…,"stdout":…,"stderr":…}`
    private static func run(requestJSON: String) -> String {
        func respond(_ code: Int32, _ stdout: String, _ stderr: String) -> String {
            let obj: [String: Any] = ["exit_code": code, "stdout": stdout, "stderr": stderr]
            return (try? JSONSerialization.data(withJSONObject: obj))
                .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"exit_code":127,"stderr":"encode error"}"#
        }
        guard let data = requestJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? [String], !command.isEmpty else {
            return respond(127, "", "codex: bad exec request")
        }

        // Codex's shell tool sends ["bash","-lc", script]; fall back to quoting a plain argv.
        let script: String
        if command.count >= 3, command[0].hasSuffix("sh"), command[1] == "-lc" || command[1] == "-c" {
            script = command[2]
        } else {
            script = command.map { arg in
                arg.rangeOfCharacter(from: .whitespaces) == nil && !arg.contains("'")
                    ? arg : "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }.joined(separator: " ")
        }

        let r = execScript(script, cwd: obj["cwd"] as? String)
        return respond(r.code, r.stdout, r.stderr)
    }

    /// Runs a bash script through PocketCode's sandboxed LocalShell (with Python)
    /// rooted at the installed workspace. Shared by the Codex exec handler above
    /// and by `ClaudeRuntime`, so both agents run tools through the same sandbox.
    static func execScript(_ script: String, cwd: String?) -> (code: Int32, stdout: String, stderr: String) {
        lock.lock(); let root = workspaceRoot; lock.unlock()
        guard let root else { return (127, "", "no workspace") }

        let state = ShellState(root: root)
        if let cwd {
            let url = URL(fileURLWithPath: cwd)
            if url.path.hasPrefix(state.sandbox.root.path) { state.cwd = url }
        }
        var services = ShellServices()
        services.runPython = PythonRuntime.shellCommand

        let out = ShellOutput(), err = ShellOutput()
        let done = DispatchSemaphore(value: 0)
        var status: Int32 = 1
        Task.detached {
            do {
                status = await ShellExecutor.run(try ShellParser.parse(script), state: state,
                                                 terminal: out, terminalError: err,
                                                 input: nil, services: services)
            } catch {
                err.write(Data((error.localizedDescription + "\n").utf8))
                status = 2
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 120) == .timedOut {
            return (124, String(decoding: out.data, as: UTF8.self),
                    String(decoding: err.data, as: UTF8.self) + "\ncommand timed out")
        }
        return (status, String(decoding: out.data, as: UTF8.self),
                String(decoding: err.data, as: UTF8.self))
    }
}
