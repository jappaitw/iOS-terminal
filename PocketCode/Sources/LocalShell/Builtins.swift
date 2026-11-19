import Foundation

/// Built-in commands of the local shell. Each takes a context and returns an exit status.
/// Behaviour follows the common BSD/GNU subset; unsupported options are rejected with a
/// clear message instead of being silently ignored.
enum Builtins {
    static let table: [String: ShellExecutor.Builtin] = [
        "pwd": pwd, "cd": cd, "ls": ls, "mkdir": mkdir, "rmdir": rmdir, "touch": touch,
        "cat": cat, "cp": cp, "mv": mv, "rm": rm, "grep": grep, "find": find,
        "head": head, "tail": tail, "echo": echo, "clear": clear, "wc": wc, "sort": sort,
        "uniq": uniq, "tree": tree, "basename": basename, "dirname": dirname, "env": env,
        "export": export, "unset": unset, "history": history, "which": which, "type": which,
        "help": help, "true": { _ in 0 }, "false": { _ in 1 }, "date": date, "sleep": sleep,
        "code": code, "open": code, "whoami": { c in c.stdout.line("mobile"); return 0 },
        "curl": curl, "wget": wget, "rg": rg, "sed": sed,
        "uname": { c in c.stdout.line(c.args.contains("-a") ? "Darwin iOS PocketCode" : "Darwin"); return 0 },
    ]

    /// Shown by `help` and used for Tab completion of command names.
    static let summaries: [(String, String)] = [
        ("cat", "print files"), ("cd", "change directory"), ("clear", "clear the screen"),
        ("codex", "on-device AI coding agent (sign in, then ask it to build/edit/run)"),
        ("claude", "on-device Claude agent (Anthropic API key; ask it to build/edit/run)"),
        ("bench", "benchmark the active local model (tok/s + memory) on this device"),
        ("curl", "HTTP requests (-X -H -d -o -I --max-time)"), ("wget", "download a URL"),
        ("rg", "recursive search (ripgrep-style front end)"), ("sed", "stream edit: s/pattern/replacement/[gip], -i in place"),
        ("code", "open a file in the editor"), ("cp", "copy (-r for folders)"), ("echo", "print text"),
        ("find", "find files (-name, -type f|d, -maxdepth)"), ("grep", "search text (-i -n -v -r -l -c -F)"),
        ("head", "first lines (-n N)"), ("ls", "list files (-l -a -1 -h)"), ("mkdir", "make folders (-p)"),
        ("mv", "move / rename"), ("pwd", "print current folder"), ("python", "run Python (python file.py, python -c, REPL)"),
        ("rm", "remove (-r, -f)"), ("sort", "sort lines (-r -n -u)"), ("tail", "last lines (-n N)"),
        ("touch", "create file / update time"), ("tree", "folder tree"), ("wc", "count lines/words/bytes"),
    ]

    static var commandNames: [String] { (Array(table.keys) + ["python", "python3", "codex", "claude", "bench", "exit"]).sorted() }

    // MARK: Option parsing helper

    /// Splits `-abc` style flags from operands. Returns nil (after printing) on an unknown flag.
    static func flags(_ c: ShellContext, allowed: String, valued: String = "") -> (flags: [Character: String], operands: [String])? {
        var flags: [Character: String] = [:], operands: [String] = []
        var i = 1, endOfFlags = false
        while i < c.args.count {
            let a = c.args[i]
            if endOfFlags || a == "-" || !a.hasPrefix("-") { operands.append(a); i += 1; continue }
            if a == "--" { endOfFlags = true; i += 1; continue }
            var chars = Array(a.dropFirst())
            // `-n5` / `-n 5` / `-5` (head/tail shorthand)
            if valued.contains("n"), chars.allSatisfy(\.isNumber) { flags["n"] = String(chars); i += 1; continue }
            while !chars.isEmpty {
                let f = chars.removeFirst()
                if valued.contains(f) {
                    if !chars.isEmpty { flags[f] = String(chars); chars = [] }
                    else if i + 1 < c.args.count { i += 1; flags[f] = c.args[i] }
                    else { _ = c.fail("option requires an argument -- \(f)"); return nil }
                } else if allowed.contains(f) {
                    flags[f] = ""
                } else {
                    _ = c.fail("unsupported option -- \(f)", status: 2)
                    return nil
                }
            }
            i += 1
        }
        return (flags, operands)
    }

    private static func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    /// Lines of the given files, or of stdin when there are none.
    private static func inputs(_ c: ShellContext, _ operands: [String]) -> [(name: String, text: String)]? {
        if operands.isEmpty {
            if let t = c.stdinText { return [("(standard input)", t)] }
            if let input = c.terminalInput {
                var text = ""
                while let line = input.readLine(), !c.isCancelled { text += line + "\n" }
                return [("(standard input)", text)]
            }
            return [("(standard input)", "")]
        }
        var out: [(String, String)] = []
        for op in operands {
            do {
                let url = try c.resolve(op)
                if isDir(url) { _ = c.fail("\(op): Is a directory"); continue }
                out.append((op, String(decoding: try Data(contentsOf: url), as: UTF8.self)))
            } catch {
                _ = c.fail("\(op): \(Self.message(error))")
            }
        }
        return out
    }

    static func message(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return "No such file or directory"
            case NSFileWriteFileExistsError: return "File exists"
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return "Permission denied"
            default: break
            }
        }
        return error.localizedDescription
    }

    private static func splitLines(_ text: String) -> [Substring] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    // MARK: Navigation

    static func pwd(_ c: ShellContext) async -> Int32 {
        c.stdout.line(c.state.sandbox.display(c.state.cwd)); return 0
    }

    static func cd(_ c: ShellContext) async -> Int32 {
        let target = c.args.count > 1 ? c.args[1] : "~"
        do {
            let url = try c.resolve(target)
            guard isDir(url) else { return c.fail("\(target): Not a directory") }
            c.state.cwd = url
            return 0
        } catch {
            return c.fail(message(error))
        }
    }

    // MARK: ls

    static func ls(_ c: ShellContext) async -> Int32 {
        guard let (f, ops) = flags(c, allowed: "laA1hFR") else { return 2 }
        let long = f["l"] != nil, all = f["a"] != nil || f["A"] != nil, one = f["1"] != nil, human = f["h"] != nil
        var status: Int32 = 0
        let targets = ops.isEmpty ? ["."] : ops
        for (n, op) in targets.enumerated() {
            do {
                let url = try c.resolve(op)
                guard FileManager.default.fileExists(atPath: url.path) else { status = c.fail("\(op): No such file or directory"); continue }
                var entries: [URL]
                if isDir(url) {
                    entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    if !all { entries = entries.filter { !$0.lastPathComponent.hasPrefix(".") } }
                    entries.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    if targets.count > 1 { c.stdout.line((n > 0 ? "\n" : "") + op + ":") }
                } else {
                    entries = [url]
                }
                if long { lsLong(c, entries, human: human) }
                else if one || !c.stdout.isTerminal { entries.forEach { c.stdout.line($0.lastPathComponent) } }
                else { lsColumns(c, entries) }
            } catch {
                status = c.fail("\(op): \(message(error))")
            }
        }
        return status
    }

    private static func colored(_ url: URL) -> String {
        let name = url.lastPathComponent
        if isDir(url) { return "\u{1B}[1;34m\(name)\u{1B}[0m" }
        if ["py", "sh"].contains(url.pathExtension) { return "\u{1B}[32m\(name)\u{1B}[0m" }
        return name
    }

    private static func lsColumns(_ c: ShellContext, _ entries: [URL]) {
        guard !entries.isEmpty else { return }
        let names = entries.map(\.lastPathComponent)
        let width = (names.map { displayWidth($0) }.max() ?? 0) + 2
        let cols = max(1, c.services.columns() / max(width, 1))
        let rows = (names.count + cols - 1) / cols
        for r in 0..<rows {
            var line = ""
            for col in 0..<cols {
                let i = col * rows + r
                guard i < entries.count else { continue }
                let pad = String(repeating: " ", count: max(0, width - displayWidth(names[i])))
                line += colored(entries[i]) + (col == cols - 1 || i + rows >= entries.count ? "" : pad)
            }
            c.stdout.line(line)
        }
    }

    private static func lsLong(_ c: ShellContext, _ entries: [URL], human: Bool) {
        let df = DateFormatter()
        df.dateFormat = "MMM d HH:mm"
        for u in entries {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: u.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let type = (attrs[.type] as? FileAttributeType) == .typeDirectory ? "d" : (attrs[.type] as? FileAttributeType) == .typeSymbolicLink ? "l" : "-"
            var p = type
            for shift in stride(from: 6, through: 0, by: -3) {
                let bits = (perms >> shift) & 7
                p += (bits & 4 != 0 ? "r" : "-") + (bits & 2 != 0 ? "w" : "-") + (bits & 1 != 0 ? "x" : "-")
            }
            let sizeText = human ? ByteCountFormatter.string(fromByteCount: size, countStyle: .binary).replacingOccurrences(of: " ", with: "") : String(size)
            let date = (attrs[.modificationDate] as? Date).map(df.string) ?? ""
            c.stdout.line("\(p)  \(sizeText.leftPad(8))  \(date.leftPad(12))  \(colored(u))")
        }
    }

    // MARK: Files

    static func mkdir(_ c: ShellContext) async -> Int32 {
        guard let (f, ops) = flags(c, allowed: "p") else { return 2 }
        guard !ops.isEmpty else { return c.fail("missing operand") }
        var status: Int32 = 0
        for op in ops {
            do {
                let url = try c.resolve(op)
                if FileManager.default.fileExists(atPath: url.path), f["p"] == nil { status = c.fail("\(op): File exists"); continue }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: f["p"] != nil)
            } catch { status = c.fail("\(op): \(message(error))") }
        }
        return status
    }

    static func rmdir(_ c: ShellContext) async -> Int32 {
        var status: Int32 = 0
        for op in c.args.dropFirst() {
            do {
                let url = try c.resolve(op)
                guard isDir(url) else { status = c.fail("\(op): Not a directory"); continue }
                guard (try FileManager.default.contentsOfDirectory(atPath: url.path)).isEmpty else { status = c.fail("\(op): Directory not empty"); continue }
                try FileManager.default.removeItem(at: url)
            } catch { status = c.fail("\(op): \(message(error))") }
        }
        return status
    }

    static func touch(_ c: ShellContext) async -> Int32 {
        guard c.args.count > 1 else { return c.fail("missing file operand") }
        var status: Int32 = 0
        for op in c.args.dropFirst() {
            do {
                let url = try c.resolve(op)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                } else if !FileManager.default.createFile(atPath: url.path, contents: Data()) {
                    status = c.fail("\(op): No such file or directory")
                }
            } catch { status = c.fail("\(op): \(message(error))") }
        }
        return status
    }

    static func cat(_ c: ShellContext) async -> Int32 {
        guard let (f, ops) = flags(c, allowed: "n") else { return 2 }
        let before = c.stderr.data.count
        guard let files = inputs(c, ops) else { return 1 }
        var n = 0
        for file in files {
            if f["n"] != nil {
                for line in splitLines(file.text) { n += 1; c.stdout.line("\(String(n).leftPad(6))\t\(line)") }
            } else {
                c.stdout.write(file.text)
            }
        }
        return files.count == max(ops.count, 1) && c.stderr.data.count == before ? 0 : 1
    }

    static func cp(_ c: ShellContext) async -> Int32 {
        guard let (f, ops) = flags(c, allowed: "rRf") else { return 2 }
        return copyOrMove(c, ops, recursive: f["r"] != nil || f["R"] != nil, move: false)
    }

    static func mv(_ c: ShellContext) async -> Int32 {
        guard let (_, ops) = flags(c, allowed: "f") else { return 2 }
        return copyOrMove(c, ops, recursive: true, move: true)
    }

    private static func copyOrMove(_ c: ShellContext, _ ops: [String], recursive: Bool, move: Bool) -> Int32 {
        guard ops.count >= 2 else { return c.fail("missing destination file operand") }
        do {
            let dest = try c.resolve(ops.last!)
            let sources = ops.dropLast()
            let destIsDir = isDir(dest)
            if sources.count > 1, !destIsDir { return c.fail("target '\(ops.last!)' is not a directory") }
            var status: Int32 = 0
            for op in sources {
                let src = try c.resolve(op)
                guard FileManager.default.fileExists(atPath: src.path) else { status = c.fail("\(op): No such file or directory"); continue }
                if isDir(src), !recursive { status = c.fail("\(op) is a directory (not copied; use -r)"); continue }
                let target = destIsDir ? dest.appendingPathComponent(src.lastPathComponent) : dest
                if target.path == src.path { status = c.fail("'\(op)' and '\(ops.last!)' are the same file"); continue }
                if target.path.hasPrefix(src.path + "/") { status = c.fail("cannot \(move ? "move" : "copy") '\(op)' into itself"); continue }
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                if move { try FileManager.default.moveItem(at: src, to: target) }
                else { try FileManager.default.copyItem(at: src, to: target) }
            }
            return status
        } catch {
            return c.fail(message(error))
        }
    }

    static func rm(_ c: ShellContext) async -> Int32 {
        guard let (f, ops) = flags(c, allowed: "rRfdi") else { return 2 }
        let recursive = f["r"] != nil || f["R"] != nil, force = f["f"] != nil
        guard !ops.isEmpty else { return force ? 0 : c.fail("missing operand") }
        var status: Int32 = 0
        for op in ops {
            do {
                let url = try c.resolve(op)
                if url.path == c.state.sandbox.root.path { status = c.fail("refusing to remove the workspace root"); continue }
                guard FileManager.default.fileExists(atPath: url.path) || (try? url.checkResourceIsReachable()) == true else {
                    if !force { status = c.fail("\(op): No such file or directory") }
                    continue
                }
                if isDir(url), !recursive { status = c.fail("\(op): is a directory (use -r)"); continue }
                try FileManager.default.removeItem(at: url)
            } catch { status = c.fail("\(op): \(message(error))") }
        }
        return status
    }

    // MARK: Text

    static func echo(_ c: ShellContext) async -> Int32 {
        var args = Array(c.args.dropFirst()), newline = true
        if args.first == "-n" { newline = false; args.removeFirst() }
        c.stdout.write(args.joined(separator: " ") + (newline ? "\n" : ""))
        return 0
    }

    static func clear(_ c: ShellContext) async -> Int32 {
        c.stdout.write("\u{1B}[3J\u{1B}[2J\u{1B}[H"); return 0
    }

    static func head(_ c: ShellContext) async -> Int32 { await headTail(c, head: true) }
    static func tail(_ c: ShellContext) async -> Int32 { await headTail(c, head: false) }

    private static func headTail(_ c: ShellContext, head: Bool) async -> Int32 {
        guard let (f, ops) = flags(c, allowed: "", valued: "n") else { return 2 }
        guard let n = Int(f["n"] ?? "10"), n >= 0 else { return c.fail("invalid number of lines") }
        guard let files = inputs(c, ops) else { return 1 }
        for (i, file) in files.enumerated() {
            if files.count > 1 { c.stdout.line((i > 0 ? "\n" : "") + "==> \(file.name) <==") }
            let lines = splitLines(file.text)
            let slice = head ? lines.prefix(n) : lines.suffix(n)
            slice.forEach { c.stdout.line(String($0)) }
        }
        return files.count == max(ops.count, 1) ? 0 : 1
    }

    static func wc(_ c: ShellContext) async -> Int32 {
        guard let (f, ops) = flags(c, allowed: "lwc") else { return 2 }
        let showAll = f.isEmpty
        guard let files = inputs(c, ops) else { return 1 }
        var total = (0, 0, 0)
        for file in files {
            let l = file.text.filter { $0 == "\n" }.count
            let w = file.text.split(whereSeparator: { $0.isWhitespace }).count
            let b = file.text.utf8.count
            total = (total.0 + l, total.1 + w, total.2 + b)
            c.stdout.line(wcLine(l, w, b, f, showAll) + (ops.isEmpty ? "" : " \(file.name)"))
        }
        if files.count > 1 { c.stdout.line(wcLine(total.0, total.1, total.2, f, showAll) + " total") }
        return 0
    }

    private static func wcLine(_ l: Int, _ w: Int, _ b: Int, _ f: [Character: String], _ all: Bool) -> String {
        var parts: [String] = []
        if all || f["l"] != nil { parts.append(String(l).leftPad(8)) }
        if all || f["w"] != nil { parts.append(String(w).leftPad(8)) }
        if all || f["c"] != nil { parts.append(String(b).leftPad(8)) }
        return parts.joined()
    }

    static func sort(_ c: ShellContext) async -> Int32 {
        guard let (f, ops) = flags(c, allowed: "rnu") else { return 2 }
        guard let files = inputs(c, ops) else { return 1 }
        var lines = files.flatMap { splitLines($0.text).map(String.init) }
        if f["n"] != nil {
            lines.sort { (Double($0.trimmingCharacters(in: .whitespaces).prefix { "-.0123456789".contains($0) }) ?? 0)
                       < (Double($1.trimmingCharacters(in: .whitespaces).prefix { "-.0123456789".contains($0) }) ?? 0) }
        } else {
            lines.sort()
        }
        if f["r"] != nil { lines.reverse() }
        if f["u"] != nil { var seen = Set<String>(); lines = lines.filter { seen.insert($0).inserted } }
        lines.forEach { c.stdout.line($0) }
        return 0
    }

    static func uniq(_ c: ShellContext) async -> Int32 {
        guard let (f, ops) = flags(c, allowed: "c") else { return 2 }
        guard let files = inputs(c, ops) else { return 1 }
        var prev: String?, count = 0
        func emit() { if let p = prev { c.stdout.line(f["c"] != nil ? "\(String(count).leftPad(7)) \(p)" : p) } }
        for line in files.flatMap({ splitLines($0.text).map(String.init) }) {
            if line == prev { count += 1 } else { emit(); prev = line; count = 1 }
        }
        emit()
        return 0
    }

    // MARK: grep

    static func grep(_ c: ShellContext) async -> Int32 {
        guard let (f, ops) = flags(c, allowed: "inrvlcFEhwHR", valued: "e") else { return 2 }
        var operands = ops
        let patternText: String
        if let e = f["e"] { patternText = e } else if !operands.isEmpty { patternText = operands.removeFirst() } else { return c.fail("usage: grep [-inrvlcFw] pattern [file ...]", status: 2) }
        let recursive = f["r"] != nil || f["R"] != nil
        var pattern = f["F"] != nil ? NSRegularExpression.escapedPattern(for: patternText) : patternText
        if pattern.isEmpty { pattern = "(?:)" } // like grep: an empty pattern matches every line
        if f["w"] != nil { pattern = "\\b(?:\(pattern))\\b" }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: f["i"] != nil ? [.caseInsensitive] : []) else {
            return c.fail("invalid regular expression", status: 2)
        }

        // Collect (display name, url) pairs; directories expand only with -r.
        var targets: [(String, URL?)] = []
        if operands.isEmpty {
            if recursive { operands = ["."] } else { targets = [("(standard input)", nil)] }
        }
        for op in operands {
            guard let url = try? c.resolve(op) else { _ = c.fail("\(op): outside the workspace"); continue }
            if isDir(url) {
                guard recursive else { _ = c.fail("\(op): Is a directory"); continue }
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey])
                while let u = walker?.nextObject() as? URL {
                    if c.isCancelled { return 130 }
                    if [".git", "node_modules", "__pycache__"].contains(u.lastPathComponent) { walker?.skipDescendants(); continue }
                    if !isDir(u) { targets.append(((op == "." ? "" : op.hasSuffix("/") ? op : op + "/") + String(u.path.dropFirst(url.path.count + 1)), u)) }
                }
            } else {
                targets.append((op, url))
            }
        }
        let showNames = f["h"] == nil && (targets.count > 1 || recursive || f["H"] != nil)
        var anyMatch = false
        for (name, url) in targets {
            if c.isCancelled { return 130 }
            let text: String
            if let url {
                guard let data = try? Data(contentsOf: url) else { _ = c.fail("\(name): No such file or directory"); continue }
                if data.prefix(4096).contains(0) { continue } // binary
                text = String(decoding: data, as: UTF8.self)
            } else {
                text = c.stdinText ?? ""
            }
            var count = 0
            for (i, line) in splitLines(text).enumerated() {
                let s = String(line)
                let range = NSRange(s.startIndex..., in: s)
                let hit = regex.firstMatch(in: s, range: range)
                guard (hit != nil) != (f["v"] != nil) else { continue }
                count += 1; anyMatch = true
                if f["l"] != nil || f["c"] != nil { continue }
                var out = ""
                if showNames { out += "\u{1B}[35m\(name)\u{1B}[0m:" }
                if f["n"] != nil { out += "\u{1B}[32m\(i + 1)\u{1B}[0m:" }
                if let hit, f["v"] == nil, let r = Range(hit.range, in: s) {
                    out += String(s[..<r.lowerBound]) + "\u{1B}[1;31m" + String(s[r]) + "\u{1B}[0m" + String(s[r.upperBound...])
                } else {
                    out += s
                }
                c.stdout.line(out)
            }
            if f["l"] != nil, count > 0 { c.stdout.line(name) }
            if f["c"] != nil { c.stdout.line(showNames ? "\(name):\(count)" : String(count)) }
        }
        return anyMatch ? 0 : 1
    }

    // MARK: find / tree

    static func find(_ c: ShellContext) async -> Int32 {
        var args = Array(c.args.dropFirst())
        var roots: [String] = []
        while let a = args.first, !a.hasPrefix("-") { roots.append(a); args.removeFirst() }
        if roots.isEmpty { roots = ["."] }
        var namePattern: String?, caseless = false, type: Character?, maxDepth = Int.max
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "-name", "-iname":
                guard !args.isEmpty else { return c.fail("\(a): requires an argument") }
                namePattern = args.removeFirst(); caseless = a == "-iname"
            case "-type":
                guard let t = args.first?.first, "fd".contains(t) else { return c.fail("-type: use f or d") }
                type = t; args.removeFirst()
            case "-maxdepth":
                guard let n = args.first.flatMap(Int.init) else { return c.fail("-maxdepth: requires a number") }
                maxDepth = n; args.removeFirst()
            default:
                return c.fail("unsupported expression: \(a) (supported: -name, -iname, -type f|d, -maxdepth N)")
            }
        }
        func matches(_ url: URL) -> Bool {
            if let t = type, (t == "d") != isDir(url) { return false }
            if let p = namePattern { return fnmatch(p, url.lastPathComponent, caseless ? FNM_CASEFOLD : 0) == 0 }
            return true
        }
        var status: Int32 = 0
        for root in roots {
            guard let base = try? c.resolve(root), FileManager.default.fileExists(atPath: base.path) else {
                status = c.fail("\(root): No such file or directory"); continue
            }
            if matches(base) { c.stdout.line(root) }
            guard isDir(base), maxDepth > 0 else { continue }
            let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey])
            while let u = walker?.nextObject() as? URL {
                if c.isCancelled { return 130 }
                let depth = walker?.level ?? 1
                if depth >= maxDepth { walker?.skipDescendants() }
                if depth > maxDepth { continue }
                if matches(u) {
                    let rel = String(u.path.dropFirst(base.path.count + 1))
                    c.stdout.line(root == "." ? "./" + rel : (root.hasSuffix("/") ? root : root + "/") + rel)
                }
            }
        }
        return status
    }

    static func tree(_ c: ShellContext) async -> Int32 {
        guard let base = try? c.resolve(c.args.count > 1 ? c.args[1] : ".") else { return c.fail("outside the workspace") }
        guard isDir(base) else { return c.fail("not a directory") }
        var dirs = 0, files = 0
        func walk(_ url: URL, _ prefix: String, _ depth: Int) {
            guard depth < 12, !c.isCancelled else { return }
            let entries = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__pycache__" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for (i, e) in entries.enumerated() {
                let last = i == entries.count - 1
                c.stdout.line(prefix + (last ? "└── " : "├── ") + colored(e))
                if isDir(e) { dirs += 1; walk(e, prefix + (last ? "    " : "│   "), depth + 1) } else { files += 1 }
            }
        }
        c.stdout.line("\u{1B}[1;34m\(c.args.count > 1 ? c.args[1] : ".")\u{1B}[0m")
        walk(base, "", 0)
        c.stdout.line("\n\(dirs) director\(dirs == 1 ? "y" : "ies"), \(files) file\(files == 1 ? "" : "s")")
        return 0
    }

    // MARK: Misc

    static func basename(_ c: ShellContext) async -> Int32 {
        guard c.args.count > 1 else { return c.fail("missing operand") }
        var name = (c.args[1] as NSString).lastPathComponent
        if c.args.count > 2, name.hasSuffix(c.args[2]), name != c.args[2] { name.removeLast(c.args[2].count) }
        c.stdout.line(name); return 0
    }

    static func dirname(_ c: ShellContext) async -> Int32 {
        guard c.args.count > 1 else { return c.fail("missing operand") }
        let d = (c.args[1] as NSString).deletingLastPathComponent
        c.stdout.line(d.isEmpty ? "." : d); return 0
    }

    static func env(_ c: ShellContext) async -> Int32 {
        c.state.env.sorted { $0.key < $1.key }.forEach { c.stdout.line("\($0.key)=\($0.value)") }
        c.stdout.line("PWD=\(c.state.sandbox.display(c.state.cwd))")
        return 0
    }

    static func export(_ c: ShellContext) async -> Int32 {
        if c.args.count == 1 { return await env(c) }
        for a in c.args.dropFirst() {
            guard let eq = a.firstIndex(of: "="), eq != a.startIndex else { return c.fail("\(a): not a valid assignment (use NAME=value)") }
            c.state.env[String(a[..<eq])] = String(a[a.index(after: eq)...])
        }
        return 0
    }

    static func unset(_ c: ShellContext) async -> Int32 {
        c.args.dropFirst().forEach { c.state.env[$0] = nil }; return 0
    }

    static func history(_ c: ShellContext) async -> Int32 {
        for (i, h) in c.state.history.enumerated() { c.stdout.line("\(String(i + 1).leftPad(5))  \(h)") }
        return 0
    }

    static func which(_ c: ShellContext) async -> Int32 {
        var status: Int32 = 0
        for name in c.args.dropFirst() {
            if table[name] != nil || ["python", "python3", "exit"].contains(name) { c.stdout.line("\(name): PocketCode built-in") }
            else { c.stdout.line("\(name) not found"); status = 1 }
        }
        return status
    }

    static func date(_ c: ShellContext) async -> Int32 {
        let df = DateFormatter()
        df.dateFormat = "EEE MMM d HH:mm:ss zzz yyyy"
        c.stdout.line(df.string(from: Date())); return 0
    }

    static func sleep(_ c: ShellContext) async -> Int32 {
        guard let s = c.args.dropFirst().first.flatMap(Double.init), s >= 0 else { return c.fail("usage: sleep seconds") }
        try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
        return Task.isCancelled ? 130 : 0
    }

    static func code(_ c: ShellContext) async -> Int32 {
        guard c.args.count > 1 else { return c.fail("usage: code <file>") }
        var status: Int32 = 0
        for op in c.args.dropFirst() {
            do {
                let url = try c.resolve(op)
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: Data()) }
                guard !isDir(url) else { status = c.fail("\(op): Is a directory"); continue }
                c.services.openInEditor(url.path)
            } catch { status = c.fail("\(op): \(message(error))") }
        }
        return status
    }

    static func help(_ c: ShellContext) async -> Int32 {
        c.stdout.line("\u{1B}[1mPocketCode local shell\u{1B}[0m — runs on this device, inside the workspace folder.")
        c.stdout.line("Not bash: supports quotes, $VARS, globs (*.py), |, >, >>, <, 2>, &&, ||, ;")
        c.stdout.line("")
        for (name, text) in summaries { c.stdout.line("  \u{1B}[36m\(name.padding(toLength: 8, withPad: " ", startingAt: 0))\u{1B}[0m \(text)") }
        c.stdout.line("\nAlso: basename dirname env export unset history which date sleep tree uniq whoami uname exit")
        c.stdout.line("Ctrl-C interrupts, ↑/↓ history, Tab completes names.")
        return 0
    }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}

/// Terminal column width (East Asian wide characters take 2 columns).
func displayWidth(_ s: String) -> Int {
    s.unicodeScalars.reduce(0) { w, u in
        let v = u.value
        if v == 0 || (0x300...0x36F).contains(v) || u.properties.generalCategory == .nonspacingMark { return w }
        let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFD).contains(v)
        return w + (wide ? 2 : 1)
    }
}
