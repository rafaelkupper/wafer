import AppKit
import Foundation
import WaferCore

/// The app's active reader palette and the native colors derived from it.
/// This process-wide state lives in the app target; WaferCore stays stateless
/// and takes palettes as explicit parameters.
extension ReaderTheme {
    @MainActor private(set) static var current: ReaderThemePalette = .dark

    @MainActor static func setCurrent(_ palette: ReaderThemePalette) {
        guard current != palette else {
            return
        }

        current = palette
        NotificationCenter.default.post(name: .readerThemeDidChange, object: palette)
    }

    @MainActor static func resetToDefaultForTesting() {
        current = .dark
    }

    @MainActor static var backgroundHex: String { current.backgroundHex }
    @MainActor static var secondaryTextHex: String { current.secondaryTextHex }

    @MainActor static var sidebarBackgroundHex: String { current.sidebarBackgroundHex }
    @MainActor static var sidebarSelectionHex: String { current.sidebarSelectionHex }
    @MainActor static var sidebarHoverAlpha: CGFloat { CGFloat(current.sidebarHover.alpha) }
    @MainActor static var sidebarChromeFillAlpha: CGFloat { CGFloat(current.sidebarChromeFill.alpha) }
    @MainActor static var sidebarChromeBorderAlpha: CGFloat { CGFloat(current.sidebarChromeBorder.alpha) }
    @MainActor static var sidebarChromeSelectedFillAlpha: CGFloat { CGFloat(current.sidebarChromeSelectedFill.alpha) }
    @MainActor static var sidebarChromeHoverFillAlpha: CGFloat { CGFloat(current.sidebarChromeHoverFill.alpha) }

    @MainActor static var backgroundColor: NSColor { ReaderTheme.color(fromHex: current.backgroundHex) }
    @MainActor static var sidebarBackgroundColor: NSColor { ReaderTheme.color(fromHex: current.sidebarBackgroundHex) }
    @MainActor static var sidebarSelectionColor: NSColor { ReaderTheme.color(fromHex: current.sidebarSelectionHex) }
    @MainActor static var sidebarHoverColor: NSColor { current.sidebarHover.readerColor }
    @MainActor static var sidebarChromeFillColor: NSColor { current.sidebarChromeFill.readerColor }
    @MainActor static var sidebarChromeBorderColor: NSColor { current.sidebarChromeBorder.readerColor }
    @MainActor static var tabBarBackgroundColor: NSColor { current.resolvedTab.barBackground.readerColor }
    @MainActor static var tabBarBorderColor: NSColor { current.resolvedTab.barBorder.readerColor }
    @MainActor static var tabRestingFillColor: NSColor { current.resolvedTab.restingFill.readerColor }
    @MainActor static var tabHoverFillColor: NSColor { current.resolvedTab.hoverFill.readerColor }
    @MainActor static var tabSelectedFillColor: NSColor { current.resolvedTab.selectedFill.readerColor }
    @MainActor static var tabSelectedTextColor: NSColor { current.resolvedTab.selectedText.readerColor }
    @MainActor static var tabUnselectedTextColor: NSColor { current.resolvedTab.unselectedText.readerColor }
    @MainActor static var tabCloseIconColor: NSColor { current.resolvedTab.closeIcon.readerColor }
    @MainActor static var tabCloseHoverFillColor: NSColor { current.resolvedTab.closeHoverFill.readerColor }
    @MainActor static var tabInsertionIndicatorColor: NSColor { current.resolvedTab.insertionIndicator.readerColor }
    @MainActor static var sidebarChromeSelectedFillColor: NSColor { current.sidebarChromeSelectedFill.readerColor }
    @MainActor static var sidebarChromeHoverFillColor: NSColor { current.sidebarChromeHoverFill.readerColor }
    @MainActor static var sidebarPrimaryTextColor: NSColor { current.sidebarPrimaryText.readerColor }
    @MainActor static var sidebarSecondaryTextColor: NSColor { current.sidebarSecondaryText.readerColor }
    @MainActor static var titlebarPrimaryTextColor: NSColor { current.titlebarPrimaryText.readerColor }
    @MainActor static var findBarBackgroundColor: NSColor { current.findBarBackground.readerColor }
    @MainActor static var findBarBorderColor: NSColor { current.findBarBorder.readerColor }
    @MainActor static var statisticsLabelColor: NSColor { current.statisticsLabel.readerColor }
    @MainActor static var statisticsIconColor: NSColor { current.statisticsIcon.readerColor }
    @MainActor static var statisticsIconButtonColor: NSColor { current.statisticsIconButton.readerColor }
    @MainActor static var statisticsPillRestingBackgroundColor: NSColor {
        current.statisticsPillRestingBackground.readerColor
    }
    @MainActor static var statisticsPillHoverBackgroundColor: NSColor {
        current.statisticsPillHoverBackground.readerColor
    }
    @MainActor static var statisticsPillHoverBorderColor: NSColor {
        current.statisticsPillHoverBorder.readerColor
    }
    @MainActor static var statisticsIconButtonRestingBackgroundColor: NSColor {
        current.statisticsIconButtonRestingBackground.readerColor
    }
    @MainActor static var statisticsIconButtonHoverBackgroundColor: NSColor {
        current.statisticsIconButtonHoverBackground.readerColor
    }
    @MainActor static var statisticsIconButtonActiveBackgroundColor: NSColor {
        current.statisticsIconButtonActiveBackground.readerColor
    }
    @MainActor static var statisticsIconButtonHoverBorderColor: NSColor {
        current.statisticsIconButtonHoverBorder.readerColor
    }
    @MainActor static var windowAppearance: NSAppearance? {
        NSAppearance(named: current.appearanceIsDark ? .darkAqua : .aqua)
    }

    @MainActor static var styleSheet: String {
        styleSheet(for: current)
    }
}
