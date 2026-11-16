import XCTest
import Runestone
@testable import PocketCode

final class LanguageTests: XCTestCase {
    func testDetectByExtension() {
        XCTAssertEqual(LanguageInfo.detect("/a/main.swift").name, "Swift")
        XCTAssertEqual(LanguageInfo.detect("/a/app.PY").name, "Python")
        XCTAssertEqual(LanguageInfo.detect("/a/x.tsx").name, "TypeScript React")
        XCTAssertEqual(LanguageInfo.detect("/a/c.yml").name, "YAML")
        XCTAssertEqual(LanguageInfo.detect("/a/unknown.zzz").name, "Plain Text")
        XCTAssertNil(LanguageInfo.detect("/a/notes.txt").treeSitter)
    }

    func testDetectBySpecialFileName() {
        XCTAssertEqual(LanguageInfo.detect("/r/Dockerfile").name, "Dockerfile")
        XCTAssertEqual(LanguageInfo.detect("/r/Makefile").name, "Makefile")
        XCTAssertEqual(LanguageInfo.detect("/home/u/.zshrc").name, "Shell Script")
        XCTAssertEqual(LanguageInfo.detect("/r/.gitignore").name, "Ignore")
    }

    func testImagesAreRecognised() {
        XCTAssertEqual(LanguageInfo.detect("/a/logo.png").name, "Image")
    }

    /// Diagnostic for PLAN 1.4: how much of the first-open delay is per-language setup.
    func testHighlightStateTiming() throws {
        let text = String(repeating: "func f(x: Int) -> Int { return x * 2 } // comment\n", count: 2000)
        let lang = try XCTUnwrap(LanguageInfo.detect("a.swift").treeSitter)
        var times: [Double] = []
        for _ in 0..<3 {
            let t0 = Date()
            _ = TextViewState(text: text, theme: DarkPlusTheme(), language: lang)
            times.append(Date().timeIntervalSince(t0))
        }
        print("TIMING TextViewState swift x3:", times.map { String(format: "%.3f", $0) })
        let py = try XCTUnwrap(LanguageInfo.detect("a.py").treeSitter)
        let t1 = Date()
        _ = TextViewState(text: "def f():\n    return 1\n", theme: DarkPlusTheme(), language: py)
        print("TIMING first python after swift:", String(format: "%.3f", Date().timeIntervalSince(t1)))
    }
}
