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
        } else {
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

/// Fixed key row between the terminal and the tab bar: keys the iOS keyboard lacks.
private struct TerminalKeyRow: View {
    let session: TerminalSession
    @State private var ctrlOn = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("esc") { session.send(text: "\u{1b}") }
                Button {
                    session.terminalView.controlModifier.toggle()
                    ctrlOn = session.terminalView.controlModifier
                } label: {
                    label("ctrl").background(ctrlOn ? Color(hex: 0x0E639C) : VS.titleBG, in: RoundedRectangle(cornerRadius: 6))
                }
                key(nil, image: "arrow.right.to.line") { session.send(text: "\t") }
                ForEach(["~", "|", "/", "-", "_", "$", "\"", "'"], id: \.self) { s in
                    key(s) { session.send(text: s) }
                }
                arrowKey("arrow.left", "D")
                arrowKey("arrow.down", "B")
                arrowKey("arrow.up", "A")
                arrowKey("arrow.right", "C")
                key(nil, image: "keyboard.chevron.compact.down") { _ = session.terminalView.resignFirstResponder() }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 42)
        .background(Color(hex: 0x252526))
        .overlay(alignment: .top) { Rectangle().fill(VS.border).frame(height: 1) }
    }

    private func syncCtrl() { ctrlOn = session.terminalView.controlModifier }

    private func label(_ title: String?, image: String? = nil) -> some View {
        Group {
            if let title { Text(title).font(.system(size: 14, weight: .medium, design: .monospaced)) }
            else if let image { Image(systemName: image).font(.system(size: 14)) }
        }
        .foregroundStyle(Color(hex: 0xE0E0E0))
        .padding(.horizontal, 11).padding(.vertical, 6)
    }

    private func key(_ title: String?, image: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button { action(); syncCtrl() } label: {
            label(title, image: image).background(VS.titleBG, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func arrowKey(_ image: String, _ letter: String) -> some View {
        key(nil, image: image) {
            let app = session.terminalView.getTerminal().applicationCursor
            session.send(text: "\u{1b}" + (app ? "O" : "[") + letter)
        }
    }
}

/// Embeds the session's long-lived SwiftTerm view.
private struct TerminalHost: UIViewRepresentable {
    let session: TerminalSession

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(hex: 0x1E1E1E)
        attach(session.terminalView, to: container)
        DispatchQueue.main.async { _ = session.terminalView.becomeFirstResponder() }
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if session.terminalView.superview !== container { attach(session.terminalView, to: container) }
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
