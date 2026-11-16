import UIKit
import SafariServices

/// Opens web pages in an in-app Safari sheet. Staying inside PocketCode keeps the app in
/// the foreground, so the SSH session (and any port forward an OAuth callback needs)
/// keeps running while the person signs in.
@MainActor
enum InAppBrowser {
    private final class Delegate: NSObject, SFSafariViewControllerDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onClose() }
    }
    private static var delegates: [ObjectIdentifier: Delegate] = [:]

    static func present(_ url: URL, onClose: @escaping () -> Void = {}) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let top = topViewController() else { return }
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(hex: 0x3794FF)
        vc.preferredBarTintColor = UIColor(hex: 0x252526)
        vc.dismissButtonStyle = .done
        let id = ObjectIdentifier(vc)
        let delegate = Delegate { delegates[id] = nil; onClose() }
        delegates[id] = delegate
        vc.delegate = delegate
        top.present(vc, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}
