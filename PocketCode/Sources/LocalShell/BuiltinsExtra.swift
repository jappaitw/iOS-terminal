import Foundation

/// Tools the Codex agent (and users coming from desktop shells) reach for
/// constantly: network fetch and text transforms. Unknown flags are skipped
/// with a warning instead of failing — agents pass exotic options, and a
/// best-effort run beats a dead tool call.
extension Builtins {
    // MARK: curl / wget

    static func curl(_ c: ShellContext) async -> Int32 {
        var url: String?
        var method: String?
        var headers: [(String, String)] = []
        var body: String?
        var outputPath: String?
        var silent = false, includeHeaders = false, failOnHTTPError = false
        var timeout: Double = 60
        // Options whose value we must swallow even when we ignore the option.
        let ignoredValued: Set<String> = ["--connect-timeout", "--retry", "-u", "--user", "-A", "--user-agent", "--cacert"]

        var i = 1
        while i < c.args.count {
            let arg = c.args[i]
            func value() -> String? { i += 1; return i < c.args.count ? c.args[i] : nil }
            switch arg {
            case "-s", "--silent", "-S", "--show-error", "-L", "--location", "-k", "--insecure", "-g", "--globoff":
                if arg == "-s" || arg == "--silent" { silent = true }
            case "-i", "--include": includeHeaders = true
            case "-I", "--head": includeHeaders = true; method = "HEAD"
            case "-f", "--fail": failOnHTTPError = true
            case "-X", "--request": method = value()
            case "-H", "--header":
                if let h = value(), let colon = h.firstIndex(of: ":") {
                    headers.append((String(h[..<colon]).trimmingCharacters(in: .whitespaces),
                                    String(h[h.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
                }
            case "-d", "--data", "--data-raw", "--data-binary":
                if let d = value() { body = body.map { $0 + "&" + d } ?? d }
            case "-o", "--output": outputPath = value()
            case "-O", "--remote-name": outputPath = "" // filled from the URL below
            case "--max-time", "-m": timeout = value().flatMap(Double.init) ?? timeout
            default:
                if ignoredValued.contains(arg) { _ = value() }
                else if arg.hasPrefix("-") { c.stderr.line("curl: ignoring unsupported option \(arg)") }
                else { url = arg }
            }
            i += 1
        }

        guard var text = url else { return c.fail("curl: no URL", status: 2) }
        if !text.contains("://") { text = "https://" + text }
        guard let u = URL(string: text), ["http", "https"].contains(u.scheme ?? "") else {
            return c.fail("curl: unsupported URL: \(text)", status: 3)
        }
        var request = URLRequest(url: u, timeoutInterval: timeout)
        request.httpMethod = method ?? (body != nil ? "POST" : "GET")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let body {
            request.httpBody = Data(body.utf8)
            if !headers.contains(where: { $0.0.lowercased() == "content-type" }) {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            if includeHeaders, let http {
                c.stdout.line("HTTP/1.1 \(http.statusCode)")
                for (k, v) in http.allHeaderFields { c.stdout.line("\(k): \(v)") }
                c.stdout.line("")
            }
            if var path = outputPath {
                if path.isEmpty { path = u.lastPathComponent.isEmpty ? "index.html" : u.lastPathComponent }
                do { try data.write(to: try c.resolve(path)) } catch { return c.fail("curl: \(error.localizedDescription)") }
                if !silent { c.stderr.line("curl: saved \(data.count) bytes to \(path)") }
            } else if request.httpMethod != "HEAD" {
                c.stdout.write(data)
            }
            if failOnHTTPError, let http, http.statusCode >= 400 {
                return c.fail("curl: (22) The requested URL returned error: \(http.statusCode)", status: 22)
            }
            return 0
        } catch {
            return c.fail("curl: \(error.localizedDescription)", status: 7)
        }
    }

    /// `wget URL` — download to the URL's filename (or -O name), via curl.
    static func wget(_ c: ShellContext) async -> Int32 {
        var args = ["curl"]
        var i = 1
        var explicitOutput = false
        while i < c.args.count {
            let arg = c.args[i]
            if arg == "-O" || arg == "--output-document" {
                i += 1
                if i < c.args.count { args += ["-o", c.args[i]]; explicitOutput = true }
            } else if arg == "-q" || arg == "--quiet" {
                args.append("-s")
            } else if arg.hasPrefix("-") {
                c.stderr.line("wget: ignoring unsupported option \(arg)")
            } else {
                args.append(arg)
            }
            i += 1
        }
        if !explicitOutput { args.insert(contentsOf: ["-O"], at: 1) }
        return await curl(rewritten(c, args: args))
    }

    // MARK: rg — ripgrep-flavoured front end over the grep engine

    static func rg(_ c: ShellContext) async -> Int32 {
        var args = ["grep", "-r", "-n"]
        var i = 1
        let ignoredValued: Set<String> = ["--glob", "-g", "--type", "-t", "--max-count", "-m", "--threads", "-A", "-B", "-C"]
        while i < c.args.count {
            let arg = c.args[i]
            switch arg {
            case "-i", "--ignore-case", "-v", "--invert-match", "-l", "--files-with-matches",
                 "-c", "--count", "-w", "--word-regexp", "-F", "--fixed-strings":
                args.append(String(arg.prefix(2)))
            case "-e", "--regexp":
                i += 1
                if i < c.args.count { args += ["-e", c.args[i]] }
            case "-N", "--no-line-number":
                args.removeAll { $0 == "-n" }
            case "-S", "--smart-case", "--color", "--no-heading", "--hidden":
                if arg == "--color" { i += 1 } // swallow its value
            default:
                if ignoredValued.contains(arg) { i += 1 }
                else if arg.hasPrefix("-") { c.stderr.line("rg: ignoring unsupported option \(arg)") }
                else { args.append(arg) }
            }
            i += 1
        }
        return await grep(rewritten(c, args: args))
    }

    // MARK: sed — the `s///` subset that covers day-to-day agent use

    static func sed(_ c: ShellContext) async -> Int32 {
        var expressions: [String] = []
        var files: [String] = []
        var inPlace = false, quiet = false
        var i = 1
        while i < c.args.count {
            let arg = c.args[i]
            switch arg {
            case "-n": quiet = true
            case "-i", "--in-place": inPlace = true
            case "-E", "-r": break // our regexes are "extended" already
            case "-e": i += 1; if i < c.args.count { expressions.append(c.args[i]) }
            default:
                if arg.hasPrefix("-") && arg != "-" { c.stderr.line("sed: ignoring unsupported option \(arg)") }
                else if expressions.isEmpty { expressions.append(arg) }
                else { files.append(arg) }
            }
            i += 1
        }
        struct Sub { let regex: NSRegularExpression; let replacement: String; let global: Bool; let print: Bool }
        var subs: [Sub] = []
        for expr in expressions {
            guard expr.count >= 4, expr.hasPrefix("s") else { return c.fail("sed: only s/pattern/replacement/ commands are supported", status: 2) }
            let sep = expr[expr.index(expr.startIndex, offsetBy: 1)]
            let parts = expr.dropFirst(2).split(separator: sep, maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return c.fail("sed: bad expression: \(expr)", status: 2) }
            let flags = parts.count == 3 ? String(parts[2]) : ""
            // sed replacements use \1; NSRegularExpression wants $1.
            var replacement = String(parts[1]).replacingOccurrences(of: "&", with: "$0")
            for n in 1...9 { replacement = replacement.replacingOccurrences(of: "\\\(n)", with: "$\(n)") }
            // BSD sed's basic-regex escapes (\( \) \+ …) are ICU's plain operators.
            var pattern = String(parts[0])
            for (bre, icu) in [("\\(", "("), ("\\)", ")"), ("\\{", "{"), ("\\}", "}"), ("\\+", "+"), ("\\?", "?"), ("\\|", "|")] {
                pattern = pattern.replacingOccurrences(of: bre, with: icu)
            }
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: flags.contains("i") ? [.caseInsensitive] : []) else {
                return c.fail("sed: invalid pattern: \(parts[0])", status: 2)
            }
            subs.append(Sub(regex: regex, replacement: replacement, global: flags.contains("g"), print: flags.contains("p")))
        }
        guard !subs.isEmpty else { return c.fail("usage: sed [-n] [-i] 's/pattern/replacement/[gip]' [file ...]", status: 2) }

        func transform(_ text: String, emit: (String) -> Void) -> String {
            var out: [String] = []
            let keepsTrailingNewline = text.hasSuffix("\n")
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if keepsTrailingNewline { lines.removeLast() } // the artefact after the final newline
            for line in lines {
                var l = String(line)
                var printed = false
                for sub in subs {
                    let range = NSRange(l.startIndex..., in: l)
                    let matched = sub.regex.firstMatch(in: l, range: range) != nil
                    if sub.global {
                        l = sub.regex.stringByReplacingMatches(in: l, range: range, withTemplate: sub.replacement)
                    } else if let m = sub.regex.firstMatch(in: l, range: range) {
                        // Restricting the search range to the first match replaces only it.
                        l = sub.regex.stringByReplacingMatches(in: l, range: m.range, withTemplate: sub.replacement)
                    }
                    if matched, sub.print { printed = true }
                }
                if !quiet { emit(l) } else if printed { emit(l) }
                out.append(l)
            }
            var result = out.joined(separator: "\n")
            if keepsTrailingNewline && !result.hasSuffix("\n") { result += "\n" }
            return result
        }

        if files.isEmpty || files == ["-"] {
            let text = String(decoding: c.stdinData ?? Data(), as: UTF8.self)
            _ = transform(text) { c.stdout.line($0) }
            return 0
        }
        var status: Int32 = 0
        for file in files {
            guard let url = try? c.resolve(file), let data = FileManager.default.contents(atPath: url.path) else {
                status = c.fail("sed: \(file): No such file"); continue
            }
            let result = transform(String(decoding: data, as: UTF8.self)) { if !inPlace { c.stdout.line($0) } }
            if inPlace {
                do { try result.write(to: url, atomically: true, encoding: .utf8) }
                catch { status = c.fail("sed: \(file): \(error.localizedDescription)") }
            }
        }
        return status
    }

    /// A context identical to `c` but with different argv, for delegating builtins.
    private static func rewritten(_ c: ShellContext, args: [String]) -> ShellContext {
        let n = ShellContext(args: args, state: c.state, stdout: c.stdout, stderr: c.stderr,
                             stdinData: c.stdinData, terminalInput: c.terminalInput, services: c.services)
        n.interruptHandler = c.interruptHandler
        return n
    }
}
