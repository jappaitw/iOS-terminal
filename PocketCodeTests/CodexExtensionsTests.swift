import XCTest
@testable import PocketCode

/// v1.3 groundwork: skills discovery and HTTP MCP servers, exercised through
/// the same protocol surface the settings UI will use.
final class CodexExtensionsTests: XCTestCase {
    static var codexHome: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("codex-home", isDirectory: true)
    }

    /// Boots the engine via the real `codex` command (idempotent per process)
    /// and returns a dedicated protocol connection.
    private func bootEngineAndConnect() async throws -> CodexProtocolClient {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ShellState(root: root)
        var services = ShellServices()
        services.runCodex = CodexRuntime.shellCommand
        let input = ShellInput(); input.close()
        let out = ShellOutput(), err = ShellOutput()
        _ = await ShellExecutor.run(try ShellParser.parse("codex"), state: state,
                                    terminal: out, terminalError: err, input: input, services: services)
        let stderr = String(decoding: err.data, as: UTF8.self)
        XCTAssertFalse(stderr.contains("could not connect"), stderr)

        let sock = "/private/tmp/pocketcode-\(getuid())/cx-\(getpid()).sock"
        let client = CodexProtocolClient(socketPath: sock)
        XCTAssertTrue(client.connect(), "could not open a second protocol connection")
        client.initialize()
        return client
    }

    func testPlantedSkillAppearsInSkillsList() async throws {
        let skillDir = Self.codexHome.appendingPathComponent("skills/pocode-test-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: pocode-test-skill\ndescription: proves skills load on iOS\n---\n\n# Body\n"
            .write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: skillDir) }

        let client = try await bootEngineAndConnect()
        let result = client.rawRequest(method: "skills/list", params: ["forceReload": true])
        let data = result?["data"] as? [[String: Any]]
        XCTAssertNotNil(data, "skills/list returned no data: \(result ?? [:])")
        XCTAssertTrue("\(data ?? [])".contains("pocode-test-skill"),
                      "planted skill missing: \(String(describing: data).prefix(600))")
    }

    func testHttpMcpServerIsRegisteredAndListed() async throws {
        // The settings UI will write exactly this; here we hand-write it and reload.
        let config = Self.codexHome.appendingPathComponent("config.toml")
        let original = try? String(contentsOf: config, encoding: .utf8)
        try FileManager.default.createDirectory(at: Self.codexHome, withIntermediateDirectories: true)
        let newConfig = (original ?? "") + "\n[mcp_servers.deepwiki]\nurl = \"https://mcp.deepwiki.com/mcp\"\n"
        try newConfig.write(to: config, atomically: true, encoding: .utf8)
        defer {
            if let original { try? original.write(to: config, atomically: true, encoding: .utf8) }
            else { try? FileManager.default.removeItem(at: config) }
        }

        let client = try await bootEngineAndConnect()
        _ = client.rawRequest(method: "config/mcpServer/reload", params: [:])
        let result = client.rawRequest(method: "mcpServerStatus/list", params: [:])
        let data = result?["data"] as? [[String: Any]]
        XCTAssertNotNil(data, "mcpServerStatus/list returned no data: \(result ?? [:])")
        let entry = (data ?? []).first { ($0["name"] as? String) == "deepwiki" }
        XCTAssertNotNil(entry, "deepwiki server not listed: \(String(describing: data).prefix(600))")
        // Connection state depends on the network; listing proves registration.
        print("[ext-test] deepwiki status: \(entry ?? [:])")
    }
}
