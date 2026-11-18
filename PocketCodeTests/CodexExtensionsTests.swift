import XCTest
@testable import PocketCode

/// v1.3 groundwork: proves the engine's skills discovery works on iOS with a
/// planted CODEX_HOME skill, via the same protocol the settings UI will use.
final class CodexExtensionsTests: XCTestCase {
    func testPlantedSkillAppearsInSkillsList() async throws {
        // Plant a skill where the engine looks: Documents/codex-home/skills/<name>/SKILL.md.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let skillDir = docs.appendingPathComponent("codex-home/skills/pocode-test-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: pocode-test-skill\ndescription: proves skills load on iOS\n---\n\n# Body\n"
            .write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: skillDir) }

        // Boot the engine exactly like the `codex` command does (EOF cancels sign-in).
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
        XCTAssertFalse(String(decoding: err.data, as: UTF8.self).contains("could not connect"),
                       String(decoding: err.data, as: UTF8.self))

        // Our own protocol connection to the same in-process engine.
        let sock = "/private/tmp/pocketcode-\(getuid())/cx-\(getpid()).sock"
        let client = CodexProtocolClient(socketPath: sock)
        XCTAssertTrue(client.connect(), "could not connect a second protocol client")
        client.initialize()

        let result = client.rawRequest(method: "skills/list", params: ["forceReload": true])
        let data = result?["data"] as? [[String: Any]]
        XCTAssertNotNil(data, "skills/list returned no data: \(result ?? [:])")
        let names = (data ?? []).compactMap { entry -> String? in
            (entry["name"] as? String)
                ?? ((entry["skill"] as? [String: Any])?["name"] as? String)
                ?? ((entry["metadata"] as? [String: Any])?["name"] as? String)
        }
        XCTAssertTrue(names.contains("pocode-test-skill") ||
                      "\(data ?? [])".contains("pocode-test-skill"),
                      "planted skill missing; got: \(names), raw: \(String(describing: data).prefix(600))")
    }
}
