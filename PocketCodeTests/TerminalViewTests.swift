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
