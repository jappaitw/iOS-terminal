import XCTest
import WebKit
@testable import PocketCode

/// Drives the real `codex` shell command far enough to prove the embedded
/// engine starts and the terminal session reaches the sign-in menu. No network
/// credentials needed: we cancel at the login prompt.
final class CodexRuntimeTests: XCTestCase {
    @MainActor
    func testPocodeWritesAndRunsPythonWithLocalQwen() async throws {
        guard ProcessInfo.processInfo.environment["POCODE_LOCAL_E2E"] == "1" else {
            throw XCTSkip("Enable POCODE_LOCAL_E2E and install Qwen 1.5B to test pocode.")
        }
        let model = ProcessInfo.processInfo.environment["POCODE_MODEL"] ?? "qwen2.5-1.5b-instruct-q4_k_m"
        let store = ModelStore.shared
        store.refreshInstalled()
        guard store.installed.contains(model) else { throw XCTSkip("Local model \(model) is not installed.") }
        let previous = store.activeModelID
        store.activeModelID = model
        defer { store.activeModelID = previous }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pocode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let input = ShellInput()
        input.push("Use your tools to create hello.py containing print(\"POCODE_OK\"). Then use your tools to run python hello.py.")
        input.push("/exit")
        input.close()
        var services = ShellServices()
        services.runCodex = CodexRuntime.shellCommand
        let out = ShellOutput(), err = ShellOutput()
        let status = await ShellExecutor.run(try ShellParser.parse("pocode"), state: ShellState(root: root),
                                             terminal: out, terminalError: err, input: input, services: services)
        let transcript = String(decoding: out.data + err.data, as: UTF8.self)
        XCTAssertEqual(status, 0, transcript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("hello.py").path), transcript)
        XCTAssertTrue(transcript.contains("Saved ~/hello.py"), transcript)
        XCTAssertTrue(transcript.contains("Exit 0: POCODE_OK"), transcript)
    }

    @MainActor
    func testQwen3BCreatesRepairsAndPreviewsFallingBlocks() async throws {
        guard ProcessInfo.processInfo.environment["POCODE_GAME_E2E"] == "1" else {
            throw XCTSkip("Enable POCODE_GAME_E2E to run the Qwen falling-blocks acceptance test.")
        }
        let model = "qwen2.5-3b-instruct-q4_k_m"
        let store = ModelStore.shared
        store.refreshInstalled()
        guard store.installed.contains(model) else { throw XCTSkip("Qwen 3B is not installed.") }
        let previous = store.activeModelID
        store.activeModelID = model
        defer { store.activeModelID = previous }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = "Qwen3B-Blocks-\(UUID().uuidString.prefix(6))"
        let root = docs.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("GAME_WORKSPACE=\(name)")

        // Seed only the independent test. The model writes every playable asset.
        let contract = """
        from html.parser import HTMLParser
        from pathlib import Path

        class GamePage(HTMLParser):
            def __init__(self):
                super().__init__()
                self.tags = []

            def handle_starttag(self, tag, attrs):
                self.tags.append((tag, dict(attrs)))

        page = GamePage()
        page.feed(Path('index.html').read_text())
        ids = {attrs.get('id') for tag, attrs in page.tags if tag == 'button'}
        missing = {'left', 'right', 'rotate', 'drop', 'restart'} - ids
        assert not missing, 'CONTROL_MISSING: ' + ', '.join(sorted(missing))
        assert any(tag == 'canvas' and attrs.get('id') == 'board' for tag, attrs in page.tags)
        assert any(tag == 'link' and attrs.get('href') == 'style.css' for tag, attrs in page.tags)
        assert any(tag == 'script' and attrs.get('src') == 'game.js' for tag, attrs in page.tags)
        assert Path('style.css').stat().st_size > 0
        assert Path('game.js').stat().st_size > 0
        print('WEB_CONTRACT_OK')
        """
        try contract.write(to: root.appendingPathComponent("verify_game.py"), atomically: true, encoding: .utf8)

        let input = ShellInput()
        input.push("""
        Build a compact original falling-block puzzle in three files for a 6x10 canvas board.
        For this step only, use write_file to create game.js. Keep it short.
        Use a falling L-shaped piece, timed gravity, collision, stacking, line clear, and restart.
        Bind HTML element IDs board, left, right, rotate, drop (hard drop), and restart.
        Start at x=2. Expose window.gameState = () => ({x, y, locked}) for verification,
        where locked is the count of pieces placed since restart. Use no imports or external libraries.
        """.replacingOccurrences(of: "\n", with: " "))
        input.push("""
        Now use write_file to create index.html and style.css, keeping both short.
        index.html must link style.css, load game.js at the end of the body, and include canvas #board
        and touchscreen buttons with the IDs left, right, rotate, down, restart.
        For this first draft only use id="down" on the hard-drop button to seed an acceptance failure.
        Make the page fit an iPhone portrait screen. Do not run tests yet.
        """.replacingOccurrences(of: "\n", with: " "))
        input.push("""
        Use run_command to execute python verify_game.py now, before editing anything.
        If it fails, read the error, use write_file to fix the game files, then run python verify_game.py again.
        Do not edit verify_game.py. Stop after the test passes and report how to open index.html.
        """.replacingOccurrences(of: "\n", with: " "))
        input.push("/exit")
        input.close()

        var services = ShellServices()
        services.runCodex = CodexRuntime.shellCommand
        let out = ShellOutput(), err = ShellOutput()
        let status = await ShellExecutor.run(try ShellParser.parse("pocode"), state: ShellState(root: root),
                                             terminal: out, terminalError: err, input: input, services: services)
        let transcript = String(decoding: out.data + err.data, as: UTF8.self)
        print(transcript)
        XCTAssertEqual(status, 0, transcript)
        let failure = try XCTUnwrap(transcript.range(of: "AssertionError: CONTROL_MISSING:"), transcript)
        let success = try XCTUnwrap(transcript.range(of: "Exit 0: WEB_CONTRACT_OK"), transcript)
        XCTAssertLessThan(failure.lowerBound, success.lowerBound, transcript)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("verify_game.py"), encoding: .utf8), contract)
        XCTAssertTrue(["index.html", "style.css", "game.js"].allSatisfy { transcript.contains("Saved ~/\($0)") }, transcript)

        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 393, height: 700))
        web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        for _ in 0..<30 {
            if let isReady = try? await web.evaluateJavaScript("typeof window.gameState === 'function'"), isReady as? Bool == true {
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let result = try await web.evaluateJavaScript("""
        (() => {
            if (typeof window.gameState !== 'function' || !document.styleSheets.length) return false;
            const click = id => document.getElementById(id).click();
            click('restart');
            const start = window.gameState();
            click('left');
            const left = window.gameState();
            click('right');
            const right = window.gameState();
            click('rotate');
            click('drop');
            const drop = window.gameState();
            click('restart');
            return left.x === start.x - 1 && right.x === start.x &&
                   drop.locked === 1 && window.gameState().locked === 0;
        })()
        """)
        XCTAssertEqual(result as? Bool, true, "WebKit failed to run the game or its controls.")
        print("GAME_PREVIEW_OK=\(name)/index.html")
    }

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
        // Signed-out: EOF cancels the sign-in gate (exit 1). Signed-in (the
        // developer's simulator session persists in CODEX_HOME): EOF leaves
        // the prompt loop cleanly (exit 0).
        let expected: Int32 = stdout.contains("Signed in") ? 0 : 1
        XCTAssertEqual(status, expected, "stdout: \(stdout) stderr: \(stderr)")
    }
}
