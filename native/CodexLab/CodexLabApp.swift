import SwiftUI

/// Experimental harness for the embedded Codex app-server (pocket-codex).
/// Proves, on simulator / device: pc_start() boots the server on a unix socket
/// in the app container, and a JSON-RPC `initialize` handshake round-trips.
/// Nothing here touches the real PocketCode app.
@main
struct CodexLabApp: App {
    var body: some Scene { WindowGroup { CodexLabView() } }
}

struct CodexLabView: View {
    @State private var log = "CodexLab — embedded Codex app-server PoC\n"
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("pocket-codex ABI v\(pc_abi_version())").font(.headline)
            Button(running ? "Server running" : "Start server + initialize") { start() }
                .disabled(running)
                .buttonStyle(.borderedProminent)
            ScrollView {
                Text(log)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .onAppear { if !running { start() } }
    }

    private func append(_ s: String) {
        print("[codexlab] \(s)")
        DispatchQueue.main.async { log += s + "\n" }
    }

    private func start() {
        running = true
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let home = docs.appendingPathComponent("codex-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // sockaddr_un caps paths at ~104 bytes. The device container's tmp fits;
        // the simulator's host-side path doesn't, so use the host /tmp there.
        #if targetEnvironment(simulator)
        let sock = "/tmp/codexlab.sock"
        #else
        let sock = NSTemporaryDirectory() + "codex.sock"
        #endif
        unlink(sock)

        var err: UnsafeMutablePointer<CChar>?
        let rc = pc_start(sock, home.path, &err)
        if rc != 0 {
            append("pc_start failed (\(rc)): \(err.map { String(cString: $0) } ?? "?")")
            if let err { pc_free(err) }
            running = false
            return
        }
        append("pc_start ok → \(sock)")
        Thread.detachNewThread { handshake(sock) }
    }

    private func handshake(_ path: String) {
        // The server needs a moment to bind the socket; retry briefly.
        var fd: Int32 = -1
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
            if attempt == 39 { append("could not connect to \(path)") ; return }
        }
        append("socket connected")

        // The app-server's unix-socket transport speaks WebSocket (tungstenite
        // accept). Minimal RFC 6455 client: HTTP upgrade, then masked text frames.
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let upgrade = "GET / HTTP/1.1\r\nHost: codex\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n\r\n"
        _ = upgrade.withCString { write(fd, $0, strlen($0)) }
        guard let head = readUntil(fd, marker: Array("\r\n\r\n".utf8)), head.contains("101") else {
            append("websocket upgrade refused"); close(fd); return
        }
        append("websocket upgraded")

        sendText(fd, """
        {"id":1,"method":"initialize","params":{"clientInfo":{"name":"pocketcode-lab","title":"CodexLab","version":"0.1.0"}}}
        """)
        append("→ initialize sent, waiting for reply…")

        while let text = readFrame(fd) {
            append("← \(text)")
        }
        append("(connection closed)")
        close(fd)
    }

    private func readUntil(_ fd: Int32, marker: [UInt8]) -> String? {
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

    private func sendText(_ fd: Int32, _ text: String) {
        let payload = [UInt8](text.utf8)
        var frame: [UInt8] = [0x81] // FIN + text
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

    /// Reads one frame; returns text payload, "" for control frames, nil when closed.
    private func readFrame(_ fd: Int32) -> String? {
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
        if head[1] & 0x80 != 0 { guard readN(4) != nil else { return nil } } // server frames shouldn't mask
        guard let payload = length > 0 ? readN(length) : [] else { return nil }
        if opcode == 0x8 { return nil } // close
        if opcode == 0x1 { return String(bytes: payload, encoding: .utf8) ?? "" }
        return "" // ping/pong/binary ignored in the lab
    }
}
