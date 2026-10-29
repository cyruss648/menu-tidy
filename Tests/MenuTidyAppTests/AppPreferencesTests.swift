import XCTest
@testable import MenuTidy

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testThemeAndLanguagePersistAcrossInstances() {
        let suiteName = "MenuTidyAppPreferencesTests.\(UUID().uuidString)"
        let firstDefaults = UserDefaults(suiteName: suiteName)!
        firstDefaults.removePersistentDomain(forName: suiteName)

        let first = AppPreferences(defaults: firstDefaults)
        XCTAssertEqual(first.theme, .system)
        XCTAssertEqual(first.language, .chinese)

        first.theme = .dark
        first.language = .english

        let second = AppPreferences(defaults: firstDefaults)
        XCTAssertEqual(second.theme, .dark)
        XCTAssertEqual(second.language, .english)
        XCTAssertEqual(second.locale.identifier, "en")
        XCTAssertEqual(second.preferredColorScheme, .dark)

        firstDefaults.removePersistentDomain(forName: suiteName)
    }

    func testSystemThemeLeavesColorSchemeUnforced() {
        let defaults = UserDefaults(suiteName: "MenuTidyAppPreferencesTests.\(UUID().uuidString)")!
        let preferences = AppPreferences(defaults: defaults)
        preferences.theme = .system
        XCTAssertNil(preferences.preferredColorScheme)
    }
}
