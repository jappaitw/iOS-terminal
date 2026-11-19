import Foundation

/// Minimal client for the Codex app-server: WebSocket over a unix socket,
/// JSON-RPC in both directions. Terminal-oriented — runTurn blocks, streaming
/// the agent's output to the shell until the turn completes.
final class CodexProtocolClient {
    private let socketPath: String
    private var fd: Int32 = -1
    private var nextId = 1
    private let writeLock = NSLock()

    private(set) var authMode: String?
    private var loginCompleted: Bool?

    init(socketPath: String) { self.socketPath = socketPath }

    var isLoggedIn: Bool { authMode != nil }

    // MARK: connection

    func connect() -> Bool {
        for _ in 0..<40 {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                socketPath.utf8CString.withUnsafeBytes { raw.copyBytes(from: $0.prefix(raw.count - 1)) }
            }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
            }
            if ok == 0 {
                let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
                let upgrade = "GET / HTTP/1.1\r\nHost: codex\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n\r\n"
                _ = upgrade.withCString { write(fd, $0, strlen($0)) }
                if let head = readUntil(marker: Array("\r\n\r\n".utf8)), head.contains("101") { return true }
                close(fd); fd = -1
                return false
            }
            close(fd); fd = -1
            usleep(250_000)
        }
        return false
    }

    func initialize() {
        let id = request(method: "initialize", params: [
            "clientInfo": ["name": "pocketcode", "title": "PocketCode", "version": "1.0"],
            "capabilities": ["experimentalApi": true],
        ])
        _ = awaitResponse(id: id)
        if let status = sendAndAwait(method: "getAuthStatus", params: [:]),
           let method = (status["authMethod"] as? String), !method.isEmpty {
            authMode = method
        }
    }

    // MARK: auth

    func loginAPIKey(_ key: String) -> Bool {
        guard let r = sendAndAwait(method: "account/login/start", params: ["type": "apiKey", "apiKey": key]) else { return false }
        if r["type"] != nil { authMode = "apikey"; return true }
        return false
    }

    /// Returns the OpenAI auth URL to open; call waitForLogin afterwards.
    func startChatGPTLogin() -> URL? {
        guard let r = sendAndAwait(method: "account/login/start", params: ["type": "chatgpt"]),
              let auth = r["authUrl"] as? String else { return nil }
        return URL(string: auth)
    }

    /// Reads events until login completes or `isCancelled` turns true (checked
    /// twice a second — Ctrl-C stays responsive even while the socket is quiet).
    func waitForLogin(isCancelled: @escaping () -> Bool) -> Bool {
        while true {
            if isCancelled() { return false }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let readable = poll(&p, 1, 500)
            if readable < 0 { return false }
            if readable == 0 { continue }
            guard let msg = readMessage() else { return false }
            if answerServerRequest(msg) { continue }
            if msg["method"] as? String == "account/login/completed",
               let params = msg["params"] as? [String: Any] {
                let ok = params["success"] as? Bool ?? false
                if ok { authMode = "chatgpt" }
                return ok
            }
            if msg["method"] as? String == "account/updated",
               let params = msg["params"] as? [String: Any],
               let mode = params["authMode"] as? String {
                authMode = mode; return true
            }
        }
    }

    func logout() {
        _ = sendAndAwait(method: "account/logout", params: [:])
        authMode = nil
    }

    // MARK: threads & turns

    func startThread(cwd: String, model: String? = nil, provider: String? = nil, local: Bool = false) -> String? {
        var params: [String: Any] = ["cwd": cwd]
        if let model { params["model"] = model }
        if let provider { params["modelProvider"] = provider }
        if local {
            params["baseInstructions"] = """
            You are Pocode, a coding assistant running on the user's iPhone. When asked to
            build or edit something, call write_file to save the actual code in the current
            workspace — do NOT just print the code in your reply.
            Wait for write_file to succeed before calling run_command to execute the file.
            Use relative paths. Report the files you saved and actual tool results.
            If a tool fails, report that failure rather than claiming you completed the task.
            """
            params["config"] = [
                "features.apps": false,
                "features.plugins": false,
                "features.goals": false,
                "features.shell_tool": false,
                "web_search": "disabled",
            ] as [String: Any]
            params["dynamicTools"] = [
                localTool("write_file", description: "Create or update a workspace file with UTF-8 text.",
                          arguments: ["path": "Path relative to the current directory.", "content": "Complete file contents."]),
                localTool("run_command", description: "Execute a command in the workspace and return its output.",
                          arguments: ["command": "A shell command such as python hello.py or ls."]),
            ]
        }
        guard let r = sendAndAwait(method: "thread/start", params: params) else { return nil }
        if let thread = r["thread"] as? [String: Any], let id = thread["id"] as? String { return id }
        return nil
    }

    private func localTool(_ name: String, description: String, arguments: [String: String]) -> [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": arguments.mapValues { ["type": "string", "description": $0] },
                "required": arguments.keys.sorted(),
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }

    func interruptTurn(threadId: String) {
        _ = request(method: "turn/interrupt", params: ["threadId": threadId])
    }

    /// Sends a prompt and streams the agent's work to `out` until the turn ends.
    func runTurn(threadId: String, prompt: String, localWorkspace: ShellContext? = nil,
                 out: @escaping (String) -> Void) {
        _ = request(method: "turn/start", params: [
            "threadId": threadId,
            "input": [["type": "text", "text": prompt]],
        ])
        var reasoningShown = false
        while true {
            guard let msg = readMessage() else { out("\r\n\u{1B}[31m(connection closed)\u{1B}[0m\r\n"); return }
            if msg["method"] as? String == "item/tool/call", let id = msg["id"], let localWorkspace {
                let params = msg["params"] as? [String: Any] ?? [:]
                let (success, result) = runLocalTool(params, workspace: localWorkspace)
                out("\r\n\(result.replacingOccurrences(of: "\n", with: "\r\n"))\r\n")
                reply(id: id, result: ["success": success, "contentItems": [["type": "inputText", "text": result]]])
                continue
            }
            if answerServerRequest(msg) { continue }
            guard let method = msg["method"] as? String,
                  let params = msg["params"] as? [String: Any] else { continue }
            switch method {
            case "item/started", "item/updated", "item/completed":
                if let item = params["item"] as? [String: Any] {
                    render(item, completed: method == "item/completed", reasoningShown: &reasoningShown, out: out)
                }
            case "error":
                if let error = params["error"] as? [String: Any], let m = error["message"] as? String {
                    out("\r\n\u{1B}[31m\(m)\u{1B}[0m\r\n")
                }
            case "turn/completed":
                if let turn = params["turn"] as? [String: Any], let status = turn["status"] as? String,
                   status == "failed", let e = turn["error"] as? [String: Any], let m = e["message"] as? String {
                    out("\r\n\u{1B}[31mTurn failed: \(m)\u{1B}[0m\r\n")
                }
                return
            default:
                break
            }
        }
    }

    private func runLocalTool(_ params: [String: Any], workspace: ShellContext) -> (Bool, String) {
        let arguments = params["arguments"] as? [String: String] ?? [:]
        let state = workspace.state
        switch params["tool"] as? String {
        case "write_file":
            guard let path = arguments["path"], !path.isEmpty, let content = arguments["content"] else {
                return (false, "write_file requires a path and content.")
            }
            do {
                let file = try state.sandbox.resolve(path, from: state.cwd)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: file, options: .atomic)
                return (true, "Saved \(state.sandbox.display(file))")
            } catch {
                return (false, "Write failed: \(error.localizedDescription)")
            }
        case "run_command":
            guard let command = arguments["command"], !command.isEmpty else {
                return (false, "run_command requires a command.")
            }
            let result = CodexHostBridge.execScript(command, cwd: state.cwd.path, workspaceRoot: state.sandbox.root)
            let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return (result.code == 0, "Exit \(result.code): \(output)")
        default:
            return (false, "Unknown local workspace tool.")
        }
    }

    private func render(_ item: [String: Any], completed: Bool,
                        reasoningShown: inout Bool, out: @escaping (String) -> Void) {
        guard let type = item["type"] as? String else { return }
        switch type {
        case "agentMessage":
            if completed, let text = item["text"] as? String {
                out("\r\n\(text.replacingOccurrences(of: "\n", with: "\r\n"))\r\n")
            }
        case "commandExecution":
            if !completed, let command = item["command"] as? String {
                out("\r\n\u{1B}[2m$ \(command)\u{1B}[0m\r\n")
            }
        case "fileChange":
            if !completed { out("\r\n\u{1B}[33m• editing files…\u{1B}[0m\r\n") }
        case "reasoning":
            if !reasoningShown { out("\r\n\u{1B}[2mthinking…\u{1B}[0m"); reasoningShown = true }
        default:
            break
        }
    }

    // MARK: JSON-RPC plumbing

    private func request(method: String, params: [String: Any]) -> Int {
        let id = nextId; nextId += 1
        sendRaw(["id": id, "method": method, "params": params])
        return id
    }

    private func reply(id: Any, result: [String: Any]) { sendRaw(["id": id, "result": result]) }

    private func sendRaw(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }
        sendText(text)
    }

    /// Sends a request and returns the matching response's `result` object.
    private func sendAndAwait(method: String, params: [String: Any]) -> [String: Any]? {
        awaitResponse(id: request(method: method, params: params))
    }

    /// Generic request — the settings UI (skills, MCP servers) and tests drive
    /// protocol methods this client has no dedicated wrapper for.
    func rawRequest(method: String, params: [String: Any]) -> [String: Any]? {
        sendAndAwait(method: method, params: params)
    }

    private func awaitResponse(id: Int) -> [String: Any]? {
        while let msg = readMessage() {
            if (msg["id"] as? Int) == id { return msg["result"] as? [String: Any] ?? [:] }
            _ = answerServerRequest(msg)
        }
        return nil
    }

    /// Server→client requests. Approvals are auto-accepted — the tools they
    /// gate already run confined to the workspace — and anything we don't
    /// understand gets a proper JSON-RPC error instead of a malformed reply
    /// (the codex engine rejects unknown decision values, killing the tool).
    private func answerServerRequest(_ msg: [String: Any]) -> Bool {
        guard let method = msg["method"] as? String, let id = msg["id"] else { return false }
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            reply(id: id, result: ["decision": "accept"])
        default:
            sendRaw(["id": id, "error": ["code": -32601, "message": "not supported by this client: \(method)"]])
        }
        return true
    }

    private func readMessage() -> [String: Any]? {
        while let text = readFrame() {
            if text.isEmpty { continue }
            if let data = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
        }
        return nil
    }

    // MARK: RFC 6455 framing

    private func sendText(_ text: String) {
        writeLock.lock(); defer { writeLock.unlock() }
        let payload = [UInt8](text.utf8)
        var frame: [UInt8] = [0x81]
        if payload.count < 126 {
            frame.append(UInt8(payload.count) | 0x80)
        } else if payload.count <= 0xFFFF {
            frame.append(126 | 0x80)
            frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127 | 0x80)
            var len = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $1 ^ mask[$0 % 4] })
        frame.withUnsafeBufferPointer { _ = write(fd, $0.baseAddress, $0.count) }
    }

    private func readUntil(marker: [UInt8]) -> String? {
        var data: [UInt8] = []
        var byte: UInt8 = 0
        while data.count < 16 * 1024 {
            if read(fd, &byte, 1) != 1 { return nil }
            data.append(byte)
            if data.count >= marker.count, Array(data.suffix(marker.count)) == marker {
                return String(bytes: data, encoding: .utf8)
            }
        }
        return nil
    }

    private func readFrame() -> String? {
        func readN(_ n: Int) -> [UInt8]? {
            var outBytes = [UInt8](); outBytes.reserveCapacity(n)
            var buf = [UInt8](repeating: 0, count: n)
            while outBytes.count < n {
                let got = read(fd, &buf, n - outBytes.count)
                if got <= 0 { return nil }
                outBytes.append(contentsOf: buf[0..<got])
            }
            return outBytes
        }
        guard let head = readN(2) else { return nil }
        let opcode = head[0] & 0x0F
        var length = Int(head[1] & 0x7F)
        if length == 126 { guard let ext = readN(2) else { return nil }; length = Int(ext[0]) << 8 | Int(ext[1]) }
        else if length == 127 {
            guard let ext = readN(8) else { return nil }
            length = ext.reduce(0) { $0 << 8 | Int($1) }
        }
        if head[1] & 0x80 != 0 { guard readN(4) != nil else { return nil } }
        guard let payload = length > 0 ? readN(length) : [] else { return nil }
        switch opcode {
        case 0x8: return nil
        case 0x9: sendPong(payload); return ""
        case 0x1: return String(bytes: payload, encoding: .utf8) ?? ""
        default: return ""
        }
    }

    private func sendPong(_ payload: [UInt8]) {
        writeLock.lock(); defer { writeLock.unlock() }
        var frame: [UInt8] = [0x8A, UInt8(payload.count) | 0x80]
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $1 ^ mask[$0 % 4] })
        frame.withUnsafeBufferPointer { _ = write(fd, $0.baseAddress, $0.count) }
    }
}
