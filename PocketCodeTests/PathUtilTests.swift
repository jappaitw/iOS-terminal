import XCTest
@testable import PocketCode

final class PathUtilTests: XCTestCase {
    func testJoin() {
        XCTAssertEqual(PathUtil.join("/home/u", "a.txt"), "/home/u/a.txt")
        XCTAssertEqual(PathUtil.join("/home/u/", "a.txt"), "/home/u/a.txt")
        XCTAssertEqual(PathUtil.join("/", "etc"), "/etc")
    }

    func testParentAndName() {
        XCTAssertEqual(PathUtil.parent("/home/u/a.txt"), "/home/u")
        XCTAssertEqual(PathUtil.parent("/etc"), "/")
        XCTAssertEqual(PathUtil.parent("/"), "/")
        XCTAssertEqual(PathUtil.name("/home/u/a.txt"), "a.txt")
    }

    func testSortedPutsFoldersFirstThenNaturalOrder() {
        let items = [
            FileItem(name: "file10.txt", path: "/file10.txt", isDirectory: false),
            FileItem(name: "zeta", path: "/zeta", isDirectory: true),
            FileItem(name: "file2.txt", path: "/file2.txt", isDirectory: false),
            FileItem(name: "Alpha", path: "/Alpha", isDirectory: true),
        ]
        XCTAssertEqual(PathUtil.sorted(items).map(\.name), ["Alpha", "zeta", "file2.txt", "file10.txt"])
    }

    func testShellQuote() {
        XCTAssertEqual(PathUtil.shellQuote("/plain/path"), "'/plain/path'")
        XCTAssertEqual(PathUtil.shellQuote("/it's here"), "'/it'\\''s here'")
        XCTAssertEqual(PathUtil.shellQuote("$(rm -rf ~)"), "'$(rm -rf ~)'")
    }
}
