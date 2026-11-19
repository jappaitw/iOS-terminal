import SwiftUI
import WebKit

/// In-app preview for web projects: the agent builds an HTML game or page and
/// the user runs it right on the phone — the "see your app" half of developing
/// on the device. Local files load with read access to the workspace root so
/// relative scripts/styles/assets work; remote (SFTP) files render from the
/// editor buffer (standalone pages only).
struct WebPreviewSheet: View {
    let title: String
    let fileURL: URL?        // local file to load (nil → use html string)
    let rootURL: URL?        // directory granted read access (workspace root)
    let html: String?        // fallback: render this markup directly
    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            WebView(fileURL: fileURL, rootURL: rootURL, html: html, reloadToken: reloadToken)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

private struct WebView: UIViewRepresentable {
    let fileURL: URL?
    let rootURL: URL?
    let html: String?
    let reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Games and demos shouldn't need a tap to start their audio.
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isInspectable = true
        web.allowsBackForwardNavigationGestures = true
        load(web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.lastToken != reloadToken {
            context.coordinator.lastToken = reloadToken
            load(web)
        }
    }

    private func load(_ web: WKWebView) {
        if let fileURL {
            web.loadFileURL(fileURL, allowingReadAccessTo: rootURL ?? fileURL.deletingLastPathComponent())
        } else if let html {
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastToken = 0 }
}
