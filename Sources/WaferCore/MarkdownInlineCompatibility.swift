import Foundation

enum EmojiShortcodes {
    static let all: [String: String] = {
        guard
            let resourceURL = ReaderTheme.resourceURL(named: "gemoji-shortcodes.json"),
            let data = try? Data(contentsOf: resourceURL),
            let shortcodes = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }

        return shortcodes
    }()
}

enum MarkdownInlineCompatibility {
    static func htmlByRenderingTextDecorations(
        in text: String,
        emojiShortcodes: [String: String] = EmojiShortcodes.all
    ) -> String {
        var output = ""
        var literalStart = text.startIndex
        var cursor = text.startIndex

        while cursor < text.endIndex {
            if let highlight = highlightCandidate(in: text, at: cursor) {
                output += String(text[literalStart..<cursor]).escapedHTML
                let content = String(text[highlight.contentRange])
                output += "<mark>\(htmlByRenderingEmojiShortcodes(in: content, emojiShortcodes: emojiShortcodes))</mark>"
                cursor = highlight.fullRange.upperBound
                literalStart = cursor
                continue
            }

            if let shortcode = emojiShortcodeCandidate(in: text, at: cursor) {
                output += String(text[literalStart..<cursor]).escapedHTML
                if let emoji = emojiShortcodes[shortcode.label] {
                    output += emoji.escapedHTML
                } else {
                    output += String(text[shortcode.range]).escapedHTML
                }
                cursor = shortcode.range.upperBound
                literalStart = cursor
                continue
            }

            cursor = text.index(after: cursor)
        }

        output += String(text[literalStart...]).escapedHTML
        return output
    }

    private static func htmlByRenderingEmojiShortcodes(
        in text: String,
        emojiShortcodes: [String: String]
    ) -> String {
        var output = ""
        var literalStart = text.startIndex
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard let shortcode = emojiShortcodeCandidate(in: text, at: cursor) else {
                cursor = text.index(after: cursor)
                continue
            }

            output += String(text[literalStart..<cursor]).escapedHTML
            if let emoji = emojiShortcodes[shortcode.label] {
                output += emoji.escapedHTML
            } else {
                output += String(text[shortcode.range]).escapedHTML
            }
            cursor = shortcode.range.upperBound
            literalStart = cursor
        }

        output += String(text[literalStart...]).escapedHTML
        return output
    }

    private static func emojiShortcodeCandidate(
        in text: String,
        at colonIndex: String.Index
    ) -> (range: Range<String.Index>, label: String)? {
        guard text[colonIndex] == ":" else {
            return nil
        }

        let labelStart = text.index(after: colonIndex)
        guard labelStart < text.endIndex else {
            return nil
        }

        var cursor = labelStart
        while cursor < text.endIndex {
            guard text[cursor] == ":" else {
                cursor = text.index(after: cursor)
                continue
            }

            let label = String(text[labelStart..<cursor])
            guard isValidEmojiShortcode(label) else {
                return nil
            }

            return (colonIndex..<text.index(after: cursor), label)
        }

        return nil
    }

    private static func isValidEmojiShortcode(_ label: String) -> Bool {
        guard !label.isEmpty else {
            return false
        }

        return label.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 43, 45, 48...57, 95, 97...122:
                return true
            default:
                return false
            }
        }
    }

    private static func highlightCandidate(
        in text: String,
        at delimiterStart: String.Index
    ) -> (fullRange: Range<String.Index>, contentRange: Range<String.Index>)? {
        guard
            let openingRange = highlightDelimiterRange(in: text, at: delimiterStart),
            isHighlightOpeningDelimiter(openingRange, in: text)
        else {
            return nil
        }

        let contentStart = openingRange.upperBound
        var searchStart = contentStart
        while let closingRange = text.range(of: "==", range: searchStart..<text.endIndex) {
            defer {
                searchStart = text.index(after: closingRange.lowerBound)
            }

            if isHighlightOpeningDelimiter(closingRange, in: text) {
                return nil
            }

            guard closingRange.lowerBound > contentStart,
                  isHighlightClosingDelimiter(closingRange, in: text) else {
                continue
            }

            return (
                openingRange.lowerBound..<closingRange.upperBound,
                contentStart..<closingRange.lowerBound
            )
        }

        return nil
    }

    private static func highlightDelimiterRange(
        in text: String,
        at delimiterStart: String.Index
    ) -> Range<String.Index>? {
        guard text[delimiterStart...].hasPrefix("==") else {
            return nil
        }

        return delimiterStart..<text.index(delimiterStart, offsetBy: 2)
    }

    private static func isIsolatedHighlightDelimiter(
        _ range: Range<String.Index>,
        in text: String
    ) -> Bool {
        if range.lowerBound > text.startIndex,
           text[text.index(before: range.lowerBound)] == "=" {
            return false
        }

        if range.upperBound < text.endIndex,
           text[range.upperBound] == "=" {
            return false
        }

        return true
    }

    private static func isHighlightOpeningDelimiter(
        _ range: Range<String.Index>,
        in text: String
    ) -> Bool {
        guard isIsolatedHighlightDelimiter(range, in: text) else {
            return false
        }

        guard range.lowerBound > text.startIndex else {
            return true
        }

        let previous = text[text.index(before: range.lowerBound)]
        return !previous.isLetter && !previous.isNumber && previous != "_"
    }

    private static func isHighlightClosingDelimiter(
        _ range: Range<String.Index>,
        in text: String
    ) -> Bool {
        guard isIsolatedHighlightDelimiter(range, in: text) else {
            return false
        }

        return !isHighlightOpeningDelimiter(range, in: text)
    }
}
