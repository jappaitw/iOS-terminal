import SwiftUI
import Runestone
import Combine
import TreeSitterSwiftRunestone
import os

let editorLog = Logger(subsystem: "com.jlmxstudio.pocketcode", category: "editor")

enum Panel: String, CaseIterable, Identifiable {
    case explorer, search, editor, terminal
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .explorer: return "doc.on.doc"
        case .search: return "magnifyingglass"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        }
    }
    var title: String { rawValue.capitalized }
}

/// An open editor tab.
@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    enum Content { case loading, text, image(UIImage), binary(Int), tooLarge(UInt64), confirmLarge(UInt64), failed(String) }

    /// Files above this size ask before opening; above `hardLimit` they are refused.
    static let softLimit: UInt64 = 5 * 1024 * 1024
    static let hardLimit: UInt64 = 50 * 1024 * 1024
    /// Above this size syntax highlighting is turned off so typing stays responsive.
    static let highlightLimit: UInt64 = 2 * 1024 * 1024

    let id = UUID()
    @Published var path: String
    @Published var content: Content = .loading
    @Published var isDirty = false
    @Published var cursor = (line: 1, column: 1)
    /// True while the editor has keyboard focus (drives the editor key row).
    @Published var isEditing = false
    var name: String { PathUtil.name(path) }
    var language: LanguageInfo { LanguageInfo.detect(path) }

    /// The Runestone view lives with the document so undo history and scroll position survive tab switches.
    lazy var textView: TextView = { textViewMade = true; return EditorDocument.makeTextView() }()
    private var textViewMade = false
    private var savedText = ""
    private var settingsSub: AnyCancellable?

    init(path: String) {
        self.path = path
        // objectWillChange fires before the value changes; hop a runloop to read the new value.
        settingsSub = AppSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
    }

    /// Pushes font / indent / wrap preferences into the live editor view.
    func applySettings() {
        guard textViewMade else { return }
        Self.apply(AppSettings.shared, to: textView)
    }

    private static func apply(_ s: AppSettings, to tv: TextView) {
        if (tv.theme as? DarkPlusTheme)?.font.pointSize != CGFloat(s.editorFontSize) {
            tv.theme = DarkPlusTheme(fontSize: s.editorFontSize)
        }
        tv.indentStrategy = s.indentWithTabs ? .tab(length: s.indentWidth) : .space(length: s.indentWidth)
        tv.isLineWrappingEnabled = s.lineWrapping
    }

    /// - Parameter force: skip the "this file is large" confirmation (the user tapped Open Anyway).
    func load(from fs: FileSystemProvider, force: Bool = false) async {
        content = .loading
        let t0 = Date()
        do {
            if let size = try? await fs.fileSize(path) {
                if size > Self.hardLimit { content = .tooLarge(size); return }
                if size > Self.softLimit && !force { content = .confirmLarge(size); return }
            }
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
            let lang = data.count > Self.highlightLimit ? nil : language.treeSitter
            let theme = DarkPlusTheme(fontSize: AppSettings.shared.editorFontSize)
            // Parsing large files can take a moment, so build the state off the main thread.
            let state = await Task.detached { () -> UncheckedBox<TextViewState> in
                if let lang { return UncheckedBox(TextViewState(text: text, theme: theme, language: lang)) }
                return UncheckedBox(TextViewState(text: text, theme: theme))
            }.value
            textView.setState(state.value)
            Self.apply(AppSettings.shared, to: textView)
            isDirty = false
            content = .text
            if let line = pendingLine { pendingLine = nil; goTo(line: line) }
            editorLog.info("opened \(data.count) bytes, highlight=\(lang != nil), \(String(format: "%.2f", Date().timeIntervalSince(t0)), privacy: .public)s")
        } catch {
            content = .failed(error.localizedDescription)
        }
    }

    /// The first syntax-highlighted state the app builds pays a one-time ~1s setup cost
    /// (measured in LanguageTests.testHighlightStateTiming); later ones, in any language, are fast.
    /// Paying it in the background at launch keeps the first file open snappy.
    nonisolated static func warmUpHighlighting() {
        Task.detached(priority: .utility) {
            let t0 = Date()
            _ = TextViewState(text: "let x = 1 // warm-up\n", theme: DarkPlusTheme(), language: .swift)
            editorLog.info("highlight warm-up \(String(format: "%.2f", Date().timeIntervalSince(t0)), privacy: .public)s")
        }
    }

    func textDidChange() { isDirty = textView.text != savedText }

    func save(to fs: FileSystemProvider) async throws {
        let text = textView.text
        try await fs.write(Data(text.utf8), to: path)
        savedText = text
        isDirty = false
    }

    /// 1-based line to reveal once the file has loaded (from a search result).
    var pendingLine: Int?

    /// Scrolls to and selects a 1-based line.
    func goTo(line: Int) {
        guard case .text = content else { pendingLine = line; return }
        _ = textView.goToLine(max(line - 1, 0), select: .line)
        cursor = (line, 1) // programmatic selection doesn't call the delegate
    }

    private static func makeTextView() -> TextView {
        let tv = TextView()
        tv.backgroundColor = UIColor(hex: 0x1E1E1E)
        tv.showLineNumbers = true
        tv.lineSelectionDisplayType = .line
        tv.lineHeightMultiplier = 1.35
        apply(AppSettings.shared, to: tv)
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
    private(set) var fs: FileSystemProvider
    let connection: SSHConnection?

    @Published var rootPath: String = ""
    @Published var panel: Panel = .explorer
    @Published var documents: [EditorDocument] = []
    @Published var activeDocumentID: EditorDocument.ID?
    @Published var terminals: [TerminalSession] = []
    @Published var activeTerminalID: TerminalSession.ID?
    @Published var errorMessage: String?
    /// Set when the explorer root can't be loaded at all; shown inline instead of an alert.
    @Published var rootError: String?
    @Published var isRetrying = false

    enum LinkState: Equatable { case connected, checking, reconnecting, lost(String) }
    /// State of the SSH link, shown in the status bar. Always `.connected` for local workspaces.
    @Published private(set) var link: LinkState = .connected
    private var reconnectTask: Task<Bool, Never>?
    /// True when logged in over SSH but the host offers no SFTP (terminal still works).
    var sftpUnavailable: Bool { fs is UnavailableFileSystem }

    // Explorer tree state
    @Published var expanded: Set<String> = []
    @Published var children: [String: [FileItem]] = [:]
    @Published var loading: Set<String> = []
    @Published var selectedPath: String?
    @Published var showHidden = AppSettings.shared.showHiddenFiles

    private var terminalCounter = 0

    // Layout (iPad / regular width). Lives here so menu commands can drive it.
    @Published var isCompact = true
    @Published var sidebarVisible = true
    @Published var sidebarPanel: Panel = .explorer
    @Published var terminalVisible = false
    @Published var showSettings = false

    func showSidebar(_ p: Panel) {
        sidebarPanel = p
        sidebarVisible = true
        panel = p
    }

    func toggleSidebar() {
        if isCompact { panel = .explorer } else { sidebarVisible.toggle() }
    }

    func toggleTerminal() {
        if isCompact {
            if terminals.isEmpty { newTerminal() }
            panel = .terminal
        } else {
            terminalVisible.toggle()
            if terminalVisible && terminals.isEmpty { newTerminal() }
        }
    }

    /// Cycles editor tabs (⌘⇧] / ⌘⇧[).
    func selectEditor(offset: Int) {
        guard !documents.isEmpty else { return }
        let i = documents.firstIndex { $0.id == activeDocumentID } ?? 0
        activeDocumentID = documents[(i + offset + documents.count) % documents.count].id
        panel = .editor
    }
    let search = SearchModel()
    /// Git branch and per-file status for remote workspaces inside a repo (nil otherwise).
    @Published private(set) var git: GitSnapshot?
    private var gitTask: Task<Void, Never>?

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
            rootError = nil
            expanded = [rootPath]
            await refresh(rootPath)
            refreshGit()
        } catch {
            rootError = error.localizedDescription
        }
    }

    /// Retry loading the explorer; on an SFTP-less host this first retries the SFTP subsystem.
    func retryRoot() async {
        isRetrying = true
        defer { isRetrying = false }
        if sftpUnavailable, let connection, let sftp = await connection.reopenSFTP() {
            fs = SFTPFileSystem(sftp: sftp, startPath: connection.host.startPath)
        }
        await bootstrap()
    }

    /// Health check (run when the app returns to the foreground or before restarting a shell).
    /// If the session died, signs in again and moves the explorer and all terminals onto it.
    /// Returns true if the connection is usable afterwards.
    @discardableResult
    func ensureConnected() async -> Bool {
        guard let connection else { return true }
        if let reconnectTask { return await reconnectTask.value }
        let task = Task<Bool, Never> { @MainActor in
            defer { self.reconnectTask = nil }
            self.link = .checking
            let healthy = await connection.isHealthy()
            guard !Task.isCancelled else { return false }
            if healthy { self.link = .connected; return true }
            self.link = .reconnecting
            do {
                try await connection.reconnect()
            } catch {
                self.link = .lost(error.localizedDescription)
                return false
            }
            guard !Task.isCancelled else {
                connection.close()
                return false
            }
            self.fs = connection.makeFileSystem()
            self.link = .connected
            if self.rootError == nil && !self.rootPath.isEmpty { await self.refreshAll() } else { await self.bootstrap() }
            guard !Task.isCancelled else { return false }
            for t in self.terminals { t.reattach(client: connection.client) }
            return true
        }
        reconnectTask = task
        return await task.value
    }

    /// Restart a dead shell, reconnecting first if the SSH session itself is gone.
    func restart(_ session: TerminalSession) async {
        guard await ensureConnected(), !session.isRunning else { return }
        session.start()
    }

    func shutdown() {
        reconnectTask?.cancel()
        gitTask?.cancel()
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
        refreshGit()
    }

    /// Re-reads `git status` on the host. Local workspaces can't run git on iOS, so they show none.
    func refreshGit() {
        guard let connection, !rootPath.isEmpty else { git = nil; return }
        gitTask?.cancel()
        let root = rootPath
        gitTask = Task {
            let out = try? await connection.run(GitSnapshot.script(root: root), timeoutSeconds: 20)
            guard !Task.isCancelled else { return }
            let snap = out.flatMap(GitSnapshot.parse)
            if snap != git { git = snap }
        }
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
            refreshGit()
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
            refreshGit()
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
            refreshGit()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Transfers

    /// Progress text shown while uploading / downloading ("Uploading 2 of 5…").
    @Published var transferStatus: String?
    /// A downloaded file waiting to be handed to the share sheet.
    @Published var shareItem: ShareItem?
    struct ShareItem: Identifiable { let id = UUID(); let url: URL }

    static let transferLimit: UInt64 = 100 * 1024 * 1024

    /// Copies a file to a temporary local file and offers it through the share sheet
    /// ("Save to Files", AirDrop, other apps).
    func download(_ item: FileItem) async {
        guard !item.isDirectory else { return }
        if let size = (try? await fs.fileSize(item.path)) ?? item.size, size > Self.transferLimit {
            errorMessage = "\(item.name) is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .binary)); downloads are limited to 100 MB. Use scp or rsync from a computer instead."
            return
        }
        if !isRemote { shareItem = ShareItem(url: URL(fileURLWithPath: item.path)); return }
        transferStatus = "Downloading \(item.name)…"
        defer { transferStatus = nil }
        do {
            let data = try await fs.read(item.path)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("downloads/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(item.name)
            try data.write(to: url)
            shareItem = ShareItem(url: url)
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    /// Removes the temporary copy once the share sheet is gone.
    func finishedSharing(_ item: ShareItem) {
        guard isRemote else { return }
        try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
    }

    /// Names in `dir` that an upload of `urls` would overwrite (from the explorer's listing).
    func uploadConflicts(_ urls: [URL], in dir: String) -> [String] {
        let existing = Set((children[dir] ?? []).map(\.name))
        return urls.map(\.lastPathComponent).filter(existing.contains)
    }

    /// Uploads files picked from the Files app into `dir`, replacing same-named files.
    func upload(_ urls: [URL], to dir: String) async {
        defer { transferStatus = nil }
        var failures: [String] = []
        for (i, url) in urls.enumerated() {
            transferStatus = urls.count == 1 ? "Uploading \(url.lastPathComponent)…" : "Uploading \(i + 1) of \(urls.count)…"
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
                if size > Self.transferLimit { failures.append("\(url.lastPathComponent) (over 100 MB)"); continue }
                let data = try Data(contentsOf: url)
                try await fs.write(data, to: PathUtil.join(dir, url.lastPathComponent))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        expanded.insert(dir)
        await refresh(dir)
        refreshGit()
        if !failures.isEmpty { errorMessage = "Some files weren't uploaded:\n" + failures.joined(separator: "\n") }
    }

    // MARK: Editor

    func open(_ path: String, line: Int? = nil) {
        if let doc = documents.first(where: { $0.path == path }) {
            activeDocumentID = doc.id
            if let line { doc.goTo(line: line) }
        } else {
            let doc = EditorDocument(path: path)
            doc.pendingLine = line
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
        do { try await doc.save(to: fs); refreshGit() } catch { errorMessage = "Save failed: \(error.localizedDescription)" }
    }

    func saveAll() async {
        for doc in documents where doc.isDirty { await save(doc) }
    }

    // MARK: Terminal

    /// Remote workspaces open a shell over SSH; local ones open PocketCode's on-device shell
    /// rooted at the workspace folder.
    var canOpenTerminal: Bool { isRemote || !rootPath.isEmpty }

    func newTerminal(at directory: String? = nil, agent: Bool = false) {
        terminalCounter += 1
        let dir = directory ?? (rootPath.isEmpty ? nil : rootPath)
        let session: TerminalSession
        if let connection {
            session = TerminalSession(client: connection.client, index: terminalCounter, initialDirectory: dir)
        } else {
            guard !rootPath.isEmpty else { terminalCounter -= 1; return }
            let root = URL(fileURLWithPath: rootPath)
            session = TerminalSession(localRoot: root, index: terminalCounter,
                                      initialDirectory: dir, services: localShellServices(),
                                      agent: agent)
        }
        terminals.append(session)
        activeTerminalID = session.id
        panel = .terminal
        terminalVisible = true
    }

    /// Hooks the local shell uses to reach the rest of the app.
    private func localShellServices() -> ShellServices {
        var services = ShellServices()
        services.openInEditor = { path in
            Task { @MainActor [weak self] in
                await self?.refreshAll()
                self?.open(path)
            }
        }
        services.runPython = PythonRuntime.shellCommand
        services.runCodex = CodexRuntime.shellCommand
        services.runClaude = ClaudeRuntime.shellCommand
        services.runBench = BenchmarkRuntime.shellCommand
        services.runGit = GitRuntime.shellCommand
        return services
    }

    func killTerminal(_ session: TerminalSession) {
        session.stop()
        terminals.removeAll { $0.id == session.id }
        if activeTerminalID == session.id { activeTerminalID = terminals.last?.id }
    }
}
