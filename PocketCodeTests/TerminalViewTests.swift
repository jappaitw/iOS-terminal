import XCTest
import UIKit
import SwiftTerm
@testable import PocketCode

@MainActor
final class TerminalViewTests: XCTestCase {
    /// UIKit asks `hasText` through the UIKeyInput (Objective-C) protocol to decide whether
    /// holding the keyboard's delete key keeps repeating. Our subclass must answer true even
    /// though nothing is buffered locally; stock SwiftTerm answers false.
    func testHoldToDeleteSeesText() {
        let stock = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let ours = PocketTerminalView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertFalse((stock as UIKeyInput).hasText, "precondition: stock view reports no text when empty")
        XCTAssertTrue((ours as UIKeyInput).hasText)
    }
}

final class TerminalLinkScannerTests: XCTestCase {
    typealias L = TerminalLinkScanner.Line

    func testSoftWrappedURLIsJoined() {
        let cols = 20
        let lines = [L(text: "Visit:", wrapped: false),
                     L(text: "https://claude.com/c", wrapped: false),
                     L(text: "ai/oauth?code=true&c", wrapped: true),
                     L(text: "lient=abc", wrapped: true),
                     L(text: "", wrapped: false)]
        XCTAssertEqual(TerminalLinkScanner.links(in: lines, cols: cols),
                       ["https://claude.com/cai/oauth?code=true&client=abc"])
    }

    func testHardBreakAtRightEdgeIsJoined() {
        // TUIs (Ink) may print explicit newlines exactly at the terminal width.
        let cols = 20
        let lines = [L(text: "https://example.com/", wrapped: false),
                     L(text: "path%2Fto?x=1", wrapped: false),
                     L(text: "Paste code here >", wrapped: false)]
        XCTAssertEqual(TerminalLinkScanner.links(in: lines, cols: cols), ["https://example.com/path%2Fto?x=1"])
    }

    func testShortLinesAreNotJoinedAndPunctuationTrimmed() {
        let lines = [L(text: "see https://a.dev/x).", wrapped: false),
                     L(text: "next line", wrapped: false),
                     L(text: "and http://b.test:8080/y,", wrapped: false)]
        XCTAssertEqual(TerminalLinkScanner.links(in: lines, cols: 80), ["https://a.dev/x", "http://b.test:8080/y"])
    }

    func testDisplayShortensQuery() {
        XCTAssertEqual(TerminalLinks.display("https://claude.com/cai/oauth/authorize?code=true"), "claude.com/cai/oauth/authorize?…")
    }
}
