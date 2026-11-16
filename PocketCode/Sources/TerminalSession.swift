import Foundation
import UIKit
import SwiftTerm
import Combine
import Citadel
import NIOCore
import NIOSSH

/// A shell running in a remote PTY, rendered by a SwiftTerm view that the session owns
/// (so scrollback survives tab switches).
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, TerminalViewDelegate {
    let id = UUID()
    @Published var title: String
    @Published private(set) var isRunning = false
    @Published private(set) var exitMessage: String?
    /// Newest URL that appeared in the output (e.g. an OAuth sign-in link printed by a CLI
    /// running on the host). Shown as a bar with Open / Copy, since the remote program
    /// can't open the phone's browser itself.
    @Published var detectedLink: String?
    private var seenLinks: Set<String> = []
    private var linkScan: Task<Void, Never>?

    let terminalView: SwiftTerm.TerminalView
    private var client: SSHClient
    /// Bumped on every start; a finishing task only updates state if it is still the current run.
    private var runID = 0
    /// Only the very first shell clears the screen after cd; restarts keep the scrollback visible.
    private var hasStarted = false
    private let initialDirectory: String?
    private var writer: TTYStdinWriter?
    /// Single ordered pipeline for everything typed; unstructured per-key Tasks
    /// are NOT ordered and scrambled fast input. The box yields synchronously in
    /// the delegate callback, so arrival order is byte order.
    private let input = InputBox()

    final class InputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: AsyncStream<[UInt8]>.Continuation?
        func set(_ c: AsyncStream<[UInt8]>.Continuation?) { lock.lock(); cont = c; lock.unlock() }
        func yield(_ b: [UInt8]) { lock.lock(); cont?.yield(b); lock.unlock() }
        func finish() { lock.lock(); cont?.finish(); cont = nil; lock.unlock() }
    }
    private var task: Task<Void, Never>?
    private var settingsSub: AnyCancellable?
    private var size = (cols: 80, rows: 24)

    init(client: SSHClient, index: Int, initialDirectory: String?) {
        self.client = client
        self.initialDirectory = initialDirectory
        self.title = "bash \(index)"
        self.terminalView = PocketTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        super.init()
        configureView()
        start()
    }

    private func configureView() {
        let tv = terminalView
        tv.terminalDelegate = self
        tv.font = .monospacedSystemFont(ofSize: AppSettings.shared.terminalFontSize, weight: .regular)
        settingsSub = AppSettings.shared.$terminalFontSize
            .removeDuplicates()
            .sink { [weak tv] size in tv?.font = .monospacedSystemFont(ofSize: size, weight: .regular) }
        tv.nativeBackgroundColor = UIColor(hex: 0x1E1E1E)
        tv.nativeForegroundColor = UIColor(hex: 0xCCCCCC)
        tv.caretColor = UIColor(hex: 0xCCCCCC)
        tv.optionAsMetaKey = true
        tv.inputAccessoryView = nil // key row lives in TerminalPanel's layout instead
        // VS Code's integrated terminal ANSI palette.
        let palette: [UInt32] = [0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
                                 0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5]
        tv.installColors(palette.map { hex in
            SwiftTerm.Color(red: UInt16((hex >> 16) & 0xFF) * 257,
                            green: UInt16((hex >> 8) & 0xFF) * 257,
                            blue: UInt16(hex & 0xFF) * 257)
        })
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        exitMessage = nil
        runID += 1
        let run = runID
        let clear = !hasStarted
        hasStarted = true
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        input.set(continuation)
        let client = client
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: size.cols,
            terminalRowHeight: size.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([.ECHO: 1])
        )
        task = Task { [weak self] in
            do {
                try await client.withPTY(request) { inbound, outbound in
                    guard let self else { return }
                    self.writer = outbound
                    if let dir = self.initialDirectory {
                        continuation.yield(Array("cd \(PathUtil.shellQuote(dir))\(clear ? " && clear" : "")\n".utf8))
                    }
                    try await outbound.changeSize(cols: self.size.cols, rows: self.size.rows, pixelWidth: 0, pixelHeight: 0)
                    // Writer pump: consumes the ordered stream off the main actor.
                    // AsyncStream iteration ends on cancellation or finish().
                    async let pump: Void = {
                        for await chunk in stream {
                            try? await outbound.write(ByteBuffer(bytes: chunk))
                        }
                    }()
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buf), .stderr(let buf):
                            self.terminalView.feed(byteArray: ArraySlice(buf.readableBytesView))
                            self.scheduleLinkScan()
                        }
                    }
                    continuation.finish()
                    await pump
                }
                self?.finish(run, message: nil)
            } catch is CancellationError {
                self?.finish(run, message: nil)
            } catch is ChannelError {
                // The SSH channel closed under us: the shell was killed or the connection dropped.
                self?.finish(run, message: "Session ended")
            } catch {
                self?.finish(run, message: error.localizedDescription)
            }
        }
    }

    private func finish(_ run: Int, message: String?) {
        guard run == runID, isRunning else { return }
        input.finish()
        writer = nil
        isRunning = false
        exitMessage = message ?? "Process exited"
        terminalView.feed(text: "\r\n\u{1B}[2m[\(exitMessage!)]\u{1B}[0m\r\n")
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Moves the session onto a fresh SSH client (after a reconnect) and starts a new shell.
    /// The old run is abandoned silently; scrollback is kept.
    func reattach(client: SSHClient) {
        task?.cancel()
        task = nil
        runID += 1 // the old task's finish() becomes a no-op
        input.finish()
        writer = nil
        isRunning = false
        self.client = client
        terminalView.feed(text: "\r\n\u{1B}[33m[Reconnected]\u{1B}[0m\r\n")
        start()
    }

    func send(text: String) { input.yield(Array(text.utf8)) }

    // MARK: Links

    /// URLs on the visible screen, oldest first.
    func visibleLinks() -> [String] {
        let t = terminalView.getTerminal()
        var lines: [TerminalLinkScanner.Line] = []
        for row in 0..<t.rows {
            guard let line = t.getLine(row: row) else { continue }
            lines.append(.init(text: line.translateToString(trimRight: true), wrapped: line.isWrapped))
        }
        return TerminalLinkScanner.links(in: lines, cols: t.cols)
    }

    /// Debounced: output arrives in bursts; scan once it settles.
    private func scheduleLinkScan() {
        linkScan?.cancel()
        linkScan = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            if let newest = self.visibleLinks().last, !self.seenLinks.contains(newest) {
                self.seenLinks.insert(newest)
                self.detectedLink = newest
            }
        }
    }

    /// Like VS Code's "Clear": wipe scrollback locally, then ask the shell to redraw its prompt (Ctrl-L).
    func clearScreen() {
        terminalView.feed(text: "\u{1B}[3J\u{1B}[2J\u{1B}[H")
        if isRunning { send(text: "\u{0C}") }
    }

    // MARK: TerminalViewDelegate

    nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        input.yield(Array(data))
    }

    nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            self.size = (newCols, newRows)
            if let writer = self.writer {
                try? await writer.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0)
            }
        }
    }

    nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
        Task { @MainActor in if !title.isEmpty { self.title = title } }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    nonisolated func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

    nonisolated func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        Task { @MainActor in UIApplication.shared.open(url) }
    }

    nonisolated func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { Task { @MainActor in UIPasteboard.general.string = s } }
    }
}


/// Replaces SwiftTerm's built-in accessory bar, which clips its buttons at the bottom
/// of the screen. Same construction as the editor's symbol row: a scrollable stack
/// laid out with Auto Layout inside a keyboard-styled UIInputView.

/// SwiftTerm's view with one UIKit behaviour fixed: holding the keyboard's delete key
/// should keep deleting. iOS only auto-repeats delete while the input view reports
/// `hasText == true`, but SwiftTerm reports true only while it buffers unsent input —
/// in a terminal every keystroke goes straight to the remote shell, so it is almost
/// always false and delete fires once. The remote side owns the text, so from the
/// keyboard's point of view there is always something to delete.
///
/// `hasText` is `public` (not `open`) in SwiftTerm, so it can't be overridden in Swift;
/// UIKit reads it through Objective-C, so we add our own implementation to this
/// subclass only (the superclass and SwiftTerm's internal Swift calls are untouched).
final class PocketTerminalView: SwiftTerm.TerminalView {
    private static let installHasText: Void = {
        let sel = NSSelectorFromString("hasText")
        let block: @convention(block) (AnyObject) -> Bool = { _ in true }
        let imp = imp_implementationWithBlock(block)
        // "B@:" = returns BOOL, takes self and _cmd.
        if !class_addMethod(PocketTerminalView.self, sel, imp, "B@:") {
            if let m = class_getInstanceMethod(PocketTerminalView.self, sel) { method_setImplementation(m, imp) }
        }
    }()

    override init(frame: CGRect) {
        _ = Self.installHasText
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        _ = Self.installHasText
        super.init(coder: coder)
    }
}


/// Finds http(s) URLs in terminal text, rejoining URLs that wrap across rows — either
/// soft-wrapped by the terminal (`wrapped`) or hard-broken by a TUI exactly at the edge.
enum TerminalLinkScanner {
    struct Line { let text: String; let wrapped: Bool }

    private static let pattern = try! NSRegularExpression(pattern: #"https?://[^\s"'<>`]+"#)
    private static let urlChars = CharacterSet.urlQueryAllowed.union(.urlPathAllowed).union(CharacterSet(charactersIn: "%#"))

    static func links(in lines: [Line], cols: Int) -> [String] {
        // Build logical lines.
        var logical: [String] = []
        for (i, line) in lines.enumerated() {
            let joinToPrevious: Bool = {
                guard i > 0, !logical.isEmpty else { return false }
                if line.wrapped { return true }
                // Hard break at the right edge in the middle of a URL-looking run.
                let prev = lines[i - 1].text
                guard prev.count >= cols, let last = prev.unicodeScalars.last, urlChars.contains(last),
                      let first = line.text.unicodeScalars.first, urlChars.contains(first) else { return false }
                return logical[logical.count - 1].range(of: "https?://[^\\s]*$", options: .regularExpression) != nil
            }()
            if joinToPrevious { logical[logical.count - 1] += line.text } else { logical.append(line.text) }
        }
        var out: [String] = []
        for text in logical {
            let ns = text as NSString
            for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var url = ns.substring(with: m.range)
                while let c = url.last, ".,;:!?)]}".contains(c) { url.removeLast() }
                if URL(string: url) != nil, !out.contains(url) { out.append(url) }
            }
        }
        return out
    }
}
