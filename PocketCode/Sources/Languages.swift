import SwiftUI
import Runestone
import TreeSitterBashRunestone
import TreeSitterCRunestone
import TreeSitterCPPRunestone
import TreeSitterCSharpRunestone
import TreeSitterCSSRunestone
import TreeSitterGoRunestone
import TreeSitterHTMLRunestone
import TreeSitterJavaRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterJSONRunestone
import TreeSitterMarkdownRunestone
import TreeSitterPHPRunestone
import TreeSitterPythonRunestone
import TreeSitterRubyRunestone
import TreeSitterRustRunestone
import TreeSitterSQLRunestone
import TreeSitterSwiftRunestone
import TreeSitterTOMLRunestone
import TreeSitterTSXRunestone
import TreeSitterTypeScriptRunestone
import TreeSitterYAMLRunestone

struct LanguageInfo {
    let name: String
    let treeSitter: TreeSitterLanguage?
    /// Short glyph + color shown as the file icon, in the spirit of VS Code's Seti icons.
    let badge: String
    let color: Color

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "ico"]

    static func detect(_ path: String) -> LanguageInfo {
        let file = PathUtil.name(path).lowercased()
        let ext = (file as NSString).pathExtension
        switch file {
        case "dockerfile": return .init(name: "Dockerfile", treeSitter: .bash, badge: "🐳", color: Color(hex: 0x519ABA))
        case "makefile": return .init(name: "Makefile", treeSitter: .bash, badge: "M", color: Color(hex: 0xE37933))
        case ".gitignore", ".gitattributes", ".gitmodules":
            return .init(name: "Ignore", treeSitter: nil, badge: "◆", color: Color(hex: 0x41535B))
        case ".bashrc", ".zshrc", ".profile", ".bash_profile", ".env":
            return .init(name: "Shell Script", treeSitter: .bash, badge: "$", color: Color(hex: 0x89E051))
        default: break
        }
        switch ext {
        case "swift": return .init(name: "Swift", treeSitter: .swift, badge: "swift", color: Color(hex: 0xF05138))
        case "py", "pyw": return .init(name: "Python", treeSitter: .python, badge: "py", color: Color(hex: 0x3572A5))
        case "js", "mjs", "cjs": return .init(name: "JavaScript", treeSitter: .javaScript, badge: "JS", color: Color(hex: 0xCBCB41))
        case "jsx": return .init(name: "JavaScript React", treeSitter: .jsx, badge: "⚛", color: Color(hex: 0x519ABA))
        case "ts", "mts", "cts": return .init(name: "TypeScript", treeSitter: .typeScript, badge: "TS", color: Color(hex: 0x519ABA))
        case "tsx": return .init(name: "TypeScript React", treeSitter: .tsx, badge: "⚛", color: Color(hex: 0x519ABA))
        case "json", "jsonc": return .init(name: "JSON", treeSitter: .json, badge: "{}", color: Color(hex: 0xCBCB41))
        case "md", "markdown": return .init(name: "Markdown", treeSitter: .markdown, badge: "M↓", color: Color(hex: 0x519ABA))
        case "html", "htm": return .init(name: "HTML", treeSitter: .html, badge: "<>", color: Color(hex: 0xE37933))
        case "css": return .init(name: "CSS", treeSitter: .css, badge: "#", color: Color(hex: 0x519ABA))
        case "scss", "sass", "less": return .init(name: "SCSS", treeSitter: .css, badge: "#", color: Color(hex: 0xF55385))
        case "c", "h": return .init(name: "C", treeSitter: .c, badge: "C", color: Color(hex: 0x519ABA))
        case "cpp", "cc", "cxx", "hpp", "hh", "mm", "m": return .init(name: "C++", treeSitter: .cpp, badge: "C++", color: Color(hex: 0xA074C4))
        case "cs": return .init(name: "C#", treeSitter: .cSharp, badge: "C#", color: Color(hex: 0x178600))
        case "go": return .init(name: "Go", treeSitter: .go, badge: "go", color: Color(hex: 0x519ABA))
        case "rs": return .init(name: "Rust", treeSitter: .rust, badge: "rs", color: Color(hex: 0xDEA584))
        case "java", "kt", "kts": return .init(name: "Java", treeSitter: .java, badge: "J", color: Color(hex: 0xCC3E44))
        case "rb", "gemspec": return .init(name: "Ruby", treeSitter: .ruby, badge: "rb", color: Color(hex: 0xCC3E44))
        case "php": return .init(name: "PHP", treeSitter: .php, badge: "php", color: Color(hex: 0xA074C4))
        case "sh", "bash", "zsh", "fish": return .init(name: "Shell Script", treeSitter: .bash, badge: "$", color: Color(hex: 0x89E051))
        case "yml", "yaml": return .init(name: "YAML", treeSitter: .yaml, badge: "yml", color: Color(hex: 0xA074C4))
        case "toml": return .init(name: "TOML", treeSitter: .toml, badge: "⚙", color: Color(hex: 0x8DC149))
        case "sql": return .init(name: "SQL", treeSitter: .sql, badge: "db", color: Color(hex: 0xF55385))
        case "xml", "plist", "svg", "storyboard", "xib":
            return .init(name: "XML", treeSitter: .html, badge: "<>", color: Color(hex: 0xE37933))
        case "txt", "log": return .init(name: "Plain Text", treeSitter: nil, badge: "≡", color: Color(hex: 0x8B8B8B))
        default:
            if imageExtensions.contains(ext) { return .init(name: "Image", treeSitter: nil, badge: "▣", color: Color(hex: 0xA074C4)) }
            return .init(name: "Plain Text", treeSitter: nil, badge: "≡", color: Color(hex: 0x8B8B8B))
        }
    }
}

/// Small file-type badge used in the explorer and editor tabs.
struct FileBadge: View {
    let path: String
    var body: some View {
        let lang = LanguageInfo.detect(path)
        Text(lang.badge)
            .font(.system(size: lang.badge.count > 2 ? 7.5 : 10, weight: .heavy, design: .rounded))
            .foregroundStyle(lang.color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: 18, height: 16)
    }
}
