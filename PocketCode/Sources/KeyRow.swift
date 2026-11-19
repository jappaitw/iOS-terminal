import SwiftUI

/// Whether the panel a view lives in is the one on screen. On iPhone the panels are stacked
/// in a ZStack; `allowsHitTesting(false)` does not stop the gesture recognizers inside
/// UIKit-backed views (terminal, code editor), so those switch off interaction themselves.
private struct PanelActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var panelActive: Bool {
        get { self[PanelActiveKey.self] }
        set { self[PanelActiveKey.self] = newValue }
    }
}

/// One key on the extra key row.
struct RowKey: Identifiable {
    let id: String
    var title: String?
    var image: String?
    var highlighted = false
    var action: () -> Void

    static func text(_ t: String, _ action: @escaping () -> Void) -> RowKey { RowKey(id: t, title: t, action: action) }
    static func icon(_ name: String, id: String? = nil, _ action: @escaping () -> Void) -> RowKey {
        RowKey(id: id ?? name, image: name, action: action)
    }
}

/// The extra key row shared by the editor and terminal. It is part of the layout
/// (sits above the status bar and tabs), not a keyboard accessory, so it never floats
/// over content or the home indicator and looks the same everywhere.
struct KeyRow: View {
    let keys: [RowKey]
    static let height: CGFloat = 42

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(keys) { key in
                    Button(action: key.action) {
                        Group {
                            if let t = key.title { Text(t).font(.system(size: 14, weight: .medium, design: .monospaced)) }
                            else if let i = key.image { Image(systemName: i).font(.system(size: 14)) }
                        }
                        .foregroundStyle(Color(hex: 0xE0E0E0))
                        .frame(minWidth: 18)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        // Fixed dark pill: the key row belongs to the terminal, which
                        // stays dark in light mode — an adaptive color here would turn
                        // the pills light and make the fixed-light glyphs invisible.
                        .background(key.highlighted ? Color(hex: 0x0E639C) : Color(hex: 0x3C3C3C), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .accessibilityLabel(key.title ?? key.id)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: Self.height)
        .background(Color(hex: 0x252526))
        .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0x444444)).frame(height: 1) }
    }
}
