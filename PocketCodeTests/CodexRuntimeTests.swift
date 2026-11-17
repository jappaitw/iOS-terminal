import XCTest
@testable import PocketCode

/// Drives the real `codex` shell command far enough to prove the embedded
/// engine starts and the terminal session reaches the sign-in menu. No network
/// credentials needed: we cancel at the login prompt.
final class CodexRuntimeTests: XCTestCase {
    func testCodexEngineStartsAndShowsLoginMenu() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = ShellState(root: root)
        var services = ShellServices()
        services.runCodex = CodexRuntime.shellCommand

        // "9" is an invalid menu choice (prints a hint), then EOF cancels sign-in.
        let input = ShellInput()
        input.push("9")
        input.close()

        let out = ShellOutput(), err = ShellOutput()
        let status = await ShellExecutor.run(try ShellParser.parse("codex"), state: state,
                                             terminal: out, terminalError: err,
                                             input: input, services: services)
        let stdout = String(decoding: out.data, as: UTF8.self)
        let stderr = String(decoding: err.data, as: UTF8.self)

        XCTAssertFalse(stderr.contains("could not connect"), "engine failed to start: \(stderr)")
        XCTAssertFalse(stderr.contains("codex failed to start"), stderr)
        XCTAssertTrue(stdout.contains("Codex"), "missing banner: \(stdout)")
        XCTAssertTrue(stdout.contains("[1] ChatGPT") || stdout.contains("Signed in"),
                      "expected the sign-in gate or an existing session: \(stdout)")
        XCTAssertEqual(status, 1, "cancelled sign-in should exit 1; stderr: \(stderr)")
    }
}
