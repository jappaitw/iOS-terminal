import XCTest
@testable import PocketCode

final class SearchAndGitTests: XCTestCase {
    func testParseGrepWithNull() {
        let out = "./src/a.swift\u{0}12:let x = 1\n./src/a.swift\u{0}30:  x += 1\n./odd:name.txt\u{0}3:has: colons\n"
        let r = SearchModel.parseGrep(out, root: "/home/u/proj")
        XCTAssertEqual(r.map(\.path), ["/home/u/proj/src/a.swift", "/home/u/proj/odd:name.txt"])
        XCTAssertEqual(r[0].matches.map(\.line), [12, 30])
        XCTAssertEqual(r[1].matches.first?.text, "has: colons")
    }

    func testParseGrepWithoutNull() {
        let r = SearchModel.parseGrep("./b.py:7:print(1)\ngarbage line\n", root: "/r")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].path, "/r/b.py")
        XCTAssertEqual(r[0].matches, [SearchMatch(line: 7, text: "print(1)")])
    }

    func testGrepScriptQuotesQuery() {
        let s = SearchModel.grepScript(query: "it's $(x)", options: SearchOptions(caseSensitive: false, wholeWord: true, regex: false), root: "/a b")
        XCTAssertTrue(s.hasPrefix("cd '/a b' && grep "))
        XCTAssertTrue(s.contains(" -i "))
        XCTAssertTrue(s.contains(" -w "))
        XCTAssertTrue(s.contains(" -F "))
        XCTAssertTrue(s.contains("-e 'it'\\''s $(x)' -- ."))
    }

    func testLineMatcher() throws {
        XCTAssertTrue(try LineMatcher(query: "foo.bar", options: .init()).matches("x FOO.BAR y"))
        XCTAssertFalse(try LineMatcher(query: "foo.bar", options: .init()).matches("fooXbar"))
        XCTAssertTrue(try LineMatcher(query: "foo.bar", options: .init(regex: true)).matches("fooXbar"))
        XCTAssertFalse(try LineMatcher(query: "Foo", options: .init(caseSensitive: true)).matches("foo"))
        XCTAssertFalse(try LineMatcher(query: "cat", options: .init(wholeWord: true)).matches("concat"))
        XCTAssertThrowsError(try LineMatcher(query: "(", options: .init(regex: true)))
    }

    func testParseGitStatus() throws {
        let out = "/repo\n## main...origin/main [ahead 2]\0 M src/app.swift\0?? notes/\0A  new.txt\0R  moved.txt\0old.txt\0UU conflict.c\0 D gone.md\0"
        let g = try XCTUnwrap(GitSnapshot.parse(out))
        XCTAssertEqual(g.branch, "main")
        XCTAssertEqual(g.files["/repo/src/app.swift"], .modified)
        XCTAssertEqual(g.files["/repo/notes"], .untracked)
        XCTAssertEqual(g.files["/repo/new.txt"], .added)
        XCTAssertEqual(g.files["/repo/moved.txt"], .renamed)
        XCTAssertNil(g.files["/repo/old.txt"], "rename source must not be read as its own entry")
        XCTAssertEqual(g.files["/repo/conflict.c"], .conflict)
        XCTAssertEqual(g.files["/repo/gone.md"], .deleted)
        XCTAssertEqual(g.folders["/repo/src"], .modified)
        XCTAssertEqual(g.folders["/repo"], .conflict, "a folder takes its most severe child")
    }

    func testGitBranchVariants() {
        XCTAssertEqual(GitSnapshot.parse("/r\n## No commits yet on dev\0")?.branch, "dev")
        XCTAssertEqual(GitSnapshot.parse("/r\n## HEAD (no branch)\0")?.branch, "HEAD (detached)")
        XCTAssertEqual(GitSnapshot.parse("/r\n## feature/x\0")?.branch, "feature/x")
        XCTAssertNil(GitSnapshot.parse(""), "not a repo → no snapshot")
    }

    @MainActor func testSettingsPersist() {
        let d = UserDefaults(suiteName: "pocketcode.tests.\(UUID())")!
        let a = AppSettings(defaults: d)
        XCTAssertEqual(a.indentLabel, "Spaces: 4")
        a.indentWidth = 2; a.indentWithTabs = true; a.terminalFontSize = 30
        a.clampTerminalFont(5)
        XCTAssertEqual(a.terminalFontSize, AppSettings.fontRange.upperBound)
        let b = AppSettings(defaults: d)
        XCTAssertEqual(b.indentWidth, 2)
        XCTAssertEqual(b.indentString, "\t")
        XCTAssertEqual(b.indentLabel, "Tab Size: 2")
    }
}
