import XCTest
@testable import PocketCode

/// Opt-in end-to-end acceptance: drives one real model turn through the full
/// stack (terminal session → engine → model → host-exec tools → workspace).
/// Costs real quota, so it only runs with TEST_RUNNER_POCODE_E2E=1 and an
/// existing signed-in session in CODEX_HOME.
final class CodexE2ETests: XCTestCase {
    func testOneTurnCreatesAndRunsHelloPy() async throws {
        guard ProcessInfo.processInfo.environment["POCODE_E2E"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_POCODE_E2E=1 to run the live acceptance turn")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ShellState(root: root)
        var services = ShellServices()
        services.runCodex = CodexRuntime.shellCommand
        services.runPython = PythonRuntime.shellCommand

        let input = ShellInput()
        input.push("Create hello.py that prints exactly POCODE_OK (nothing else), then run it with python and show the output.")
        input.push("/exit")
        input.close()
        let out = ShellOutput(), err = ShellOutput()
        let status = await ShellExecutor.run(try ShellParser.parse("codex"), state: state,
                                             terminal: out, terminalError: err,
                                             input: input, services: services)
        let stdout = String(decoding: out.data, as: UTF8.self)
        let stderr = String(decoding: err.data, as: UTF8.self)
        print("[e2e] status=\(status)\n[e2e] stdout:\n\(stdout)\n[e2e] stderr:\n\(stderr)")

        XCTAssertTrue(stdout.contains("Signed in"), "needs a signed-in session: \(stdout.prefix(300))")
        let hello = root.appendingPathComponent("hello.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hello.path),
                      "the agent should have created hello.py; stdout: \(stdout)")

        // The loop's hard evidence: our own embedded Python runs the agent's file.
        let out2 = ShellOutput(), err2 = ShellOutput()
        let pyStatus = await ShellExecutor.run(try ShellParser.parse("python hello.py"), state: state,
                                               terminal: out2, terminalError: err2,
                                               input: nil, services: services)
        XCTAssertEqual(pyStatus, 0, String(decoding: err2.data, as: UTF8.self))
        XCTAssertTrue(String(decoding: out2.data, as: UTF8.self).contains("POCODE_OK"))
    }
}
