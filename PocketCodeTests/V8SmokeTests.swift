import XCTest
@testable import PocketCode

/// Isolation probe for the V8 code-mode blocker: initialise V8 and make one
/// isolate, with none of codex around it. If this fails, the denoland iOS V8
/// prebuilt itself is the problem; if it passes, codex's usage is.
final class V8SmokeTests: XCTestCase {
    /// Guards the file-save tool: apply-patch's bash query must compile against
    /// OUR grammar, not Runestone's older colliding one.
    func testBashToolQueryParses() throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = pc_bash_tool_smoketest(&err)
        let message = err.map { String(cString: $0) } ?? ""
        if let err { pc_free(err) }
        print("[bash-tool-smoke] rc=\(rc) msg=\(message)")
        XCTAssertEqual(rc, 0, "apply-patch bash query failed: \(message)")
    }

    func testV8Initialises() throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = pc_v8_smoketest(&err)
        let message = err.map { String(cString: $0) } ?? ""
        if let err { pc_free(err) }
        print("[v8-smoke] rc=\(rc) msg=\(message)")
        XCTAssertEqual(rc, 0, "V8 failed to initialise in isolation: \(message)")
    }
}
