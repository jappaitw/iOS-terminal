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
    @StateObject private var navigation = WorkspaceNavigation()

    var body: some View {
        Group {
            if let location = navigation.activeLocation, let workspace = navigation.activeWorkspace {
                WorkspaceView(workspace: workspace, onBack: navigation.showHome,
                              onClose: { navigation.close(at: location) })
                    .id(location)
            } else {
                HomeView(navigation: navigation)
            }
        }
        .background(VS.editorBG.ignoresSafeArea())
    }
}

/// Returning home hides the active workspace. Closing it releases its sessions and connection.
@MainActor
final class WorkspaceNavigation: ObservableObject {
    enum Location: Hashable {
        case folder(String)
        case ssh(SSHHost.ID)

        static func local(_ url: URL) -> Self {
            .folder(url.standardizedFileURL.resolvingSymlinksInPath().path)
        }
    }

    struct Entry: Identifiable {
        let id: Location
        let workspace: Workspace
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var activeLocation: Location?

    var activeWorkspace: Workspace? { entries.first { $0.id == activeLocation }?.workspace }

    func open(_ workspace: Workspace, at location: Location) {
        if resume(at: location) {
            if activeWorkspace !== workspace { workspace.shutdown() }
            return
        }
        entries.append(Entry(id: location, workspace: workspace))
        activeLocation = location
    }

    @discardableResult
    func resume(at location: Location) -> Bool {
        guard entries.contains(where: { $0.id == location }) else { return false }
        activeLocation = location
        return true
    }

    func showHome() {
        activeLocation = nil
    }

    func close(at location: Location) {
        guard let index = entries.firstIndex(where: { $0.id == location }) else { return }
        if activeLocation == location { showHome() }
        entries.remove(at: index).workspace.shutdown()
    }
}
