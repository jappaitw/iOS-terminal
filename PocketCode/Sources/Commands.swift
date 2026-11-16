import SwiftUI

/// Menu bar / hardware-keyboard commands. On iPad, holding ⌘ lists these in the shortcut
/// overlay (and iPadOS shows them in the menu bar). Bindings follow VS Code where iOS allows.
struct WorkspaceCommands: Commands {
    @FocusedObject private var workspace: Workspace?

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") { if let w = workspace, let d = w.activeDocument { Task { await w.save(d) } } }
                .keyboardShortcut("s")
                .disabled(workspace?.activeDocument == nil)
            Button("Save All") { if let w = workspace { Task { await w.saveAll() } } }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(workspace == nil)
        }
        CommandGroup(after: .newItem) {
            Button("New Terminal") { workspace?.newTerminal() }
                .keyboardShortcut("`", modifiers: [.control, .shift])
                .disabled(workspace?.isRemote != true)
            Button("Close Editor") { if let w = workspace, let d = w.activeDocument { w.close(d) } }
                .keyboardShortcut("w")
                .disabled(workspace?.activeDocument == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { workspace?.showSettings = true }
                .keyboardShortcut(",")
                .disabled(workspace == nil)
        }
        CommandMenu("View") {
            Button("Explorer") { workspace?.showSidebar(.explorer) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Search") { workspace?.showSidebar(.search) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Toggle Sidebar") { workspace?.toggleSidebar() }
                .keyboardShortcut("b")
            Button("Toggle Terminal") { workspace?.toggleTerminal() }
                .keyboardShortcut("`", modifiers: .control)
            Button("Toggle Panel") { workspace?.toggleTerminal() }
                .keyboardShortcut("j")
            Divider()
            Button("Zoom In") { zoom(1) }.keyboardShortcut("=")
            Button("Zoom Out") { zoom(-1) }.keyboardShortcut("-")
            Button("Reset Zoom") { AppSettings.shared.editorFontSize = 13; AppSettings.shared.terminalFontSize = 12 }
                .keyboardShortcut("0")
        }
        CommandMenu("Go") {
            Button("Next Editor") { workspace?.selectEditor(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Editor") { workspace?.selectEditor(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }

    /// Zooms whichever surface is in front: the terminal panel or the editor.
    private func zoom(_ delta: Double) {
        let s = AppSettings.shared
        if workspace?.panel == .terminal { s.clampTerminalFont(delta) }
        else { s.editorFontSize = min(max(s.editorFontSize + delta, AppSettings.fontRange.lowerBound), AppSettings.fontRange.upperBound) }
    }
}
