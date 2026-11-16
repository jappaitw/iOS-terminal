import Foundation

/// A word as typed, keeping track of which parts were quoted (quoted text is not
/// glob-expanded, and single-quoted text is not variable-expanded).
struct ShellWord: Equatable {
    enum Quote: Equatable { case none, single, double }
    struct Part: Equatable { var text: String; var quote: Quote }
    var parts: [Part]

    var raw: String { parts.map(\.text).joined() }
    var hasUnquotedGlob: Bool {
        parts.contains { $0.quote == .none && $0.text.contains(where: { "*?[".contains($0) }) }
    }
}

struct ShellRedirect: Equatable {
    enum Kind: Equatable { case input, output, append, error, errorAppend, errorToOutput }
    var kind: Kind
    var target: ShellWord?
}

struct ShellCommand: Equatable {
    var words: [ShellWord] = []
    var redirects: [ShellRedirect] = []
}

/// `a | b | c`
struct ShellPipeline: Equatable { var commands: [ShellCommand] }

/// Pipelines joined by `;`, `&&`, `||` (evaluated left to right, like sh).
struct ShellList: Equatable {
    enum Joiner: Equatable { case always, and, or }
    var items: [(joiner: Joiner, pipeline: ShellPipeline)]

    static func == (a: ShellList, b: ShellList) -> Bool {
        a.items.count == b.items.count && zip(a.items, b.items).allSatisfy { $0.joiner == $1.joiner && $0.pipeline == $1.pipeline }
    }
}

enum ShellParseError: LocalizedError, Equatable {
    case unterminatedQuote
    case missingRedirectTarget
    case emptyCommand(String)
    var errorDescription: String? {
        switch self {
        case .unterminatedQuote: return "syntax error: unterminated quote"
        case .missingRedirectTarget: return "syntax error: missing file after redirection"
        case .emptyCommand(let near): return "syntax error near `\(near)`"
        }
    }
}

/// A deliberately small POSIX-sh-like parser: words with '…', "…" and \ escapes,
/// `|`, `;`, `&&`, `||`, `<`, `>`, `>>`, `2>`, `2>>`, `2>&1`, and `#` comments.
/// No subshells, functions, loops or command substitution — PocketCode's local
/// shell is not bash and doesn't pretend to be.
enum ShellParser {
    private enum Token: Equatable {
        case word(ShellWord)
        case pipe, semicolon, and, or
        case redirect(ShellRedirect.Kind)
    }

    static func parse(_ line: String) throws -> ShellList {
        let tokens = try tokenize(line)
        var list = ShellList(items: [])
        var pipeline = ShellPipeline(commands: [])
        var command = ShellCommand()
        var joiner: ShellList.Joiner = .always
        var pendingRedirect: ShellRedirect.Kind?

        func endCommand(near: String) throws {
            if command.words.isEmpty && command.redirects.isEmpty { throw ShellParseError.emptyCommand(near) }
            pipeline.commands.append(command)
            command = ShellCommand()
        }
        func endPipeline(near: String, next: ShellList.Joiner) throws {
            try endCommand(near: near)
            list.items.append((joiner, pipeline))
            pipeline = ShellPipeline(commands: [])
            joiner = next
        }

        for t in tokens {
            if let kind = pendingRedirect {
                guard case .word(let w) = t else { throw ShellParseError.missingRedirectTarget }
                command.redirects.append(ShellRedirect(kind: kind, target: w))
                pendingRedirect = nil
                continue
            }
            switch t {
            case .word(let w): command.words.append(w)
            case .redirect(.errorToOutput): command.redirects.append(ShellRedirect(kind: .errorToOutput, target: nil))
            case .redirect(let k): pendingRedirect = k
            case .pipe: try endCommand(near: "|")
            case .semicolon: try endPipeline(near: ";", next: .always)
            case .and: try endPipeline(near: "&&", next: .and)
            case .or: try endPipeline(near: "||", next: .or)
            }
        }
        if pendingRedirect != nil { throw ShellParseError.missingRedirectTarget }
        if command.words.isEmpty && command.redirects.isEmpty {
            // Trailing `;` is fine; a trailing `|`, `&&` or `||` is not.
            if !pipeline.commands.isEmpty || joiner != .always { throw ShellParseError.emptyCommand("newline") }
        } else {
            pipeline.commands.append(command)
        }
        if !pipeline.commands.isEmpty { list.items.append((joiner, pipeline)) }
        return list
    }

    private static func tokenize(_ line: String) throws -> [Token] {
        var tokens: [Token] = []
        var chars = Array(line)
        var i = 0
        var current: [ShellWord.Part] = []
        var inWord = false

        func appendText(_ s: String, _ q: ShellWord.Quote) {
            if let last = current.last, last.quote == q { current[current.count - 1].text += s }
            else { current.append(.init(text: s, quote: q)) }
            inWord = true
        }
        func flush() {
            if inWord { tokens.append(.word(ShellWord(parts: current))) }
            current = []; inWord = false
        }
        func peek(_ off: Int = 1) -> Character? { i + off < chars.count ? chars[i + off] : nil }

        chars.append("\0") // sentinel simplifies lookahead
        while i < chars.count - 1 {
            let c = chars[i]
            switch c {
            case " ", "\t":
                flush()
            case "#" where !inWord:
                i = chars.count - 1; continue
            case "'":
                guard let end = chars[(i + 1)...].firstIndex(of: "'"), end < chars.count - 1 else { throw ShellParseError.unterminatedQuote }
                appendText(String(chars[(i + 1)..<end]), .single)
                i = end
            case "\"":
                var j = i + 1, text = ""
                while j < chars.count - 1 && chars[j] != "\"" {
                    if chars[j] == "\\", j + 1 < chars.count - 1, "\"\\$`".contains(chars[j + 1]) { text.append(chars[j + 1]); j += 2; continue }
                    text.append(chars[j]); j += 1
                }
                guard j < chars.count - 1 else { throw ShellParseError.unterminatedQuote }
                appendText(text, .double)
                i = j
            case "\\":
                if let n = peek(), n != "\0" { appendText(String(n), .single); i += 1 }
            case "|":
                flush()
                if peek() == "|" { tokens.append(.or); i += 1 } else { tokens.append(.pipe) }
            case "&" where peek() == "&":
                flush(); tokens.append(.and); i += 1
            case ";":
                flush(); tokens.append(.semicolon)
            case ">":
                // `2>` / `2>>` / `2>&1` only when the 2 stands alone as the start of a word.
                if inWord, current.count == 1, current[0].quote == .none, current[0].text == "2" {
                    current = []; inWord = false
                    if peek() == ">" { tokens.append(.redirect(.errorAppend)); i += 1 }
                    else if peek() == "&", peek(2) == "1" { tokens.append(.redirect(.errorToOutput)); i += 2 }
                    else { tokens.append(.redirect(.error)) }
                } else {
                    flush()
                    if peek() == ">" { tokens.append(.redirect(.append)); i += 1 } else { tokens.append(.redirect(.output)) }
                }
            case "<":
                flush(); tokens.append(.redirect(.input))
            default:
                appendText(String(c), .none)
            }
            i += 1
        }
        flush()
        return tokens
    }
}
