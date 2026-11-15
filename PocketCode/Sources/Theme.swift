import SwiftUI
import UIKit
import Runestone

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) { self.init(uiColor: UIColor(hex: hex, alpha: alpha)) }
}

/// Dark+ inspired palette.
enum VS {
    static let editorBG = Color(hex: 0x1E1E1E)
    static let sidebarBG = Color(hex: 0x252526)
    static let activityBG = Color(hex: 0x333333)
    static let titleBG = Color(hex: 0x3C3C3C)
    static let tabInactiveBG = Color(hex: 0x2D2D2D)
    static let panelBG = Color(hex: 0x1E1E1E)
    static let border = Color(hex: 0x444444)
    static let text = Color(hex: 0xCCCCCC)
    static let textDim = Color(hex: 0x8B8B8B)
    static let accent = Color(hex: 0x3794FF)
    static let statusBar = Color(hex: 0x007ACC)
    static let statusBarRemote = Color(hex: 0x16825D)
    static let selection = Color(hex: 0x37373D)
    static let selectionActive = Color(hex: 0x04395E)
    static let modified = Color(hex: 0xE2C08D)
    static let error = Color(hex: 0xF14C4C)
    static let indentGuide = Color(hex: 0x404040)

    static let monoFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
}

/// Runestone theme mapped to Dark+ token colors.
final class DarkPlusTheme: Theme {
    let font: UIFont
    let textColor = UIColor(hex: 0xD4D4D4)
    let gutterBackgroundColor = UIColor(hex: 0x1E1E1E)
    let gutterHairlineColor = UIColor(hex: 0x1E1E1E)
    let lineNumberColor = UIColor(hex: 0x858585)
    let lineNumberFont: UIFont
    let selectedLineBackgroundColor = UIColor(hex: 0x2A2D2E)
    let selectedLinesLineNumberColor = UIColor(hex: 0xC6C6C6)
    let selectedLinesGutterBackgroundColor = UIColor(hex: 0x1E1E1E)
    let invisibleCharactersColor = UIColor(hex: 0x404040)
    let pageGuideHairlineColor = UIColor(hex: 0x404040)
    let pageGuideBackgroundColor = UIColor(hex: 0x1E1E1E)
    let markedTextBackgroundColor = UIColor(hex: 0x264F78)

    init(fontSize: CGFloat = 13) {
        font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        lineNumberFont = .monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
    }

    func textColor(for highlightName: String) -> UIColor? {
        let h = highlightName
        func has(_ p: String) -> Bool { h == p || h.hasPrefix(p + ".") }
        if has("comment") { return UIColor(hex: 0x6A9955) }
        if has("string.escape") || has("escape") { return UIColor(hex: 0xD7BA7D) }
        if has("string.regex") || has("regex") { return UIColor(hex: 0xD16969) }
        if has("string") || has("character") { return UIColor(hex: 0xCE9178) }
        if has("number") || has("float") || has("boolean") { return UIColor(hex: 0xB5CEA8) }
        if has("keyword.control") || has("keyword.return") || has("conditional") || has("repeat")
            || has("keyword.import") || has("include") || has("exception") { return UIColor(hex: 0xC586C0) }
        if has("keyword") || has("storage") || has("tag") || has("constant.builtin") || has("variable.builtin")
            { return UIColor(hex: 0x569CD6) }
        if has("function") || has("method") || has("constructor") { return UIColor(hex: 0xDCDCAA) }
        if has("type") || has("namespace") || has("module") || has("class") { return UIColor(hex: 0x4EC9B0) }
        if has("constant") || has("enum") { return UIColor(hex: 0x4FC1FF) }
        if has("attribute") || has("property") || has("field") || has("parameter") || has("label")
            || has("variable") { return UIColor(hex: 0x9CDCFE) }
        if has("text.title") || has("markup.heading") { return UIColor(hex: 0x569CD6) }
        if has("text.literal") || has("markup.raw") { return UIColor(hex: 0xCE9178) }
        if has("text.uri") || has("markup.link") { return UIColor(hex: 0x3794FF) }
        if has("operator") || has("punctuation") { return UIColor(hex: 0xD4D4D4) }
        return nil
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        if highlightName.hasPrefix("text.emphasis") { return .italic }
        if highlightName.hasPrefix("text.strong") || highlightName.hasPrefix("text.title") { return .bold }
        return []
    }
}
