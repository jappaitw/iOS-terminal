import XCTest
@testable import PocketCode

/// The agent-facing tool set: sed, rg, and curl's offline behaviour.
final class BuiltinsExtraTests: XCTestCase {
    var root: URL!
    var state: ShellState!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("extra-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        state = ShellState(root: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func sh(_ line: String, input: String? = nil) async throws -> (Int32, String, String) {
        let out = ShellOutput(), err = ShellOutput()
        let shellInput: ShellInput? = input.map { text in
            let i = ShellInput()
            text.split(separator: "\n", omittingEmptySubsequences: false).forEach { i.push(String($0)) }
            i.close()
            return i
        }
        let status = await ShellExecutor.run(try ShellParser.parse(line), state: state,
                                             terminal: out, terminalError: err,
                                             input: shellInput, services: ShellServices())
        func clean(_ d: Data) -> String {
            String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        }
        return (status, clean(out.data), clean(err.data))
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testSedBasics() async throws {
        try write("a.txt", "hello world\nhello again\n")
        var r = try await sh("sed 's/hello/hi/' a.txt")
        XCTAssertEqual(r.1, "hi world\nhi again\n")

        r = try await sh("sed 's/l/L/g' a.txt")
        XCTAssertEqual(r.1, "heLLo worLd\nheLLo again\n")

        _ = try await sh("sed -i 's/world/pocode/' a.txt")
        let changed = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(changed, "hello pocode\nhello again\n")

        r = try await sh("echo one two | sed 's/\\(one\\) \\(two\\)/\\2 \\1/'")
        XCTAssertEqual(r.1, "two one\n")
    }

    func testRgDelegatesToGrepRecursively() async throws {
        try write("x.py", "needle here\nnothing\n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write("sub/y.txt", "another needle\n")
        let r = try await sh("rg needle")
        XCTAssertEqual(r.0, 0, r.2)
        XCTAssertTrue(r.1.contains("x.py:1:needle here"), r.1)
        XCTAssertTrue(r.1.contains("sub/y.txt:1:another needle"), r.1)
        // ripgrep-isms that we ignore shouldn't break the call.
        let quiet = try await sh("rg --no-heading -S needle x.py")
        XCTAssertEqual(quiet.0, 0, quiet.2)
    }

    func testCurlArgumentHandlingOffline() async throws {
        var r = try await sh("curl")
        XCTAssertEqual(r.0, 2)
        XCTAssertTrue(r.2.contains("no URL"), r.2)

        r = try await sh("curl ftp://example.com/file")
        XCTAssertEqual(r.0, 3)

        // Output path outside the workspace must be refused before any I/O.
        r = try await sh("curl -o ../escape.txt https://127.0.0.1:1/x --max-time 1")
        XCTAssertNotEqual(r.0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.txt").path))
    }
}
