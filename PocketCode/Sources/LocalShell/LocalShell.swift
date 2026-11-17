import Foundation

/// PocketCode's on-device shell: a line editor + the Swift command interpreter.
/// The terminal sends raw keystrokes (as a PTY would); there is no real TTY, so this
/// class does what the kernel's line discipline and the shell's readline would do:
/// echo, cursor movement, history, completion, and — while a command runs — a simple
/// "cooked" mode that hands whole lines to the command's stdin.
@MainActor
final class LocalShell {
    let state: ShellState
    var services: ShellServices
    /// Raw text to the terminal (already using \r\n).
    private let emit: (String) -> Void
    var onExit: () -> Void = {}

    // Line editor
    private var line: [Character] = []
    private var cursor = 0
    private var historyPos: Int?
    private var draft: [Character] = []
    private var pendingUTF8: [UInt8] = []
    private var escape: [UInt8]?
    private var lastTabAt: Date?

    // Running job
    private var job: Task<Void, Never>?
    private var jobInput: ShellInput?
    private var jobContexts: [ShellContext] = []
    private var jobLine: [Character] = []
    /// Whether the last thing written to the terminal ended a line (so the prompt never
    /// gets glued to output that lacked a trailing newline).
    private var atLineStart = true

    var isBusy: Bool { job != nil }

    init(root: URL, services: ShellServices = ShellServices(), emit: @escaping (String) -> Void) {
        self.state = ShellState(root: root)
        self.services = services
        self.emit = emit
    }

    func start(initialDirectory: String? = nil) {
        if let dir = initialDirectory, let url = try? state.sandbox.resolve(dir, from: state.cwd) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { state.cwd = url }
        }
        emit("\u{1B}[2mPocketCode local shell — runs on this device. Type `help` for commands.\u{1B}[0m\r\n")
        prompt()
    }

    // MARK: Output

    /// Sink that converts newlines and hops to the main queue (callable from any thread).
    private func terminalSink(error: Bool) -> ShellOutput {
        ShellOutput { [weak self] text in
            let converted = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            let out = error ? "\u{1B}[31m" + converted + "\u{1B}[0m" : converted
            DispatchQueue.main.async {
                guard let self, !out.isEmpty else { return }
                self.emit(out)
                self.atLineStart = converted.hasSuffix("\n")
            }
        }
    }

    private var promptText: String {
        let status = state.lastStatus == 0 ? "" : "\u{1B}[31m[\(state.lastStatus)]\u{1B}[0m "
        return status + "\u{1B}[32mlocal\u{1B}[0m:\u{1B}[1;34m\(state.sandbox.display(state.cwd))\u{1B}[0m$ "
    }

    private func prompt() {
        line = []; cursor = 0; historyPos = nil
        emit(promptText)
    }

    private func redraw() {
        var s = "\r" + promptText + String(line) + "\u{1B}[K"
        let back = displayWidth(String(line[cursor...]))
        if back > 0 { s += "\u{1B}[\(back)D" }
        emit(s)
    }

    // MARK: Input

    func receive(_ bytes: [UInt8]) {
        for b in bytes { feed(b) }
    }

    private func feed(_ b: UInt8) {
        // Escape sequences: ESC [ X, ESC O X, ESC [ n ~
        if var esc = escape {
            esc.append(b)
            escape = esc
            if esc.count == 1 {
                if b != UInt8(ascii: "[") && b != UInt8(ascii: "O") { escape = nil } // lone ESC: ignore
                return
            }
            if (0x40...0x7E).contains(b) { escape = nil; handleEscape(esc) }
            else if esc.count > 6 { escape = nil }
            return
        }
        if b == 0x1B { escape = []; return }

        if isBusy { cookedInput(b); return }

        switch b {
        case 0x0D, 0x0A: submit()
        case 0x7F, 0x08: backspace()
        case 0x03: emit("^C\r\n"); state.lastStatus = 130; prompt()
        case 0x04: if line.isEmpty { emit("\r\n\u{1B}[2m(use `exit` to close this terminal)\u{1B}[0m\r\n"); prompt() }
        case 0x0C: emit("\u{1B}[2J\u{1B}[H"); redraw()
        case 0x01: cursor = 0; redraw()
        case 0x05: cursor = line.count; redraw()
        case 0x15: line.removeSubrange(0..<cursor); cursor = 0; redraw()
        case 0x0B: line.removeSubrange(cursor...); redraw()
        case 0x17: deleteWord()
        case 0x09: complete()
        default:
            if b < 0x20 { return }
            insertUTF8(b)
        }
    }

    private func insertUTF8(_ b: UInt8) {
        pendingUTF8.append(b)
        guard let s = String(bytes: pendingUTF8, encoding: .utf8) else {
            if pendingUTF8.count > 4 { pendingUTF8 = [] }
            return
        }
        pendingUTF8 = []
        for ch in s {
            if isBusy { jobLine.append(ch); emit(String(ch)); continue }
            line.insert(ch, at: cursor)
            cursor += 1
            if cursor == line.count { emit(String(ch)) } else { redraw() }
        }
    }

    private func backspace() {
        guard cursor > 0 else { return }
        let removed = line.remove(at: cursor - 1)
        cursor -= 1
        if cursor == line.count {
            // Common case (deleting at the end): erase in place, which also works on wrapped lines.
            let w = max(displayWidth(String(removed)), 1)
            emit(String(repeating: "\u{8}", count: w) + String(repeating: " ", count: w) + String(repeating: "\u{8}", count: w))
        } else {
            redraw()
        }
    }

    private func deleteWord() {
        var i = cursor
        while i > 0, line[i - 1] == " " { i -= 1 }
        while i > 0, line[i - 1] != " " { i -= 1 }
        line.removeSubrange(i..<cursor)
        cursor = i
        redraw()
    }

    private func handleEscape(_ seq: [UInt8]) {
        guard let final = seq.last.map({ Character(UnicodeScalar($0)) }) else { return }
        if isBusy { return }
        switch final {
        case "A": historyStep(-1)
        case "B": historyStep(1)
        case "C": if cursor < line.count { cursor += 1; redraw() }
        case "D": if cursor > 0 { cursor -= 1; redraw() }
        case "H": cursor = 0; redraw()
        case "F": cursor = line.count; redraw()
        case "~":
            let code = String(decoding: seq.dropFirst().dropLast(), as: UTF8.self)
            if code == "3", cursor < line.count { line.remove(at: cursor); redraw() }
            if code == "1" || code == "7" { cursor = 0; redraw() }
            if code == "4" || code == "8" { cursor = line.count; redraw() }
        default: break
        }
    }

    private func historyStep(_ delta: Int) {
        let h = state.history
        guard !h.isEmpty else { return }
        if historyPos == nil { draft = line; historyPos = h.count }
        let next = max(0, min(h.count, historyPos! + delta))
        historyPos = next
        line = next == h.count ? draft : Array(h[next])
        cursor = line.count
        redraw()
    }

    // MARK: Completion

    private func complete() {
        let before = String(line[..<cursor])
        let tokenStart = before.lastIndex(where: { $0 == " " || $0 == "|" || $0 == ";" || $0 == ">" || $0 == "<" }).map { before.index(after: $0) } ?? before.startIndex
        let token = String(before[tokenStart...])
        let isCommand = before[..<tokenStart].trimmingCharacters(in: .whitespaces).isEmpty
            || ["|", ";", "&"].contains(before[..<tokenStart].trimmingCharacters(in: .whitespaces).last ?? " ")

        var candidates: [(name: String, isDir: Bool)] = []
        var dirPart = ""
        if isCommand && !token.contains("/") {
            candidates = Builtins.commandNames.filter { $0.hasPrefix(token) }.map { ($0, false) }
        } else {
            let slash = token.lastIndex(of: "/")
            dirPart = slash.map { String(token[...$0]) } ?? ""
            let prefix = slash.map { String(token[token.index(after: $0)...]) } ?? token
            if let dir = try? state.sandbox.resolve(dirPart.isEmpty ? "." : dirPart, from: state.cwd),
               let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                candidates = names.filter { $0.hasPrefix(prefix) && (prefix.hasPrefix(".") || !$0.hasPrefix(".")) }
                    .sorted()
                    .map { name in
                        var d: ObjCBool = false
                        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &d)
                        return (name, d.boolValue)
                    }
            }
        }
        let typed = isCommand && !token.contains("/") ? token : String(token.dropFirst(dirPart.count))
        guard !candidates.isEmpty else { return }
        if candidates.count == 1 {
            let c = candidates[0]
            insert(String(c.name.dropFirst(typed.count)) + (c.isDir ? "/" : " "))
            return
        }
        let common = candidates.map(\.name).reduce(candidates[0].name) { $0.commonPrefix(with: $1) }
        if common.count > typed.count {
            insert(String(common.dropFirst(typed.count)))
        } else if let last = lastTabAt, Date().timeIntervalSince(last) < 1.5 {
            emit("\r\n" + candidates.map { $0.isDir ? $0.name + "/" : $0.name }.joined(separator: "  ") + "\r\n")
            redraw()
        }
        lastTabAt = Date()
    }

    private func insert(_ s: String) {
        line.insert(contentsOf: Array(s), at: cursor)
        cursor += s.count
        redraw()
    }

    // MARK: Running commands

    private func submit() {
        let text = String(line).trimmingCharacters(in: .whitespaces)
        emit("\r\n")
        guard !text.isEmpty else { prompt(); return }
        if state.history.last != text { state.history.append(text) }
        if text == "exit" || text.hasPrefix("exit ") { onExit(); return }
        let list: ShellList
        do { list = try ShellParser.parse(text) } catch {
            emit("\u{1B}[31mpocketcode: \(error.localizedDescription)\u{1B}[0m\r\n")
            state.lastStatus = 2
            prompt()
            return
        }
        run(list)
    }

    private func run(_ list: ShellList) {
        let input = ShellInput()
        jobInput = input
        jobContexts = []
        jobLine = []
        let state = state, services = services
        let out = terminalSink(error: false), err = terminalSink(error: true)
        job = Task.detached { [weak self] in
            _ = await ShellExecutor.run(list, state: state, terminal: out, terminalError: err, input: input, services: services) { ctx in
                DispatchQueue.main.async { self?.jobContexts.append(ctx) }
            }
            // After all output already queued on the main queue.
            DispatchQueue.main.async { self?.jobFinished() }
        }
    }

    private func jobFinished() {
        job = nil
        jobInput?.close()
        jobInput = nil
        jobContexts = []
        // Start the prompt on a fresh line even if the program's output didn't end with \n.
        if !atLineStart { emit("\u{1B}[7m%\u{1B}[0m\r\n") }
        atLineStart = true
        prompt()
    }

    /// Keystrokes while a command runs: echo + line buffering for its stdin.
    private func cookedInput(_ b: UInt8) {
        switch b {
        case 0x03:
            emit("^C\r\n")
            interrupt()
        case 0x04:
            jobInput?.push(nil)
        case 0x0D, 0x0A:
            emit("\r\n")
            jobInput?.push(String(jobLine))
            jobLine = []
        case 0x7F, 0x08:
            if !jobLine.isEmpty {
                let w = displayWidth(String(jobLine.removeLast()))
                emit(String(repeating: "\u{8} \u{8}", count: max(w, 1)))
            }
        default:
            if b >= 0x20 { insertUTF8(b) }
        }
    }

    /// Ctrl-C: cancel builtins (they poll Task.isCancelled) and interrupt Python.
    func interrupt() {
        // Programs that handle Ctrl-C themselves (Python → KeyboardInterrupt) keep their
        // stdin, so e.g. the REPL survives a ^C like it does in a real terminal.
        let handlers = jobContexts.compactMap(\.interruptHandler)
        handlers.forEach { $0() }
        if handlers.isEmpty {
            job?.cancel()
            jobInput?.close()
        }
    }

    func resize(cols: Int) {
        let c = max(cols, 20)
        services.columns = { c }
    }

    func stop() {
        interrupt()
    }
}
