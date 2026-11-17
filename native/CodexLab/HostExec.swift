import Foundation

/// Runs Codex shell tool calls through PocketCode's LocalShell (and embedded
/// Python) instead of fork/exec. The C callback registered with
/// pc_set_exec_handler can't capture context, so the workspace root lives here.
enum HostShell {
    static var root: URL?

    /// `{"command":[…],"cwd":"…"}` → `{"exit_code":…,"stdout":…,"stderr":…}`
    static func run(requestJSON: String) -> String {
        func respond(_ code: Int32, _ out: String, _ err: String) -> String {
            let obj: [String: Any] = ["exit_code": code, "stdout": out, "stderr": err]
            return (try? JSONSerialization.data(withJSONObject: obj))
                .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"exit_code":127,"stderr":"encode error"}"#
        }
        guard let root else { return respond(127, "", "host shell: no workspace") }
        guard let data = requestJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? [String], !command.isEmpty else {
            return respond(127, "", "host shell: bad request")
        }

        // codex's shell tool sends ["bash","-lc", script]; anything else is a
        // plain argv that we re-quote into one command line.
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
        // Shell tool calls are bounded; 120 s mirrors codex's own default.
        if done.wait(timeout: .now() + 120) == .timedOut {
            return respond(124, String(decoding: out.data, as: UTF8.self),
                           String(decoding: err.data, as: UTF8.self) + "\nhost shell: timed out")
        }
        return respond(status, String(decoding: out.data, as: UTF8.self),
                       String(decoding: err.data, as: UTF8.self))
    }
}
