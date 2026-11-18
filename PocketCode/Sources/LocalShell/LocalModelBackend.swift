import Foundation

/// When the user has chosen a local model, boots the embedded llama.cpp server
/// and registers it as a codex model provider. Returns nil when no local model
/// is active (the caller then uses cloud Codex).
enum LocalModelBackend {
    struct Active { let model: String; let provider: String }

    private static let lock = NSLock()
    private static var running: Active?
    private static let port: Int32 = 8080
    static let providerName = "pocodelocal"

    static func ensureRunning(out: (String) -> Void) async -> Active? {
        let activeID = await MainActor.run { ModelStore.shared.activeModelID }
        guard let activeID else { return nil }

        lock.lock()
        if let running { lock.unlock(); return running }
        lock.unlock()

        let (ggufPath, templateName) = await MainActor.run { () -> (String, String?) in
            let store = ModelStore.shared
            return (store.fileURL(for: activeID).path, store.template(for: activeID))
        }
        guard FileManager.default.fileExists(atPath: ggufPath) else {
            out("\u{1B}[33mLocal model file missing; falling back to cloud Codex.\u{1B}[0m\r\n")
            return nil
        }

        let template = templateName.flatMap { Bundle.main.path(forResource: $0, ofType: "jinja") }
        out("\u{1B}[2mStarting local model…\u{1B}[0m\r\n")
        let rc = pll_start(ggufPath, port, 32768, template)
        if rc != 0 {
            out("\u{1B}[33mLocal model already running or failed; using cloud Codex.\u{1B}[0m\r\n")
        }
        if await waitHealthy() {
            let active = Active(model: ggufPath, provider: providerName)
            lock.lock(); running = active; lock.unlock()
            out("\u{1B}[32m✓ Local model ready (offline).\u{1B}[0m\r\n")
            return active
        }
        out("\u{1B}[33mLocal model didn't become ready; using cloud Codex.\u{1B}[0m\r\n")
        return nil
    }

    static func registerProviderIfNeeded(home: URL) {
        let config = home.appendingPathComponent("config.toml")
        var text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        guard !text.contains("model_providers.\(providerName)") else { return }
        text += """

        [model_providers.\(providerName)]
        name = "Pocode Local"
        base_url = "http://127.0.0.1:\(port)/v1"
        wire_api = "responses"
        """
        try? text.write(to: config, atomically: true, encoding: .utf8)
    }

    private static func waitHealthy() async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<180 {
            if let (data, resp) = try? await URLSession.shared.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               String(decoding: data, as: UTF8.self).contains("ok") {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }
}
