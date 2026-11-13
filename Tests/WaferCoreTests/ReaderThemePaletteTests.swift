import AppKit
import Foundation
import XCTest
@testable import WaferCore

@MainActor
final class ReaderThemePaletteTests: XCTestCase {
    func testDarkPaletteMatchesV05GoldenValues() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ReaderThemePalette.dark)
        let actual = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(
            actual.trimmingCharacters(in: .whitespacesAndNewlines),
            Self.darkPaletteV05GoldenJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func testDarkPaletteMatchesCurrentReaderThemeWebTokens() {
        let palette = ReaderThemePalette.dark

        XCTAssertEqual(palette.name, "Dark")
        XCTAssertTrue(palette.appearanceIsDark)
        XCTAssertEqual(palette.backgroundHex, cssRootToken("--bg-color"))
        XCTAssertEqual(palette.textHex, cssRootToken("--text-color"))
        XCTAssertEqual(palette.headingHex, cssRootToken("--heading-color"))
        assertStyleSheetRule("h4 {\n    font-size: 1.12rem;", property: "color", includesHex: palette.minorHeadingHex)
        assertStyleSheetRule("h6 {\n    font-size: 0.93rem;", property: "color", includesHex: palette.minorHeadingHex)
        XCTAssertEqual(palette.secondaryTextHex, cssRootToken("--secondary-text-color"))
        XCTAssertEqual(palette.linkHex, cssRootToken("--link-color"))
        assertStyleSheetRule("a:hover {", property: "color", includesHex: palette.linkHoverHex)
        XCTAssertEqual(palette.ruleHex, cssRootToken("--rule-color"))
        XCTAssertEqual(palette.codeBlockBackgroundHex, cssRootToken("--code-block-bg"))
        XCTAssertEqual(palette.selectionHex, cssRootToken("--selection-bg-color"))
        assertStyleSheetRule("::selection,", property: "color", includesHex: palette.selectionTextHex)
        XCTAssertEqual(palette.inlineCodeBackgroundHex, "#30343A")
        XCTAssertTrue(fallbackStyleSheet.contains("--inline-code-bg: \(palette.inlineCodeBackgroundHex);"))
        assertStyleSheetRule("kbd {", property: "color", includesHex: palette.kbdTextHex)
        assertStyleSheetRule("kbd {", property: "border", includesHex: palette.kbdBorderHex)
        assertStyleSheetRule("kbd {", property: "box-shadow", includesColor: palette.kbdShadow)
    }

    func testDarkPaletteMatchesCurrentReaderThemeStyleSheetInventory() {
        let palette = ReaderThemePalette.dark

        assertStyleSheetRule(".md-callout {", property: "background", includesColor: palette.calloutBackground)
        assertStyleSheetRule(".md-callout-note {", property: "border-left-color", includesColor: palette.calloutNoteBorder)
        assertStyleSheetRule(".md-callout-note {", property: "background", includesColor: palette.calloutNoteBackground)
        assertStyleSheetRule(".md-callout-tip {", property: "border-left-color", includesColor: palette.calloutTipBorder)
        assertStyleSheetRule(".md-callout-tip {", property: "background", includesColor: palette.calloutTipBackground)
        assertStyleSheetRule(
            ".md-callout-important {",
            property: "border-left-color",
            includesColor: palette.calloutImportantBorder
        )
        assertStyleSheetRule(
            ".md-callout-important {",
            property: "background",
            includesColor: palette.calloutImportantBackground
        )
        assertStyleSheetRule(".md-callout-warning {", property: "border-left-color", includesColor: palette.calloutWarningBorder)
        assertStyleSheetRule(".md-callout-warning {", property: "background", includesColor: palette.calloutWarningBackground)
        assertStyleSheetRule(".md-callout-caution {", property: "border-left-color", includesColor: palette.calloutCautionBorder)
        assertStyleSheetRule(".md-callout-caution {", property: "background", includesColor: palette.calloutCautionBackground)
        assertStyleSheetRule(".md-symbol-link {", property: "color", includesHex: palette.symbolLinkTextHex)
        assertStyleSheetRule(".md-symbol-link {", property: "border", includesColor: palette.symbolLinkBorder)
        assertStyleSheetRule(".md-inline-chip {", property: "border", includesColor: palette.inlineChipBorder)
        assertStyleSheetRule(".md-inline-chip {", property: "background", includesColor: palette.inlineChipBackground)

        assertStyleSheetRule(".md-mermaid-diagram {", property: "background", includesColor: palette.mermaidContainerBackground)
        assertStyleSheetRule(".md-mermaid-diagram {", property: "border", includesColor: palette.mermaidContainerBorder)
        assertStyleSheetRule(".md-mermaid-output svg .section,", property: "fill", includesHex: palette.mermaid.sectionBkgColor)
        assertStyleSheetRule(".md-mermaid-output svg .section1,", property: "fill", includesHex: palette.mermaid.sectionBkgColor2)
        assertStyleSheetRule(".md-mermaid-output svg .grid .tick,", property: "stroke", includesColor: palette.mermaidGridStroke)
        assertStyleSheetRule(".md-mermaid-output svg .today {", property: "stroke", includesHex: palette.mermaid.todayLineColor)
        assertStyleSheetRule(".md-mermaid-output svg .task {", property: "fill", includesHex: palette.mermaid.taskBkgColor)
        assertStyleSheetRule(".md-mermaid-output svg .task {", property: "stroke", includesHex: palette.mermaid.taskBorderColor)
        assertStyleSheetRule(".md-mermaid-output svg .active0,", property: "fill", includesHex: palette.mermaid.activeTaskBkgColor)
        assertStyleSheetRule(".md-mermaid-output svg .active0,", property: "stroke", includesHex: palette.mermaid.activeTaskBorderColor)
        assertStyleSheetRule(".md-mermaid-output svg .done0,", property: "fill", includesHex: palette.mermaid.doneTaskBkgColor)
        assertStyleSheetRule(".md-mermaid-output svg .done0,", property: "stroke", includesHex: palette.mermaid.doneTaskBorderColor)
        assertStyleSheetRule(".md-mermaid-output svg .crit0,", property: "fill", includesHex: palette.mermaid.critBkgColor)
        assertStyleSheetRule(".md-mermaid-output svg .crit0,", property: "stroke", includesHex: palette.mermaid.critBorderColor)
        assertStyleSheetRule(".md-mermaid-output svg .doneCrit0,", property: "fill", includesHex: palette.mermaid.doneTaskBkgColor)
        assertStyleSheetRule(".md-mermaid-output svg .doneCrit0,", property: "stroke", includesHex: palette.mermaid.critBorderColor)
        assertStyleSheetRule(".md-mermaid-output svg .sectionTitle,", property: "fill", includesHex: palette.mermaid.taskTextColor)
        assertStyleSheetRule(".md-mermaid-output svg .sectionTitle,", property: "color", includesHex: palette.mermaid.taskTextColor)
        assertStyleSheetRule(".md-mermaid-output svg.erDiagram .entityBox,", property: "stroke", includesHex: palette.mermaid.nodeBorder)
        assertStyleSheetRule(
            ".md-mermaid-output svg.erDiagram .outer-path > path:first-child,",
            property: "fill",
            includesHex: palette.mermaid.attributeBackgroundColorEven
        )
        assertStyleSheetRule(
            ".md-mermaid-output svg.erDiagram .row-rect-odd > path:first-child,",
            property: "fill",
            includesHex: palette.mermaid.attributeBackgroundColorOdd
        )
        assertStyleSheetRule(
            ".md-mermaid-output svg.erDiagram .relationshipLabelBox,",
            property: "fill",
            includesHex: palette.mermaid.erEdgeLabelBackground
        )
        assertStyleSheetRule(".md-mermaid-output svg.erDiagram text,", property: "fill", includesHex: palette.mermaid.nodeTextColor)
        assertStyleSheetRule(".md-mermaid-output svg.erDiagram text,", property: "color", includesHex: palette.mermaid.nodeTextColor)
        assertStyleSheetRule(
            ".md-mermaid-output svg.erDiagram foreignObject div,",
            property: "color",
            includesHex: palette.mermaid.nodeTextColor
        )
        assertStyleSheetRule(".md-mermaid-open {", property: "color", includesHex: palette.mermaidControlTextHex)
        assertStyleSheetRule(".md-mermaid-open {", property: "background", includesColor: palette.mermaidControlBackground)
        assertStyleSheetRule(".md-mermaid-open {", property: "border", includesColor: palette.mermaidControlBorder)
        assertStyleSheetRule(
            ".md-mermaid-open:hover,",
            property: "background",
            includesHex: palette.mermaidControlHoverBackgroundHex
        )
        assertStyleSheetRule(
            ".md-mermaid-open:hover,",
            property: "border-color",
            includesColor: palette.mermaidControlHoverBorder
        )
        assertStyleSheetRule(".md-mermaid-error {", property: "color", includesHex: palette.mermaidErrorTextHex)
        assertStyleSheetRule(".md-mermaid-source {", property: "background", includesColor: palette.mermaidSourceBackground)

        assertStyleSheetRule(".md-diagram-inspector {", property: "background", includesColor: palette.diagramInspectorBackdrop)
        assertStyleSheetRule(".md-diagram-inspector {", property: "color", includesHex: palette.diagramInspectorTextHex)
        assertStyleSheetRule(
            ".md-diagram-inspector-toolbar {",
            property: "background",
            includesColor: palette.diagramInspectorToolbarBackground
        )
        assertStyleSheetRule(
            ".md-diagram-inspector-toolbar {",
            property: "border",
            includesColor: palette.diagramInspectorToolbarBorder
        )
        assertStyleSheetRule(
            ".md-diagram-inspector-toolbar button {",
            property: "color",
            includesHex: palette.diagramInspectorButtonTextHex
        )
        assertStyleSheetRule(
            ".md-diagram-inspector-toolbar button {",
            property: "background",
            includesHex: palette.diagramInspectorButtonBackgroundHex
        )
        assertStyleSheetRule(
            ".md-diagram-inspector-toolbar button {",
            property: "border",
            includesColor: palette.diagramInspectorButtonBorder
        )
        assertStyleSheetRule(
            ".md-diagram-inspector-toolbar button:hover,",
            property: "background",
            includesHex: palette.diagramInspectorButtonHoverBackgroundHex
        )
        assertStyleSheetRule(
            ".md-diagram-inspector-toolbar button:hover,",
            property: "border-color",
            includesColor: palette.diagramInspectorButtonHoverBorder
        )
        assertStyleSheetRule(
            ".md-diagram-inspector-viewport {",
            property: "background",
            includesHex: palette.diagramInspectorViewportBackgroundHex
        )
        assertStyleSheetRule(
            ".md-diagram-inspector-viewport {",
            property: "border",
            includesColor: palette.diagramInspectorViewportBorder
        )
        assertStyleSheetRule(
            ".md-diagram-inspector-viewport:focus-visible {",
            property: "outline",
            includesColor: palette.diagramInspectorViewportFocusOutline
        )

        assertStyleSheetRule(".cm-s-inner .cm-variable,", property: "color", includesHex: palette.syntaxVariableHex)
        assertStyleSheetRule(".cm-s-inner .cm-link {", property: "color", includesHex: palette.syntaxVariableHex)
        assertStyleSheetRule(".cm-s-inner .cm-keyword {", property: "color", includesHex: palette.syntaxKeywordHex)
        assertStyleSheetRule(".cm-s-inner .cm-string {", property: "color", includesHex: palette.syntaxStringHex)
        assertStyleSheetRule(".cm-s-inner .cm-comment {", property: "color", includesHex: palette.syntaxCommentHex)
        assertStyleSheetRule(".cm-s-inner .cm-number {", property: "color", includesHex: palette.syntaxNumberHex)
        assertStyleSheetRule(".cm-s-inner .cm-atom {", property: "color", includesHex: palette.syntaxAtomHex)
        assertStyleSheetRule(".cm-s-inner .cm-variable-2 {", property: "color", includesHex: palette.syntaxSecondaryVariableHex)
        assertStyleSheetRule(".cm-s-inner .cm-header,", property: "color", includesHex: palette.syntaxDefinitionHex)
        assertStyleSheetRule(".cm-s-inner .cm-positive {", property: "color", includesHex: palette.syntaxPositiveHex)
        assertStyleSheetRule(".cm-s-inner .cm-negative {", property: "color", includesHex: palette.syntaxNegativeHex)
    }

    func testDarkPaletteCapturesCurrentHardcodedAppChromeColors() {
        let palette = ReaderThemePalette.dark

        assertPaletteColor(palette.titlebarPrimaryText, matches: ReaderTheme.color(palette.sidebarPrimaryText).withAlphaComponent(0.72))
        XCTAssertEqual(palette.statisticsLabel, ReaderThemeColor(hex: "#DBDBDB", alpha: 0.98))
        XCTAssertEqual(palette.statisticsIcon, ReaderThemeColor(hex: "#D1D1D1", alpha: 0.9))
        XCTAssertEqual(palette.statisticsIconButton, ReaderThemeColor(hex: "#D1D1D1", alpha: 0.92))
        XCTAssertEqual(palette.statisticsPillRestingBackground, ReaderThemeColor(hex: "#FFFFFF", alpha: 0.045))
        XCTAssertEqual(palette.statisticsPillHoverBackground, ReaderThemeColor(hex: "#FFFFFF", alpha: 0.08))
        XCTAssertEqual(palette.statisticsPillHoverBorder, ReaderThemeColor(hex: "#FFFFFF", alpha: 0.14))
        XCTAssertEqual(palette.statisticsIconButtonRestingBackground, ReaderThemeColor(hex: "#FFFFFF", alpha: 0.03))
        XCTAssertEqual(palette.statisticsIconButtonHoverBackground, ReaderThemeColor(hex: "#FFFFFF", alpha: 0.07))
        XCTAssertEqual(palette.statisticsIconButtonActiveBackground, ReaderThemeColor(hex: "#FFFFFF", alpha: 0.12))
        XCTAssertEqual(palette.statisticsIconButtonHoverBorder, ReaderThemeColor(hex: "#FFFFFF", alpha: 0.12))
    }

    func testDarkMermaidPaletteMatchesCurrentBootstrapVariables() {
        let palette = ReaderThemePalette.dark.mermaid
        let output = renderMermaidDocument()

        XCTAssertEqual(palette.theme, "base")
        XCTAssertTrue(output.html.contains("&quot;theme&quot;:&quot;\(palette.theme)&quot;"))
        for variable in palette.themeVariables {
            XCTAssertTrue(
                output.html.contains("&quot;\(variable.key)&quot;:&quot;\(variable.value)&quot;"),
                "Missing Mermaid theme variable \(variable.key)=\(variable.value)"
            )
        }
        XCTAssertTrue(output.html.contains("&quot;fontFamily&quot;:&quot;\(palette.fontFamily)&quot;"))
    }

    func testLightPaletteIsPopulatedAndReadable() {
        let palette = ReaderThemePalette.light

        XCTAssertEqual(palette.name, "Light")
        XCTAssertFalse(palette.appearanceIsDark)
        XCTAssertGreaterThanOrEqual(contrastRatio(foreground: palette.textHex, background: palette.backgroundHex), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(foreground: palette.headingHex, background: palette.backgroundHex), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(foreground: palette.secondaryTextHex, background: palette.backgroundHex), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(foreground: palette.linkHex, background: palette.backgroundHex), 4.5)
    }

    func testBuiltInPalettesHaveNoEmptyOrMalformedColorValues() {
        for palette in [ReaderThemePalette.dark, .light] {
            for stringValue in strings(in: palette) {
                XCTAssertFalse(stringValue.value.isEmpty, "Empty string at \(stringValue.path)")
                if stringValue.value.hasPrefix("#") {
                    XCTAssertTrue(isHexColor(stringValue.value), "Malformed hex color at \(stringValue.path)")
                }
            }

            for color in colorTokens(in: palette) {
                XCTAssertTrue(isHexColor(color.value.hex), "Malformed token hex at \(color.path)")
                XCTAssertGreaterThanOrEqual(color.value.alpha, 0, "Negative alpha at \(color.path)")
                XCTAssertLessThanOrEqual(color.value.alpha, 1, "Alpha above 1 at \(color.path)")
            }
        }
    }

    private func cssRootToken(_ name: String) -> String {
        for line in ReaderTheme.styleSheet(for: .dark).components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(name): ") else {
                continue
            }
            return String(trimmed.dropFirst(name.count + 2).dropLast())
        }

        XCTFail("Missing CSS root token \(name)")
        return ""
    }

    private func renderMermaidDocument() -> WebKitRenderOutput {
        let parser = MarkdownParser()
        let document = parser.parse(
            source: """
            ```mermaid
            graph TD
              A --> B
            ```
            """,
            baseURL: nil
        )
        return WebKitHTMLRenderer().render(document: document)
    }

    private func assertStyleSheetRule(
        _ selector: String,
        property: String,
        includesHex hex: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertStyleSheetRule(selector, property: property, includesAnyColor: cssHexCandidates(for: hex), file: file, line: line)
    }

    private func assertStyleSheetRule(
        _ selector: String,
        property: String,
        includesColor color: ReaderThemeColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let components = rgbComponents(for: color.hex)
        let rgba = "rgba(\(components.red), \(components.green), \(components.blue), \(color.alpha))"
        assertStyleSheetRule(selector, property: property, includesAnyColor: [rgba], file: file, line: line)
    }

    private func assertStyleSheetRule(
        _ selector: String,
        property: String,
        includesAnyColor colors: [String],
        file: StaticString,
        line: UInt
    ) {
        guard
            let selectorRange = ReaderTheme.styleSheet(for: .dark).range(of: selector),
            let blockEnd = ReaderTheme.styleSheet(for: .dark)[selectorRange.upperBound...].range(of: "}")?.upperBound
        else {
            XCTFail("Missing style rule for \(selector)", file: file, line: line)
            return
        }

        let block = ReaderTheme.styleSheet(for: .dark)[selectorRange.lowerBound..<blockEnd]
        XCTAssertTrue(block.contains("\(property):"), "Missing property \(property) in \(selector)", file: file, line: line)
        XCTAssertTrue(
            colors.contains { block.contains($0) } || propertyUsesThemeVariable(property, in: block),
            "Missing \(property) color \(colors.joined(separator: " or ")) or themed variable in \(selector)",
            file: file,
            line: line
        )
    }

    private func propertyUsesThemeVariable(_ property: String, in block: Substring) -> Bool {
        let pattern = #"\#(NSRegularExpression.escapedPattern(for: property)):\s*[^;]*var\(--"#
        return block.range(of: pattern, options: .regularExpression) != nil
    }

    private func cssHexCandidates(for hex: String) -> [String] {
        var candidates = [hex.uppercased(), hex.lowercased()]
        let digits = String(hex.dropFirst())
        if
            digits.count == 6,
            digits[digits.startIndex] == digits[digits.index(after: digits.startIndex)],
            digits[digits.index(digits.startIndex, offsetBy: 2)] == digits[digits.index(digits.startIndex, offsetBy: 3)],
            digits[digits.index(digits.startIndex, offsetBy: 4)] == digits[digits.index(digits.startIndex, offsetBy: 5)]
        {
            let short = "#\(digits[digits.startIndex])\(digits[digits.index(digits.startIndex, offsetBy: 2)])\(digits[digits.index(digits.startIndex, offsetBy: 4)])"
            candidates.append(short.uppercased())
            candidates.append(short.lowercased())
        }
        return Array(Set(candidates))
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
        let expected = components(for: hex, alpha: alpha)
        let actual = color.usingColorSpace(.deviceRGB) ?? color
        XCTAssertEqual(actual.redComponent, expected.red, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.green, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blue, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expected.alpha, accuracy: accuracy, file: file, line: line)
    }

    private func contrastRatio(foreground: String, background: String) -> Double {
        let foregroundLuminance = relativeLuminance(of: foreground)
        let backgroundLuminance = relativeLuminance(of: background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(of hex: String) -> Double {
        let components = components(for: hex, alpha: 1)
        return (0.2126 * linear(Double(components.red)))
            + (0.7152 * linear(Double(components.green)))
            + (0.0722 * linear(Double(components.blue)))
    }

    private func linear(_ component: Double) -> Double {
        if component <= 0.03928 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }

    private func rgbComponents(for hex: String) -> (red: Int, green: Int, blue: Int) {
        let digits = String(hex.dropFirst())
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        return (
            red: Int((value >> 16) & 0xFF),
            green: Int((value >> 8) & 0xFF),
            blue: Int(value & 0xFF)
        )
    }

    private func components(for hex: String, alpha: Double) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let value = rgbComponents(for: hex)
        return (
            red: CGFloat(value.red) / 255,
            green: CGFloat(value.green) / 255,
            blue: CGFloat(value.blue) / 255,
            alpha: CGFloat(alpha)
        )
    }

    private func isHexColor(_ value: String) -> Bool {
        let pattern = #"^#[0-9A-Fa-f]{6}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private func strings(in value: Any, path: String = "palette") -> [(path: String, value: String)] {
        if let value = value as? String {
            return [(path, value)]
        }

        if value is Double || value is Bool {
            return []
        }

        return Mirror(reflecting: value).children.flatMap { child in
            strings(in: child.value, path: "\(path).\(child.label ?? "?")")
        }
    }

    private func colorTokens(in value: Any, path: String = "palette") -> [(path: String, value: ReaderThemeColor)] {
        if let value = value as? ReaderThemeColor {
            return [(path, value)]
        }

        if value is String || value is Double || value is Bool {
            return []
        }

        return Mirror(reflecting: value).children.flatMap { child in
            colorTokens(in: child.value, path: "\(path).\(child.label ?? "?")")
        }
    }

    private static let darkPaletteV05GoldenJSON = """
    {
      "appearanceIsDark" : true,
      "backgroundHex" : "#383E44",
      "calloutBackground" : {
        "alpha" : 0.04,
        "hex" : "#FFFFFF"
      },
      "calloutCautionBackground" : {
        "alpha" : 0.12,
        "hex" : "#BE7D7D"
      },
      "calloutCautionBorder" : {
        "alpha" : 0.94,
        "hex" : "#BE7D7D"
      },
      "calloutImportantBackground" : {
        "alpha" : 0.11,
        "hex" : "#8F98D5"
      },
      "calloutImportantBorder" : {
        "alpha" : 0.92,
        "hex" : "#8F98D5"
      },
      "calloutNoteBackground" : {
        "alpha" : 0.11,
        "hex" : "#7DA1BC"
      },
      "calloutNoteBorder" : {
        "alpha" : 0.9,
        "hex" : "#7DA1BC"
      },
      "calloutTipBackground" : {
        "alpha" : 0.11,
        "hex" : "#7FB597"
      },
      "calloutTipBorder" : {
        "alpha" : 0.9,
        "hex" : "#7FB597"
      },
      "calloutWarningBackground" : {
        "alpha" : 0.12,
        "hex" : "#BF9866"
      },
      "calloutWarningBorder" : {
        "alpha" : 0.94,
        "hex" : "#BF9866"
      },
      "codeBlockBackgroundHex" : "#2F3135",
      "diagramInspectorBackdrop" : {
        "alpha" : 0.86,
        "hex" : "#121416"
      },
      "diagramInspectorButtonBackgroundHex" : "#2F3135",
      "diagramInspectorButtonBorder" : {
        "alpha" : 0.18,
        "hex" : "#D7DDE3"
      },
      "diagramInspectorButtonHoverBackgroundHex" : "#383E44",
      "diagramInspectorButtonHoverBorder" : {
        "alpha" : 0.52,
        "hex" : "#F1F3F5"
      },
      "diagramInspectorButtonTextHex" : "#F1F3F5",
      "diagramInspectorTextHex" : "#F1F3F5",
      "diagramInspectorToolbarBackground" : {
        "alpha" : 0.94,
        "hex" : "#212427"
      },
      "diagramInspectorToolbarBorder" : {
        "alpha" : 0.14,
        "hex" : "#D7DDE3"
      },
      "diagramInspectorViewportBackgroundHex" : "#2F3135",
      "diagramInspectorViewportBorder" : {
        "alpha" : 0.14,
        "hex" : "#D7DDE3"
      },
      "diagramInspectorViewportFocusOutline" : {
        "alpha" : 0.54,
        "hex" : "#F1F3F5"
      },
      "findBarBackground" : {
        "alpha" : 0.94,
        "hex" : "#484848"
      },
      "findBarBorder" : {
        "alpha" : 0.08,
        "hex" : "#FFFFFF"
      },
      "headingHex" : "#E2E4E7",
      "inlineChipBackground" : {
        "alpha" : 0.055,
        "hex" : "#FFFFFF"
      },
      "inlineChipBorder" : {
        "alpha" : 0.08,
        "hex" : "#FFFFFF"
      },
      "inlineCodeBackgroundHex" : "#30343A",
      "kbdBorderHex" : "#727880",
      "kbdShadow" : {
        "alpha" : 0.22,
        "hex" : "#000000"
      },
      "kbdTextHex" : "#FFFFFF",
      "linkHex" : "#D7DDE3",
      "linkHoverHex" : "#FFFFFF",
      "mermaid" : {
        "activeTaskBkgColor" : "#596579",
        "activeTaskBorderColor" : "#A1A7AE",
        "altSectionBkgColor" : "#2A3035",
        "attributeBackgroundColorEven" : "#252A2E",
        "attributeBackgroundColorOdd" : "#30363B",
        "background" : "#383E44",
        "critBkgColor" : "#6E4E54",
        "critBorderColor" : "#D48D8D",
        "doneTaskBkgColor" : "#3F474F",
        "doneTaskBorderColor" : "#727880",
        "edgeLabelBackground" : "#252A2E",
        "erEdgeLabelBackground" : "#252A2E",
        "fontFamily" : "Helvetica Neue, Helvetica, Arial, sans-serif",
        "gridColor" : "#727880",
        "lineColor" : "#D7DDE3",
        "mainBkg" : "#252A2E",
        "nodeBorder" : "#838B94",
        "nodeTextColor" : "#F1F3F5",
        "primaryBorderColor" : "#727880",
        "primaryColor" : "#2F3135",
        "primaryTextColor" : "#E2E4E7",
        "secondaryColor" : "#383E44",
        "secondaryTextColor" : "#E2E4E7",
        "sectionBkgColor" : "#252A2E",
        "sectionBkgColor2" : "#30363B",
        "taskBkgColor" : "#4C5662",
        "taskBorderColor" : "#838B94",
        "taskTextClickableColor" : "#F1F3F5",
        "taskTextColor" : "#F1F3F5",
        "taskTextDarkColor" : "#F1F3F5",
        "taskTextLightColor" : "#F1F3F5",
        "taskTextOutsideColor" : "#D7DDE3",
        "tertiaryColor" : "#212427",
        "tertiaryTextColor" : "#E2E4E7",
        "textColor" : "#BCC3CA",
        "theme" : "base",
        "titleColor" : "#F1F3F5",
        "todayLineColor" : "#D7DDE3",
        "vertLineColor" : "#D7DDE3"
      },
      "mermaidContainerBackground" : {
        "alpha" : 0.78,
        "hex" : "#2F3135"
      },
      "mermaidContainerBorder" : {
        "alpha" : 0.12,
        "hex" : "#D7DDE3"
      },
      "mermaidControlBackground" : {
        "alpha" : 0.92,
        "hex" : "#1C2023"
      },
      "mermaidControlBorder" : {
        "alpha" : 0.26,
        "hex" : "#D7DDE3"
      },
      "mermaidControlHoverBackgroundHex" : "#1C2023",
      "mermaidControlHoverBorder" : {
        "alpha" : 0.58,
        "hex" : "#F1F3F5"
      },
      "mermaidControlTextHex" : "#F1F3F5",
      "mermaidErrorTextHex" : "#E7B0B0",
      "mermaidGridStroke" : {
        "alpha" : 0.34,
        "hex" : "#D7DDE3"
      },
      "mermaidSourceBackground" : {
        "alpha" : 0.14,
        "hex" : "#000000"
      },
      "minorHeadingHex" : "#FFFFFF",
      "name" : "Dark",
      "ruleHex" : "#4C525A",
      "secondaryTextHex" : "#A1A7AE",
      "selectionHex" : "#4B84D1",
      "selectionTextHex" : "#FFFFFF",
      "sidebarBackgroundHex" : "#212427",
      "sidebarChromeBorder" : {
        "alpha" : 0.035,
        "hex" : "#FFFFFF"
      },
      "sidebarChromeFill" : {
        "alpha" : 0.024,
        "hex" : "#FFFFFF"
      },
      "sidebarChromeHoverFill" : {
        "alpha" : 0.04,
        "hex" : "#FFFFFF"
      },
      "sidebarChromeSelectedFill" : {
        "alpha" : 0.065,
        "hex" : "#FFFFFF"
      },
      "sidebarHover" : {
        "alpha" : 0.028,
        "hex" : "#FFFFFF"
      },
      "sidebarPrimaryText" : {
        "alpha" : 0.96,
        "hex" : "#E6E6E6"
      },
      "sidebarSecondaryText" : {
        "alpha" : 0.92,
        "hex" : "#A8A8A8"
      },
      "sidebarSelectionHex" : "#1C2023",
      "statisticsIcon" : {
        "alpha" : 0.9,
        "hex" : "#D1D1D1"
      },
      "statisticsIconButton" : {
        "alpha" : 0.92,
        "hex" : "#D1D1D1"
      },
      "statisticsIconButtonActiveBackground" : {
        "alpha" : 0.12,
        "hex" : "#FFFFFF"
      },
      "statisticsIconButtonHoverBackground" : {
        "alpha" : 0.07,
        "hex" : "#FFFFFF"
      },
      "statisticsIconButtonHoverBorder" : {
        "alpha" : 0.12,
        "hex" : "#FFFFFF"
      },
      "statisticsIconButtonRestingBackground" : {
        "alpha" : 0.03,
        "hex" : "#FFFFFF"
      },
      "statisticsLabel" : {
        "alpha" : 0.98,
        "hex" : "#DBDBDB"
      },
      "statisticsPillHoverBackground" : {
        "alpha" : 0.08,
        "hex" : "#FFFFFF"
      },
      "statisticsPillHoverBorder" : {
        "alpha" : 0.14,
        "hex" : "#FFFFFF"
      },
      "statisticsPillRestingBackground" : {
        "alpha" : 0.045,
        "hex" : "#FFFFFF"
      },
      "symbolLinkBorder" : {
        "alpha" : 0.14,
        "hex" : "#C8D6F0"
      },
      "symbolLinkTextHex" : "#C8D6F0",
      "syntaxAtomHex" : "#87B8CC",
      "syntaxCommentHex" : "#D59452",
      "syntaxDefinitionHex" : "#9496EF",
      "syntaxKeywordHex" : "#CB94D4",
      "syntaxNegativeHex" : "#D48D8D",
      "syntaxNumberHex" : "#68AE95",
      "syntaxPositiveHex" : "#88C09D",
      "syntaxSecondaryVariableHex" : "#A2BCD7",
      "syntaxStringHex" : "#D87272",
      "syntaxVariableHex" : "#D2D8EA",
      "tab" : {
        "barBackground" : {
          "alpha" : 1,
          "hex" : "#212427"
        },
        "barBorder" : {
          "alpha" : 0.06,
          "hex" : "#FFFFFF"
        },
        "closeHoverFill" : {
          "alpha" : 0.1,
          "hex" : "#FFFFFF"
        },
        "closeIcon" : {
          "alpha" : 0.92,
          "hex" : "#A8A8A8"
        },
        "hoverFill" : {
          "alpha" : 0.06,
          "hex" : "#FFFFFF"
        },
        "insertionIndicator" : {
          "alpha" : 0.9,
          "hex" : "#D7DDE3"
        },
        "restingFill" : {
          "alpha" : 0.02,
          "hex" : "#FFFFFF"
        },
        "selectedFill" : {
          "alpha" : 1,
          "hex" : "#383E44"
        },
        "selectedText" : {
          "alpha" : 0.96,
          "hex" : "#E6E6E6"
        },
        "unselectedText" : {
          "alpha" : 0.92,
          "hex" : "#A8A8A8"
        }
      },
      "textHex" : "#BCC3CA",
      "titlebarPrimaryText" : {
        "alpha" : 0.72,
        "hex" : "#E6E6E6"
      }
    }
    """
}
