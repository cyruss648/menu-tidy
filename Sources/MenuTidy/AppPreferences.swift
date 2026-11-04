import AppKit
import Combine
import SwiftUI

/// User-facing appearance preferences shared by SwiftUI windows, the tray and
/// AppKit menus. The values are intentionally independent from macOS so the
/// user can keep Menu Tidy in a predictable language and color mode.
@MainActor
final class AppPreferences: ObservableObject {
    enum Theme: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .system: "跟随系统"
            case .light: "浅色"
            case .dark: "深色"
            }
        }

        var symbol: String {
            switch self {
            case .system: "circle.lefthalf.filled"
            case .light: "sun.max.fill"
            case .dark: "moon.stars.fill"
            }
        }

        var preferredColorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }

        /// A nil window appearance follows the system, but SwiftUI can keep
        /// the last explicit scheme in an already-created hosting view.
        /// Resolving it here gives that view a concrete value to observe.
        @MainActor var resolvedColorScheme: ColorScheme {
            switch self {
            case .light: return ColorScheme.light
            case .dark: return ColorScheme.dark
            case .system:
                let appearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                return appearance == .darkAqua ? ColorScheme.dark : ColorScheme.light
            }
        }

        var nsAppearanceName: NSAppearance.Name? {
            switch self {
            case .system: nil
            case .light: .aqua
            case .dark: .darkAqua
            }
        }
    }

    enum Language: String, CaseIterable, Identifiable {
        case chinese = "zh-Hans"
        case english = "en"

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .chinese: "简体中文"
            case .english: "English"
            }
        }

        var locale: Locale { Locale(identifier: rawValue) }
    }

    static let shared = AppPreferences()
    static let didChangeNotification = Notification.Name("MenuTidyAppPreferencesDidChange")

    @Published var theme: Theme {
        didSet {
            defaults.set(theme.rawValue, forKey: Self.themeKey)
            notifyChange()
        }
    }
    @Published var language: Language {
        didSet {
            defaults.set(language.rawValue, forKey: Self.languageKey)
            notifyChange()
        }
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = Theme(rawValue: defaults.string(forKey: Self.themeKey) ?? "system") ?? .system
        language = Language(rawValue: defaults.string(forKey: Self.languageKey) ?? "zh-Hans") ?? .chinese
    }

    var locale: Locale { language.locale }
    var preferredColorScheme: ColorScheme? { theme.preferredColorScheme }
    var resolvedColorScheme: ColorScheme { theme.resolvedColorScheme }

    /// AppKit menus do not receive SwiftUI's locale environment, so they use
    /// the same bundle lookup explicitly.
    func localized(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key), locale: locale, arguments: arguments)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static let themeKey = "appearance.theme.v1"
    private static let languageKey = "appearance.language.v1"
}
