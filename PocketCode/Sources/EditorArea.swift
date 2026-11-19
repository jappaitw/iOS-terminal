import SwiftUI
import Runestone

struct EditorArea: View {
    @ObservedObject var workspace: Workspace
    @State private var confirmClose: EditorDocument?
    @State private var previewDoc: EditorDocument?

    var body: some View {
        VStack(spacing: 0) {
            if workspace.documents.isEmpty {
                emptyState
            } else {
                tabBar
                if let doc = workspace.activeDocument {
                    Breadcrumbs(path: doc.path, root: workspace.rootPath)
                    DocumentView(doc: doc, workspace: workspace).id(doc.id)
                }
            }
        }
        .background(VS.editorBG)
        .confirmationDialog("Do you want to save the changes you made to \(confirmClose?.name ?? "")?",
                            isPresented: Binding(get: { confirmClose != nil }, set: { if !$0 { confirmClose = nil } }),
                            titleVisibility: .visible) {
            Button("Save") {
                if let d = confirmClose { Task { await workspace.save(d); if !d.isDirty { workspace.close(d) } } }
                confirmClose = nil
            }
            Button("Don't Save", role: .destructive) { if let d = confirmClose { workspace.close(d) }; confirmClose = nil }
        } message: { Text("Your changes will be lost if you don't save them.") }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(VS.textDim.opacity(0.4))
            Text("Open a file from the Explorer").foregroundStyle(VS.textDim)
            Button("Show Explorer") { workspace.showSidebar(.explorer) }.font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(workspace.documents) { doc in
                        EditorTab(doc: doc, active: doc.id == workspace.activeDocumentID,
                                  onSelect: { workspace.activeDocumentID = doc.id },
                                  onClose: { if doc.isDirty { confirmClose = doc } else { workspace.close(doc) } })
                            .id(doc.id)
                    }
                }
            }
            .onChange(of: workspace.activeDocumentID) { _, id in withAnimation { proxy.scrollTo(id) } }
        }
        .frame(height: 35)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            HStack(spacing: 2) {
                if let doc = workspace.activeDocument, isPreviewable(doc.path) {
                    Button {
                        Task { if doc.isDirty { await workspace.save(doc) }; previewDoc = doc }
                    } label: {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 14))
                            .frame(width: 30, height: 35)
                            .background(Color(hex: 0x252526))
                    }
                    .accessibilityLabel("Preview")
                }
                if let doc = workspace.activeDocument { SaveButton(doc: doc, workspace: workspace) }
            }
        }
        .background(Color(hex: 0x252526))
        .sheet(item: $previewDoc) { doc in
            if workspace.isRemote {
                WebPreviewSheet(title: doc.name, fileURL: nil, rootURL: nil, html: doc.textView.text)
            } else {
                WebPreviewSheet(title: doc.name,
                                fileURL: URL(fileURLWithPath: doc.path),
                                rootURL: URL(fileURLWithPath: workspace.rootPath), html: nil)
            }
        }
    }

    private func isPreviewable(_ path: String) -> Bool {
        ["html", "htm", "svg"].contains((path as NSString).pathExtension.lowercased())
    }
}

/// Editor-group action on the right of the tab bar, shown while the active file has unsaved changes.
private struct SaveButton: View {
    @ObservedObject var doc: EditorDocument
    let workspace: Workspace
    var body: some View {
        if doc.isDirty {
            Button { Task { await workspace.save(doc) } } label: {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                    .frame(width: 44, height: 35)
                    .background(Color(hex: 0x252526))
            }
            .accessibilityLabel("Save")
        }
    }
}

private struct EditorTab: View {
    @ObservedObject var doc: EditorDocument
    let active: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            FileBadge(path: doc.path)
            Text(doc.name).font(.system(size: 13)).foregroundStyle(active ? Color.white : VS.textDim).lineLimit(1)
            Button(action: onClose) {
                Image(systemName: doc.isDirty ? "circle.fill" : "xmark")
                    .font(.system(size: doc.isDirty ? 8 : 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(active || doc.isDirty ? VS.text : VS.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 35)
        .background(active ? VS.editorBG : VS.tabInactiveBG)
        .overlay(alignment: .top) { if active { Rectangle().fill(VS.accent).frame(height: 1) } }
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Close", action: onClose)
            Button("Copy Path") { UIPasteboard.general.string = doc.path }
        }
    }
}

private struct Breadcrumbs: View {
    let path: String
    let root: String
    var body: some View {
        let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        let parts = rel.split(separator: "/").map(String.init)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8)) }
                    if i == parts.count - 1 { FileBadge(path: part).scaleEffect(0.85) }
                    Text(part)
                }
            }
            .padding(.horizontal, 12)
        }
        .font(.system(size: 12))
        .foregroundStyle(VS.textDim)
        .frame(height: 22)
        .background(VS.editorBG)
    }
}

private struct DocumentView: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var workspace: Workspace
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        switch doc.content {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text:
            VStack(spacing: 0) {
                CodeEditor(doc: doc)
                if doc.isEditing && settings.showKeyRow {
                    EditorKeyRow(doc: doc, onSave: { Task { await workspace.save(doc) } })
                }
            }
        case .image(let img):
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: img).interpolation(.none)
            }
            .background(Color(hex: 0x1E1E1E))
        case .binary(let size):
            message(icon: "doc.questionmark",
                    text: "The file is not displayed in the text editor because it is either binary or uses an unsupported text encoding.\n\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        case .tooLarge(let size):
            message(icon: "doc.badge.ellipsis",
                    text: "This file is \(Self.format(size)), which is too large to open in the editor (limit \(Self.format(EditorDocument.hardLimit))).\nUse the terminal (less, head, tail) to view it.",
                    reload: false)
        case .confirmLarge(let size):
            VStack(spacing: 12) {
                Image(systemName: "doc.badge.ellipsis").font(.largeTitle)
                Text("This file is \(Self.format(size)). Opening it may be slow\(size > EditorDocument.highlightLimit ? " and syntax highlighting will be turned off" : "").")
                    .multilineTextAlignment(.center).font(.callout)
                Button("Open Anyway") { Task { await doc.load(from: workspace.fs, force: true) } }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.white)
            }
            .foregroundStyle(VS.textDim).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let err):
            message(icon: "exclamationmark.triangle", text: err)
        }
    }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    private func message(icon: String, text: String, reload: Bool = true) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle)
            Text(text).multilineTextAlignment(.center).font(.callout)
            if reload { Button("Reload") { Task { await doc.load(from: workspace.fs) } } }
        }
        .foregroundStyle(VS.textDim).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hosts the document's Runestone TextView.
private struct CodeEditor: UIViewRepresentable {
    let doc: EditorDocument
    @Environment(\.panelActive) private var active

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    func makeUIView(context: Context) -> TextView {
        let tv = doc.textView
        tv.editorDelegate = context.coordinator
        tv.inputAccessoryView = nil // the key row lives in the layout (EditorKeyRow)
        return tv
    }

    func updateUIView(_ uiView: TextView, context: Context) {
        uiView.isUserInteractionEnabled = active
        // Runestone's first responder is an internal subview, so `isFirstResponder` is always
        // false here; resign on the visible → hidden transition instead, or typing elsewhere
        // (e.g. the Search field) would land in this hidden editor.
        if context.coordinator.wasActive && !active { _ = uiView.resignFirstResponder() }
        context.coordinator.wasActive = active
    }

    @MainActor
    final class Coordinator: NSObject, TextViewDelegate {
        let doc: EditorDocument
        var wasActive = true
        init(doc: EditorDocument) { self.doc = doc }

        func textViewDidChange(_ textView: TextView) { doc.textDidChange() }
        func textViewDidBeginEditing(_ textView: TextView) { doc.isEditing = true }
        func textViewDidEndEditing(_ textView: TextView) { doc.isEditing = false }

        func textViewDidChangeSelection(_ textView: TextView) {
            if let loc = textView.textLocation(at: textView.selectedRange.location) {
                doc.cursor = (loc.lineNumber + 1, loc.column + 1)
            }
        }
    }
}

/// Editor symbols that are painful to reach on the iOS keyboard, on the shared key row.
private struct EditorKeyRow: View {
    let doc: EditorDocument
    let onSave: () -> Void

    var body: some View {
        let tv = doc.textView
        KeyRow(keys: [
            .icon("arrow.right.to.line", id: "indent") { tv.insertText(AppSettings.shared.indentString) },
            .icon("arrow.left", id: "left") { move(tv, -1) },
            .icon("arrow.right", id: "right") { move(tv, 1) },
        ] + ["{", "}", "(", ")", "[", "]", "<", ">", "=", ";", ":", "\"", "'", "`", "/", "\\", "|", "&", "$", "#", "_", "-", "+", "*", "!", "?"]
            .map { s in RowKey.text(s) { tv.insertText(s) } } + [
            .icon("arrow.uturn.backward", id: "undo") { tv.undoManager?.undo() },
            .icon("arrow.uturn.forward", id: "redo") { tv.undoManager?.redo() },
            .icon("magnifyingglass", id: "find") { tv.findInteraction?.presentFindNavigator(showingReplace: true) },
            .icon("square.and.arrow.down", id: "save", onSave),
            .icon("keyboard.chevron.compact.down", id: "hide keyboard") { _ = tv.resignFirstResponder() },
        ])
    }

    private func move(_ tv: TextView, _ delta: Int) {
        let r = tv.selectedRange
        let loc = delta < 0 ? max(r.location - 1, 0) : min(r.location + r.length + 1, (tv.text as NSString).length)
        tv.selectedRange = NSRange(location: r.length > 0 ? (delta < 0 ? r.location : r.location + r.length) : loc, length: 0)
    }
}
