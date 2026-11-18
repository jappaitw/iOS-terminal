import Foundation

/// Confines paths to the workspace root. Every file the local shell (and later the AI
/// agent's tools) touches goes through here, so a command can never reach app data
/// outside the folder the user opened (host list, Keychain-adjacent files, …).
struct WorkspaceSandbox: Sendable {
    let root: URL

    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    enum Failure: LocalizedError {
        case outside(String)
        var errorDescription: String? {
            if case .outside(let p) = self { return "\(p): outside the workspace" }
            return nil
        }
    }

    /// Resolves `path` (absolute, `~`-relative or relative to `cwd`) and checks it stays
    /// inside the root. Symlinks are resolved for the part of the path that exists.
    func resolve(_ path: String, from cwd: URL) throws -> URL {
        let url: URL
        if path == "~" { url = root }
        else if path.hasPrefix("~/") { url = root.appendingPathComponent(String(path.dropFirst(2))) }
        else if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else { url = cwd.appendingPathComponent(path) }
        let resolved = Self.resolveExisting(url.standardizedFileURL)
        guard contains(resolved) else { throw Failure.outside(path) }
        return resolved
    }

    func contains(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path, r = root.path
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    /// Path relative to the root, shown as `~` / `~/sub/dir`.
    func display(_ url: URL) -> String {
        let p = url.standardizedFileURL.path, r = root.path
        if p == r { return "~" }
        if p.hasPrefix(r + "/") { return "~/" + p.dropFirst(r.count + 1) }
        return p
    }

    /// Resolve symlinks in the longest existing prefix, keep the rest as typed.
    private static func resolveExisting(_ url: URL) -> URL {
        var existing = url, tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var out = existing.resolvingSymlinksInPath()
        for t in tail { out.appendPathComponent(t) }
        return out.standardizedFileURL
    }
}

/// Mutable shell state. Only touched by the running job or, between jobs, by the line
/// editor — never both at once — so it is a plain class.
final class ShellState: @unchecked Sendable {
    let sandbox: WorkspaceSandbox
    var cwd: URL
    var env: [String: String]
    var lastStatus: Int32 = 0
    var history: [String] = []

    init(root: URL) {
        sandbox = WorkspaceSandbox(root: root)
        cwd = sandbox.root
        env = ["HOME": "~", "SHELL": "pocketcode", "TERM": "xterm-256color", "USER": "mobile", "LANG": "en_US.UTF-8"]
    }
}

/// Where a command writes. Terminal sinks convert `\n` to `\r\n` and hop to the main
/// queue (serial, so output order is preserved); buffer sinks feed the next pipe stage
/// or a redirect file.
final class ShellOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let live: ((String) -> Void)?

    init(live: ((String) -> Void)? = nil) { self.live = live }

    /// True when writing straight to the terminal (not a pipe or file).
    var isTerminal: Bool { live != nil }

    func write(_ data: Data) {
        if let live {
            let text = String(decoding: data, as: UTF8.self)
            live(text)
        } else {
            lock.lock(); buffer.append(data); lock.unlock()
        }
    }
    func write(_ s: String) { write(Data(s.utf8)) }
    func line(_ s: String = "") { write(s + "\n") }

    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}

/// Source of keyboard input for a running job (Python's input(), the REPL, `cat` with
/// no file). Lines arrive from the line editor; `nil` = EOF (Ctrl-D).
final class ShellInput: @unchecked Sendable {
    private let lock = NSCondition()
    private var lines: [String?] = []
    private var closed = false

    func push(_ line: String?) { lock.lock(); lines.append(line); lock.signal(); lock.unlock() }
    func close() { lock.lock(); closed = true; lock.broadcast(); lock.unlock() }

    /// Blocks the calling (background) thread until a line or EOF arrives.
    func readLine() -> String? {
        lock.lock(); defer { lock.unlock() }
        while lines.isEmpty && !closed { lock.wait() }
        if lines.isEmpty { return nil }
        return lines.removeFirst()
    }
}

/// Everything a builtin gets.
final class ShellContext: @unchecked Sendable {
    let args: [String]
    let state: ShellState
    let stdout: ShellOutput
    let stderr: ShellOutput
    /// Piped / redirected input, if any.
    let stdinData: Data?
    /// Interactive input when the command is the last stage reading from the terminal.
    let terminalInput: ShellInput?
    let services: ShellServices
    /// Set by Ctrl-C. Builtins check it in loops; Python receives KeyboardInterrupt.
    var interruptHandler: (() -> Void)?

    init(args: [String], state: ShellState, stdout: ShellOutput, stderr: ShellOutput,
         stdinData: Data?, terminalInput: ShellInput?, services: ShellServices) {
        self.args = args; self.state = state; self.stdout = stdout; self.stderr = stderr
        self.stdinData = stdinData; self.terminalInput = terminalInput; self.services = services
    }

    var name: String { args.first ?? "" }
    var isCancelled: Bool { Task.isCancelled }

    func resolve(_ path: String) throws -> URL { try state.sandbox.resolve(path, from: state.cwd) }

    func fail(_ message: String, status: Int32 = 1) -> Int32 {
        stderr.line("\(name): \(message)")
        return status
    }

    /// Text of stdin (pipe/redirect), or nil if the command is reading from nowhere.
    var stdinText: String? { stdinData.map { String(decoding: $0, as: UTF8.self) } }
}

/// Hooks into the rest of the app (open a file in the editor, run Python, cols…).
struct ShellServices: Sendable {
    var columns: @Sendable () -> Int = { 80 }
    var openInEditor: @Sendable (String) -> Void = { _ in }
    var runPython: (@Sendable (ShellContext) async -> Int32)?
    var runCodex: (@Sendable (ShellContext) async -> Int32)?
    var runClaude: (@Sendable (ShellContext) async -> Int32)?
}

/// Variable, tilde and glob expansion.
enum ShellExpansion {
    static func expand(_ word: ShellWord, state: ShellState) -> [String] {
        var text = ""
        for part in word.parts {
            switch part.quote {
            case .single: text += part.text
            case .double: text += substitute(part.text, state: state)
            case .none:
                var t = substitute(part.text, state: state)
                if text.isEmpty, t == "~" || t.hasPrefix("~/") { t = state.sandbox.root.path + t.dropFirst() }
                text += t
            }
        }
        guard word.hasUnquotedGlob else { return [text] }
        let matches = glob(text, cwd: state.cwd)
        return matches.isEmpty ? [text] : matches
    }

    /// $NAME, ${NAME}, $? and $PWD.
    static func substitute(_ s: String, state: ShellState) -> String {
        guard s.contains("$") else { return s }
        var out = "", chars = Array(s), i = 0
        while i < chars.count {
            guard chars[i] == "$", i + 1 < chars.count else { out.append(chars[i]); i += 1; continue }
            let next = chars[i + 1]
            if next == "?" { out += String(state.lastStatus); i += 2; continue }
            var name = "", j = i + 1
            if next == "{" {
                j += 1
                while j < chars.count, chars[j] != "}" { name.append(chars[j]); j += 1 }
                j += 1
            } else {
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { name.append(chars[j]); j += 1 }
            }
            if name.isEmpty { out.append("$"); i += 1; continue }
            out += value(name, state: state)
            i = j
        }
        return out
    }

    private static func value(_ name: String, state: ShellState) -> String {
        switch name {
        case "PWD": return state.sandbox.display(state.cwd)
        default: return state.env[name] ?? ""
        }
    }

    /// Glob within one directory level per component: `*.py`, `src/*.swift`, `a?/b*`.
    static func glob(_ pattern: String, cwd: URL) -> [String] {
        let absolute = pattern.hasPrefix("/")
        var bases: [(url: URL, display: String)] = [(absolute ? URL(fileURLWithPath: "/") : cwd, absolute ? "/" : "")]
        let comps = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for (n, comp) in comps.enumerated() {
            let last = n == comps.count - 1
            var next: [(URL, String)] = []
            for base in bases {
                if comp.contains(where: { "*?[".contains($0) }) {
                    let names = ((try? FileManager.default.contentsOfDirectory(atPath: base.url.path)) ?? [])
                        .filter { (comp.hasPrefix(".") || !$0.hasPrefix(".")) && fnmatch(comp, $0, 0) == 0 }
                        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    for name in names {
                        let u = base.url.appendingPathComponent(name)
                        var isDir: ObjCBool = false
                        if !last, !(FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue) { continue }
                        next.append((u, base.display + name + (last ? "" : "/")))
                    }
                } else {
                    let u = base.url.appendingPathComponent(comp)
                    if FileManager.default.fileExists(atPath: u.path) { next.append((u, base.display + comp + (last ? "" : "/"))) }
                }
            }
            bases = next
            if bases.isEmpty { return [] }
        }
        return bases.map(\.display)
    }
}

/// Runs a parsed command line.
enum ShellExecutor {
    typealias Builtin = (ShellContext) async -> Int32

    static func run(_ list: ShellList, state: ShellState, terminal: ShellOutput, terminalError: ShellOutput,
                    input: ShellInput?, services: ShellServices, onContext: @escaping (ShellContext) -> Void = { _ in }) async -> Int32 {
        var status: Int32 = 0
        for item in list.items {
            if Task.isCancelled { return 130 }
            switch item.joiner {
            case .and where status != 0: continue
            case .or where status == 0: continue
            default: break
            }
            status = await runPipeline(item.pipeline, state: state, terminal: terminal, terminalError: terminalError,
                                       input: input, services: services, onContext: onContext)
            state.lastStatus = status
        }
        return status
    }

    private static func runPipeline(_ p: ShellPipeline, state: ShellState, terminal: ShellOutput, terminalError: ShellOutput,
                                    input: ShellInput?, services: ShellServices, onContext: (ShellContext) -> Void) async -> Int32 {
        var piped: Data?
        var status: Int32 = 0
        for (n, cmd) in p.commands.enumerated() {
            if Task.isCancelled { return 130 }
            let isLast = n == p.commands.count - 1
            let args = cmd.words.flatMap { ShellExpansion.expand($0, state: state) }

            // Redirects
            var stdinData = piped
            var outFile: (URL, append: Bool)?
            var errFile: (URL, append: Bool)?
            var errToOut = false
            for r in cmd.redirects {
                let target = r.target.flatMap { ShellExpansion.expand($0, state: state).first } ?? ""
                do {
                    switch r.kind {
                    case .input:
                        stdinData = try Data(contentsOf: try state.sandbox.resolve(target, from: state.cwd))
                    case .output: outFile = (try state.sandbox.resolve(target, from: state.cwd), false)
                    case .append: outFile = (try state.sandbox.resolve(target, from: state.cwd), true)
                    case .error: errFile = (try state.sandbox.resolve(target, from: state.cwd), false)
                    case .errorAppend: errFile = (try state.sandbox.resolve(target, from: state.cwd), true)
                    case .errorToOutput: errToOut = true
                    }
                } catch {
                    terminalError.line("pocketcode: \(target): \(error.localizedDescription)")
                    return 1
                }
            }

            let stdout: ShellOutput = (isLast && outFile == nil) ? terminal : ShellOutput()
            let stderr: ShellOutput = errToOut ? stdout : (errFile == nil ? terminalError : ShellOutput())
            let interactive = isLast && stdinData == nil && n == 0 ? input : nil
            let ctx = ShellContext(args: args, state: state, stdout: stdout, stderr: stderr,
                                   stdinData: stdinData, terminalInput: interactive, services: services)
            onContext(ctx)

            if args.isEmpty {
                status = 0
            } else if let builtin = Builtins.table[args[0]] {
                status = await builtin(ctx)
            } else if ["python", "python3"].contains(args[0]) {
                if let py = services.runPython { status = await py(ctx) }
                else { status = ctx.fail("the Python runtime isn't included in this build", status: 127) }
            } else if args[0] == "codex" {
                if let codex = services.runCodex { status = await codex(ctx) }
                else { status = ctx.fail("the Codex agent isn't included in this build", status: 127) }
            } else if args[0] == "claude" {
                if let claude = services.runClaude { status = await claude(ctx) }
                else { status = ctx.fail("the Claude agent isn't included in this build", status: 127) }
            } else {
                stderr.line("pocketcode: \(args[0]): command not found (type `help` for the list)")
                status = 127
            }

            if let (url, append) = outFile { write(stdout.data, to: url, append: append, err: terminalError) }
            if let (url, append) = errFile, stderr !== stdout { write(stderr.data, to: url, append: append, err: terminalError) }
            piped = isLast ? nil : stdout.data
        }
        return status
    }

    private static func write(_ data: Data, to url: URL, append: Bool, err: ShellOutput) {
        do {
            if append, let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            err.line("pocketcode: \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
