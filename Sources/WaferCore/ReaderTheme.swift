import AppKit
import Foundation

public enum ReaderTheme {
    @MainActor public private(set) static var current: ReaderThemePalette = .dark

    @MainActor public static func setCurrent(_ palette: ReaderThemePalette) {
        guard current != palette else {
            return
        }

        current = palette
        NotificationCenter.default.post(name: .readerThemeDidChange, object: palette)
    }

    @MainActor public static func resetToDefaultForTesting() {
        current = .dark
    }

    @MainActor public static var backgroundHex: String { current.backgroundHex }
    @MainActor public static var secondaryTextHex: String { current.secondaryTextHex }
    public static let bodyFontStack = "\"Helvetica Neue\", Helvetica, Arial, \"Segoe UI Emoji\", \"SF Pro\", sans-serif"
    public static let contentMaxWidth = 928
    public static let contentHorizontalPadding = 31
    public static let bodyLineHeight = "1.66rem"

    @MainActor static var sidebarBackgroundHex: String { current.sidebarBackgroundHex }
    @MainActor static var sidebarSelectionHex: String { current.sidebarSelectionHex }
    @MainActor static var sidebarHoverAlpha: CGFloat { CGFloat(current.sidebarHover.alpha) }
    @MainActor static var sidebarChromeFillAlpha: CGFloat { CGFloat(current.sidebarChromeFill.alpha) }
    @MainActor static var sidebarChromeBorderAlpha: CGFloat { CGFloat(current.sidebarChromeBorder.alpha) }
    @MainActor static var sidebarChromeSelectedFillAlpha: CGFloat { CGFloat(current.sidebarChromeSelectedFill.alpha) }
    @MainActor static var sidebarChromeHoverFillAlpha: CGFloat { CGFloat(current.sidebarChromeHoverFill.alpha) }

    @MainActor public static var backgroundColor: NSColor { current.backgroundHex.readerColor }
    @MainActor public static var sidebarBackgroundColor: NSColor { current.sidebarBackgroundHex.readerColor }
    @MainActor public static var sidebarSelectionColor: NSColor { current.sidebarSelectionHex.readerColor }
    @MainActor public static var sidebarHoverColor: NSColor { current.sidebarHover.readerColor }
    @MainActor public static var sidebarChromeFillColor: NSColor { current.sidebarChromeFill.readerColor }
    @MainActor public static var sidebarChromeBorderColor: NSColor { current.sidebarChromeBorder.readerColor }
    @MainActor public static var tabBarBackgroundColor: NSColor { current.resolvedTab.barBackground.readerColor }
    @MainActor public static var tabBarBorderColor: NSColor { current.resolvedTab.barBorder.readerColor }
    @MainActor public static var tabRestingFillColor: NSColor { current.resolvedTab.restingFill.readerColor }
    @MainActor public static var tabHoverFillColor: NSColor { current.resolvedTab.hoverFill.readerColor }
    @MainActor public static var tabSelectedFillColor: NSColor { current.resolvedTab.selectedFill.readerColor }
    @MainActor public static var tabSelectedTextColor: NSColor { current.resolvedTab.selectedText.readerColor }
    @MainActor public static var tabUnselectedTextColor: NSColor { current.resolvedTab.unselectedText.readerColor }
    @MainActor public static var tabCloseIconColor: NSColor { current.resolvedTab.closeIcon.readerColor }
    @MainActor public static var tabCloseHoverFillColor: NSColor { current.resolvedTab.closeHoverFill.readerColor }
    @MainActor public static var tabInsertionIndicatorColor: NSColor { current.resolvedTab.insertionIndicator.readerColor }
    @MainActor public static var sidebarChromeSelectedFillColor: NSColor { current.sidebarChromeSelectedFill.readerColor }
    @MainActor public static var sidebarChromeHoverFillColor: NSColor { current.sidebarChromeHoverFill.readerColor }
    @MainActor public static var sidebarPrimaryTextColor: NSColor { current.sidebarPrimaryText.readerColor }
    @MainActor public static var sidebarSecondaryTextColor: NSColor { current.sidebarSecondaryText.readerColor }
    @MainActor public static var titlebarPrimaryTextColor: NSColor { current.titlebarPrimaryText.readerColor }
    @MainActor public static var findBarBackgroundColor: NSColor { current.findBarBackground.readerColor }
    @MainActor public static var findBarBorderColor: NSColor { current.findBarBorder.readerColor }
    @MainActor public static var statisticsLabelColor: NSColor { current.statisticsLabel.readerColor }
    @MainActor public static var statisticsIconColor: NSColor { current.statisticsIcon.readerColor }
    @MainActor public static var statisticsIconButtonColor: NSColor { current.statisticsIconButton.readerColor }
    @MainActor public static var statisticsPillRestingBackgroundColor: NSColor {
        current.statisticsPillRestingBackground.readerColor
    }
    @MainActor public static var statisticsPillHoverBackgroundColor: NSColor {
        current.statisticsPillHoverBackground.readerColor
    }
    @MainActor public static var statisticsPillHoverBorderColor: NSColor {
        current.statisticsPillHoverBorder.readerColor
    }
    @MainActor public static var statisticsIconButtonRestingBackgroundColor: NSColor {
        current.statisticsIconButtonRestingBackground.readerColor
    }
    @MainActor public static var statisticsIconButtonHoverBackgroundColor: NSColor {
        current.statisticsIconButtonHoverBackground.readerColor
    }
    @MainActor public static var statisticsIconButtonActiveBackgroundColor: NSColor {
        current.statisticsIconButtonActiveBackground.readerColor
    }
    @MainActor public static var statisticsIconButtonHoverBorderColor: NSColor {
        current.statisticsIconButtonHoverBorder.readerColor
    }
    @MainActor public static var windowAppearance: NSAppearance? {
        NSAppearance(named: current.appearanceIsDark ? .darkAqua : .aqua)
    }

    @MainActor public static var styleSheet: String {
        styleSheet(for: current)
    }

    public static func styleSheet(for palette: ReaderThemePalette) -> String {
        "\(generatedRootBlock(for: palette))\n\n\(styleSheetBody)"
    }

    public static func resourceURL(named resourceFileName: String) -> URL? {
        let candidateFileNames: [String]
        let lastPathComponent = (resourceFileName as NSString).lastPathComponent
        if lastPathComponent != resourceFileName {
            candidateFileNames = [resourceFileName, lastPathComponent]
        } else {
            candidateFileNames = [resourceFileName]
        }

        for candidateFileName in candidateFileNames {
            if let resourceURL = resourceURL(forCandidateFileName: candidateFileName) {
                return resourceURL
            }
        }
        return nil
    }

    private static func resourceURL(forCandidateFileName resourceFileName: String) -> URL? {
        let name = (resourceFileName as NSString).deletingPathExtension
        let ext = (resourceFileName as NSString).pathExtension
        let resourceExtension = ext.isEmpty ? nil : ext
        return packagedResourceBundle.flatMap {
            resourceURL(named: resourceFileName, name: name, resourceExtension: resourceExtension, in: $0)
        } ?? swiftPMResourceURL(
            named: resourceFileName,
            name: name,
            resourceExtension: resourceExtension
        )
    }

    public static func generatedRootBlock(for palette: ReaderThemePalette) -> String {
        let variables = cssVariables(for: palette)
            .map { "    \($0.name): \($0.value);" }
            .joined(separator: "\n")
        return """
        :root {
        \(variables)
        }
        """
    }

    private static let styleSheetBody = loadStyleSheetBody()

    private static func loadStyleSheetBody() -> String {
        if
            let styleSheetURL = resourceURL(named: "reader-theme.css"),
            let styleSheet = try? String(contentsOf: styleSheetURL, encoding: .utf8)
        {
            return inlineStyleSheetBody(from: styleSheet)
        }

        return fallbackStyleSheetBody
    }

    private static func inlineStyleSheetBody(from styleSheet: String) -> String {
        let source = styleSheet.hasPrefix("\u{feff}") ? String(styleSheet.dropFirst()) : styleSheet
        let trimmed = source.drop(while: \.isWhitespace)
        guard
            trimmed.hasPrefix("@charset"),
            let semicolon = trimmed.firstIndex(of: ";")
        else {
            return source
        }

        var result = String(trimmed[trimmed.index(after: semicolon)...])
        while let first = result.first, first.isNewline {
            result.removeFirst()
        }
        return result
    }

    private static func cssVariables(for palette: ReaderThemePalette) -> [(name: String, value: String)] {
        [
            ("--bg-color", palette.backgroundHex),
            ("--text-color", palette.textHex),
            ("--heading-color", palette.headingHex),
            ("--minor-heading-color", palette.minorHeadingHex),
            ("--secondary-text-color", palette.secondaryTextHex),
            ("--link-color", palette.linkHex),
            ("--link-hover-color", palette.linkHoverHex),
            ("--rule-color", palette.ruleHex),
            ("--code-block-bg", palette.codeBlockBackgroundHex),
            ("--inline-code-bg", palette.inlineCodeBackgroundHex),
            ("--selection-bg-color", palette.selectionHex),
            ("--selection-text-color", palette.selectionTextHex),
            ("--kbd-text-color", palette.kbdTextHex),
            ("--kbd-border-color", palette.kbdBorderHex),
            ("--kbd-shadow-color", cssColor(palette.kbdShadow)),
            ("--callout-bg", cssColor(palette.calloutBackground)),
            ("--callout-note-border", cssColor(palette.calloutNoteBorder)),
            ("--callout-note-bg", cssColor(palette.calloutNoteBackground)),
            ("--callout-tip-border", cssColor(palette.calloutTipBorder)),
            ("--callout-tip-bg", cssColor(palette.calloutTipBackground)),
            ("--callout-important-border", cssColor(palette.calloutImportantBorder)),
            ("--callout-important-bg", cssColor(palette.calloutImportantBackground)),
            ("--callout-warning-border", cssColor(palette.calloutWarningBorder)),
            ("--callout-warning-bg", cssColor(palette.calloutWarningBackground)),
            ("--callout-caution-border", cssColor(palette.calloutCautionBorder)),
            ("--callout-caution-bg", cssColor(palette.calloutCautionBackground)),
            ("--symbol-link-text-color", palette.symbolLinkTextHex),
            ("--symbol-link-border-color", cssColor(palette.symbolLinkBorder)),
            ("--inline-chip-border-color", cssColor(palette.inlineChipBorder)),
            ("--inline-chip-bg", cssColor(palette.inlineChipBackground)),
            ("--mermaid-container-bg", cssColor(palette.mermaidContainerBackground)),
            ("--mermaid-container-border-color", cssColor(palette.mermaidContainerBorder)),
            ("--mermaid-grid-stroke-color", cssColor(palette.mermaidGridStroke)),
            ("--mermaid-section-bg", palette.mermaid.sectionBkgColor),
            ("--mermaid-section-alt-bg", palette.mermaid.sectionBkgColor2),
            ("--mermaid-today-line-color", palette.mermaid.todayLineColor),
            ("--mermaid-task-bg", palette.mermaid.taskBkgColor),
            ("--mermaid-task-border-color", palette.mermaid.taskBorderColor),
            ("--mermaid-active-task-bg", palette.mermaid.activeTaskBkgColor),
            ("--mermaid-active-task-border-color", palette.mermaid.activeTaskBorderColor),
            ("--mermaid-done-task-bg", palette.mermaid.doneTaskBkgColor),
            ("--mermaid-done-task-border-color", palette.mermaid.doneTaskBorderColor),
            ("--mermaid-critical-bg", palette.mermaid.critBkgColor),
            ("--mermaid-critical-border-color", palette.mermaid.critBorderColor),
            ("--mermaid-task-text-color", palette.mermaid.taskTextColor),
            ("--mermaid-er-node-border-color", palette.mermaid.nodeBorder),
            ("--mermaid-er-even-bg", palette.mermaid.attributeBackgroundColorEven),
            ("--mermaid-er-odd-bg", palette.mermaid.attributeBackgroundColorOdd),
            ("--mermaid-er-label-bg", palette.mermaid.erEdgeLabelBackground),
            ("--mermaid-er-text-color", palette.mermaid.nodeTextColor),
            ("--mermaid-control-text-color", palette.mermaidControlTextHex),
            ("--mermaid-control-bg", cssColor(palette.mermaidControlBackground)),
            ("--mermaid-control-border-color", cssColor(palette.mermaidControlBorder)),
            ("--mermaid-control-hover-bg", palette.mermaidControlHoverBackgroundHex),
            ("--mermaid-control-hover-border-color", cssColor(palette.mermaidControlHoverBorder)),
            ("--mermaid-error-text-color", palette.mermaidErrorTextHex),
            ("--mermaid-source-bg", cssColor(palette.mermaidSourceBackground)),
            ("--diagram-inspector-backdrop", cssColor(palette.diagramInspectorBackdrop)),
            ("--diagram-inspector-text-color", palette.diagramInspectorTextHex),
            ("--diagram-inspector-toolbar-bg", cssColor(palette.diagramInspectorToolbarBackground)),
            ("--diagram-inspector-toolbar-border-color", cssColor(palette.diagramInspectorToolbarBorder)),
            ("--diagram-inspector-button-text-color", palette.diagramInspectorButtonTextHex),
            ("--diagram-inspector-button-bg", palette.diagramInspectorButtonBackgroundHex),
            ("--diagram-inspector-button-border-color", cssColor(palette.diagramInspectorButtonBorder)),
            ("--diagram-inspector-button-hover-bg", palette.diagramInspectorButtonHoverBackgroundHex),
            ("--diagram-inspector-button-hover-border-color", cssColor(palette.diagramInspectorButtonHoverBorder)),
            ("--diagram-inspector-viewport-bg", palette.diagramInspectorViewportBackgroundHex),
            ("--diagram-inspector-viewport-border-color", cssColor(palette.diagramInspectorViewportBorder)),
            ("--diagram-inspector-viewport-focus-outline-color", cssColor(palette.diagramInspectorViewportFocusOutline)),
            ("--syntax-variable-color", palette.syntaxVariableHex),
            ("--syntax-keyword-color", palette.syntaxKeywordHex),
            ("--syntax-string-color", palette.syntaxStringHex),
            ("--syntax-comment-color", palette.syntaxCommentHex),
            ("--syntax-number-color", palette.syntaxNumberHex),
            ("--syntax-atom-color", palette.syntaxAtomHex),
            ("--syntax-secondary-variable-color", palette.syntaxSecondaryVariableHex),
            ("--syntax-definition-color", palette.syntaxDefinitionHex),
            ("--syntax-positive-color", palette.syntaxPositiveHex),
            ("--syntax-negative-color", palette.syntaxNegativeHex),
        ]
    }

    private static func cssColor(_ color: ReaderThemeColor) -> String {
        if color.alpha >= 1 {
            return color.hex
        }

        let components = color.hex.rgbComponents
        return "rgba(\(components.red), \(components.green), \(components.blue), \(color.alpha.cssAlphaString))"
    }

    private static var packagedResourceBundle: Bundle? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }

        return Bundle(
            url: resourceURL.appendingPathComponent("Wafer_WaferCore.bundle", isDirectory: true)
        )
    }

    private static func resourceURL(
        named resourceFileName: String,
        name: String,
        resourceExtension: String?,
        in bundle: Bundle
    ) -> URL? {
        if let url = bundle.url(forResource: name, withExtension: resourceExtension) {
            return url
        }

        let directURL = bundle.resourceURL?.appendingPathComponent(resourceFileName)
        guard let directURL, FileManager.default.fileExists(atPath: directURL.path) else {
            return nil
        }
        return directURL
    }

    private static func swiftPMResourceURL(
        named resourceFileName: String,
        name: String,
        resourceExtension: String?
    ) -> URL? {
        #if DEBUG
        resourceURL(
            named: resourceFileName,
            name: name,
            resourceExtension: resourceExtension,
            in: Bundle.module
        )
        #else
        nil
        #endif
    }
}

let fallbackStyleSheet = "\(ReaderTheme.generatedRootBlock(for: .dark))\n\n\(fallbackStyleSheetBody)"

private let fallbackStyleSheetBody = """
html,
body {
    margin: 0;
    min-height: 100%;
    background: var(--bg-color);
    color: var(--text-color);
    font-family: "Helvetica Neue", Helvetica, Arial, "Segoe UI Emoji", "SF Pro", sans-serif;
    line-height: 1.66rem;
    overflow-x: hidden;
}

#write {
    box-sizing: border-box;
    max-width: 928px;
    margin: 0 auto;
    padding: 0 31px 43px;
}

pre {
    padding: 16px;
    overflow: auto;
    background: var(--code-block-bg);
}

code {
    font-family: Monaco, Consolas, "Andale Mono", "DejaVu Sans Mono", monospace;
    background: var(--inline-code-bg);
}

pre code {
    background: transparent;
}
"""

public extension Notification.Name {
    static let readerThemeDidChange = Notification.Name("dev.wafer.readerThemeDidChange")
}

extension ReaderThemeColor {
    var readerColor: NSColor {
        hex.readerColor.withAlphaComponent(CGFloat(alpha))
    }
}

private extension String {
    var readerColor: NSColor {
        let components = rgbComponents
        return NSColor(
            srgbRed: CGFloat(components.red) / 255,
            green: CGFloat(components.green) / 255,
            blue: CGFloat(components.blue) / 255,
            alpha: CGFloat(components.alpha) / 255
        )
    }

    var rgbComponents: (red: Int, green: Int, blue: Int, alpha: Int) {
        let digits = hasPrefix("#") ? String(dropFirst()) : self
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)

        switch digits.count {
        case 8:
            return (
                red: Int((value >> 24) & 0xFF),
                green: Int((value >> 16) & 0xFF),
                blue: Int((value >> 8) & 0xFF),
                alpha: Int(value & 0xFF)
            )
        default:
            return (
                red: Int((value >> 16) & 0xFF),
                green: Int((value >> 8) & 0xFF),
                blue: Int(value & 0xFF),
                alpha: 0xFF
            )
        }
    }
}

private extension Double {
    var cssAlphaString: String {
        let formatted = String(format: "%.4f", self)
        return formatted
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}
