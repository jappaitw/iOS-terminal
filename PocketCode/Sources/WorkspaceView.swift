import SwiftUI

/// VS Code-style shell. iPhone (compact): one panel at a time with an activity bar at the bottom.
/// iPad / landscape (regular): activity bar + sidebar + editor with a terminal panel underneath.
struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    let onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("layout.terminalHeight") private var terminalHeight: Double = 260
    @AppStorage("layout.sidebarWidth") private var sidebarWidth: Double = 280
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if hSize == .regular { regularLayout } else { compactLayout }
            StatusBar(workspace: workspace)
            if hSize != .regular { activityBar(vertical: false) }
        }
        .background(VS.editorBG)
        .sheet(isPresented: $workspace.showSettings) { SettingsView() }
        .task { await workspace.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends sockets in the background; check (and rebuild) the session on return.
            if phase == .active { Task { await workspace.ensureConnected() } }
        }
        .alert("Error", isPresented: .constant(workspace.errorMessage != nil), presenting: workspace.errorMessage) { _ in
            Button("OK") { workspace.errorMessage = nil }
        } message: { Text($0) }
        // Keyboard shortcuts live in WorkspaceCommands (menu bar / ⌘ overlay on iPad).
        .focusedSceneObject(workspace)
        .onAppear { workspace.isCompact = hSize != .regular }
        .onChange(of: hSize) { _, h in workspace.isCompact = h != .regular }
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
                if workspace.canOpenTerminal {
                    Button { workspace.newTerminal() } label: { Label("New Terminal", systemImage: "terminal") }
                }
                Divider()
                Button { workspace.showSettings = true } label: { Label("Settings…", systemImage: "gearshape") }
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
            SearchView(workspace: workspace, model: workspace.search).opacity(workspace.panel == .search ? 1 : 0)
                .allowsHitTesting(workspace.panel == .search)
            EditorArea(workspace: workspace).opacity(workspace.panel == .editor ? 1 : 0)
                .allowsHitTesting(workspace.panel == .editor)
                .environment(\.panelActive, workspace.panel == .editor)
            TerminalPanel(workspace: workspace).opacity(workspace.panel == .terminal ? 1 : 0)
                .allowsHitTesting(workspace.panel == .terminal)
                .environment(\.panelActive, workspace.panel == .terminal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Regular (iPad)

    private var regularLayout: some View {
        HStack(spacing: 0) {
            activityBar(vertical: true)
            if workspace.sidebarVisible {
                Group {
                    if workspace.sidebarPanel == .search { SearchView(workspace: workspace, model: workspace.search) }
                    else { ExplorerView(workspace: workspace) }
                }
                .frame(width: sidebarWidth)
                // Drag the divider to resize; the width is remembered.
                Rectangle().fill(VS.border).frame(width: 1)
                    .overlay(Color.clear.frame(width: 16).contentShape(Rectangle())
                        .hoverEffect(.highlight)
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                let start = dragStart ?? sidebarWidth
                                dragStart = start
                                sidebarWidth = min(max(200, start + v.translation.width), 520)
                            }
                            .onEnded { _ in dragStart = nil }))
            }
            GeometryReader { geo in
                VStack(spacing: 0) {
                    EditorArea(workspace: workspace)
                    if workspace.terminalVisible {
                        Rectangle().fill(VS.border).frame(height: 1)
                            .overlay(Color.clear.frame(height: 16).contentShape(Rectangle())
                                .hoverEffect(.highlight)
                                .gesture(DragGesture(minimumDistance: 1)
                                    .onChanged { v in
                                        let start = dragStart ?? terminalHeight
                                        dragStart = start
                                        terminalHeight = min(max(120, start - v.translation.height), geo.size.height - 120)
                                    }
                                    .onEnded { _ in dragStart = nil }))
                        TerminalPanel(workspace: workspace).frame(height: terminalHeight)
                    }
                }
            }
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
                .hoverEffect(.highlight)
                .disabled(p == .terminal && !workspace.canOpenTerminal)
            }
            if vertical { Spacer() }
        }
        .frame(width: vertical ? 48 : nil)
        .background(VS.activityBG)
    }

    private func isActive(_ p: Panel) -> Bool {
        if hSize == .regular {
            switch p {
            case .explorer: return workspace.sidebarVisible && workspace.sidebarPanel == .explorer
            case .search: return workspace.sidebarVisible && workspace.sidebarPanel == .search
            case .editor: return true
            case .terminal: return workspace.terminalVisible
            }
        }
        return workspace.panel == p
    }

    private func select(_ p: Panel) {
        if hSize == .regular {
            switch p {
            case .explorer, .search:
                if workspace.sidebarVisible && workspace.sidebarPanel == p { workspace.sidebarVisible = false } else { workspace.showSidebar(p) }
            case .editor: workspace.sidebarVisible = false
            case .terminal: workspace.toggleTerminal()
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
            if let git = workspace.git {
                Button { Task { await workspace.refreshAll() } } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(git.branch + (git.files.isEmpty ? "" : "*")).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Branch \(git.branch), \(git.files.count) changes. Tap to refresh.")
            }
            LinkIndicator(workspace: workspace)
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

/// Shows reconnect progress; when the link is lost, tapping it retries.
private struct LinkIndicator: View {
    @ObservedObject var workspace: Workspace
    /// A healthy check takes milliseconds; only surface it once it has dragged on for a second.
    @State private var slowCheck = false

    var body: some View {
        Group {
            switch workspace.link {
            case .connected:
                EmptyView()
            case .checking:
                if slowCheck { spinner("Checking connection…") }
            case .reconnecting:
                spinner("Reconnecting…")
            case .lost(let reason):
                Button { Task { await workspace.ensureConnected() } } label: {
                    Label("Disconnected · Retry", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .accessibilityHint(reason)
            }
        }
        .task(id: workspace.link) {
            slowCheck = false
            guard workspace.link == .checking else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { slowCheck = true }
        }
    }

    private func spinner(_ text: String) -> some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini).tint(.white)
            Text(text)
        }
    }
}

private struct DocumentStatus: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject private var settings = AppSettings.shared
    var body: some View {
        // Drop the least useful items first when the bar is narrow (iPhone portrait).
        ViewThatFits(in: .horizontal) {
            items(indent: true, encoding: true)
            items(indent: true, encoding: false)
            items(indent: false, encoding: false)
            Text("Ln \(doc.cursor.line), Col \(doc.cursor.column)")
        }
        .lineLimit(1)
    }

    private func items(indent: Bool, encoding: Bool) -> some View {
        HStack(spacing: 12) {
            Text("Ln \(doc.cursor.line), Col \(doc.cursor.column)")
            if indent { Text(settings.indentLabel).opacity(0.9) }
            if encoding { Text("UTF-8").opacity(0.9) }
            Text(doc.language.name)
        }
        .fixedSize()
    }
}
