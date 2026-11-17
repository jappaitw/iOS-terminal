import SafariServices
import SwiftUI

/// Experimental harness for the embedded Codex app-server (pocket-codex).
/// Proves, on simulator / device: the server boots on a unix socket in the app
/// container, JSON-RPC round-trips, login works, and a turn produces agent
/// output. Nothing here touches the real PocketCode app.
@main
struct CodexLabApp: App {
    var body: some Scene { WindowGroup { CodexLabView() } }
}

struct CodexLabView: View {
    @StateObject private var client = CodexClient()
    @State private var apiKey = ""
    @State private var prompt = "Reply with exactly: HELLO FROM IOS"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CodexLab — \(client.status)").font(.headline)
            HStack {
                SecureField("OpenAI API key (sk-…)", text: $apiKey).textFieldStyle(.roundedBorder)
                Button("Login") { client.login(apiKey: apiKey) }.disabled(apiKey.isEmpty)
                Button("ChatGPT") { client.loginChatGPT() }
            }
            .sheet(item: $client.authURL) { item in
                SafariView(url: item.url)   // in-app: keeps our process (and the
                                            // localhost:1455 callback server) alive
            }
            HStack {
                TextField("Prompt", text: $prompt).textFieldStyle(.roundedBorder)
                Button("Run turn") { client.runTurn(prompt: prompt) }.disabled(!client.ready)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(client.log)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("end")
                }
                .onChange(of: client.log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .padding()
        .onAppear { client.startIfNeeded() }
    }
}

struct AuthURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// In-app browser for the ChatGPT OAuth flow; the app (and its localhost:1455
/// callback listener) stays alive while the user signs in.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

/// Minimal app-server JSON-RPC client over WebSocket-on-unix-socket.
final class CodexClient: ObservableObject {
    @Published var log = ""
    @Published var status = "idle"
    @Published var ready = false
    @Published var authURL: AuthURL?

    /// Confirms codex's OAuth callback server is reachable on loopback.
    func probeLoginServer(_ authURL: URL) {
        let port = URLComponents(url: authURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "redirect_uri" }?.value
            .flatMap(URL.init(string:))?.port ?? 1455
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse {
                self.append("login server listening on 127.0.0.1:\(port) (HTTP \(http.statusCode))")
            } else {
                self.append("login server probe: \(error?.localizedDescription ?? "no response")")
            }
        }.resume()
    }

    private var fd: Int32 = -1
    private var nextId = 1
    private var threadId: String?
    private var started = false
    private let writeLock = NSLock()

    func startIfNeeded() {
        guard !started else { return }
        started = true
        status = "starting server…"
        #if targetEnvironment(simulator)
        let sock = "/tmp/codexlab.sock"
        #else
        let sock = NSTemporaryDirectory() + "codex.sock"
        #endif
        unlink(sock)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let home = docs.appendingPathComponent("codex-home", isDirectory: true)
        let workspace = docs.appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        // Every Codex shell tool call runs through PocketCode's LocalShell
        // (and the embedded CPython) instead of fork/exec.
        HostShell.root = workspace
        pc_set_exec_handler({ requestPtr in
            guard let requestPtr else { return nil }
            let request = String(cString: requestPtr)
            print("[codexlab] host-exec request: \(request)")
            let response = HostShell.run(requestJSON: request)
            print("[codexlab] host-exec response: \(response.prefix(500))")
            return strdup(response)
        }, { response in free(response) })

        // Self-test: the exact path a Codex tool call takes, no model needed.
        Thread.detachNewThread {
            let probe = #"{"command":["bash","-lc","echo ping && python -c 'print(6*7)'"],"cwd":"\#(workspace.path)"}"#
            print("[codexlab] self-test: \(HostShell.run(requestJSON: probe))")
        }

        var err: UnsafeMutablePointer<CChar>?
        let rc = pc_start(sock, home.path, &err)
        guard rc == 0 else {
            append("pc_start failed (\(rc)): \(err.map { String(cString: $0) } ?? "?")")
            if let err { pc_free(err) }
            status = "server failed"
            return
        }
        append("pc_start ok")
        Thread.detachNewThread { [weak self] in self?.connectAndRun(sock) }
    }

    func login(apiKey: String) {
        send(method: "account/login/start", params: ["type": "apiKey", "apiKey": apiKey])
    }

    func loginChatGPT() {
        send(method: "account/login/start", params: ["type": "chatgpt"])
    }

    func runTurn(prompt: String) {
        guard let threadId else { append("no thread yet"); return }
        send(method: "turn/start", params: [
            "threadId": threadId,
            "input": [["type": "text", "text": prompt]],
        ])
    }

    // MARK: transport

    private func connectAndRun(_ path: String) {
        for attempt in 0..<40 {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                path.utf8CString.withUnsafeBytes { raw.copyBytes(from: $0.prefix(raw.count - 1)) }
            }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
            }
            if ok == 0 { break }
            close(fd); fd = -1
            usleep(250_000)
            if attempt == 39 { append("could not connect"); return }
        }

        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let upgrade = "GET / HTTP/1.1\r\nHost: codex\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n\r\n"
        _ = upgrade.withCString { write(fd, $0, strlen($0)) }
        guard let head = readUntil(marker: Array("\r\n\r\n".utf8)), head.contains("101") else {
            append("websocket upgrade refused"); close(fd); return
        }
        DispatchQueue.main.async { self.status = "connected" }

        send(method: "initialize", params: [
            "clientInfo": ["name": "pocketcode-lab", "title": "CodexLab", "version": "0.1.0"],
        ])
        send(method: "getAuthStatus", params: [:])

        while let text = readFrame() {
            if !text.isEmpty { handle(text) }
        }
        append("(connection closed)")
        close(fd)
    }

    private func handle(_ text: String) {
        append("← \(text.prefix(2000))")
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let method = obj["method"] as? String {
            // Server-initiated notifications / requests.
            if method == "item/completed" || method == "turn/completed" {
                DispatchQueue.main.async { self.status = "turn done — see log" }
            }
            if let id = obj["id"] {
                // Server request needing an answer (e.g. approvals): approve everything in the lab.
                reply(id: id, result: ["decision": "approved"])
            }
            return
        }
        // Responses by request id.
        if obj["result"] != nil, let result = obj["result"] as? [String: Any] {
            if let auth = result["authUrl"] as? String, let url = URL(string: auth) {
                append("auth URL received; opening in-app browser")
                probeLoginServer(url)
                DispatchQueue.main.async { self.authURL = AuthURL(url: url) }
            }
            if result["platformOs"] != nil {
                // initialize response → start a thread in the lab workspace.
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let ws = docs.appendingPathComponent("workspace").path
                send(method: "thread/start", params: ["cwd": ws])
            }
            if let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String {
                threadId = id
                DispatchQueue.main.async { self.ready = true; self.status = "thread \(id.prefix(8))… ready" }
                // Automation: LAB_AUTOKEY (+ optional LAB_AUTOPROMPT) logs in and
                // runs one turn unattended, for simctl-driven verification.
                let env = ProcessInfo.processInfo.environment
                if env["LAB_AUTOCHATGPT"] != nil { loginChatGPT() }
                if let key = env["LAB_AUTOKEY"] {
                    login(apiKey: key)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        self.runTurn(prompt: env["LAB_AUTOPROMPT"] ?? "Reply with exactly: HELLO FROM IOS")
                    }
                }
            } else if let id = result["threadId"] as? String ?? result["id"] as? String, threadId == nil,
                      id.count > 8 {
                threadId = id
                DispatchQueue.main.async { self.ready = true; self.status = "thread ready" }
            }
        }
    }

    // MARK: json-rpc plumbing

    private func send(method: String, params: [String: Any]) {
        let id = nextId; nextId += 1
        let msg: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }
        append("→ \(method)")
        sendText(text)
    }

    private func reply(id: Any, result: [String: Any]) {
        let msg: [String: Any] = ["id": id, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }
        sendText(text)
    }

    private func append(_ s: String) {
        print("[codexlab] \(s)")
        DispatchQueue.main.async { self.log += s + "\n" }
    }

    // MARK: RFC 6455 client framing

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

    /// One frame: text payload, "" for control frames, nil when closed.
    private func readFrame() -> String? {
        func readN(_ n: Int) -> [UInt8]? {
            var out = [UInt8](); out.reserveCapacity(n)
            var buf = [UInt8](repeating: 0, count: n)
            while out.count < n {
                let got = read(fd, &buf, n - out.count)
                if got <= 0 { return nil }
                out.append(contentsOf: buf[0..<got])
            }
            return out
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
        case 0x8: return nil // close
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
