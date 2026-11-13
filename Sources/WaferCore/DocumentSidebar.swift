import Foundation
import Markdown

public struct DocumentSidebarEntry: Equatable, Sendable {
    public let fileURL: URL
    public let displayTitle: String
    public let previewText: String
    public let isCurrent: Bool
    public let isAvailable: Bool
    public let needsSummary: Bool

    public init(
        fileURL: URL,
        displayTitle: String,
        previewText: String,
        isCurrent: Bool,
        isAvailable: Bool,
        needsSummary: Bool = false
    ) {
        self.fileURL = fileURL
        self.displayTitle = displayTitle
        self.previewText = previewText
        self.isCurrent = isCurrent
        self.isAvailable = isAvailable
        self.needsSummary = needsSummary
    }
}

public struct DocumentOutlineItem: Equatable, Sendable {
    public let title: String
    public let level: Int
    public let anchorID: String

    public init(title: String, level: Int, anchorID: String) {
        self.title = title
        self.level = level
        self.anchorID = anchorID
    }
}

public enum DocumentSidebarDataBuilder {
    static func sidebarEntries(
        from document: MarkdownDocument,
        assetResolver: AssetResolver,
        parser: MarkdownParser = MarkdownParser(),
        loadLinkedFiles: Bool = true
    ) -> [DocumentSidebarEntry] {
        guard let currentFileURL = normalizedCurrentFileURL(for: document) else {
            return []
        }

        var candidateURLs = [currentFileURL]
        var seen = Set([FileIdentity.identity(for: currentFileURL)])
        let linkedURLs = MarkdownLinkCollector.collect(from: document, assetResolver: assetResolver)

        for linkedURL in linkedURLs {
            let normalizedURL = FileIdentity.normalized(linkedURL)
            let normalizedIdentity = FileIdentity.identity(for: normalizedURL)
            if seen.insert(normalizedIdentity).inserted {
                candidateURLs.append(normalizedURL)
            }
        }

        let currentSummary = DocumentFileSummary(
            displayTitle: documentDisplayTitle(for: document, fallbackURL: currentFileURL),
            previewText: documentPreviewText(for: document)
        )

        let entries = candidateURLs.map { fileURL in
            if fileURL == currentFileURL {
                return DocumentSidebarEntry(
                    fileURL: fileURL,
                    displayTitle: currentSummary.displayTitle,
                    previewText: currentSummary.previewText,
                    isCurrent: true,
                    isAvailable: true
                )
            }

            if loadLinkedFiles { return summary(for: fileURL, parser: parser) }
            return DocumentSidebarEntry(
                fileURL: fileURL,
                displayTitle: fileURL.deletingPathExtension().lastPathComponent,
                previewText: "",
                isCurrent: false,
                isAvailable: true,
                needsSummary: true
            )
        }

        return entries.sorted(by: sidebarEntryOrder(lhs:rhs:))
    }

    /// Summaries are intentionally limited to the beginning of a linked note.
    public static func summary(for fileURL: URL, parser: MarkdownParser = MarkdownParser()) -> DocumentSidebarEntry {
        guard let prefix = try? BoundedFileReader.prefix(from: fileURL, maximumByteCount: 256 * 1024),
              let source = MarkdownSourceDecoding.decodePrefix(prefix.data, truncated: prefix.truncated) else {
            return DocumentSidebarEntry(fileURL: fileURL,
                displayTitle: fileURL.deletingPathExtension().lastPathComponent,
                previewText: "Unavailable", isCurrent: false, isAvailable: false)
        }
        let document = parser.parse(source: source, baseURL: fileURL)
        return DocumentSidebarEntry(fileURL: fileURL,
            displayTitle: documentDisplayTitle(for: document, fallbackURL: fileURL),
            previewText: documentPreviewText(for: document), isCurrent: false, isAvailable: true)
    }

    static func outlineItems(from document: MarkdownDocument) -> [DocumentOutlineItem] {
        HeadingOutlineCollector.collect(from: document)
    }

    private static func normalizedCurrentFileURL(for document: MarkdownDocument) -> URL? {
        guard let baseURL = document.baseURL, baseURL.isFileURL else {
            return nil
        }

        return FileIdentity.normalized(baseURL)
    }

    private static func sidebarEntryOrder(lhs: DocumentSidebarEntry, rhs: DocumentSidebarEntry) -> Bool {
        let titleComparison = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        let pathComparison = lhs.fileURL.lastPathComponent.localizedCaseInsensitiveCompare(rhs.fileURL.lastPathComponent)
        if pathComparison != .orderedSame {
            return pathComparison == .orderedAscending
        }

        return lhs.fileURL.path.localizedStandardCompare(rhs.fileURL.path) == .orderedAscending
    }

    static func documentDisplayTitle(for document: MarkdownDocument, fallbackURL: URL) -> String {
        if let headingTitle = FirstHeadingTitleExtractor.extract(from: document), !headingTitle.isEmpty {
            return headingTitle
        }

        if let frontMatterTitle = frontMatterTitle(for: document), !frontMatterTitle.isEmpty {
            return frontMatterTitle
        }

        return fallbackURL.deletingPathExtension().lastPathComponent
    }

    static func frontMatterTitle(for document: MarkdownDocument) -> String? {
        guard let frontMatter = document.frontMatter else {
            return nil
        }

        for line in frontMatter.components(separatedBy: .newlines) {
            guard line.first?.isWhitespace != true, let separator = line.firstIndex(of: ":") else {
                continue
            }

            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.compare("title", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else {
                continue
            }

            let valueStart = line.index(after: separator)
            return line[valueStart...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingMatchingQuotes
        }

        return nil
    }

    private static func documentPreviewText(for document: MarkdownDocument) -> String {
        DocumentPreviewExtractor.extract(from: document)
    }

    static func decodedSource(from data: Data) -> String? {
        MarkdownSourceDecoding.decode(data)
    }
}

private struct DocumentFileSummary {
    let displayTitle: String
    let previewText: String
}

private struct MarkdownLinkCollector: MarkupVisitor {
    typealias Result = [URL]

    let baseURL: URL?
    let assetResolver: AssetResolver

    static func collect(from document: MarkdownDocument, assetResolver: AssetResolver) -> [URL] {
        var collector = MarkdownLinkCollector(baseURL: document.baseURL, assetResolver: assetResolver)
        return collector.visit(document.ast)
    }

    mutating func visit(_ markup: Markup) -> [URL] {
        markup.accept(&self)
    }

    mutating func defaultVisit(_ markup: Markup) -> [URL] {
        markup.children.flatMap { visit($0) }
    }

    mutating func visitLink(_ link: Link) -> [URL] {
        guard
            let destination = link.destination,
            case .markdownFile(let url) = assetResolver.linkTarget(for: destination, relativeTo: baseURL)
        else {
            return defaultVisit(link)
        }

        return [url] + defaultVisit(link)
    }
}

private struct FirstHeadingTitleExtractor: MarkupVisitor {
    typealias Result = String?

    private let knownFootnoteLabels: Set<String>

    static func extract(from document: MarkdownDocument) -> String? {
        var extractor = FirstHeadingTitleExtractor(knownFootnoteLabels: Set(MarkdownFootnoteSupport.definitionMap(from: document.footnotes).keys))
        return extractor.visit(document.ast)?.collapsingWhitespace
    }

    mutating func visit(_ markup: Markup) -> String? {
        markup.accept(&self)
    }

    mutating func defaultVisit(_ markup: Markup) -> String? {
        for child in markup.children {
            if let title = visit(child), !title.isEmpty {
                return title
            }
        }
        return nil
    }

    mutating func visitHeading(_ heading: Heading) -> String? {
        guard heading.level == 1 else {
            return nil
        }

        return MarkdownSemanticSupport
            .strippedHTMLText(from: heading.plainText)
            .strippingKnownFootnoteReferences(knownLabels: knownFootnoteLabels)
    }
}

private struct DocumentPreviewExtractor: MarkupVisitor {
    typealias Result = String?

    private let knownFootnoteLabels: Set<String>

    static func extract(from document: MarkdownDocument) -> String {
        var extractor = DocumentPreviewExtractor(knownFootnoteLabels: Set(MarkdownFootnoteSupport.definitionMap(from: document.footnotes).keys))
        return extractor.visit(document.ast)?.previewSnippet ?? ""
    }

    mutating func visit(_ markup: Markup) -> String? {
        markup.accept(&self)
    }

    mutating func defaultVisit(_ markup: Markup) -> String? {
        for child in markup.children {
            if let preview = visit(child), !preview.isEmpty {
                return preview
            }
        }
        return nil
    }

    mutating func visitHeading(_ heading: Heading) -> String? {
        nil
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String? {
        stripFootnoteReferences(from: paragraph.plainText).collapsingWhitespace
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String? {
        if let alert = MarkdownSemanticSupport.gitHubAlert(for: blockQuote) {
            let body = MarkdownSemanticSupport.gitHubAlertBodyPlainText(from: blockQuote, alert: alert)
            return stripFootnoteReferences(from: body.isEmpty ? alert.definition.label : "\(alert.definition.label) \(body)").collapsingWhitespace
        }

        return stripFootnoteReferences(from: blockQuote.plainText).collapsingWhitespace
    }

    mutating func visitListItem(_ listItem: ListItem) -> String? {
        stripFootnoteReferences(from: listItem.plainText).collapsingWhitespace.strippingTaskListPrefix
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String? {
        codeBlock.code.collapsingWhitespace
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String? {
        MarkdownSemanticSupport.strippedHTMLText(from: html.format()).collapsingWhitespace
    }

    mutating func visitBlockDirective(_ blockDirective: BlockDirective) -> String? {
        if let callout = MarkdownSemanticSupport.calloutDefinition(for: blockDirective) {
            let body = blockDirective.children
                .map(\.plainText)
                .map(stripFootnoteReferences)
                .map(\.collapsingWhitespace)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            return stripFootnoteReferences(from: body.isEmpty ? callout.label : "\(callout.label) \(body)").collapsingWhitespace
        }

        return blockDirective.format().collapsingWhitespace
    }

    private func stripFootnoteReferences(from text: String) -> String {
        text.strippingKnownFootnoteReferences(knownLabels: knownFootnoteLabels)
    }
}

private struct HeadingOutlineCollector: MarkupVisitor {
    typealias Result = [DocumentOutlineItem]

    private let knownFootnoteLabels: Set<String>
    private var slugger = HeadingAnchorSlugger()

    static func collect(from document: MarkdownDocument) -> [DocumentOutlineItem] {
        var collector = HeadingOutlineCollector(knownFootnoteLabels: Set(MarkdownFootnoteSupport.definitionMap(from: document.footnotes).keys))
        return collector.visit(document.ast)
    }

    mutating func visit(_ markup: Markup) -> [DocumentOutlineItem] {
        markup.accept(&self)
    }

    mutating func defaultVisit(_ markup: Markup) -> [DocumentOutlineItem] {
        markup.children.flatMap { visit($0) }
    }

    mutating func visitHeading(_ heading: Heading) -> [DocumentOutlineItem] {
        let title = MarkdownSemanticSupport
            .strippedHTMLText(from: heading.plainText)
            .strippingKnownFootnoteReferences(knownLabels: knownFootnoteLabels)
            .collapsingWhitespace
        guard !title.isEmpty else {
            return []
        }

        return [
            DocumentOutlineItem(
                title: title,
                level: heading.level,
                anchorID: slugger.slug(for: title)
            )
        ]
    }
}

struct HeadingAnchorSlugger {
    private var primaryCounts: [String: Int] = [:]
    private var gitHubCounts: [String: Int] = [:]
    private var emittedPrimaryIDs = Set<String>()
    private var emittedAliasIDs = Set<String>()
    private let reservedPrimaryIDs: Set<String>

    init(reservedPrimaryIDs: Set<String> = []) {
        self.reservedPrimaryIDs = reservedPrimaryIDs
    }

    mutating func slug(for title: String) -> String {
        let slug = primarySlug(for: title)
        emittedPrimaryIDs.insert(slug)
        return slug
    }

    mutating func slugs(for title: String) -> HeadingAnchorSlugs {
        let primary = primarySlug(for: title)
        emittedPrimaryIDs.insert(primary)

        guard let alias = gitHubSlug(for: title),
              alias != primary,
              !reservedPrimaryIDs.contains(alias),
              !emittedPrimaryIDs.contains(alias),
              !emittedAliasIDs.contains(alias) else {
            return HeadingAnchorSlugs(primary: primary, gitHubAlias: nil)
        }

        emittedAliasIDs.insert(alias)
        return HeadingAnchorSlugs(primary: primary, gitHubAlias: alias)
    }

    private mutating func primarySlug(for title: String) -> String {
        let base = title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = base.isEmpty ? "section" : base
        var count = (primaryCounts[stem] ?? 0) + 1
        var candidate = count == 1 ? stem : "\(stem)-\(count)"
        while emittedPrimaryIDs.contains(candidate) {
            count += 1
            candidate = "\(stem)-\(count)"
        }
        primaryCounts[stem] = count
        return candidate
    }

    private mutating func gitHubSlug(for title: String) -> String? {
        let base = title
            .lowercased()
            .map { character -> String in
                if character.isWhitespace {
                    return "-"
                }
                if character.isGitHubSlugCharacter {
                    return String(character)
                }
                return ""
            }
            .joined()
        guard !base.isEmpty else {
            return nil
        }

        let count = gitHubCounts[base] ?? 0
        gitHubCounts[base] = count + 1
        if count == 0 {
            return base
        }
        return "\(base)-\(count)"
    }
}

struct HeadingAnchorSlugs: Equatable {
    let primary: String
    let gitHubAlias: String?
}

private extension String {
    var trimmingMatchingQuotes: String {
        guard count >= 2 else {
            return self
        }

        let quotePairs: [(Character, Character)] = [("\"", "\""), ("'", "'")]
        for (opening, closing) in quotePairs where first == opening && last == closing {
            return String(dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return self
    }

    var previewSnippet: String {
        let preview = collapsingWhitespace
        guard preview.count > 140 else {
            return preview
        }

        let index = preview.index(preview.startIndex, offsetBy: 140)
        return preview[..<index].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

}

private extension Character {
    var isGitHubSlugCharacter: Bool {
        isLetter || isNumber || self == "-" || self == "_"
    }
}
