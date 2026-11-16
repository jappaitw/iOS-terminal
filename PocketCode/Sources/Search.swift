import SwiftUI

/// One file's worth of search hits.
struct SearchFileResult: Identifiable {
    var id: String { path }
    let path: String
    var matches: [SearchMatch]
}

struct SearchMatch: Identifiable, Hashable {
    var id: Int { line }
    let line: Int
    let text: String
}

struct SearchOptions: Equatable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
}

/// Find-in-files. Remote: `grep -rn` over SSH exec (fast, no file transfer).
/// Local: walks the folder on a background task.
@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var options = SearchOptions()
    @Published private(set) var results: [SearchFileResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var message: String?
    @Published private(set) var truncated = false
    @Published var collapsed: Set<String> = []

    static let maxMatches = 2000
    private var task: Task<Void, Never>?

    var matchCount: Int { results.reduce(0) { $0 + $1.matches.count } }

    func run(in workspace: Workspace) {
        task?.cancel()
        let q = query
        guard !q.isEmpty, !workspace.rootPath.isEmpty else { results = []; message = nil; return }
        let opts = options, root = workspace.rootPath
        isSearching = true
        message = nil
        task = Task {
            do {
                let found: [SearchFileResult]
                if let connection = workspace.connection {
                    let script = Self.grepScript(query: q, options: opts, root: root)
                    let out = try await connection.run(script, timeoutSeconds: 60)
                    found = Self.parseGrep(out, root: root)
                } else {
                    found = try await Self.searchLocal(query: q, options: opts, root: root)
                }
                guard !Task.isCancelled else { return }
                results = found
                truncated = matchCount >= Self.maxMatches
                collapsed = []
                message = found.isEmpty ? "No results found." : nil
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                message = error.localizedDescription
            }
            isSearching = false
        }
    }

    func clear() { task?.cancel(); query = ""; results = []; message = nil; isSearching = false }

    // MARK: Remote (grep)

    /// `--null` puts a NUL after each file name so names containing ':' parse correctly.
    nonisolated static func grepScript(query: String, options: SearchOptions, root: String) -> String {
        var flags = ["-rnI", "--null", "--color=never"]
        if !options.caseSensitive { flags.append("-i") }
        if options.wholeWord { flags.append("-w") }
        flags.append(options.regex ? "-E" : "-F")
        let excludes = [".git", "node_modules", ".build", "build", "dist", ".venv", "__pycache__", "Pods", "DerivedData"]
            .map { "--exclude-dir=\($0)" }
        return "cd \(PathUtil.shellQuote(root)) && grep \((flags + excludes).joined(separator: " ")) -e \(PathUtil.shellQuote(query)) -- . | head -n \(maxMatches)"
    }

    nonisolated static func parseGrep(_ output: String, root: String) -> [SearchFileResult] {
        var order: [String] = []
        var byPath: [String: [SearchMatch]] = [:]
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let file: Substring, rest: Substring
            if let nul = raw.firstIndex(of: "\0") {
                file = raw[..<nul]; rest = raw[raw.index(after: nul)...]
            } else {
                // grep without --null support: "path:line:text"
                let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                file = parts[0]; rest = parts[1]
            }
            guard let colon = rest.firstIndex(of: ":"), let line = Int(rest[..<colon]) else { continue }
            var text = String(rest[rest.index(after: colon)...])
            if text.count > 300 { text = String(text.prefix(300)) + "…" }
            var rel = String(file)
            if rel.hasPrefix("./") { rel.removeFirst(2) }
            let path = PathUtil.join(root, rel)
            if byPath[path] == nil { order.append(path) }
            byPath[path, default: []].append(SearchMatch(line: line, text: text))
        }
        return order.map { SearchFileResult(path: $0, matches: byPath[$0]!) }
    }

    // MARK: Local

    nonisolated static func searchLocal(query: String, options: SearchOptions, root: String) async throws -> [SearchFileResult] {
        try await Task.detached(priority: .userInitiated) {
            let matcher = try LineMatcher(query: query, options: options)
            let skip: Set<String> = [".git", "node_modules", ".build", "build", "dist", ".venv", "__pycache__", "Pods", "DerivedData"]
            let fm = FileManager.default
            guard let walker = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return [] }
            var results: [SearchFileResult] = []
            var total = 0
            while let url = walker.nextObject() as? URL {
                if Task.isCancelled || total >= maxMatches { break }
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if v?.isDirectory == true {
                    if skip.contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                guard (v?.fileSize ?? 0) < 2 << 20, let data = try? Data(contentsOf: url),
                      data.prefix(8000).firstIndex(of: 0) == nil, let text = String(data: data, encoding: .utf8) else { continue }
                var hits: [SearchMatch] = []
                var n = 0
                text.enumerateLines { line, stop in
                    n += 1
                    if matcher.matches(line) {
                        hits.append(SearchMatch(line: n, text: line.count > 300 ? String(line.prefix(300)) + "…" : line))
                        if total + hits.count >= maxMatches { stop = true }
                    }
                }
                if !hits.isEmpty { results.append(SearchFileResult(path: url.path, matches: hits)); total += hits.count }
            }
            return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }.value
    }
}

/// Matches one line the way grep would for the chosen options.
struct LineMatcher {
    private let regex: NSRegularExpression

    init(query: String, options: SearchOptions) throws {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw FSError.message("Invalid regular expression.")
        }
    }

    func matches(_ line: String) -> Bool { firstRange(in: line) != nil }

    func firstRange(in line: String) -> Range<String.Index>? {
        let ns = NSRange(line.startIndex..., in: line)
        guard let m = regex.firstMatch(in: line, range: ns) else { return nil }
        return Range(m.range, in: line)
    }
}

// MARK: - View

struct SearchView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: SearchModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SEARCH").font(.system(size: 11, weight: .semibold)).foregroundStyle(VS.textDim)
                Spacer()
                if !model.results.isEmpty {
                    Button { model.collapsed = Set(model.results.map(\.path)) } label: { Image(systemName: "rectangle.compress.vertical") }
                    Button { model.clear() } label: { Image(systemName: "xmark.circle") }
                }
            }
            .font(.system(size: 14)).foregroundStyle(VS.text)
            .padding(.horizontal, 14).frame(height: 36)

            HStack(spacing: 4) {
                TextField("Search", text: $model.query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(size: 13))
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { model.run(in: workspace) }
                toggle("Aa", "Match Case", \.caseSensitive)
                toggle("ab", "Match Whole Word", \.wholeWord, underline: true)
                toggle(".*", "Use Regular Expression", \.regex)
            }
            .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 4)
            .background(VS.inputBG, in: RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(focused ? VS.accent : Color.clear, lineWidth: 1))
            .padding(.horizontal, 12)

            summary.padding(.horizontal, 14).padding(.vertical, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // One container per file: match ids (line numbers) repeat across files,
                    // so they must not share the lazy stack's identity space.
                    ForEach(model.results) { file in
                        VStack(alignment: .leading, spacing: 0) {
                            fileHeader(file)
                            if !model.collapsed.contains(file.path) {
                                ForEach(file.matches) { m in matchRow(file, m) }
                            }
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .background(VS.sidebarBG)
        .onChange(of: model.options) { _, _ in if !model.query.isEmpty { model.run(in: workspace) } }
    }

    @ViewBuilder private var summary: some View {
        HStack(spacing: 6) {
            if model.isSearching { ProgressView().controlSize(.mini) }
            if let msg = model.message {
                Text(msg)
            } else if !model.results.isEmpty {
                Text("\(model.matchCount)\(model.truncated ? "+" : "") results in \(model.results.count) files")
            } else if workspace.rootPath.isEmpty {
                Text("Open a folder to search.")
            }
            Spacer()
        }
        .font(.system(size: 11)).foregroundStyle(VS.textDim)
    }

    private func toggle(_ label: String, _ help: String, _ key: WritableKeyPath<SearchOptions, Bool>, underline: Bool = false) -> some View {
        let on = model.options[keyPath: key]
        return Button { model.options[keyPath: key].toggle() } label: {
            Text(label).font(.system(size: 12, weight: .semibold, design: .monospaced)).underline(underline)
                .frame(width: 26, height: 22)
                .background(on ? Color(hex: 0x0E639C).opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? Color(hex: 0x007ACC) : Color.clear))
                .foregroundStyle(on ? Color.white : VS.textDim)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func fileHeader(_ file: SearchFileResult) -> some View {
        let rel = file.path.hasPrefix(workspace.rootPath + "/") ? String(file.path.dropFirst(workspace.rootPath.count + 1)) : file.path
        let dir = PathUtil.parent(rel) == "/" || !rel.contains("/") ? "" : PathUtil.parent(rel)
        return HStack(spacing: 4) {
            Image(systemName: model.collapsed.contains(file.path) ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .semibold)).frame(width: 14)
            FileBadge(path: file.path)
            Text(PathUtil.name(file.path)).font(.system(size: 13)).foregroundStyle(VS.text).lineLimit(1)
            Text(dir).font(.system(size: 11)).foregroundStyle(VS.textDim).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            Text("\(file.matches.count)").font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color(hex: 0x4D4D4D), in: Capsule()).foregroundStyle(VS.text)
        }
        .padding(.horizontal, 8).frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.collapsed.contains(file.path) { model.collapsed.remove(file.path) } else { model.collapsed.insert(file.path) }
        }
    }

    private func matchRow(_ file: SearchFileResult, _ m: SearchMatch) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(m.line)").font(.system(size: 10, design: .monospaced)).foregroundStyle(VS.textDim).frame(minWidth: 26, alignment: .trailing)
            highlighted(m.text.trimmingCharacters(in: .whitespaces)).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 26).padding(.trailing, 8).frame(height: 22)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .onTapGesture { workspace.open(file.path, line: m.line) }
    }

    /// The line with the first match shaded, like VS Code's search results.
    private func highlighted(_ line: String) -> Text {
        guard let matcher = try? LineMatcher(query: model.query, options: model.options),
              let r = matcher.firstRange(in: line) else { return Text(line).foregroundColor(VS.text) }
        var s = AttributedString(String(line[..<r.lowerBound]))
        s.foregroundColor = VS.text
        var hit = AttributedString(String(line[r]))
        hit.backgroundColor = Color(hex: 0x613214)
        hit.foregroundColor = .white
        var tail = AttributedString(String(line[r.upperBound...]))
        tail.foregroundColor = VS.text
        return Text(s + hit + tail)
    }
}
