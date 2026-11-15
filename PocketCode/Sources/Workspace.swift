import SwiftUI
import Runestone

enum Panel: String, CaseIterable, Identifiable {
    case explorer, editor, terminal
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .explorer: return "doc.on.doc"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        }
    }
    var title: String { rawValue.capitalized }
}

/// An open editor tab.
@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    enum Content { case loading, text, image(UIImage), binary(Int), failed(String) }

    let id = UUID()
    @Published var path: String
    @Published var content: Content = .loading
    @Published var isDirty = false
    @Published var cursor = (line: 1, column: 1)
    var name: String { PathUtil.name(path) }
    var language: LanguageInfo { LanguageInfo.detect(path) }

    /// The Runestone view lives with the document so undo history and scroll position survive tab switches.
    lazy var textView: TextView = EditorDocument.makeTextView()
    private var savedText = ""

    init(path: String) { self.path = path }

    func load(from fs: FileSystemProvider) async {
        content = .loading
        do {
            let data = try await fs.read(path)
            if let image = UIImage(data: data), LanguageInfo.imageExtensions.contains((path as NSString).pathExtension.lowercased()) {
                content = .image(image)
                return
            }
            guard data.prefix(8000).firstIndex(of: 0) == nil, let text = String(data: data, encoding: .utf8) else {
                content = .binary(data.count)
                return
            }
            savedText = text
            let lang = language.treeSitter
            let theme = DarkPlusTheme()
            // Parsing large files can take a moment, so build the state off the main thread.
            let state = await Task.detached { () -> UncheckedBox<TextViewState> in
                if let lang { return UncheckedBox(TextViewState(text: text, theme: theme, language: lang)) }
                return UncheckedBox(TextViewState(text: text, theme: theme))
            }.value
            textView.setState(state.value)
            isDirty = false
            content = .text
        } catch {
            content = .failed(error.localizedDescription)
        }
    }

    func textDidChange() { isDirty = textView.text != savedText }

    func save(to fs: FileSystemProvider) async throws {
        let text = textView.text
        try await fs.write(Data(text.utf8), to: path)
        savedText = text
        isDirty = false
    }

    private static func makeTextView() -> TextView {
        let tv = TextView()
        tv.backgroundColor = UIColor(hex: 0x1E1E1E)
        tv.theme = DarkPlusTheme()
        tv.showLineNumbers = true
        tv.lineSelectionDisplayType = .line
        tv.lineHeightMultiplier = 1.35
        tv.isLineWrappingEnabled = false
        tv.indentStrategy = .space(length: 4)
        tv.gutterLeadingPadding = 8
        tv.gutterTrailingPadding = 8
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 120, right: 16)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.keyboardAppearance = .dark
        tv.alwaysBounceVertical = true
        tv.isFindInteractionEnabled = true
        tv.characterPairs = [("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\""), ("'", "'"), ("`", "`")]
            .map { BasicCharacterPair(leading: $0.0, trailing: $0.1) as CharacterPair }
        return tv
    }
}

struct BasicCharacterPair: CharacterPair {
    let leading: String
    let trailing: String
}

struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

/// Everything about one open folder: its file system, explorer state, editor tabs and terminals.
@MainActor
final class Workspace: ObservableObject {
    let title: String
    let fs: FileSystemProvider
    let connection: SSHConnection?

    @Published var rootPath: String = ""
    @Published var panel: Panel = .explorer
    @Published var documents: [EditorDocument] = []
    @Published var activeDocumentID: EditorDocument.ID?
    @Published var terminals: [TerminalSession] = []
    @Published var activeTerminalID: TerminalSession.ID?
    @Published var errorMessage: String?

    // Explorer tree state
    @Published var expanded: Set<String> = []
    @Published var children: [String: [FileItem]] = [:]
    @Published var loading: Set<String> = []
    @Published var selectedPath: String?
    @Published var showHidden = true

    private var terminalCounter = 0

    var isRemote: Bool { connection != nil }
    var activeDocument: EditorDocument? { documents.first { $0.id == activeDocumentID } }
    var activeTerminal: TerminalSession? { terminals.first { $0.id == activeTerminalID } }

    init(title: String, fs: FileSystemProvider, connection: SSHConnection?) {
        self.title = title
        self.fs = fs
        self.connection = connection
    }

    func bootstrap() async {
        do {
            rootPath = try await fs.initialPath()
            expanded = [rootPath]
            await refresh(rootPath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shutdown() {
        terminals.forEach { $0.stop() }
        connection?.close()
    }

    // MARK: Explorer

    func refresh(_ dir: String) async {
        loading.insert(dir)
        defer { loading.remove(dir) }
        do {
            children[dir] = try await fs.list(dir)
        } catch {
            errorMessage = "\(PathUtil.name(dir)): \(error.localizedDescription)"
        }
    }

    func refreshAll() async {
        for dir in expanded { await refresh(dir) }
    }

    func toggle(_ item: FileItem) {
        selectedPath = item.path
        guard item.isDirectory else { return }
        if expanded.contains(item.path) {
            expanded.remove(item.path)
        } else {
            expanded.insert(item.path)
            if children[item.path] == nil { Task { await refresh(item.path) } }
        }
    }

    func collapseAll() { expanded = [rootPath] }

    /// The explorer tree flattened into visible rows.
    struct Row: Identifiable { let item: FileItem; let depth: Int; var id: String { item.path } }

    var visibleRows: [Row] {
        var rows: [Row] = []
        func walk(_ dir: String, _ depth: Int) {
            for item in children[dir] ?? [] {
                if !showHidden && item.name.hasPrefix(".") { continue }
                rows.append(Row(item: item, depth: depth))
                if item.isDirectory && expanded.contains(item.path) { walk(item.path, depth + 1) }
            }
        }
        walk(rootPath, 0)
        return rows
    }

    /// Directory new files/folders go into, based on the current selection (like VS Code).
    var targetDirectory: String {
        guard let sel = selectedPath else { return rootPath }
        if let item = findItem(sel), item.isDirectory { return item.path }
        return PathUtil.parent(sel)
    }

    func findItem(_ path: String) -> FileItem? {
        children[PathUtil.parent(path)]?.first { $0.path == path }
    }

    func create(name: String, in dir: String, directory: Bool) async {
        let path = PathUtil.join(dir, name)
        do {
            if directory { try await fs.createDirectory(path) } else { try await fs.createFile(path) }
            expanded.insert(dir)
            await refresh(dir)
            selectedPath = path
            if !directory { open(path) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ item: FileItem, to newName: String) async {
        let dir = PathUtil.parent(item.path)
        let newPath = PathUtil.join(dir, newName)
        do {
            try await fs.rename(item.path, to: newPath)
            for doc in documents where doc.path == item.path || doc.path.hasPrefix(item.path + "/") {
                doc.path = newPath + doc.path.dropFirst(item.path.count)
            }
            await refresh(dir)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ item: FileItem) async {
        do {
            try await fs.delete(item)
            documents.removeAll { $0.path == item.path || $0.path.hasPrefix(item.path + "/") }
            if activeDocument == nil { activeDocumentID = documents.last?.id }
            await refresh(PathUtil.parent(item.path))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Editor

    func open(_ path: String) {
        if let doc = documents.first(where: { $0.path == path }) {
            activeDocumentID = doc.id
        } else {
            let doc = EditorDocument(path: path)
            documents.append(doc)
            activeDocumentID = doc.id
            Task { await doc.load(from: fs) }
        }
        selectedPath = path
        panel = .editor
    }

    func close(_ doc: EditorDocument) {
        guard let i = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        documents.remove(at: i)
        if activeDocumentID == doc.id {
            activeDocumentID = documents.isEmpty ? nil : documents[min(i, documents.count - 1)].id
        }
    }

    func save(_ doc: EditorDocument) async {
        do { try await doc.save(to: fs) } catch { errorMessage = "Save failed: \(error.localizedDescription)" }
    }

    func saveAll() async {
        for doc in documents where doc.isDirty { await save(doc) }
    }

    // MARK: Terminal

    func newTerminal(at directory: String? = nil) {
        guard let connection else { return }
        terminalCounter += 1
        let session = TerminalSession(client: connection.client, index: terminalCounter,
                                      initialDirectory: directory ?? (rootPath.isEmpty ? nil : rootPath))
        terminals.append(session)
        activeTerminalID = session.id
        panel = .terminal
    }

    func killTerminal(_ session: TerminalSession) {
        session.stop()
        terminals.removeAll { $0.id == session.id }
        if activeTerminalID == session.id { activeTerminalID = terminals.last?.id }
    }
}
