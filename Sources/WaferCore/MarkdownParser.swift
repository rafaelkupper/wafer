import Foundation
import Markdown

public final class MarkdownParser {
    public init() {}

    public func parse(source: String, baseURL: URL?) -> MarkdownDocument {
        let parsedSource = Self.sourceBySplittingFrontMatter(from: source)
        let footnoteSource = Self.sourceByExtractingFootnotes(from: parsedSource.body)
        let ast = Document(parsing: footnoteSource.body, options: [.parseBlockDirectives, .parseSymbolLinks])
        // AST line N (1-based) came from source line sourceLineMap[N - 1].
        let sourceLineMap = footnoteSource.lineOrigins.map { $0 + parsedSource.bodyLineOffset + 1 }
        return MarkdownDocument(
            source: source,
            baseURL: baseURL,
            ast: ast,
            fingerprint: FileFingerprint.sha256Hex(for: source),
            frontMatter: parsedSource.frontMatter,
            footnotes: footnoteSource.footnotes,
            sourceLineMap: sourceLineMap
        )
    }

    private static func sourceBySplittingFrontMatter(
        from source: String
    ) -> (frontMatter: String?, body: String, bodyLineOffset: Int) {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first == "---" else {
            return (nil, source, 0)
        }

        for index in lines.indices.dropFirst() {
            guard lines[index] == "---" || lines[index] == "..." else {
                continue
            }

            let frontMatter = lines[lines.index(after: lines.startIndex)..<index].joined(separator: "\n")
            let bodyStart = lines.index(after: index)
            let body = bodyStart < lines.endIndex ? lines[bodyStart...].joined(separator: "\n") : ""
            return (frontMatter, body, bodyStart)
        }

        return (nil, source, 0)
    }

    private static func sourceByExtractingFootnotes(
        from source: String
    ) -> (body: String, footnotes: [FootnoteDefinition], lineOrigins: [Int]) {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var bodyLines: [String] = []
        var lineOrigins: [Int] = []
        var footnotes: [FootnoteDefinition] = []
        var seenLabels = Set<String>()
        var fence: MarkdownFence?
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if fence == nil, let definitionStart = footnoteDefinitionStart(in: line) {
                bodyLines.append("")
                lineOrigins.append(index)
                var contentLines = [definitionStart.initialContent]
                index += 1

                while index < lines.count {
                    let continuationLine = lines[index]
                    if continuationLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        guard index + 1 < lines.count, footnoteContinuationContent(in: lines[index + 1]) != nil else {
                            break
                        }
                        contentLines.append("")
                        index += 1
                        continue
                    }
                    guard let continuation = footnoteContinuationContent(in: continuationLine) else {
                        break
                    }
                    contentLines.append(continuation)
                    index += 1
                }

                let normalizedLabel = MarkdownFootnoteSupport.normalizedLabel(definitionStart.label)
                if seenLabels.insert(normalizedLabel).inserted {
                    footnotes.append(FootnoteDefinition(
                        label: definitionStart.label,
                        content: contentLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    ))
                }
                continue
            }

            bodyLines.append(line)
            lineOrigins.append(index)
            fence = updatedFence(from: line, current: fence)
            index += 1
        }

        return (bodyLines.joined(separator: "\n"), footnotes, lineOrigins)
    }

    private static func footnoteDefinitionStart(in line: String) -> (label: String, initialContent: String)? {
        let leadingSpaces = line.prefix { $0 == " " }.count
        guard leadingSpaces <= 3 else {
            return nil
        }

        let start = line.index(line.startIndex, offsetBy: leadingSpaces)
        guard line[start...].hasPrefix("[^") else {
            return nil
        }

        let labelStart = line.index(start, offsetBy: 2)
        guard
            let closingBracket = line[labelStart...].firstIndex(of: "]"),
            line.index(after: closingBracket) < line.endIndex,
            line[line.index(after: closingBracket)] == ":"
        else {
            return nil
        }

        let label = String(line[labelStart..<closingBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            return nil
        }

        let contentStart = line.index(closingBracket, offsetBy: 2)
        let content = String(line[contentStart...]).trimmingLeadingSpacesAndTabs
        return (label, content)
    }

    private static func footnoteContinuationContent(in line: String) -> String? {
        if line.first == "\t" {
            return String(line.dropFirst())
        }

        let leadingSpaces = line.prefix { $0 == " " }.count
        guard leadingSpaces >= 4 else {
            return nil
        }

        let contentStart = line.index(line.startIndex, offsetBy: 4)
        return String(line[contentStart...])
    }

    private static func updatedFence(from line: String, current: MarkdownFence?) -> MarkdownFence? {
        let leadingSpaces = line.prefix { $0 == " " }.count
        guard leadingSpaces <= 3 else {
            return current
        }

        let contentStart = line.index(line.startIndex, offsetBy: leadingSpaces)
        guard contentStart < line.endIndex else {
            return current
        }

        let marker = line[contentStart]
        guard marker == "`" || marker == "~" else {
            return current
        }

        var markerEnd = contentStart
        while markerEnd < line.endIndex, line[markerEnd] == marker {
            markerEnd = line.index(after: markerEnd)
        }
        let markerCount = line.distance(from: contentStart, to: markerEnd)
        guard markerCount >= 3 else {
            return current
        }

        if let current {
            guard current.marker == marker, markerCount >= current.count else {
                return current
            }
            let trailing = line[markerEnd...]
            return trailing.allSatisfy(\.isWhitespace) ? nil : current
        }

        return MarkdownFence(marker: marker, count: markerCount)
    }
}

private struct MarkdownFence {
    let marker: Character
    let count: Int
}

private extension String {
    var trimmingLeadingSpacesAndTabs: String {
        String(drop { $0 == " " || $0 == "\t" })
    }
}
