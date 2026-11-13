import Foundation
import XCTest
@testable import WaferApp

@MainActor
final class ThemeLibraryTests: XCTestCase {
    func testLoadThemesCreatesDirectoryAndExampleTheme() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let themesURL = tempDirectory.url.appendingPathComponent("Themes", isDirectory: true)
        let library = ThemeLibrary(
            themesDirectoryURL: themesURL,
            bundledThemesDirectoryURL: nil,
            revealHandler: { _ in }
        )

        let result = library.loadThemes()

        XCTAssertTrue(FileManager.default.fileExists(atPath: themesURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: themesURL.appendingPathComponent("Example.json").path))
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.palettes.map(\.name), [], "Example.json is a template and must not be listed")
    }

    func testLoadThemesSkipsMalformedFilesAndKeepsValidThemes() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let themesURL = tempDirectory.url.appendingPathComponent("Themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try themeData(named: "Ocean").write(to: themesURL.appendingPathComponent("Ocean.json"))
        try Data("{".utf8).write(to: themesURL.appendingPathComponent("Broken.json"))
        let library = ThemeLibrary(
            themesDirectoryURL: themesURL,
            bundledThemesDirectoryURL: nil,
            revealHandler: { _ in }
        )

        let result = library.loadThemes()

        XCTAssertEqual(result.palettes.map(\.name), ["Ocean"])
        XCTAssertEqual(result.diagnostics.map(\.fileName), ["Broken.json"])
        XCTAssertTrue(result.diagnostics[0].message.contains("invalid"))
    }

    func testLoadThemesIncludesBundledThemes() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let themesURL = tempDirectory.url.appendingPathComponent("Themes", isDirectory: true)
        let bundledURL = tempDirectory.url.appendingPathComponent("Bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledURL, withIntermediateDirectories: true)
        try themeData(named: "Ocean").write(to: bundledURL.appendingPathComponent("Ocean.json"))
        let library = ThemeLibrary(
            themesDirectoryURL: themesURL,
            bundledThemesDirectoryURL: bundledURL,
            revealHandler: { _ in }
        )

        let result = library.loadThemes()

        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.palettes.map(\.name), ["Ocean"])
    }

    func testUserThemeOverridesBundledThemeWithSameName() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let themesURL = tempDirectory.url.appendingPathComponent("Themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themesURL, withIntermediateDirectories: true)
        let bundledURL = tempDirectory.url.appendingPathComponent("Bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledURL, withIntermediateDirectories: true)
        try themeData(named: "Ocean").write(to: bundledURL.appendingPathComponent("Ocean.json"))
        try themeData(named: "Ocean") { object in
            object["backgroundHex"] = "#123456"
        }.write(to: themesURL.appendingPathComponent("Ocean.json"))
        let library = ThemeLibrary(
            themesDirectoryURL: themesURL,
            bundledThemesDirectoryURL: bundledURL,
            revealHandler: { _ in }
        )

        let result = library.loadThemes()

        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(library.palette(named: "Ocean")?.backgroundHex, "#123456")
    }

    func testShippedBundledThemesAllDecode() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let themesURL = tempDirectory.url.appendingPathComponent("Themes", isDirectory: true)
        let bundledURL = try XCTUnwrap(ThemeLibrary.defaultBundledThemesDirectoryURL())
        let library = ThemeLibrary(
            themesDirectoryURL: themesURL,
            bundledThemesDirectoryURL: bundledURL,
            revealHandler: { _ in }
        )

        let result = library.loadThemes()

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertGreaterThanOrEqual(result.palettes.count, 14)
        XCTAssertNil(library.palette(named: "Example"), "the Example template must not be listed")
        for name in ["GitHub Light", "GitHub Dark", "Dracula", "Nord", "Catppuccin Mocha"] {
            let palette = library.palette(named: name)
            XCTAssertNotNil(palette, "missing bundled theme '\(name)'")
            XCTAssertNotNil(palette?.tab, "bundled theme '\(name)' must carry explicit tab tokens")
        }
    }

    func testThemesDirectoryURLResolvesWithoutCreatingFolder() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }

        let themesURL = ThemeLibrary.resolveThemesDirectoryURL(inApplicationSupport: tempDirectory.url)

        XCTAssertEqual(
            themesURL,
            tempDirectory.url
                .appendingPathComponent("Wafer", isDirectory: true)
                .appendingPathComponent("Themes", isDirectory: true)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempDirectory.url.appendingPathComponent("Wafer", isDirectory: true).path
            )
        )
    }

    func testRevealThemesFolderUsesInjectedHandler() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let themesURL = tempDirectory.url.appendingPathComponent("Themes", isDirectory: true)
        var revealedURL: URL?
        let library = ThemeLibrary(
            themesDirectoryURL: themesURL,
            bundledThemesDirectoryURL: nil,
            revealHandler: { revealedURL = $0 }
        )

        library.revealThemesFolder()

        XCTAssertEqual(revealedURL, themesURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: themesURL.path))
    }
}
