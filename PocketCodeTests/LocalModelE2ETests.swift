import XCTest
@testable import PocketCode

/// Opt-in end-to-end for the local-model path: the embedded llama.cpp server
/// serves /v1/responses to the codex engine, a Qwen model drives the turn,
/// and tools execute through LocalShell + embedded Python — fully offline,
/// no account. Needs the GGUF planted at Documents/models/ and
/// TEST_RUNNER_POCODE_LOCAL_E2E=1 (runs in its own process so the engine
/// boots after the provider config is written).
final class LocalModelE2ETests: XCTestCase {
    private let port: Int32 = 8089

    func testLocalQwenDrivesToolsToPocodeOK() async throws {
        guard ProcessInfo.processInfo.environment["POCODE_LOCAL_E2E"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_POCODE_LOCAL_E2E=1 (and plant the GGUF) to run")
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let models = (try? FileManager.default.contentsOfDirectory(at: docs.appendingPathComponent("models"),
                                                                   includingPropertiesForKeys: nil)) ?? []
        guard let gguf = models.first(where: { $0.pathExtension == "gguf" }) else {
            throw XCTSkip("no GGUF in Documents/models")
        }

        // 1. Provider config BEFORE the engine boots (fresh process per run).
        let home = CodexRuntime.home
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent("config.toml")
        var text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        if !text.contains("model_providers.pocodelocal") {
            text += """

            [model_providers.pocodelocal]
            name = "Pocode Local"
            base_url = "http://127.0.0.1:\(port)/v1"
            wire_api = "responses"
            """
            try text.write(to: config, atomically: true, encoding: .utf8)
        }

        // 2. Start the embedded llama server and wait for the model to load.
        // codex's system preamble alone is ~10k tokens; Qwen2.5 supports 32k.
        // Qwen2.5-Coder's baked-in template lacks <tool_call> markup, so hand it
        // the tool-aware Qwen2.5 template bundled in Resources.
        let tmpl = Bundle(for: Self.self).path(forResource: "qwen2.5", ofType: "jinja")
            ?? Bundle.main.path(forResource: "qwen2.5", ofType: "jinja")
        print("[local-e2e] chat template: \(tmpl ?? "NONE")")
        XCTAssertEqual(pll_start(gguf.path, port, 32768, tmpl), 0)
        let modelID = try await waitForServer()
        print("[local-e2e] server ready, model id: \(modelID)")

        // Layer probe: minimal /v1/responses with ONE simple tool — separates
        // "llama+Qwen can't tool-call" from "codex's prompt overwhelms it".
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        probe.httpMethod = "POST"
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "input": "Create the file hello.py containing print(\"POCODE_OK\") using the write_file tool.",
            "tools": [[
                "type": "function",
                "name": "write_file",
                "description": "Write content to a file",
                "parameters": [
                    "type": "object",
                    "properties": ["path": ["type": "string"], "content": ["type": "string"]],
                    "required": ["path", "content"],
                ],
            ]],
            "stream": false,
        ])
        let (probeData, _) = try await URLSession.shared.data(for: probe)
        print("[local-e2e] PROBE: \(String(decoding: probeData, as: UTF8.self).prefix(1000))")

        // Reference probe: the mature chat/completions path with nested tools.
        var chat = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        chat.httpMethod = "POST"
        chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
        chat.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "messages": [["role": "user", "content": "Create the file hello.py containing print(\"POCODE_OK\") using the write_file tool."]],
            "tools": [[
                "type": "function",
                "function": [
                    "name": "write_file",
                    "description": "Write content to a file",
                    "parameters": [
                        "type": "object",
                        "properties": ["path": ["type": "string"], "content": ["type": "string"]],
                        "required": ["path", "content"],
                    ],
                ],
            ]],
            "stream": false,
        ])
        let (chatData, _) = try await URLSession.shared.data(for: chat)
        print("[local-e2e] CHATPROBE: \(String(decoding: chatData, as: UTF8.self).prefix(1000))")

        // 3. Codex engine + a thread pinned to the local provider.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ShellState(root: root)
        var services = ShellServices()
        services.runCodex = CodexRuntime.shellCommand
        services.runPython = PythonRuntime.shellCommand
        let boot = ShellInput(); boot.close()
        let bootOut = ShellOutput(), bootErr = ShellOutput()
        _ = await ShellExecutor.run(try ShellParser.parse("codex"), state: state,
                                    terminal: bootOut, terminalError: bootErr,
                                    input: boot, services: services)
        XCTAssertFalse(String(decoding: bootErr.data, as: UTF8.self).contains("could not connect"))

        let sock = "/private/tmp/pocketcode-\(getuid())/cx-\(getpid()).sock"
        let client = CodexProtocolClient(socketPath: sock)
        XCTAssertTrue(client.connect())
        client.initialize()

        guard let started = client.rawRequest(method: "thread/start", params: [
            "cwd": root.path, "model": modelID, "modelProvider": "pocodelocal",
        ]), let thread = started["thread"] as? [String: Any], let threadId = thread["id"] as? String else {
            return XCTFail("thread/start with local provider failed")
        }
        print("[local-e2e] thread \(threadId) on local provider")

        // 4. One real turn, fully offline.
        var transcript = ""
        client.runTurn(threadId: threadId,
                       prompt: "Create hello.py that prints exactly POCODE_OK (nothing else), then run it with python and show the output.") { chunk in
            transcript += chunk
        }
        print("[local-e2e] transcript:\n\(transcript)")

        let hello = root.appendingPathComponent("hello.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hello.path),
                      "agent did not create hello.py; transcript: \(transcript.prefix(800))")
        let out = ShellOutput(), err = ShellOutput()
        let status = await ShellExecutor.run(try ShellParser.parse("python hello.py"), state: state,
                                             terminal: out, terminalError: err, input: nil, services: services)
        XCTAssertEqual(status, 0, String(decoding: err.data, as: UTF8.self))
        XCTAssertTrue(String(decoding: out.data, as: UTF8.self).contains("POCODE_OK"))
    }

    /// Polls /health then fetches the model id from /v1/models.
    private func waitForServer() async throws -> String {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let (data, response) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!),
               (response as? HTTPURLResponse)?.statusCode == 200,
               String(decoding: data, as: UTF8.self).contains("ok") {
                let (models, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
                if let obj = try? JSONSerialization.jsonObject(with: models) as? [String: Any],
                   let list = obj["data"] as? [[String: Any]], let id = list.first?["id"] as? String {
                    return id
                }
                return "default"
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw XCTSkip("llama server did not become healthy in time")
    }
}
