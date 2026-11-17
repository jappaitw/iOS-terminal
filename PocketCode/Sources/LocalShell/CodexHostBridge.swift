import Foundation
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

    static func openURL(_ url: URL) {
        DispatchQueue.main.async { UIApplication.shared.open(url) }
    }

    /// `{"command":[…],"cwd":"…"}` → `{"exit_code":…,"stdout":…,"stderr":…}`
    private static func run(requestJSON: String) -> String {
        func respond(_ code: Int32, _ stdout: String, _ stderr: String) -> String {
            let obj: [String: Any] = ["exit_code": code, "stdout": stdout, "stderr": stderr]
            return (try? JSONSerialization.data(withJSONObject: obj))
                .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"exit_code":127,"stderr":"encode error"}"#
        }
        lock.lock(); let root = workspaceRoot; lock.unlock()
        guard let root else { return respond(127, "", "codex: no workspace") }
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

        let state = ShellState(root: root)
        if let cwd = obj["cwd"] as? String {
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
            return respond(124, String(decoding: out.data, as: UTF8.self),
                           String(decoding: err.data, as: UTF8.self) + "\ncodex: command timed out")
        }
        return respond(status, String(decoding: out.data, as: UTF8.self),
                       String(decoding: err.data, as: UTF8.self))
    }
}
