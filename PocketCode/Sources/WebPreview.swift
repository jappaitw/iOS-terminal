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
        web.navigationDelegate = context.coordinator
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
            // Read the bytes ourselves and render with loadHTMLString: on iOS,
            // file:// loads depend on the WebContent process getting a sandbox
            // extension for the read-access directory, and when that doesn't
            // land the page is silently blank. Loading the markup directly with
            // the file's folder as baseURL sidesteps that while still resolving
            // relative scripts/styles/assets. If the read fails we surface why.
            let base = rootURL ?? fileURL.deletingLastPathComponent()
            do {
                let markup = try String(contentsOf: fileURL, encoding: .utf8)
                web.loadHTMLString(markup, baseURL: base)
            } catch {
                web.loadFileURL(fileURL, allowingReadAccessTo: base)
            }
        } else if let html {
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Surfaces navigation failures into the view itself, so a preview that
    /// can't load shows the reason instead of a silent white page.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastToken = 0

        func webView(_ web: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
            show(error, in: web)
        }
        func webView(_ web: WKWebView, didFail nav: WKNavigation!, withError error: Error) {
            show(error, in: web)
        }

        private func show(_ error: Error, in web: WKWebView) {
            let message = (error as NSError).localizedDescription
                .replacingOccurrences(of: "<", with: "&lt;")
            web.loadHTMLString("""
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <body style="margin:0;background:#1e1e1e;color:#e0e0e0;font:15px -apple-system,sans-serif;\
            padding:24px;display:flex;flex-direction:column;gap:12px">
            <strong style="color:#f48771">Preview couldn't load</strong>
            <div style="color:#aaa">\(message)</div>
            </body>
            """, baseURL: nil)
        }
    }
}
