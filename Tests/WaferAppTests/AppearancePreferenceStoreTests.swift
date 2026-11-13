import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class AppearancePreferenceStoreTests: XCTestCase {
    func testAppearanceSelectionDefaultsToSystemWhenUnsetOrInvalid() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AppearancePreferenceStore(defaults: defaults)

        XCTAssertEqual(store.appearanceSelection, .system)

        defaults.set("unknown", forKey: "appearanceSelection")

        XCTAssertEqual(store.appearanceSelection, .system)
    }

    func testExplicitSelectionPersistsBroadcastsAndAppliesPalette() {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let notificationCenter = NotificationCenter()
        let store = AppearancePreferenceStore(
            defaults: defaults,
            notificationCenter: notificationCenter,
            systemIsDark: { false }
        )
        let expectation = expectation(description: "appearance preference change")
        let token = notificationCenter.addObserver(
            forName: .appearancePreferenceDidChange,
            object: nil,
            queue: nil
        ) { note in
            XCTAssertEqual(note.userInfo?["appearanceSelection"] as? String, "dark")
            XCTAssertEqual(AppearancePreferenceChange.value(from: note)?.selection, .dark)
            expectation.fulfill()
        }

        store.appearanceSelection = .dark

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(defaults.string(forKey: "appearanceSelection"), "dark")
        XCTAssertEqual(store.appearanceSelection, .dark)
        XCTAssertEqual(ReaderTheme.current, .dark)
        notificationCenter.removeObserver(token)
    }

    func testResolvedPaletteMapsSystemThroughInjectedAppearanceSource() {
        let systemAppearance = SystemAppearanceStub(isDark: false)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AppearancePreferenceStore(defaults: defaults, systemIsDark: { systemAppearance.isDark })

        XCTAssertEqual(store.resolvedPalette(), .light)

        systemAppearance.isDark = true

        XCTAssertEqual(store.resolvedPalette(), .dark)
    }

    func testSystemAppearanceChangesApplyOnlyWhenFollowingSystem() {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let systemAppearance = SystemAppearanceStub(isDark: false)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AppearancePreferenceStore(defaults: defaults, systemIsDark: { systemAppearance.isDark })

        store.applyResolvedPalette()
        XCTAssertEqual(ReaderTheme.current, .light)

        systemAppearance.isDark = true
        store.applySystemAppearanceIfNeeded()
        XCTAssertEqual(ReaderTheme.current, .dark)

        store.appearanceSelection = .light
        systemAppearance.isDark = true
        store.applySystemAppearanceIfNeeded()

        XCTAssertEqual(ReaderTheme.current, .light)
    }

    func testCustomSelectionPersistsAndAppliesThemeLibraryPalette() throws {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let themesURL = tempDirectory.url.appendingPathComponent("Themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try themeData(named: "Ocean").write(to: themesURL.appendingPathComponent("Ocean.json"))
        let library = ThemeLibrary(themesDirectoryURL: themesURL, bundledThemesDirectoryURL: nil, revealHandler: { _ in })
        library.loadThemes()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AppearancePreferenceStore(
            defaults: defaults,
            themeLibrary: library,
            missingCustomThemeNotifier: { XCTFail("Loaded custom theme should not notify: \($0)") },
            systemIsDark: { false }
        )

        store.appearanceSelection = .custom("Ocean")

        XCTAssertEqual(defaults.string(forKey: "appearanceSelection"), "custom:Ocean")
        XCTAssertEqual(store.appearanceSelection, .custom("Ocean"))
        XCTAssertEqual(ReaderTheme.current.name, "Ocean")
    }

    func testMissingCustomSelectionFallsBackToDarkAndNotifiesOnce() throws {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let library = ThemeLibrary(
            themesDirectoryURL: tempDirectory.url.appendingPathComponent("Themes", isDirectory: true),
            bundledThemesDirectoryURL: nil,
            revealHandler: { _ in }
        )
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var missingThemeNames: [String] = []
        let store = AppearancePreferenceStore(
            defaults: defaults,
            themeLibrary: library,
            missingCustomThemeNotifier: { missingThemeNames.append($0) },
            systemIsDark: { false }
        )

        store.appearanceSelection = .custom("Missing")
        store.appearanceSelection = .light
        store.appearanceSelection = .custom("Missing")

        XCTAssertEqual(missingThemeNames, ["Missing"])
        XCTAssertEqual(store.appearanceSelection, .custom("Missing"))
        XCTAssertEqual(store.resolvedPalette(), .dark)
        XCTAssertEqual(ReaderTheme.current, .dark)
    }
}
