import AppKit
import XCTest
@testable import WaferApp
import WaferCore

/// Tests for the app-owned active theme state (`ReaderTheme.current` and the
/// native colors derived from it).
@MainActor
final class ReaderThemeCurrentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ReaderTheme.resetToDefaultForTesting()
    }

    func testSidebarThemeUsesFixedDarkerSurfaceTokens() {
        XCTAssertEqual(ReaderTheme.sidebarBackgroundHex, "#212427")
        XCTAssertEqual(ReaderTheme.sidebarSelectionHex, "#1C2023")
        XCTAssertEqual(ReaderTheme.sidebarHoverAlpha, 0.028, accuracy: 0.0001)
        XCTAssertLessThan(
            luminance(of: ReaderTheme.sidebarBackgroundColor),
            luminance(of: ReaderTheme.backgroundColor)
        )
        XCTAssertTrue(ReaderTheme.styleSheet.contains("overflow-x: hidden;"))
    }

    func testSettingCurrentThemeUpdatesDerivedNativeAndCSSValues() {
        defer { ReaderTheme.resetToDefaultForTesting() }

        ReaderTheme.setCurrent(.light)

        XCTAssertEqual(ReaderTheme.current, .light)
        XCTAssertEqual(ReaderTheme.backgroundHex, ReaderThemePalette.light.backgroundHex)
        XCTAssertEqual(ReaderTheme.secondaryTextHex, ReaderThemePalette.light.secondaryTextHex)
        XCTAssertTrue(ReaderTheme.styleSheet.contains("--bg-color: #FFFFFF;"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains("--link-color: #0969DA;"))
    }

    func testDarkPaletteMatchesCurrentReaderThemeNativeColors() {
        let palette = ReaderThemePalette.dark

        XCTAssertEqual(palette.sidebarBackgroundHex, ReaderTheme.sidebarBackgroundHex)
        XCTAssertEqual(palette.sidebarSelectionHex, ReaderTheme.sidebarSelectionHex)
        XCTAssertEqual(palette.sidebarHover.alpha, Double(ReaderTheme.sidebarHoverAlpha), accuracy: 0.0001)
        XCTAssertEqual(palette.sidebarChromeFill.alpha, Double(ReaderTheme.sidebarChromeFillAlpha), accuracy: 0.0001)
        XCTAssertEqual(palette.sidebarChromeBorder.alpha, Double(ReaderTheme.sidebarChromeBorderAlpha), accuracy: 0.0001)
        XCTAssertEqual(
            palette.sidebarChromeSelectedFill.alpha,
            Double(ReaderTheme.sidebarChromeSelectedFillAlpha),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            palette.sidebarChromeHoverFill.alpha,
            Double(ReaderTheme.sidebarChromeHoverFillAlpha),
            accuracy: 0.0001
        )

        assertPaletteHex(palette.backgroundHex, matches: ReaderTheme.backgroundColor)
        assertPaletteHex(palette.sidebarBackgroundHex, matches: ReaderTheme.sidebarBackgroundColor)
        assertPaletteHex(palette.sidebarSelectionHex, matches: ReaderTheme.sidebarSelectionColor)
        assertPaletteColor(palette.sidebarHover, matches: ReaderTheme.sidebarHoverColor)
        assertPaletteColor(palette.sidebarChromeFill, matches: ReaderTheme.sidebarChromeFillColor)
        assertPaletteColor(palette.sidebarChromeBorder, matches: ReaderTheme.sidebarChromeBorderColor)
        assertPaletteColor(palette.sidebarChromeSelectedFill, matches: ReaderTheme.sidebarChromeSelectedFillColor)
        assertPaletteColor(palette.sidebarChromeHoverFill, matches: ReaderTheme.sidebarChromeHoverFillColor)
        assertPaletteColor(palette.sidebarPrimaryText, matches: ReaderTheme.sidebarPrimaryTextColor)
        assertPaletteColor(palette.sidebarSecondaryText, matches: ReaderTheme.sidebarSecondaryTextColor)
    }

    private func luminance(of color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return (0.2126 * rgb.redComponent) + (0.7152 * rgb.greenComponent) + (0.0722 * rgb.blueComponent)
    }

    private func assertPaletteColor(
        _ token: ReaderThemeColor,
        matches color: NSColor,
        accuracy: CGFloat = 0.003,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertPaletteHex(token.hex, alpha: token.alpha, matches: color, accuracy: accuracy, file: file, line: line)
    }

    private func assertPaletteHex(
        _ hex: String,
        alpha: Double = 1,
        matches color: NSColor,
        accuracy: CGFloat = 0.003,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        let actual = color.usingColorSpace(.deviceRGB) ?? color
        XCTAssertEqual(actual.redComponent, CGFloat((value >> 16) & 0xFF) / 255, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, CGFloat((value >> 8) & 0xFF) / 255, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, CGFloat(value & 0xFF) / 255, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, CGFloat(alpha), accuracy: accuracy, file: file, line: line)
    }
}
