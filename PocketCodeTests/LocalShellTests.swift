import XCTest
@testable import PocketCode

final class ShellParserTests: XCTestCase {
    private func words(_ line: String) throws -> [[String]] {
        try ShellParser.parse(line).items.flatMap { $0.pipeline.commands.map { $0.words.map(\.raw) } }
    }

    func testQuotingAndEscapes() throws {
        XCTAssertEqual(try words(#"echo "a b" 'c  d' e\ f"#), [["echo", "a b", "c  d", "e f"]])
        XCTAssertEqual(try words(#"echo "say \"hi\"" x"y"z"#), [["echo", #"say "hi""#, "xyz"]])
        XCTAssertEqual(try words("echo a # comment"), [["echo", "a"]])
        XCTAssertThrowsError(try ShellParser.parse("echo 'oops"))
    }

    func testOperators() throws {
        let list = try ShellParser.parse("ls | grep x > out.txt && echo ok || echo no; pwd")
        XCTAssertEqual(list.items.map(\.joiner), [.always, .and, .or, .always])
        XCTAssertEqual(list.items[0].pipeline.commands.count, 2)
        XCTAssertEqual(list.items[0].pipeline.commands[1].redirects.first?.kind, .output)
        XCTAssertEqual(list.items[0].pipeline.commands[1].redirects.first?.target?.raw, "out.txt")
    }

    func testStderrRedirects() throws {
        let c = try ShellParser.parse("python x.py 2> err.txt").items[0].pipeline.commands[0]
        XCTAssertEqual(c.words.map(\.raw), ["python", "x.py"])
        XCTAssertEqual(c.redirects.map(\.kind), [.error])
        let d = try ShellParser.parse("cmd 2>&1 | cat").items[0].pipeline.commands[0]
        XCTAssertEqual(d.redirects.map(\.kind), [.errorToOutput])
    }

    func testSyntaxErrors() {
        XCTAssertThrowsError(try ShellParser.parse("| ls"))
        XCTAssertThrowsError(try ShellParser.parse("ls |"))
        XCTAssertThrowsError(try ShellParser.parse("echo >"))
        XCTAssertNoThrow(try ShellParser.parse("ls;"))
    }
}

final class LocalShellCommandTests: XCTestCase {
    var root: URL!
    var state: ShellState!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        state = ShellState(root: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Runs a command line; returns (status, stdout, stderr) with ANSI colors stripped.
    @discardableResult
    private func sh(_ line: String, input: String? = nil) async throws -> (Int32, String, String) {
        let out = ShellOutput(), err = ShellOutput()
        let list = try ShellParser.parse(line)
        let shellInput: ShellInput? = input.map { text in
            let i = ShellInput()
            text.split(separator: "\n", omittingEmptySubsequences: false).forEach { i.push(String($0)) }
            i.close()
            return i
        }
        let status = await ShellExecutor.run(list, state: state, terminal: out, terminalError: err, input: shellInput, services: ShellServices())
        func clean(_ d: Data) -> String { String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }
        return (status, clean(out.data), clean(err.data))
    }

    func testFileLifecycle() async throws {
        try await sh("mkdir -p src/app && touch src/app/main.py && echo 'print(1)' > src/app/main.py")
        var r = try await sh("cat src/app/main.py")
        XCTAssertEqual(r.1, "print(1)\n")
        try await sh("cp src/app/main.py copy.py && mv copy.py moved.py")
        r = try await sh("ls")
        XCTAssertEqual(r.1.split(separator: "\n").sorted(), ["moved.py", "src"])
        r = try await sh("rm src")
        XCTAssertEqual(r.0, 1)
        XCTAssertTrue(r.2.contains("is a directory"))
        r = try await sh("rm -r src && ls")
        XCTAssertEqual(r.1, "moved.py\n")
    }

    func testCdPwdAndPrompt() async throws {
        try await sh("mkdir a")
        var r = try await sh("cd a && pwd")
        XCTAssertEqual(r.1, "~/a\n")
        XCTAssertEqual(state.sandbox.display(state.cwd), "~/a")
        r = try await sh("cd ~ && pwd")
        XCTAssertEqual(r.1, "~\n")
        r = try await sh("cd nope")
        XCTAssertEqual(r.0, 1)
    }

    func testSandboxBlocksEscapes() async throws {
        var r = try await sh("cd ..")
        XCTAssertEqual(r.0, 1)
        XCTAssertTrue(r.2.contains("outside the workspace"))
        r = try await sh("cat /etc/hosts")
        XCTAssertTrue(r.2.contains("outside the workspace"))
        r = try await sh("echo x > ../escape.txt")
        XCTAssertNotEqual(r.0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.txt").path))
        // A symlink inside the workspace pointing outside must not be followed.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        r = try await sh("ls link")
        XCTAssertTrue(r.2.contains("outside the workspace"))
        r = try await sh("rm -r ~")
        XCTAssertTrue(r.2.contains("refusing"))
    }

    func testPipesRedirectsAndText() async throws {
        try await sh("echo banana > f.txt; echo apple >> f.txt; echo cherry >> f.txt; echo apple >> f.txt")
        var r = try await sh("cat f.txt | sort | uniq -c")
        XCTAssertEqual(r.1, "      2 apple\n      1 banana\n      1 cherry\n")
        r = try await sh("grep -n an f.txt")
        XCTAssertEqual(r.1, "1:banana\n")
        r = try await sh("head -n 2 f.txt; tail -1 f.txt")
        XCTAssertEqual(r.1, "banana\napple\napple\n")
        r = try await sh("wc -l < f.txt")
        XCTAssertEqual(r.1.trimmingCharacters(in: .whitespaces), "4\n")
        r = try await sh("grep zzz f.txt || echo none")
        XCTAssertEqual(r.1, "none\n")
        r = try await sh("nosuchcmd 2> err.txt; cat err.txt")
        XCTAssertTrue(r.1.contains("command not found"))
    }

    func testGlobsVariablesAndFind() async throws {
        try await sh("mkdir -p pkg && touch a.py b.py c.txt pkg/d.py")
        var r = try await sh("echo *.py")
        XCTAssertEqual(r.1, "a.py b.py\n")
        r = try await sh("echo '*.py' \"$HOME\"")
        XCTAssertEqual(r.1, "*.py ~\n")
        r = try await sh("export NAME=Pocket && echo hi $NAME ${NAME}Code")
        XCTAssertEqual(r.1, "hi Pocket PocketCode\n")
        r = try await sh("find . -name '*.py' -type f")
        XCTAssertEqual(r.1.split(separator: "\n").sorted(), ["./a.py", "./b.py", "./pkg/d.py"])
        r = try await sh("grep -rl '' . ; echo $?")
        XCTAssertEqual(r.1.split(separator: "\n").last, "0", "out=\(r.1) err=\(r.2)")
    }

    func testGrepRecursiveAndOptions() async throws {
        try await sh("mkdir src && echo 'def Hello():' > src/a.py && echo 'hello world' > b.txt")
        var r = try await sh("grep -ri hello .")
        XCTAssertEqual(Set(r.1.split(separator: "\n")), ["src/a.py:def Hello():", "b.txt:hello world"])
        r = try await sh("grep -c -i hello b.txt src/a.py")
        XCTAssertEqual(r.1, "b.txt:1\nsrc/a.py:1\n")
        r = try await sh("grep -z x b.txt")
        XCTAssertEqual(r.0, 2)
        XCTAssertTrue(r.2.contains("unsupported option"))
    }

    func testCatReadsInteractiveInput() async throws {
        let r = try await sh("cat", input: "line one\nline two")
        XCTAssertEqual(r.1, "line one\nline two\n")
    }

    func testUnknownCommandAndPythonMissing() async throws {
        var r = try await sh("frobnicate")
        XCTAssertEqual(r.0, 127)
        r = try await sh("python main.py")
        XCTAssertEqual(r.0, 127)
    }
}

/// Drives the interactive shell with keystrokes, like the terminal does.
@MainActor
final class LocalShellInteractiveTests: XCTestCase {
    func testTypingRunsCommandsAndHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ishell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var screen = ""
        let shell = LocalShell(root: root) { screen += $0 }
        shell.start()

        func type(_ s: String) { shell.receive(Array(s.utf8)) }
        func settle() async { for _ in 0..<20 { try? await Task.sleep(nanoseconds: 20_000_000); if !shell.isBusy { break } }; try? await Task.sleep(nanoseconds: 50_000_000) }

        type("echo hello\r")
        await settle()
        XCTAssertTrue(screen.contains("hello\r\n"), screen)

        // Edit: type "ecxho", move left 3, backspace the x.
        screen = ""
        type("ecxho again\u{1B}[D\u{1B}[D\u{1B}[D\u{1B}[D\u{1B}[D\u{1B}[D\u{1B}[D\u{1B}[D\u{7F}\r")
        await settle()
        XCTAssertTrue(screen.contains("again\r\n"), screen)

        // Up arrow recalls the previous command.
        screen = ""
        type("\u{1B}[A\r")
        await settle()
        XCTAssertTrue(screen.contains("again\r\n"), screen)
        XCTAssertEqual(shell.state.history, ["echo hello", "echo again"])

        // Tab completes a file name.
        FileManager.default.createFile(atPath: root.appendingPathComponent("hello_world.py").path, contents: Data())
        screen = ""
        type("ls hel\t\r")
        await settle()
        XCTAssertTrue(screen.contains("hello_world.py"), screen)
    }
}
