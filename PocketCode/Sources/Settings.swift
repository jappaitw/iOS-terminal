import SwiftUI
import Combine

/// User preferences, persisted in UserDefaults. Views and long-lived UIKit views
/// (editor / terminal) observe `AppSettings.shared` so changes apply immediately.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var editorFontSize: Double { didSet { save("editorFontSize", editorFontSize) } }
    @Published var indentWidth: Int { didSet { save("indentWidth", indentWidth) } }
    @Published var indentWithTabs: Bool { didSet { save("indentWithTabs", indentWithTabs) } }
    @Published var lineWrapping: Bool { didSet { save("lineWrapping", lineWrapping) } }
    @Published var terminalFontSize: Double { didSet { save("terminalFontSize", terminalFontSize) } }
    @Published var showKeyRow: Bool { didSet { save("showKeyRow", showKeyRow) } }
    @Published var showHiddenFiles: Bool { didSet { save("showHiddenFiles", showHiddenFiles) } }
    /// "system" / "light" / "dark" — mirrors iOS's own appearance choices.
    @Published var appearance: String { didSet { save("appearance", appearance) } }

    static let fontRange: ClosedRange<Double> = 9...24

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func v<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: "settings." + key) as? T ?? fallback }
        editorFontSize = v("editorFontSize", 13)
        indentWidth = v("indentWidth", 4)
        indentWithTabs = v("indentWithTabs", false)
        lineWrapping = v("lineWrapping", false)
        terminalFontSize = v("terminalFontSize", 12)
        showKeyRow = v("showKeyRow", true)
        showHiddenFiles = v("showHiddenFiles", true)
        appearance = v("appearance", "dark")
    }

    /// nil lets the system decide (the "follow device" choice).
    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: "settings." + key) }

    /// Text inserted by the Tab key / indent actions.
    var indentString: String { indentWithTabs ? "\t" : String(repeating: " ", count: indentWidth) }
    var indentLabel: String { indentWithTabs ? "Tab Size: \(indentWidth)" : "Spaces: \(indentWidth)" }

    func clampTerminalFont(_ delta: Double) {
        terminalFontSize = min(max(terminalFontSize + delta, Self.fontRange.lowerBound), Self.fontRange.upperBound)
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("AI") {
                    NavigationLink { ModelSettingsView() } label: {
                        Label("AI Model", systemImage: "brain")
                    }
                }
                Section("Extensions") {
                    NavigationLink { SkillsSettingsView() } label: {
                        Label("Skills", systemImage: "sparkles")
                    }
                    NavigationLink { McpServersSettingsView() } label: {
                        Label("MCP Servers", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        Text("Follow Device").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                Section("Editor") {
                    Stepper(value: $settings.editorFontSize, in: AppSettings.fontRange, step: 1) {
                        LabeledContent("Font Size", value: "\(Int(settings.editorFontSize)) pt")
                    }
                    Picker("Indent Using", selection: $settings.indentWithTabs) {
                        Text("Spaces").tag(false)
                        Text("Tabs").tag(true)
                    }
                    Picker(settings.indentWithTabs ? "Tab Width" : "Spaces per Indent", selection: $settings.indentWidth) {
                        ForEach([2, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Toggle("Word Wrap", isOn: $settings.lineWrapping)
                    Text("func greet() {\n\(settings.indentWithTabs ? "→   " : String(repeating: "·", count: settings.indentWidth))return \"Hello\"\n}")
                        .font(.system(size: settings.editorFontSize, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Section("Terminal") {
                    Stepper(value: $settings.terminalFontSize, in: AppSettings.fontRange, step: 1) {
                        LabeledContent("Font Size", value: "\(Int(settings.terminalFontSize)) pt")
                    }
                }
                Section {
                    Toggle("Show Extra Key Row", isOn: $settings.showKeyRow)
                } header: { Text("Keyboard") } footer: {
                    Text("The row of symbols, arrows, esc and ctrl shown above the bottom tabs while typing in the editor or terminal.")
                }
                Section("Explorer") {
                    Toggle("Show Hidden Files by Default", isOn: $settings.showHiddenFiles)
                }
                Section {
                    NavigationLink("Open Source Licenses") { LicensesView() }
                    LabeledContent("Version", value: AppInfo.versionString)
                } footer: {
                    Text("PocketCode is not affiliated with or endorsed by Microsoft or Visual Studio Code.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        // Follows the app's appearance setting (App.swift) instead of forcing dark.
    }
}

enum AppInfo {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "–"
        let b = info?["CFBundleVersion"] as? String ?? "–"
        return "\(v) (\(b))"
    }
}
