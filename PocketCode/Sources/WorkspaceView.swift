import SwiftUI

/// VS Code-style shell. iPhone (compact): one panel at a time with an activity bar at the bottom.
/// iPad / landscape (regular): activity bar + sidebar + editor with a terminal panel underneath.
struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    let onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var sidebarVisible = true
    @State private var terminalVisible = false
    @State private var terminalHeight: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if hSize == .regular { regularLayout } else { compactLayout }
            StatusBar(workspace: workspace)
            if hSize != .regular { activityBar(vertical: false) }
        }
        .background(VS.editorBG)
        .task { await workspace.bootstrap() }
        .alert("Error", isPresented: .constant(workspace.errorMessage != nil), presenting: workspace.errorMessage) { _ in
            Button("OK") { workspace.errorMessage = nil }
        } message: { Text($0) }
        .background {
            // Hardware keyboard shortcuts
            Group {
                Button("") { if let d = workspace.activeDocument { Task { await workspace.save(d) } } }
                    .keyboardShortcut("s", modifiers: .command)
                Button("") { Task { await workspace.saveAll() } }.keyboardShortcut("s", modifiers: [.command, .option])
                Button("") { if let d = workspace.activeDocument { workspace.close(d) } }.keyboardShortcut("w", modifiers: .command)
                Button("") { sidebarVisible.toggle(); workspace.panel = .explorer }.keyboardShortcut("b", modifiers: .command)
                Button("") { toggleTerminal() }.keyboardShortcut("`", modifiers: .control)
            }
            .opacity(0)
        }
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
            }
            Spacer()
            HStack(spacing: 6) {
                if workspace.isRemote {
                    Image(systemName: "server.rack").font(.caption2).foregroundStyle(VS.statusBarRemote)
                }
                Text(workspace.title).font(.system(size: 13, weight: .medium)).foregroundStyle(VS.text).lineLimit(1)
            }
            Spacer()
            Menu {
                if let doc = workspace.activeDocument {
                    Button { Task { await workspace.save(doc) } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                }
                Button { Task { await workspace.saveAll() } } label: { Label("Save All", systemImage: "square.and.arrow.down.on.square") }
                Button { Task { await workspace.refreshAll() } } label: { Label("Refresh Explorer", systemImage: "arrow.clockwise") }
                Toggle(isOn: $workspace.showHidden) { Label("Show Hidden Files", systemImage: "eye") }
                if workspace.isRemote {
                    Button { workspace.newTerminal(); terminalVisible = true } label: { Label("New Terminal", systemImage: "terminal") }
                }
                Divider()
                Button(role: .destructive, action: onClose) { Label("Close Workspace", systemImage: "xmark") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).frame(width: 28, height: 28)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(VS.titleBG)
        .foregroundStyle(VS.text)
    }

    // MARK: Compact (iPhone)

    @ViewBuilder private var compactLayout: some View {
        ZStack {
            ExplorerView(workspace: workspace).opacity(workspace.panel == .explorer ? 1 : 0)
                .allowsHitTesting(workspace.panel == .explorer)
            EditorArea(workspace: workspace).opacity(workspace.panel == .editor ? 1 : 0)
                .allowsHitTesting(workspace.panel == .editor)
            TerminalPanel(workspace: workspace).opacity(workspace.panel == .terminal ? 1 : 0)
                .allowsHitTesting(workspace.panel == .terminal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Regular (iPad)

    private var regularLayout: some View {
        HStack(spacing: 0) {
            activityBar(vertical: true)
            if sidebarVisible {
                ExplorerView(workspace: workspace).frame(width: 280)
                Rectangle().fill(VS.border).frame(width: 1)
            }
            GeometryReader { geo in
                VStack(spacing: 0) {
                    EditorArea(workspace: workspace)
                    if terminalVisible {
                        Rectangle().fill(VS.border).frame(height: 1)
                            .overlay(Color.clear.frame(height: 14).contentShape(Rectangle()).gesture(
                                DragGesture().onChanged { v in
                                    terminalHeight = min(max(120, terminalHeight - v.translation.height), geo.size.height - 120)
                                }))
                        TerminalPanel(workspace: workspace).frame(height: terminalHeight)
                    }
                }
            }
        }
    }

    private func toggleTerminal() {
        if hSize == .regular {
            terminalVisible.toggle()
            if terminalVisible && workspace.terminals.isEmpty { workspace.newTerminal() }
        } else {
            workspace.panel = .terminal
        }
    }

    // MARK: Activity bar

    private func activityBar(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            ForEach(Panel.allCases) { p in
                Button { select(p) } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: p.icon).font(.system(size: vertical ? 20 : 19))
                            if p == .editor && workspace.documents.contains(where: \.isDirty) {
                                Circle().fill(VS.text).frame(width: 7, height: 7).offset(x: 5, y: -2)
                            }
                            if p == .terminal && !workspace.terminals.isEmpty {
                                Text("\(workspace.terminals.count)").font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4).background(VS.accent, in: Capsule()).foregroundStyle(.white)
                                    .offset(x: 9, y: -5)
                            }
                        }
                        if !vertical { Text(p.title).font(.system(size: 10)) }
                    }
                    .foregroundStyle(isActive(p) ? Color.white : VS.textDim)
                    .frame(maxWidth: vertical ? 48 : .infinity)
                    .frame(height: vertical ? 48 : 50)
                    .overlay(alignment: vertical ? .leading : .top) {
                        if isActive(p) {
                            Rectangle().fill(Color.white).frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
                        }
                    }
                }
                .disabled(p == .terminal && !workspace.isRemote)
            }
            if vertical { Spacer() }
        }
        .frame(width: vertical ? 48 : nil)
        .background(VS.activityBG)
    }

    private func isActive(_ p: Panel) -> Bool {
        if hSize == .regular {
            switch p {
            case .explorer: return sidebarVisible
            case .editor: return true
            case .terminal: return terminalVisible
            }
        }
        return workspace.panel == p
    }

    private func select(_ p: Panel) {
        if hSize == .regular {
            switch p {
            case .explorer: sidebarVisible.toggle()
            case .editor: sidebarVisible = false
            case .terminal: toggleTerminal()
            }
        } else {
            if p == .terminal && workspace.terminals.isEmpty { workspace.newTerminal() }
            workspace.panel = p
        }
    }
}

/// The blue (or green, when remote) bar along the bottom.
struct StatusBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: workspace.isRemote ? "chevron.left.forwardslash.chevron.right" : "iphone")
                Text(workspace.isRemote ? "SSH: \(workspace.title)" : "Local")
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(workspace.isRemote ? VS.statusBarRemote : Color.clear)
            Spacer()
            if let doc = workspace.activeDocument {
                DocumentStatus(doc: doc)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(VS.statusBar)
    }
}

private struct DocumentStatus: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        HStack(spacing: 12) {
            Text("Ln \(doc.cursor.line), Col \(doc.cursor.column)")
            Text("Spaces: 4").opacity(0.9)
            Text("UTF-8").opacity(0.9)
            Text(doc.language.name)
        }
        .lineLimit(1)
    }
}
