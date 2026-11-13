import Foundation

/// Front matter and fenced code blocks, plus line starts, for the edit-mode
/// source editor. All offsets are UTF-16 (NSString) offsets.
public struct MarkdownSourceStructure: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case frontMatter
            case fencedCode(language: String)
        }

        public let kind: Kind
        /// Whole lines from the opening delimiter through the closing
        /// delimiter (or the end of the text when unclosed), without the
        /// final line break.
        public let range: NSRange
        /// Lines between the delimiters, without the final line break.
        public let contentRange: NSRange
        public let openingLineRange: NSRange
        public let closingLineRange: NSRange?
    }

    /// UTF-16 offset of each line start. Always contains at least one entry.
    public let lineStarts: [Int]
    public let length: Int
    public let blocks: [Block]

    public var lineCount: Int { lineStarts.count }

    /// Zero-based line index containing `location`.
    public func lineIndex(containing location: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(low - 1, 0)
    }

    /// Range of line `index` without its line break.
    public func lineRange(at index: Int) -> NSRange {
        let start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] - 1 : length
        return NSRange(location: start, length: max(end - start, 0))
    }

    /// Range of lines `lines`, without the last line's break.
    public func range(ofLines lines: Range<Int>) -> NSRange {
        guard !lines.isEmpty else {
            return NSRange(location: lineStarts[min(lines.lowerBound, lineStarts.count - 1)], length: 0)
        }
        let start = lineStarts[lines.lowerBound]
        let end = NSMaxRange(lineRange(at: lines.upperBound - 1))
        return NSRange(location: start, length: end - start)
    }

    public func block(containing location: Int) -> Block? {
        var low = 0
        var high = blocks.count
        while low < high {
            let middle = (low + high) / 2
            let range = blocks[middle].range
            if NSMaxRange(range) < location {
                low = middle + 1
            } else if range.location > location {
                high = middle
            } else {
                return blocks[middle]
            }
        }
        return nil
    }
}

public enum MarkdownSourceTokenKind: Equatable, Sendable {
    case headingMarker
    case headingText
    case quoteMarker
    case quoteText
    case listMarker
    case taskMarker
    case thematicBreak
    case tableDelimiter
    case strong
    case emphasis
    case strikethrough
    case highlight
    case inlineCode
    case linkText
    case linkDestination
    case wikiLink
    case footnote
    case html
    case escape
    case fenceDelimiter
    case codeText
    case code(MarkdownCodeTokenKind)
    case frontMatterDelimiter
    case frontMatterKey
    case frontMatterValue
}

/// Public mirror of the fenced-code token kinds used by the reader highlighter.
public enum MarkdownCodeTokenKind: String, Equatable, Sendable {
    case keyword
    case type
    case string
    case number
    case comment
    case function
    case member
    case meta
    case addition
    case deletion
}

public struct MarkdownSourceToken: Equatable, Sendable {
    public let range: NSRange
    public let kind: MarkdownSourceTokenKind

    public init(range: NSRange, kind: MarkdownSourceTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// Fast, approximate Markdown source coloring. Tokens are emitted in
/// application order: later tokens refine earlier ones, and code spans come
/// last so markers inside them stay literal.
public struct MarkdownSourceHighlighter: Sendable {
    public init() {}

    // MARK: Structure

    public func structure(of text: NSString) -> MarkdownSourceStructure {
        let length = text.length
        var units = [unichar](repeating: 0, count: length)
        if length > 0 {
            units.withUnsafeMutableBufferPointer { buffer in
                text.getCharacters(buffer.baseAddress!, range: NSRange(location: 0, length: length))
            }
        }

        var lineStarts = [0]
        lineStarts.reserveCapacity(length / 32 + 1)
        for index in 0..<length where units[index] == 0x0A {
            lineStarts.append(index + 1)
        }

        func lineEnd(_ line: Int) -> Int {
            line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : length
        }

        var blocks: [MarkdownSourceStructure.Block] = []
        var line = 0

        // Front matter: first line exactly "---", closed by "---" or "...".
        if lineStarts.count > 1, Self.lineEquals(units, from: 0, to: lineEnd(0), "---") {
            var closing = 1
            while closing < lineStarts.count {
                let start = lineStarts[closing]
                let end = lineEnd(closing)
                if Self.lineEquals(units, from: start, to: end, "---") || Self.lineEquals(units, from: start, to: end, "...") {
                    break
                }
                closing += 1
            }
            if closing < lineStarts.count {
                let contentStart = lineStarts[1]
                let contentEnd = closing > 1 ? lineEnd(closing - 1) : contentStart
                blocks.append(MarkdownSourceStructure.Block(
                    kind: .frontMatter,
                    range: NSRange(location: 0, length: lineEnd(closing)),
                    contentRange: NSRange(location: contentStart, length: max(contentEnd - contentStart, 0)),
                    openingLineRange: NSRange(location: 0, length: lineEnd(0)),
                    closingLineRange: NSRange(location: lineStarts[closing], length: lineEnd(closing) - lineStarts[closing])
                ))
                line = closing + 1
            }
        }

        while line < lineStarts.count {
            let start = lineStarts[line]
            let end = lineEnd(line)
            guard let opening = Self.fenceOpening(units, from: start, to: end) else {
                line += 1
                continue
            }

            let language = String(utf16CodeUnits: Array(units[opening.infoStart..<end]), count: end - opening.infoStart)
                .trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0.isWhitespace || $0 == "{" })
                .first
                .map(String.init) ?? ""
            var closing = line + 1
            while closing < lineStarts.count {
                if Self.isFenceClosing(units, from: lineStarts[closing], to: lineEnd(closing), marker: opening.marker, count: opening.count) {
                    break
                }
                closing += 1
            }

            let closingLine = closing < lineStarts.count ? closing : nil
            let lastContentLine = (closingLine ?? lineStarts.count) - 1
            let contentStart = line + 1 < lineStarts.count ? lineStarts[line + 1] : end
            let contentEnd = lastContentLine > line ? lineEnd(lastContentLine) : contentStart
            let blockEnd = closingLine.map(lineEnd) ?? length
            blocks.append(MarkdownSourceStructure.Block(
                kind: .fencedCode(language: language),
                range: NSRange(location: start, length: blockEnd - start),
                contentRange: NSRange(location: contentStart, length: max(contentEnd - contentStart, 0)),
                openingLineRange: NSRange(location: start, length: end - start),
                closingLineRange: closingLine.map { NSRange(location: lineStarts[$0], length: lineEnd($0) - lineStarts[$0]) }
            ))
            line = (closingLine ?? lineStarts.count - 1) + 1
        }

        return MarkdownSourceStructure(lineStarts: lineStarts, length: length, blocks: blocks)
    }

    private static func lineEquals(_ units: [unichar], from start: Int, to end: Int, _ literal: String) -> Bool {
        var trimmedEnd = end
        while trimmedEnd > start, units[trimmedEnd - 1] == 0x0D {
            trimmedEnd -= 1
        }
        let literalUnits = Array(literal.utf16)
        guard trimmedEnd - start == literalUnits.count else {
            return false
        }
        for offset in 0..<literalUnits.count where units[start + offset] != literalUnits[offset] {
            return false
        }
        return true
    }

    private static func fenceOpening(_ units: [unichar], from start: Int, to end: Int) -> (marker: unichar, count: Int, infoStart: Int)? {
        var index = start
        while index < end, units[index] == 0x20 || units[index] == 0x09 {
            index += 1
        }
        guard index < end, units[index] == 0x60 || units[index] == 0x7E else {
            return nil
        }
        let marker = units[index]
        var count = 0
        while index < end, units[index] == marker {
            count += 1
            index += 1
        }
        guard count >= 3 else {
            return nil
        }
        // Backtick fences cannot have backticks in their info string.
        if marker == 0x60, units[index..<end].contains(0x60) {
            return nil
        }
        return (marker, count, index)
    }

    private static func isFenceClosing(_ units: [unichar], from start: Int, to end: Int, marker: unichar, count: Int) -> Bool {
        var index = start
        while index < end, units[index] == 0x20 || units[index] == 0x09 {
            index += 1
        }
        var markerCount = 0
        while index < end, units[index] == marker {
            markerCount += 1
            index += 1
        }
        guard markerCount >= count else {
            return false
        }
        while index < end {
            let unit = units[index]
            guard unit == 0x20 || unit == 0x09 || unit == 0x0D else {
                return false
            }
            index += 1
        }
        return true
    }

    // MARK: Tokens

    /// Tokens for the given whole lines. Fenced code inside the range is
    /// highlighted using its complete block so multi-line constructs color
    /// correctly; callers should pass block-aligned ranges.
    public func tokens(in text: NSString, structure: MarkdownSourceStructure, lines: Range<Int>) -> [MarkdownSourceToken] {
        guard !lines.isEmpty, lines.lowerBound < structure.lineCount else {
            return []
        }
        let clampedLines = lines.lowerBound..<min(lines.upperBound, structure.lineCount)
        let requested = structure.range(ofLines: clampedLines)
        var tokens: [MarkdownSourceToken] = []

        // Split the requested range into plain segments and special blocks.
        var cursor = requested.location
        let requestedEnd = NSMaxRange(requested)
        for block in structure.blocks where NSIntersectionRange(block.range, requested).length > 0 || NSLocationInRange(requested.location, block.range) {
            if block.range.location > cursor {
                tokens += plainTokens(in: text, range: NSRange(location: cursor, length: block.range.location - cursor))
            }
            tokens += blockTokens(in: text, block: block, clippedTo: requested)
            cursor = max(cursor, NSMaxRange(block.range))
        }
        if cursor < requestedEnd {
            tokens += plainTokens(in: text, range: NSRange(location: cursor, length: requestedEnd - cursor))
        }
        return tokens
    }

    private func blockTokens(in text: NSString, block: MarkdownSourceStructure.Block, clippedTo requested: NSRange) -> [MarkdownSourceToken] {
        var tokens: [MarkdownSourceToken] = []
        func append(_ range: NSRange, _ kind: MarkdownSourceTokenKind) {
            let clipped = NSIntersectionRange(range, requested)
            if clipped.length > 0 {
                tokens.append(MarkdownSourceToken(range: clipped, kind: kind))
            }
        }

        switch block.kind {
        case .frontMatter:
            append(block.openingLineRange, .frontMatterDelimiter)
            if let closing = block.closingLineRange {
                append(closing, .frontMatterDelimiter)
            }
            append(block.contentRange, .frontMatterValue)
            if block.contentRange.length > 0 {
                Self.frontMatterKey.enumerateMatches(in: text as String, options: [], range: block.contentRange) { match, _, _ in
                    if let range = match?.range(at: 1) {
                        append(range, .frontMatterKey)
                    }
                }
            }
        case .fencedCode(let language):
            append(block.openingLineRange, .fenceDelimiter)
            if let closing = block.closingLineRange {
                append(closing, .fenceDelimiter)
            }
            let content = block.contentRange
            guard content.length > 0 else {
                break
            }
            append(content, .codeText)
            guard NSIntersectionRange(content, requested).length > 0 else {
                break
            }
            let code = text.substring(with: content)
            for run in CodeSyntaxHighlighter().presentationRuns(code: code, language: language.isEmpty ? nil : language) {
                guard let kind = run.kind.flatMap({ MarkdownCodeTokenKind(rawValue: $0.rawValue) }) else { continue }
                append(NSRange(location: content.location + run.range.location, length: run.range.length), .code(kind))
            }
        }
        return tokens
    }

    private func plainTokens(in text: NSString, range: NSRange) -> [MarkdownSourceToken] {
        guard range.length > 0 else {
            return []
        }
        let string = text as String
        var tokens: [MarkdownSourceToken] = []
        func collect(_ regex: NSRegularExpression, _ handler: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
                if let match { handler(match) }
            }
        }
        func add(_ range: NSRange, _ kind: MarkdownSourceTokenKind) {
            if range.location != NSNotFound, range.length > 0 {
                tokens.append(MarkdownSourceToken(range: range, kind: kind))
            }
        }

        // Line-level structure.
        collect(Self.blockquote) { add($0.range(at: 2), .quoteText); add($0.range(at: 1), .quoteMarker) }
        collect(Self.atxHeading) { add($0.range(at: 2), .headingText); add($0.range(at: 1), .headingMarker) }
        collect(Self.setextUnderline) { add($0.range, .headingMarker) }
        collect(Self.thematicBreak) { add($0.range, .thematicBreak) }
        collect(Self.listMarker) { match in
            add(match.range(at: 1), .listMarker)
            add(match.range(at: 2), .taskMarker)
        }
        collect(Self.tableDelimiterRow) { add($0.range, .tableDelimiter) }
        collect(Self.tableRow) { match in
            // Unescaped pipes on lines that start with a pipe.
            let row = match.range
            var previous: unichar = 0
            for offset in 0..<row.length {
                let unit = text.character(at: row.location + offset)
                if unit == 0x7C, previous != 0x5C {
                    add(NSRange(location: row.location + offset, length: 1), .tableDelimiter)
                }
                previous = unit
            }
        }
        collect(Self.referenceDefinition) { match in
            add(match.range(at: 1), .linkText)
            add(match.range(at: 2), .linkDestination)
        }

        // Inline spans.
        collect(Self.strong) { add($0.range, .strong) }
        collect(Self.emphasis) { add($0.range, .emphasis) }
        collect(Self.strikethrough) { add($0.range, .strikethrough) }
        collect(Self.highlight) { add($0.range, .highlight) }
        collect(Self.htmlComment) { add($0.range, .html) }
        collect(Self.htmlTag) { add($0.range, .html) }
        collect(Self.link) { match in
            add(match.range(at: 1), .linkText)
            add(match.range(at: 2), .linkDestination)
        }
        collect(Self.autolink) { add($0.range, .linkDestination) }
        collect(Self.wikiLink) { add($0.range, .wikiLink) }
        collect(Self.footnoteReference) { add($0.range, .footnote) }
        collect(Self.escape) { add($0.range, .escape) }
        collect(Self.codeSpan) { add($0.range, .inlineCode) }
        return tokens
    }

    // MARK: Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals; a failure is a programming error caught by tests.
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static let frontMatterKey = regex(#"^[ \t]*([A-Za-z0-9_][A-Za-z0-9_ -]*):"#)
    private static let blockquote = regex(#"^[ \t]{0,3}(>(?:[ \t]?>)*)([^\n]*)$"#)
    private static let atxHeading = regex(#"^[ \t]{0,3}(#{1,6})(?:[ \t]+([^\n]*))?$"#)
    private static let setextUnderline = regex(#"^[ \t]{0,3}=+[ \t]*$"#)
    private static let thematicBreak = regex(#"^[ \t]{0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    private static let listMarker = regex(#"^[ \t]*(?:>[ \t]?)*([-*+]|\d{1,9}[.)])[ \t]+(\[[ xX]\](?=[ \t]|$))?"#)
    private static let tableDelimiterRow = regex(#"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*$"#)
    private static let tableRow = regex(#"^[ \t]{0,3}\|[^\n]*$"#)
    private static let referenceDefinition = regex(#"^[ \t]{0,3}(\[[^\]\n^]+\]):[ \t]*(\S+)"#)
    private static let strong = regex(#"(\*\*|__)(?=\S)[^\n]*?(?<=\S)\1"#)
    private static let emphasis = regex(#"(?<![*\w\\])\*(?=[^\s*])[^*\n]*?(?<=[^\s*\\])\*(?![*\w])|(?<![_\w\\])_(?=[^\s_])[^_\n]*?(?<=[^\s_\\])_(?![_\w])"#)
    private static let strikethrough = regex(#"~~(?=\S)[^\n]*?(?<=\S)~~"#)
    private static let highlight = regex(#"==(?=[^\s=])[^\n]*?(?<=[^\s=])=="#)
    private static let htmlComment = regex(#"<!--[^\n]*?-->"#)
    private static let htmlTag = regex(#"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>\n]*)?/?>"#)
    private static let link = regex(#"!?(\[[^\]\n]*\])(\([^)\n]*\)|\[[^\]\n]*\])"#)
    private static let autolink = regex(#"<(?:https?|mailto):[^>\s]+>|https?://[^\s<>()\]]+[^\s<>()\].,;:!?'"]"#)
    private static let wikiLink = regex(#"\[\[[^\]\n]+\]\]"#)
    private static let footnoteReference = regex(#"\[\^[^\]\n]+\]:?"#)
    private static let escape = regex(#"\\[!-/:-@\[-`{-~]"#)
    private static let codeSpan = regex(#"(?<!`)(`+)(?!`)[^\n]*?(?<!`)\1(?!`)"#)
}
