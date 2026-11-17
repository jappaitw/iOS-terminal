import XCTest
@testable import PocketCode

/// Runs the embedded CPython through the local shell, in the simulator / on device.
final class PythonRuntimeTests: XCTestCase {
    var root: URL!
    var state: ShellState!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("py-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        state = ShellState(root: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ name: String, _ text: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func sh(_ line: String, input: [String]? = nil, onContext: @escaping (ShellContext) -> Void = { _ in }) async throws -> (Int32, String, String) {
        let out = ShellOutput(), err = ShellOutput()
        var services = ShellServices()
        services.runPython = PythonRuntime.shellCommand
        let shellInput: ShellInput? = input.map { lines in
            let i = ShellInput(); lines.forEach { i.push($0) }; i.close(); return i
        }
        let status = await ShellExecutor.run(try ShellParser.parse(line), state: state, terminal: out, terminalError: err,
                                             input: shellInput, services: services, onContext: onContext)
        return (status, String(decoding: out.data, as: UTF8.self), String(decoding: err.data, as: UTF8.self))
    }

    func testAcceptanceHelloFromPocketCode() async throws {
        try write("main.py", "print(\"Hello from PocketCode!\")\n")
        let r = try await sh("python main.py")
        XCTAssertEqual(r.0, 0, r.2)
        XCTAssertEqual(r.1, "Hello from PocketCode!\n")
    }

    func testArgsExitCodesAndDashC() async throws {
        try write("args.py", "import sys\nprint(sys.argv)\nsys.exit(3)\n")
        var r = try await sh("python args.py one 'two words'")
        XCTAssertEqual(r.0, 3)
        XCTAssertEqual(r.1, "['args.py', 'one', 'two words']\n")
        r = try await sh("python3 -c 'import sys; print(sum(range(10)), sys.platform)'")
        XCTAssertEqual(r.1, "45 ios\n")
        r = try await sh("python -V")
        XCTAssertTrue(r.1.hasPrefix("Python 3."), r.1)
        r = try await sh("python missing.py")
        XCTAssertEqual(r.0, 2)
        XCTAssertTrue(r.2.contains("can't open file"))
    }

    func testTracebackShowsOnlyUserCode() async throws {
        try write("boom.py", "def f():\n    return 1 / 0\n\nf()\n")
        let r = try await sh("python boom.py")
        XCTAssertEqual(r.0, 1)
        XCTAssertTrue(r.2.contains("ZeroDivisionError"), r.2)
        XCTAssertTrue(r.2.contains("boom.py\", line 2"), r.2)
        XCTAssertFalse(r.2.contains("pocketcode_runner"), "STDERR<<" + r.2 + ">>")
        XCTAssertFalse(r.2.contains("runpy"), r.2)
    }

    func testStdinFromPipeAndTerminal() async throws {
        try write("greet.py", "name = input('Name? ')\nprint(f'Hi {name}')\n")
        var r = try await sh("echo Bob | python greet.py")
        XCTAssertEqual(r.1, "Name? Hi Bob\n")
        r = try await sh("python greet.py", input: ["Alice"])
        XCTAssertEqual(r.1, "Name? Hi Alice\n")
        r = try await sh("python greet.py > out.txt", input: ["Zoe"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("out.txt"), encoding: .utf8), "Name? Hi Zoe\n")
    }

    func testWorkspaceGuard() async throws {
        try write("escape.py", """
        import os
        results = []
        for label, action in [
            ("read /etc/hosts", lambda: open('/etc/hosts').read()),
            ("write outside", lambda: open(os.path.join('..', 'x.txt'), 'w')),
            ("list /", lambda: os.listdir('/')),
            ("ctypes", lambda: __import__('ctypes').CDLL(None)),
            ("subprocess", lambda: __import__('subprocess').run(['ls'])),
        ]:
            try:
                action()
                results.append(label + ': ALLOWED')
            except (PermissionError, OSError, RuntimeError) as e:
                results.append(label + ': blocked')
        open('inside.txt', 'w').write('ok')
        os.makedirs('sub/dir', exist_ok=True)
        print('\\n'.join(results))
        print(open('inside.txt').read(), sorted(os.listdir('.')))
        """)
        let r = try await sh("python escape.py")
        XCTAssertEqual(r.0, 0, r.2)
        XCTAssertFalse(r.1.contains("ALLOWED"), r.1)
        XCTAssertTrue(r.1.contains("ok ['escape.py', 'inside.txt', 'sub']"), r.1)
    }

    func testEditedModulesAreReimported() async throws {
        try write("helper.py", "VALUE = 1\n")
        try write("main.py", "import helper\nprint(helper.VALUE)\n")
        var r = try await sh("python main.py")
        XCTAssertEqual(r.1, "1\n")
        try write("helper.py", "VALUE = 2\n")
        r = try await sh("python main.py")
        XCTAssertEqual(r.1, "2\n")
    }

    func testCtrlCInterruptsBusyLoop() async throws {
        try write("spin.py", "print('start', flush=True)\nwhile True:\n    pass\n")
        var context: ShellContext?
        let lock = NSLock()
        Task.detached {
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                lock.lock(); let c = context; lock.unlock()
                if let h = c?.interruptHandler { try? await Task.sleep(nanoseconds: 300_000_000); h(); return }
            }
        }
        let r = try await sh("python spin.py") { ctx in lock.lock(); context = ctx; lock.unlock() }
        XCTAssertEqual(r.0, 130, r.2)
        XCTAssertTrue(r.2.contains("KeyboardInterrupt"), r.2)
        // The interpreter is still usable afterwards.
        let again = try await sh("python -c 'print(42)'")
        XCTAssertEqual(again.1, "42\n")
    }

    func testStandardLibraryAndUnittest() async throws {
        try write("calc.py", "def add(a, b):\n    return a + b\n")
        try write("test_calc.py", """
        import unittest, json, sqlite3, hashlib, decimal, datetime, re, collections
        from calc import add

        class T(unittest.TestCase):
            def test_add(self): self.assertEqual(add(2, 3), 5)
            def test_stdlib(self):
                db = sqlite3.connect(':memory:'); db.execute('create table t(x)'); db.execute('insert into t values (1)')
                self.assertEqual(db.execute('select sum(x) from t').fetchone()[0], 1)
                self.assertEqual(hashlib.sha256(b'a').hexdigest()[:8], 'ca978112')
                self.assertEqual(json.loads('[1]'), [1])
            def test_fails(self): self.assertEqual(add(1, 1), 3)

        if __name__ == '__main__':
            unittest.main()
        """)
        let r = try await sh("python -m unittest test_calc")
        XCTAssertEqual(r.0, 1, r.2)
        XCTAssertTrue(r.2.contains("Ran 3 tests"), r.2)
        XCTAssertTrue(r.2.contains("FAILED (failures=1)"), r.2)
    }

    func testREPL() async throws {
        let r = try await sh("python", input: ["x = 6 * 7", "print(x)", "1/0", "x + 1"])
        XCTAssertEqual(r.0, 0, r.2)
        XCTAssertTrue(r.1.contains("42"), r.1)
        XCTAssertTrue(r.1.contains("43"), r.1)
        XCTAssertTrue(r.2.contains("ZeroDivisionError"), r.2)
    }
}
