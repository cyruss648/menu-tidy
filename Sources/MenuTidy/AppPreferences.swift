import AppKit
import Combine
import MenuTidyCore
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

        var titleKey: LocalizedMessage {
            switch self {
            case .system: LocalizedMessage("跟随系统")
            case .light: LocalizedMessage("浅色")
            case .dark: LocalizedMessage("深色")
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

        var titleKey: LocalizedMessage {
            switch self {
            case .chinese: LocalizedMessage("简体中文")
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
    /// Observe a concrete system scheme without replacing the hosting view.
    @Published private(set) var systemColorScheme: ColorScheme

    let defaults: UserDefaults
    private let resourceBundle: Bundle

    init(defaults: UserDefaults = .standard, resourceBundle: Bundle = .main) {
        self.defaults = defaults
        self.resourceBundle = resourceBundle
        systemColorScheme = Self.currentSystemColorScheme()
        theme = Theme(rawValue: defaults.string(forKey: Self.themeKey) ?? "system") ?? .system
        language = Language(rawValue: defaults.string(forKey: Self.languageKey) ?? "zh-Hans") ?? .chinese
    }

    var locale: Locale { language.locale }
    var preferredColorScheme: ColorScheme? { theme.preferredColorScheme }
    var resolvedColorScheme: ColorScheme {
        theme == .system ? systemColorScheme : (theme == .dark ? .dark : .light)
    }

    func refreshSystemAppearance() {
        let scheme = Self.currentSystemColorScheme()
        if systemColorScheme != scheme { systemColorScheme = scheme }
    }

    private static func currentSystemColorScheme() -> ColorScheme {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// AppKit menus do not receive SwiftUI's locale environment, so they use
    /// the same bundle lookup explicitly.
    func localized(_ message: LocalizedMessage) -> String {
        let bundle = resourceBundle.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
        return message.rendered { key in
            bundle?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        }
    }

    func localizedFormat(_ key: StaticString, _ arguments: CVarArg...) -> String {
        localizedFormat(key, arguments: arguments)
    }

    func localizedFormat(_ key: StaticString, arguments: [CVarArg]) -> String {
        let source = key.description
        let bundle = resourceBundle.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
        let format = bundle?.localizedString(forKey: source, value: source, table: "Localizable") ?? source
        return String(format: format, locale: locale, arguments: arguments)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static let themeKey = "appearance.theme.v1"
    private static let languageKey = "appearance.language.v1"
}
