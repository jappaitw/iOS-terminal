import SwiftUI

struct ExplorerView: View {
    @ObservedObject var workspace: Workspace
    @State private var prompt: NamePrompt?
    @State private var pendingDelete: FileItem?
    /// Folder the file importer will upload into. Kept apart from the presentation flag:
    /// SwiftUI resets the binding *before* calling the completion handler.
    @State private var uploadDir: String?
    @State private var showImporter = false
    @State private var pendingUpload: PendingUpload?

    struct PendingUpload: Identifiable {
        let id = UUID()
        let urls: [URL]
        let dir: String
        let conflicts: [String]
    }

    struct NamePrompt: Identifiable {
        enum Kind { case newFile, newFolder, rename(FileItem) }
        let id = UUID()
        let kind: Kind
        let directory: String
        var text: String
        var title: String {
            switch kind {
            case .newFile: return "New File"
            case .newFolder: return "New Folder"
            case .rename: return "Rename"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let message = workspace.rootError {
                        unavailableState(message)
                    } else if workspace.rootPath.isEmpty || workspace.loading.contains(workspace.rootPath) && workspace.children[workspace.rootPath] == nil {
                        ProgressView().padding(.top, 40)
                    }
                    ForEach(workspace.visibleRows) { row in
                        ExplorerRow(item: row.item, depth: row.depth, workspace: workspace)
                            .contextMenu { menu(for: row.item) }
                    }
                }
                .padding(.bottom, 40)
            }
            .refreshable { await workspace.refreshAll() }
        }
        .background(VS.sidebarBG)
        .overlay(alignment: .bottom) {
            if let status = workspace.transferStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.system(size: 12)).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(hex: 0x2D2D30), in: Capsule())
                .overlay(Capsule().stroke(VS.border))
                .foregroundStyle(VS.text)
                .padding(.bottom, 12)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let dir = uploadDir, case .success(let urls) = result, !urls.isEmpty else { return }
            let conflicts = workspace.uploadConflicts(urls, in: dir)
            if conflicts.isEmpty {
                Task { await workspace.upload(urls, to: dir) }
            } else {
                // Let the picker finish dismissing, or the dialog is dropped.
                Task {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    pendingUpload = PendingUpload(urls: urls, dir: dir, conflicts: conflicts)
                }
            }
        }
        .confirmationDialog(pendingUpload.map { $0.conflicts.count == 1 ? "Replace “\($0.conflicts[0])”?" : "Replace \($0.conflicts.count) existing files?" } ?? "",
                            isPresented: Binding(get: { pendingUpload != nil }, set: { if !$0 { pendingUpload = nil } }),
                            titleVisibility: .visible, presenting: pendingUpload) { p in
            Button("Replace", role: .destructive) { Task { await workspace.upload(p.urls, to: p.dir) } }
            let fresh = p.urls.filter { !p.conflicts.contains($0.lastPathComponent) }
            if !fresh.isEmpty {
                Button("Upload Only New Files (\(fresh.count))") { Task { await workspace.upload(fresh, to: p.dir) } }
            }
        } message: { p in
            Text(p.conflicts.prefix(5).joined(separator: ", ") + (p.conflicts.count > 5 ? "…" : "") + (p.conflicts.count == 1 ? " already exists" : " already exist") + " in this folder.")
        }
        .sheet(item: $workspace.shareItem, onDismiss: nil) { item in
            ShareSheet(url: item.url) { workspace.finishedSharing(item); workspace.shareItem = nil }
                .presentationDetents([.medium, .large])
        }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: Binding(get: { prompt?.text ?? "" }, set: { prompt?.text = $0 }))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) { prompt = nil }
            Button("OK") { commit() }
        } message: {
            if let p = prompt { Text(p.directory) }
        }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item = pendingDelete { Task { await workspace.delete(item) } }
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete?.isDirectory == true ? "The folder and everything in it will be permanently deleted." : "This file will be permanently deleted.")
        }
    }

    private func unavailableState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: workspace.sftpUnavailable ? "folder.badge.questionmark" : "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(VS.textDim)
            Text(workspace.sftpUnavailable ? "File browsing unavailable" : "Couldn't open folder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(VS.text)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(VS.textDim)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button {
                    Task { await workspace.retryRoot() }
                } label: {
                    if workspace.isRetrying { ProgressView().controlSize(.small) } else { Label("Retry", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.bordered)
                .disabled(workspace.isRetrying)
                if workspace.isRemote {
                    Button {
                        if workspace.terminals.isEmpty { workspace.newTerminal() } else { workspace.panel = .terminal }
                    } label: { Label("Open Terminal", systemImage: "terminal") }
                    .buttonStyle(.borderedProminent)
                }
            }
            .font(.system(size: 13))
            .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.top, 48)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 14) {
            Text("EXPLORER").font(.system(size: 11, weight: .semibold)).foregroundStyle(VS.textDim)
            Spacer()
            Button { newItem(folder: false, in: workspace.targetDirectory) } label: { Image(systemName: "doc.badge.plus") }
            Button { newItem(folder: true, in: workspace.targetDirectory) } label: { Image(systemName: "folder.badge.plus") }
            Button { pickUpload(workspace.targetDirectory) } label: { Image(systemName: "square.and.arrow.down.on.square") }
                .accessibilityLabel("Upload Files")
            Button { Task { await workspace.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
            Button { workspace.collapseAll() } label: { Image(systemName: "rectangle.compress.vertical") }
        }
        .font(.system(size: 14))
        .foregroundStyle(VS.text)
        .disabled(workspace.rootError != nil)
        .opacity(workspace.rootError != nil ? 0.35 : 1)
        .padding(.horizontal, 14)
        .frame(height: 36)
            // Root folder title; long-press for New File / New Folder at the root.
            Text(PathUtil.name(workspace.rootPath).uppercased())
                .font(.system(size: 11, weight: .bold)).foregroundStyle(VS.text).lineLimit(1)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu { rootMenu }
        }
    }

    @ViewBuilder private func menu(for item: FileItem) -> some View {
        let dir = item.isDirectory ? item.path : PathUtil.parent(item.path)
        if !item.isDirectory {
            Button { workspace.open(item.path) } label: { Label("Open", systemImage: "doc.text") }
        }
        Button { newItem(folder: false, in: dir) } label: { Label("New File…", systemImage: "doc.badge.plus") }
        Button { newItem(folder: true, in: dir) } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
        Button { pickUpload(dir) } label: { Label("Upload Files Here…", systemImage: "square.and.arrow.down.on.square") }
        if !item.isDirectory {
            Button { Task { await workspace.download(item) } } label: {
                Label(workspace.isRemote ? "Download…" : "Share…", systemImage: "square.and.arrow.up")
            }
        }
        if workspace.isRemote {
            Button { workspace.newTerminal(at: dir) } label: { Label("Open in Integrated Terminal", systemImage: "terminal") }
        }
        Divider()
        Button { UIPasteboard.general.string = item.path } label: { Label("Copy Path", systemImage: "doc.on.clipboard") }
        Button { UIPasteboard.general.string = relativePath(item.path) } label: { Label("Copy Relative Path", systemImage: "doc.on.clipboard") }
        Divider()
        Button { prompt = NamePrompt(kind: .rename(item), directory: PathUtil.parent(item.path), text: item.name) } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Button(role: .destructive) { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
    }

    @ViewBuilder private var rootMenu: some View {
        Button { newItem(folder: false, in: workspace.rootPath) } label: { Label("New File…", systemImage: "doc.badge.plus") }
        Button { newItem(folder: true, in: workspace.rootPath) } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
        Button { pickUpload(workspace.rootPath) } label: { Label("Upload Files Here…", systemImage: "square.and.arrow.down.on.square") }
    }

    private func relativePath(_ path: String) -> String {
        path.hasPrefix(workspace.rootPath + "/") ? String(path.dropFirst(workspace.rootPath.count + 1)) : path
    }

    private func pickUpload(_ dir: String) {
        uploadDir = dir
        showImporter = true
    }

    private func newItem(folder: Bool, in dir: String) {
        prompt = NamePrompt(kind: folder ? .newFolder : .newFile, directory: dir, text: "")
    }

    private func commit() {
        guard let p = prompt else { return }
        prompt = nil
        let name = p.text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return }
        Task {
            switch p.kind {
            case .newFile: await workspace.create(name: name, in: p.directory, directory: false)
            case .newFolder: await workspace.create(name: name, in: p.directory, directory: true)
            case .rename(let item): if name != item.name { await workspace.rename(item, to: name) }
            }
        }
    }
}

private struct ExplorerRow: View {
    let item: FileItem
    let depth: Int
    @ObservedObject var workspace: Workspace

    var body: some View {
        let selected = workspace.selectedPath == item.path
        let openDoc = workspace.documents.first { $0.path == item.path }
        let change = workspace.git?.change(for: item.path)
        let nameColor: Color = openDoc?.isDirty == true ? VS.modified
            : change?.color ?? (item.name.hasPrefix(".") ? VS.textDim : VS.text)
        Group {
            HStack(spacing: 4) {
                // Indent guides
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle().fill(VS.indentGuide).frame(width: 1).frame(maxHeight: .infinity)
                        .padding(.leading, 7).padding(.trailing, 6)
                }
                Group {
                    if item.isDirectory {
                        if workspace.loading.contains(item.path) {
                            ProgressView().scaleEffect(0.5)
                        } else {
                            Image(systemName: workspace.expanded.contains(item.path) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 14)
                if item.isDirectory {
                    Image(systemName: workspace.expanded.contains(item.path) ? "folder.fill" : "folder")
                        .font(.system(size: 13)).foregroundStyle(Color(hex: 0xC09553)).frame(width: 18)
                } else {
                    FileBadge(path: item.path)
                }
                Text(item.name)
                    .font(.system(size: 13))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                if item.isSymlink { Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(VS.textDim) }
                Spacer(minLength: 0)
                if item.isDirectory, let change, workspace.git?.files[item.path] == nil {
                    Circle().fill(change.color).frame(width: 5, height: 5).padding(.trailing, 3)
                } else if let change {
                    Text(change.letter).font(.system(size: 11, weight: .semibold)).foregroundStyle(change.color)
                } else if openDoc?.isDirty == true {
                    Text("M").font(.system(size: 11, weight: .semibold)).foregroundStyle(VS.modified)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(selected ? VS.selectionActive : Color.clear)
            .overlay(alignment: .leading) { if selected { Rectangle().fill(VS.accent).frame(width: 1) } }
        }
        .onTapGesture {
            if item.isDirectory { workspace.toggle(item) } else { workspace.open(item.path) }
        }
        .accessibilityAddTraits(.isButton)
    }
}

/// UIKit share sheet (Save to Files, AirDrop, Open in…).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
