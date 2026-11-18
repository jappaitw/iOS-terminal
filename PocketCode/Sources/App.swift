import SwiftUI

@main
struct PocketCodeApp: App {
    @StateObject private var hosts = HostStore()
    @StateObject private var settings = AppSettings.shared

    init() {
        LocalFileSystem.seedWelcomeProjectIfNeeded()
        EditorDocument.warmUpHighlighting()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(hosts)
                .preferredColorScheme(settings.colorScheme)
                .tint(VS.accent)
        }
        .commands { WorkspaceCommands() }
    }
}

/// Switches between the host picker and an open workspace.
struct RootView: View {
    @State private var workspace: Workspace?

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(workspace: workspace, onClose: {
                    workspace.shutdown()
                    self.workspace = nil
                })
            } else {
                HomeView(onOpen: { self.workspace = $0 })
            }
        }
        .background(VS.editorBG.ignoresSafeArea())
    }
}
