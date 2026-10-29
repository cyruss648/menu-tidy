import SwiftUI

/// The visual language shared by the settings window and the independent tray.
/// Warm neutrals keep the interface quiet while teal is reserved for actions and
/// selected states. Every color has a dark-mode counterpart so the palette stays
/// intentional when the user chooses a fixed appearance.
enum MenuTidyPalette {
    static func canvas(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.12, green: 0.14, blue: 0.14)
            : Color(red: 0.95, green: 0.94, blue: 0.90)
    }

    static func card(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.17, green: 0.19, blue: 0.18)
            : Color(red: 0.985, green: 0.978, blue: 0.95)
    }

    static func controlSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.21, green: 0.23, blue: 0.22)
            : Color(red: 0.925, green: 0.915, blue: 0.875)
    }

    static func accent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.38, green: 0.66, blue: 0.65)
            : Color(red: 0.16, green: 0.45, blue: 0.45)
    }

    static func accentWash(for colorScheme: ColorScheme, amount: Double = 0.10) -> Color {
        accent(for: colorScheme).opacity(amount)
    }

    static func border(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color(red: 0.30, green: 0.32, blue: 0.30).opacity(0.14)
    }

    static func shadow(for colorScheme: ColorScheme) -> Color {
        Color.black.opacity(colorScheme == .dark ? 0.20 : 0.045)
    }
}
