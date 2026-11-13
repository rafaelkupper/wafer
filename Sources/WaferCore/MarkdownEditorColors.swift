import AppKit

/// Edit-mode source editor colors derived from the active reader palette, so
/// the editor follows built-in and custom themes without extra theme fields.
public struct MarkdownEditorColors {
    public let background: NSColor
    public let text: NSColor
    public let heading: NSColor
    public let secondaryText: NSColor
    public let link: NSColor
    public let inlineCodeBackground: NSColor
    public let selection: NSColor
    public let selectionText: NSColor
    public let divider: NSColor
    public let syntaxVariable: NSColor
    public let syntaxKeyword: NSColor
    public let syntaxString: NSColor
    public let syntaxComment: NSColor
    public let syntaxNumber: NSColor
    public let syntaxAtom: NSColor
    public let syntaxSecondaryVariable: NSColor
    public let syntaxDefinition: NSColor
    public let syntaxPositive: NSColor
    public let syntaxNegative: NSColor

    public init(palette: ReaderThemePalette) {
        func color(_ hex: String) -> NSColor {
            ReaderThemeColor(hex: hex).readerColor
        }

        background = color(palette.backgroundHex)
        text = color(palette.textHex)
        heading = color(palette.headingHex)
        secondaryText = color(palette.secondaryTextHex)
        link = color(palette.linkHex)
        inlineCodeBackground = color(palette.inlineCodeBackgroundHex)
        selection = color(palette.selectionHex)
        selectionText = color(palette.selectionTextHex)
        divider = color(palette.ruleHex)
        syntaxVariable = color(palette.syntaxVariableHex)
        syntaxKeyword = color(palette.syntaxKeywordHex)
        syntaxString = color(palette.syntaxStringHex)
        syntaxComment = color(palette.syntaxCommentHex)
        syntaxNumber = color(palette.syntaxNumberHex)
        syntaxAtom = color(palette.syntaxAtomHex)
        syntaxSecondaryVariable = color(palette.syntaxSecondaryVariableHex)
        syntaxDefinition = color(palette.syntaxDefinitionHex)
        syntaxPositive = color(palette.syntaxPositiveHex)
        syntaxNegative = color(palette.syntaxNegativeHex)
    }

    /// Mirrors the reader's fenced-code CSS (`cm-*` classes).
    public func color(for kind: MarkdownCodeTokenKind) -> NSColor {
        switch kind {
        case .keyword: syntaxKeyword
        case .type: syntaxDefinition
        case .string: syntaxString
        case .number: syntaxNumber
        case .comment: syntaxComment
        case .function: syntaxSecondaryVariable
        case .member: syntaxVariable
        case .meta: syntaxAtom
        case .addition: syntaxPositive
        case .deletion: syntaxNegative
        }
    }
}
