import SwiftUI
import SwiftTerm

struct TerminalPanel: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            header
            if let session = workspace.activeTerminal {
                TerminalBody(session: session, workspace: workspace).id(session.id)
            } else {
                VStack(spacing: 12) {
                    if workspace.isRemote {
                        Button { workspace.newTerminal() } label: { Label("New Terminal", systemImage: "plus") }
                    } else {
                        Image(systemName: "terminal").font(.largeTitle).foregroundStyle(VS.textDim)
                        Text("The terminal needs an SSH host.\niOS doesn't allow apps to run a local shell.")
                            .multilineTextAlignment(.center).font(.callout).foregroundStyle(VS.textDim)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(VS.panelBG)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("TERMINAL").font(.system(size: 11, weight: .semibold)).foregroundStyle(VS.text)
                .padding(.horizontal, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(VS.text).frame(height: 1).padding(.horizontal, 12).offset(y: 9) }
            Spacer()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.terminals) { s in
                        TerminalTabChip(session: s, active: s.id == workspace.activeTerminalID) {
                            workspace.activeTerminalID = s.id
                        }
                    }
                }
            }
            .frame(maxWidth: 220)
            Group {
                Button { workspace.newTerminal() } label: { Image(systemName: "plus") }
                if let s = workspace.activeTerminal {
                    Button { workspace.killTerminal(s) } label: { Image(systemName: "trash") }
                    TerminalMenu(session: s)
                }
            }
            .font(.system(size: 14))
            .frame(width: 34, height: 34)
            .disabled(!workspace.isRemote)
        }
        .foregroundStyle(VS.text)
        .frame(height: 35)
        .overlay(alignment: .top) { Rectangle().fill(VS.border).frame(height: 1) }
    }
}

/// The terminal, its key row, and (once the shell has ended) a restart banner.
private struct TerminalBody: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @ObservedObject private var settings = AppSettings.shared
    @State private var restarting = false

    var body: some View {
        TerminalHost(session: session)
        if !session.isRunning {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(VS.textDim)
                Text(session.exitMessage ?? "Process exited")
                    .font(.system(size: 12)).foregroundStyle(VS.text).lineLimit(2)
                Spacer()
                Button {
                    restarting = true
                    Task {
                        await workspace.restart(session)
                        restarting = false
                        _ = session.terminalView.becomeFirstResponder()
                    }
                } label: {
                    HStack(spacing: 4) {
                        if restarting { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                        Text("Restart")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color(hex: 0x0E639C), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                }
                .disabled(restarting)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(hex: 0x252526))
            .overlay(alignment: .top) { Rectangle().fill(VS.border).frame(height: 1) }
        } else if settings.showKeyRow {
            TerminalKeyRow(session: session)
        }
    }
}

private struct TerminalTabChip: View {
    @ObservedObject var session: TerminalSession
    let active: Bool
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "terminal").font(.system(size: 10))
                Text(session.title).lineLimit(1)
                if !session.isRunning { Circle().fill(VS.error).frame(width: 5, height: 5) }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(active ? VS.selection : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(active ? Color.white : VS.textDim)
        }
        .buttonStyle(.plain)
    }
}

/// Terminal actions. Copy / Paste / Select are also on SwiftTerm's own long-press menu;
/// these live in a button so they never fight the selection gesture.
private struct TerminalMenu: View {
    let session: TerminalSession
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Menu {
            Button { session.terminalView.paste(nil) } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                .disabled(!UIPasteboard.general.hasStrings)
            Button { session.terminalView.selectAll(nil) } label: { Label("Select All", systemImage: "selection.pin.in.out") }
            Button { session.clearScreen() } label: { Label("Clear", systemImage: "clear") }
            Divider()
            ControlGroup {
                Button { settings.clampTerminalFont(-1) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                Button { settings.clampTerminalFont(1) } label: { Label("Larger", systemImage: "textformat.size.larger") }
            } label: { Text("Font Size \(Int(settings.terminalFontSize))") }
        } label: { Image(systemName: "ellipsis") }
        .accessibilityLabel("Terminal Actions")
    }
}

/// Terminal keys the iOS keyboard lacks, on the shared key row.
private struct TerminalKeyRow: View {
    let session: TerminalSession
    @State private var ctrlOn = false

    var body: some View {
        KeyRow(keys: [
            .text("esc") { send("\u{1b}") },
            RowKey(id: "ctrl", title: "ctrl", highlighted: ctrlOn) {
                session.terminalView.controlModifier.toggle()
                ctrlOn = session.terminalView.controlModifier
            },
            .icon("arrow.right.to.line", id: "tab") { send("\t") },
        ] + ["~", "|", "/", "-", "_", "$", "\"", "'"].map { s in RowKey.text(s) { send(s) } } + [
            arrow("arrow.left", "D"), arrow("arrow.down", "B"), arrow("arrow.up", "A"), arrow("arrow.right", "C"),
            .icon("keyboard.chevron.compact.down", id: "hide keyboard") { _ = session.terminalView.resignFirstResponder() },
        ])
        // SwiftTerm resets its ctrl latch after the next key; mirror that.
        .onReceive(NotificationCenter.default.publisher(for: .terminalViewControlModifierReset)) { _ in ctrlOn = false }
    }

    private func send(_ s: String) { session.send(text: s); ctrlOn = session.terminalView.controlModifier }

    private func arrow(_ image: String, _ letter: String) -> RowKey {
        .icon(image) {
            let app = session.terminalView.getTerminal().applicationCursor
            send("\u{1b}" + (app ? "O" : "[") + letter)
        }
    }
}

/// Embeds the session's long-lived SwiftTerm view.
private struct TerminalHost: UIViewRepresentable {
    let session: TerminalSession
    @Environment(\.panelActive) private var active

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(hex: 0x1E1E1E)
        // Pinch to change the font size (does not interfere with long-press selection).
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        container.addGestureRecognizer(pinch)
        attach(session.terminalView, to: container)
        DispatchQueue.main.async { _ = session.terminalView.becomeFirstResponder() }
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if session.terminalView.superview !== container { attach(session.terminalView, to: container) }
        container.isUserInteractionEnabled = active
        if context.coordinator.wasActive && !active { _ = session.terminalView.resignFirstResponder() }
        context.coordinator.wasActive = active
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject {
        var wasActive = true
        private var startSize: Double = 12
        @objc func pinched(_ g: UIPinchGestureRecognizer) {
            let settings = AppSettings.shared
            switch g.state {
            case .began: startSize = settings.terminalFontSize
            case .changed:
                let target = (startSize * Double(g.scale)).rounded()
                if target != settings.terminalFontSize {
                    settings.terminalFontSize = min(max(target, AppSettings.fontRange.lowerBound), AppSettings.fontRange.upperBound)
                }
            default: break
            }
        }
    }

    private func attach(_ tv: UIView, to container: UIView) {
        tv.removeFromSuperview()
        tv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tv.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            tv.bottomAnchor.constraint(equalTo: container.keyboardLayoutGuide.topAnchor),
        ])
    }
}
