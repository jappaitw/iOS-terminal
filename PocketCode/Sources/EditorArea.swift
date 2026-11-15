import SwiftUI
import Runestone

struct EditorArea: View {
    @ObservedObject var workspace: Workspace
    @State private var confirmClose: EditorDocument?

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
            Button("Show Explorer") { workspace.panel = .explorer }.font(.callout)
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
            if let doc = workspace.activeDocument { SaveButton(doc: doc, workspace: workspace) }
        }
        .background(Color(hex: 0x252526))
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

    var body: some View {
        switch doc.content {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text:
            CodeEditor(doc: doc, onSave: { Task { await workspace.save(doc) } })
                .ignoresSafeArea(.keyboard, edges: [])
        case .image(let img):
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: img).interpolation(.none)
            }
            .background(Color(hex: 0x1E1E1E))
        case .binary(let size):
            message(icon: "doc.questionmark",
                    text: "The file is not displayed in the text editor because it is either binary or uses an unsupported text encoding.\n\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        case .failed(let err):
            message(icon: "exclamationmark.triangle", text: err)
        }
    }

    private func message(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle)
            Text(text).multilineTextAlignment(.center).font(.callout)
            Button("Reload") { Task { await doc.load(from: workspace.fs) } }
        }
        .foregroundStyle(VS.textDim).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hosts the document's Runestone TextView.
private struct CodeEditor: UIViewRepresentable {
    let doc: EditorDocument
    let onSave: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc, onSave: onSave) }

    func makeUIView(context: Context) -> TextView {
        let tv = doc.textView
        tv.editorDelegate = context.coordinator
        tv.inputAccessoryView = context.coordinator.makeAccessory(for: tv)
        return tv
    }

    func updateUIView(_ uiView: TextView, context: Context) {
        context.coordinator.onSave = onSave
    }

    @MainActor
    final class Coordinator: NSObject, TextViewDelegate {
        let doc: EditorDocument
        var onSave: () -> Void
        weak var textView: TextView?

        init(doc: EditorDocument, onSave: @escaping () -> Void) {
            self.doc = doc
            self.onSave = onSave
        }

        func textViewDidChange(_ textView: TextView) { doc.textDidChange() }

        func textViewDidChangeSelection(_ textView: TextView) {
            if let loc = textView.textLocation(at: textView.selectedRange.location) {
                doc.cursor = (loc.lineNumber + 1, loc.column + 1)
            }
        }

        /// Keyboard row with the symbols that are painful to reach on the iOS keyboard.
        func makeAccessory(for tv: TextView) -> UIView {
            textView = tv
            let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 400, height: 44), inputViewStyle: .keyboard)
            let scroll = UIScrollView()
            scroll.showsHorizontalScrollIndicator = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(scroll)
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(stack)

            func key(_ title: String?, image: String? = nil, _ action: @escaping () -> Void) -> UIButton {
                var cfg = UIButton.Configuration.filled()
                cfg.baseBackgroundColor = UIColor(hex: 0x3C3C3C)
                cfg.baseForegroundColor = UIColor(hex: 0xE0E0E0)
                cfg.contentInsets = .init(top: 6, leading: 10, bottom: 6, trailing: 10)
                if let image { cfg.image = UIImage(systemName: image) }
                if let title {
                    cfg.attributedTitle = AttributedString(title, attributes: .init([.font: UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)]))
                }
                return UIButton(configuration: cfg, primaryAction: UIAction { _ in action() })
            }

            stack.addArrangedSubview(key("⇥") { [weak self] in self?.textView?.insertText("    ") })
            for s in ["{", "}", "(", ")", "[", "]", "<", ">", "=", ";", ":", "\"", "'", "`", "/", "\\", "|", "&", "$", "#", "_", "-", "+", "*", "!", "?"] {
                stack.addArrangedSubview(key(s) { [weak self] in self?.textView?.insertText(s) })
            }
            stack.addArrangedSubview(key(nil, image: "arrow.uturn.backward") { [weak self] in self?.textView?.undoManager?.undo() })
            stack.addArrangedSubview(key(nil, image: "arrow.uturn.forward") { [weak self] in self?.textView?.undoManager?.redo() })
            stack.addArrangedSubview(key(nil, image: "magnifyingglass") { [weak self] in
                self?.textView?.findInteraction?.presentFindNavigator(showingReplace: true)
            })
            stack.addArrangedSubview(key(nil, image: "square.and.arrow.down") { [weak self] in self?.onSave() })
            stack.addArrangedSubview(key(nil, image: "keyboard.chevron.compact.down") { [weak self] in self?.textView?.resignFirstResponder() })

            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: bar.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
                stack.heightAnchor.constraint(equalToConstant: 34),
            ])
            return bar
        }
    }
}
