import Observation
import SwiftUI
import UIKit

enum AccentTheme: String, CaseIterable, Identifiable {
    case plum, rose, ink, forest, amber, mono

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var hex: String {
        switch self {
        case .plum: "8A55B8"
        case .rose: "C4507E"
        case .ink: "3D58A8"
        case .forest: "3E7C5A"
        case .amber: "C07A2A"
        case .mono: "57515E"
        }
    }
}

enum ColorSchemeChoice: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// App-wide look, saved in UserDefaults.
@Observable
final class Appearance {
    static let shared = Appearance()

    private(set) var accent: AccentTheme
    private(set) var scheme: ColorSchemeChoice

    private init() {
        let defaults = UserDefaults.standard
        accent = AccentTheme(rawValue: defaults.string(forKey: "accent") ?? "") ?? .plum
        scheme = ColorSchemeChoice(rawValue: defaults.string(forKey: "colorScheme") ?? "") ?? .system
    }

    func setAccent(_ accent: AccentTheme) {
        self.accent = accent
        UserDefaults.standard.set(accent.rawValue, forKey: "accent")
    }

    func setScheme(_ scheme: ColorSchemeChoice) {
        self.scheme = scheme
        UserDefaults.standard.set(scheme.rawValue, forKey: "colorScheme")
    }
}

/// Warm paper tones instead of the stock system greys.
enum Theme {
    static var accent: Color { Color(hex: Appearance.shared.accent.hex) }
    static var uiAccent: UIColor { UIColor(hex: Appearance.shared.accent.hex) }

    static let uiPaper = UIColor(light: "F4EFE7", dark: "16141A")
    static let paper = Color(uiColor: uiPaper)
    static let surface = Color(uiColor: UIColor(light: "FBF8F2", dark: "1F1C24"))
    static let raised = Color(uiColor: UIColor(light: "FFFFFF", dark: "2A2630"))
    static let line = Color(uiColor: UIColor(light: "E2DACD", dark: "34303A"))
    static let ink = Color(uiColor: UIColor(light: "2A2530", dark: "EDE7F2"))
    static let muted = Color(uiColor: UIColor(light: "7D7584", dark: "9C95A3"))
}

extension UIColor {
    convenience init(light: String, dark: String) {
        let lightColor = UIColor(hex: light), darkColor = UIColor(hex: dark)
        self.init { $0.userInterfaceStyle == .dark ? darkColor : lightColor }
    }
}

/// Icon for the slim bars, dimmed when disabled and highlighted when `active`.
struct BarIcon: View {
    @Environment(\.isEnabled) private var isEnabled
    let symbol: String
    var active = false

    init(_ symbol: String, active: Bool = false) {
        self.symbol = symbol
        self.active = active
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(active ? Theme.accent : Theme.ink)
            .frame(width: 36, height: 34)
            .background(active ? Theme.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
    }
}

extension View {
    /// Slim bar look shared by the workspace header and the pane bars.
    func barStyle(height: CGFloat = 46) -> some View {
        frame(height: height)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    func themedForm() -> some View {
        scrollContentBackground(.hidden).background(Theme.paper)
    }
}
