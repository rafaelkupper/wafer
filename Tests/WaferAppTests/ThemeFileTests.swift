import Foundation
import XCTest
@testable import WaferApp
@testable import WaferCore

final class ThemeFileTests: XCTestCase {
    func testValidThemeJSONDecodesToPalette() throws {
        let data = try themeData(named: "Ocean")

        let palette = try ThemeFile.decodePalette(from: data, fileName: "Ocean.json")

        XCTAssertEqual(palette.name, "Ocean")
        XCTAssertEqual(palette.backgroundHex, ReaderThemePalette.dark.backgroundHex)
        XCTAssertEqual(palette.kbdShadow, ReaderThemePalette.dark.kbdShadow)
        XCTAssertEqual(palette.mermaid.primaryColor, ReaderThemePalette.dark.mermaid.primaryColor)
    }

    func testEightDigitHexValuesAreAllowed() throws {
        let data = try themeData(named: "Alpha") { object in
            object["backgroundHex"] = "#11223344"
        }

        let palette = try ThemeFile.decodePalette(from: data, fileName: "Alpha.json")

        XCTAssertEqual(palette.backgroundHex, "#11223344")
    }

    func testMissingKeyThrowsWithKeyName() throws {
        let data = try themeData(named: "Missing") { object in
            object.removeValue(forKey: "textHex")
        }

        XCTAssertThrowsError(try ThemeFile.decodePalette(from: data, fileName: "Missing.json")) { error in
            XCTAssertEqual(error as? ThemeFileError, .missingKey("textHex"))
        }
    }

    func testBadHexThrowsWithNestedKeyName() throws {
        let data = try themeData(named: "BadHex") { object in
            var color = object["kbdShadow"] as! [String: Any]
            color["hex"] = "#12345G"
            object["kbdShadow"] = color
        }

        XCTAssertThrowsError(try ThemeFile.decodePalette(from: data, fileName: "BadHex.json")) { error in
            XCTAssertEqual(error as? ThemeFileError, .invalidHex(key: "kbdShadow.hex", value: "#12345G"))
        }
    }

    func testBadAlphaThrowsWithNestedKeyName() throws {
        let data = try themeData(named: "BadAlpha") { object in
            var color = object["kbdShadow"] as! [String: Any]
            color["alpha"] = 1.4
            object["kbdShadow"] = color
        }

        XCTAssertThrowsError(try ThemeFile.decodePalette(from: data, fileName: "BadAlpha.json")) { error in
            XCTAssertEqual(
                error as? ThemeFileError,
                .invalidValue(key: "kbdShadow.alpha", reason: "must be between 0 and 1")
            )
        }
    }
}

@MainActor
final class ThemeFileTabTokenTests: XCTestCase {
    func testLegacyThemeWithoutTabGroupDecodesAndDerivesTokens() throws {
        let data = try themeData(named: "Legacy") { object in
            object.removeValue(forKey: "tab")
        }

        let palette = try ThemeFile.decodePalette(from: data, fileName: "Legacy.json")
        XCTAssertNil(palette.tab)
        XCTAssertEqual(palette.resolvedTab.selectedFill.hex, palette.backgroundHex)
        XCTAssertEqual(palette.resolvedTab.barBackground.hex, palette.sidebarBackgroundHex)
        XCTAssertEqual(palette.resolvedTab.unselectedText, palette.sidebarSecondaryText)
        XCTAssertEqual(palette.resolvedTab.insertionIndicator.hex, palette.linkHex)
    }

    func testExplicitTabGroupWinsOverDerivation() throws {
        let data = try themeData(named: "Explicit")
        let palette = try ThemeFile.decodePalette(from: data, fileName: "Explicit.json")

        XCTAssertNotNil(palette.tab)
        XCTAssertEqual(palette.resolvedTab, palette.tab)
        XCTAssertEqual(palette.resolvedTab, TabPalette.dark)
    }

    func testInvalidTabHexErrorsNamingTheKey() throws {
        let data = try themeData(named: "BadTab") { object in
            var tab = object["tab"] as? [String: Any] ?? [:]
            tab["barBackground"] = ["hex": "nope", "alpha": 1]
            object["tab"] = tab
        }

        XCTAssertThrowsError(try ThemeFile.decodePalette(from: data, fileName: "BadTab.json")) { error in
            XCTAssertEqual(
                error as? ThemeFileError,
                .invalidHex(key: "tab.barBackground.hex", value: "nope")
            )
        }
    }

    func testPartialTabGroupIsRejectedNamingTheMissingKey() throws {
        let data = try themeData(named: "PartialTab") { object in
            var tab = object["tab"] as? [String: Any] ?? [:]
            tab.removeValue(forKey: "insertionIndicator")
            object["tab"] = tab
        }

        XCTAssertThrowsError(try ThemeFile.decodePalette(from: data, fileName: "PartialTab.json")) { error in
            XCTAssertEqual(error as? ThemeFileError, .missingKey("tab.insertionIndicator"))
        }
    }
}

func themeData(
    named name: String,
    mutate: (inout [String: Any]) -> Void = { _ in }
) throws -> Data {
    let data = try JSONEncoder().encode(ThemeFile(palette: .dark))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["name"] = name
    mutate(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
