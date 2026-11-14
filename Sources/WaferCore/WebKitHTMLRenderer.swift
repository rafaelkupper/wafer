import CoreGraphics
import Foundation
import Markdown

public enum RenderTarget: Sendable {
    case reader
    case preview
}

public final class WebKitHTMLRenderer {
    private let assetResolver: AssetResolver
    private let palette: ReaderThemePalette
    private let target: RenderTarget
    private let wikiLinkIndex: WikiLinkIndex?
    private let annotatesSourceLines: Bool
    private let allowsPreviewLocalImages: Bool
    private let codeSyntaxHighlighter = CodeSyntaxHighlighter()

    /// `annotatesSourceLines` adds `data-source-line` attributes to blocks for
    /// the edit-mode live preview and returns the body HTML separately so the
    /// reader can patch it in place. Reading, export, and Quick Look leave it off.
    public init(
        assetResolver: AssetResolver = AssetResolver(),
        palette: ReaderThemePalette = .dark,
        target: RenderTarget = .reader,
        wikiLinkIndex: WikiLinkIndex? = nil,
        annotatesSourceLines: Bool = false,
        allowsPreviewLocalImages: Bool = true
    ) {
        self.allowsPreviewLocalImages = allowsPreviewLocalImages
        self.assetResolver = assetResolver
        self.palette = palette
        self.target = target
        // Quick Look previews always render the unresolved styling.
        self.wikiLinkIndex = target == .reader ? wikiLinkIndex : nil
        self.annotatesSourceLines = annotatesSourceLines && target == .reader
    }

    public func render(document: MarkdownDocument) -> WebKitRenderOutput {
        return render(document: document, metadata: metadata(for: document))
    }

    public func metadata(for document: MarkdownDocument) -> DocumentRenderMetadata {
        DocumentRenderMetadata(
            statistics: target == .reader ? RenderedTextDocumentStatistics.statistics(from: document) : .zero,
            sidebarEntries: target == .reader ? DocumentSidebarDataBuilder.sidebarEntries(
                from: document, assetResolver: assetResolver, loadLinkedFiles: false) : [],
            outlineItems: DocumentSidebarDataBuilder.outlineItems(from: document)
        )
    }

    public func render(document: MarkdownDocument, metadata: DocumentRenderMetadata) -> WebKitRenderOutput {
        let statistics = metadata.statistics
        let sidebarEntries = metadata.sidebarEntries
        let outlineItems = metadata.outlineItems
        var visitor = WebKitHTMLRenderVisitor(
            baseURL: document.baseURL,
            assetResolver: assetResolver,
            codeSyntaxHighlighter: codeSyntaxHighlighter,
            footnotes: document.footnotes,
            reservedHeadingAnchorIDs: Set(outlineItems.map(\.anchorID)),
            target: target,
            wikiLinkIndex: wikiLinkIndex,
            sourceLineMap: annotatesSourceLines ? document.sourceLineMap : nil,
            allowsPreviewLocalImages: allowsPreviewLocalImages
        )
        var frontMatterHTML = visitor.renderFrontMatter(document.frontMatter)
        if annotatesSourceLines, !frontMatterHTML.isEmpty {
            frontMatterHTML = WebKitHTMLRenderVisitor.addingSourceLine(1, toFirstElementIn: frontMatterHTML)
        }
        let renderedBody = visitor.visit(document.ast)
        let footnotes = visitor.renderFootnotesSection()
        let body = frontMatterHTML + renderedBody + footnotes + visitor.finishRawHTML()
        let cspMetaTag: String
        let katexStyleSheet: String
        let rendererScripts: String
        if target == .reader {
            let scriptNonce = Self.scriptNonce()
            let hasScriptedRenderers = visitor.hasMermaidDiagrams || visitor.hasMathDisplays
            let csp = Self.contentSecurityPolicy(
                allowsPageScripts: hasScriptedRenderers,
                scriptNonce: scriptNonce
            )
            cspMetaTag = "  <meta http-equiv=\"Content-Security-Policy\" content=\"\(csp.escapedHTMLAttribute)\">"
            katexStyleSheet = visitor.hasMathDisplays
                ? "\n\(Self.katexStyleSheet ?? "")"
                : ""
            rendererScripts = hasScriptedRenderers
                ? Self.rendererScripts(
                    nonce: scriptNonce,
                    palette: palette,
                    includesMermaid: visitor.hasMermaidDiagrams,
                    includesMath: visitor.hasMathDisplays
                )
                : ""
        } else {
            cspMetaTag = ""
            katexStyleSheet = ""
            rendererScripts = ""
        }
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
        \(cspMetaTag)
          <style>
          \(ReaderTheme.styleSheet(for: palette))\(katexStyleSheet)
          </style>
        </head>
        <body>
          <main id="write">
          \(body)
          </main>
          \(rendererScripts)
        </body>
        </html>
        """

        return WebKitRenderOutput(
            html: html,
            baseURL: document.baseURL?.deletingLastPathComponent(),
            statistics: statistics,
            sidebarEntries: sidebarEntries,
            outlineItems: outlineItems,
            waitsForContentReady: target == .reader && (visitor.hasMermaidDiagrams || visitor.hasMathDisplays),
            previewAttachments: visitor.previewAttachments,
            hasWikiLinks: visitor.hasWikiLinks,
            bodyHTML: target == .reader ? body : nil,
            hasMermaidDiagrams: visitor.hasMermaidDiagrams,
            hasMathDisplays: visitor.hasMathDisplays
        )
    }
}

private struct WebKitHTMLRenderVisitor: MarkupVisitor {
    typealias Result = String

    let baseURL: URL?
    let assetResolver: AssetResolver
    let codeSyntaxHighlighter: CodeSyntaxHighlighter
    let target: RenderTarget
    let wikiLinkIndex: WikiLinkIndex?
    private(set) var hasWikiLinks = false
    private let footnoteDefinitionsByLabel: [String: FootnoteDefinition]
    private let previewAttachmentStore = PreviewAttachmentStore()
    private let allowsPreviewLocalImages: Bool
    private var htmlState = HTMLSanitizer.State()
    private var headingSlugger: HeadingAnchorSlugger
    private var inTableHead = false
    private var currentTableColumn = 0
    private var currentTableColumnAlignments: [Table.ColumnAlignment?] = []
    private var mermaidDiagramCount = 0
    private var mathDisplayCount = 0
    private var isInsideLink = false
    private var isRenderingFootnoteDefinition = false
    private let sourceLineMap: [Int]?
    private var footnoteNumbersByLabel: [String: Int] = [:]
    private var renderedFootnotes: [FootnoteDefinition] = []
    private var referencedFootnoteNumbers = Set<Int>()

    var hasMermaidDiagrams: Bool {
        mermaidDiagramCount > 0
    }

    var hasMathDisplays: Bool {
        mathDisplayCount > 0
    }

    var previewAttachments: [String: URL] {
        previewAttachmentStore.attachments
    }

    init(
        baseURL: URL?,
        assetResolver: AssetResolver,
        codeSyntaxHighlighter: CodeSyntaxHighlighter,
        footnotes: [FootnoteDefinition],
        reservedHeadingAnchorIDs: Set<String>,
        target: RenderTarget,
        wikiLinkIndex: WikiLinkIndex? = nil,
        sourceLineMap: [Int]? = nil,
        allowsPreviewLocalImages: Bool = true
    ) {
        self.allowsPreviewLocalImages = allowsPreviewLocalImages
        self.sourceLineMap = sourceLineMap
        self.baseURL = baseURL
        self.assetResolver = assetResolver
        self.codeSyntaxHighlighter = codeSyntaxHighlighter
        self.footnoteDefinitionsByLabel = MarkdownFootnoteSupport.definitionMap(from: footnotes)
        self.headingSlugger = HeadingAnchorSlugger(reservedPrimaryIDs: reservedHeadingAnchorIDs)
        self.target = target
        self.wikiLinkIndex = wikiLinkIndex
    }

    private var readAccessDirectoryURL: URL? {
        guard let baseURL else {
            return nil
        }

        guard baseURL.isFileURL else {
            return baseURL
        }

        return baseURL.hasDirectoryPath ? baseURL : baseURL.deletingLastPathComponent()
    }

    private var htmlSanitizer: HTMLSanitizer {
        HTMLSanitizer(policy: HTMLSanitizerPolicy(
            resolveImageSource: { rawSource in
                htmlImageSource(for: rawSource)
            },
            resolveLinkHref: { rawHref in
                htmlLinkHref(for: rawHref)
            },
            allowsSourceElements: target == .reader
        ))
    }

    private mutating func sanitizeRawHTML(_ source: String) -> String {
        let sanitizer = htmlSanitizer
        return sanitizer.sanitize(source, state: &htmlState)
    }

    mutating func finishRawHTML() -> String { htmlState.finish() }

    mutating func visit(_ markup: Markup) -> String {
        markup.accept(&self)
    }

    func renderFrontMatter(_ frontMatter: String?) -> String {
        guard let frontMatter else {
            return ""
        }

        let rows = frontMatterTableRows(from: frontMatter)
        return """
        <details class="md-front-matter">
        <summary>Document metadata</summary>
        <table>
        <tbody>\(rows)</tbody>
        </table>
        </details>
        """
    }

    mutating func renderFootnotesSection() -> String {
        guard !renderedFootnotes.isEmpty else {
            return ""
        }

        let previousIsRenderingFootnoteDefinition = isRenderingFootnoteDefinition
        isRenderingFootnoteDefinition = true
        defer {
            isRenderingFootnoteDefinition = previousIsRenderingFootnoteDefinition
        }

        let items = renderedFootnotes.enumerated().map { index, definition in
            let number = index + 1
            let ast = Document(parsing: definition.content, options: [.parseBlockDirectives, .parseSymbolLinks])
            let content = visit(ast)
            let backref = "<a class=\"md-footnote-backref\" href=\"\(sameDocumentFragmentHref(for: "fnref-\(number)").escapedHTMLAttribute)\" aria-label=\"Back to footnote reference\">↩</a>"
            return """
            <li id="fn-\(number)">
            \(footnoteBodyHTML(content: content, backref: backref))
            </li>
            """
        }.joined()

        return """
        <section class="md-footnotes" aria-label="Footnotes">
        <hr />
        <ol>
        \(items)
        </ol>
        </section>
        """
    }

    mutating func defaultVisit(_ markup: Markup) -> String {
        if markup is BlockMarkup {
            return "<p class=\"fallback-block\">\(markup.format().escapedHTML)</p>"
        }

        return descend(markup)
    }

    mutating func visitDocument(_ document: Document) -> String {
        guard sourceLineMap != nil, !isRenderingFootnoteDefinition else {
            return descend(document)
        }

        return document.children.map { child in
            annotatingSourceLine(of: child, in: visit(child))
        }.joined()
    }

    /// Edit-mode source line for a block in the main document, never for
    /// footnote definitions (they are parsed separately).
    private func sourceLine(of markup: Markup) -> Int? {
        guard
            let sourceLineMap,
            !isRenderingFootnoteDefinition,
            let astLine = markup.range?.lowerBound.line,
            astLine >= 1, astLine <= sourceLineMap.count
        else {
            return nil
        }

        return sourceLineMap[astLine - 1]
    }

    private func annotatingSourceLine(of markup: Markup, in html: String) -> String {
        guard let line = sourceLine(of: markup) else {
            return html
        }

        return Self.addingSourceLine(line, toFirstElementIn: html)
    }

    private func sourceLineAttribute(for markup: Markup) -> String {
        sourceLine(of: markup).map { " data-source-line=\"\($0)\"" } ?? ""
    }

    /// Inserts `data-source-line` into the first start tag when the HTML
    /// begins with an element; text, comments, and closing tags are left alone.
    static func addingSourceLine(_ line: Int, toFirstElementIn html: String) -> String {
        guard let open = html.firstIndex(where: { !$0.isWhitespace }), html[open] == "<" else {
            return html
        }

        let nameStart = html.index(after: open)
        guard nameStart < html.endIndex, html[nameStart].isLetter else {
            return html
        }

        guard let nameEnd = html[nameStart...].firstIndex(where: { $0.isWhitespace || $0 == ">" || $0 == "/" }) else {
            return html
        }

        var annotated = html
        annotated.insert(contentsOf: " data-source-line=\"\(line)\"", at: nameEnd)
        return annotated
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(descend(paragraph))</p>"
    }

    mutating func visitText(_ text: Text) -> String {
        guard !isInsideLink else {
            return text.string.escapedHTML
        }

        let textWithFootnotes = htmlByRenderingFootnoteReferences(in: text.string)
        if let textWithFootnotes {
            return textWithFootnotes
        }

        return htmlByRenderingInlineText(text.string)
    }

    private mutating func htmlByRenderingFootnoteReferences(in text: String) -> String? {
        guard !isRenderingFootnoteDefinition else {
            return nil
        }

        let references = MarkdownFootnoteSupport.references(in: text)
        let knownLabels = Set(footnoteDefinitionsByLabel.keys)
        guard references.contains(where: { knownLabels.contains($0.normalizedLabel) }) else {
            return nil
        }

        var output = ""
        var cursor = text.startIndex
        for reference in references {
            output += htmlByRenderingInlineText(String(text[cursor..<reference.range.lowerBound]))
            if let referenceHTML = footnoteReferenceHTML(for: reference.normalizedLabel) {
                output += referenceHTML
            } else {
                output += htmlByRenderingInlineText(String(text[reference.range]))
            }
            cursor = reference.range.upperBound
        }
        output += htmlByRenderingInlineText(String(text[cursor...]))
        return output
    }

    private mutating func footnoteReferenceHTML(for normalizedLabel: String) -> String? {
        guard let definition = footnoteDefinitionsByLabel[normalizedLabel] else {
            return nil
        }

        let number: Int
        if let existingNumber = footnoteNumbersByLabel[normalizedLabel] {
            number = existingNumber
        } else {
            number = renderedFootnotes.count + 1
            footnoteNumbersByLabel[normalizedLabel] = number
            renderedFootnotes.append(definition)
        }

        let idAttribute = referencedFootnoteNumbers.insert(number).inserted ? #" id="fnref-\#(number)""# : ""
        let href = sameDocumentFragmentHref(for: "fn-\(number)").escapedHTMLAttribute
        return "<sup class=\"md-footnote-ref\"><a href=\"\(href)\"\(idAttribute) aria-label=\"Footnote \(number)\">\(number)</a></sup>"
    }

    private mutating func htmlByRenderingInlineText(_ text: String) -> String {
        let wikiSpans = WikiLinkSyntax.spans(in: text)
        guard !wikiSpans.isEmpty else {
            return htmlByRenderingPlainInlineText(text)
        }

        hasWikiLinks = true
        var output = ""
        var cursor = text.startIndex
        for span in wikiSpans {
            output += htmlByRenderingPlainInlineText(String(text[cursor..<span.range.lowerBound]))
            output += wikiLinkHTML(for: span)
            cursor = span.range.upperBound
        }
        output += htmlByRenderingPlainInlineText(String(text[cursor...]))
        return output
    }

    private mutating func wikiLinkHTML(for span: WikiLinkSyntax.Span) -> String {
        if span.isEmbed, span.targetIsImage {
            return imageHTML(source: span.target, altText: span.displayText)
        }

        let headingAnchorID = span.heading.map { heading in
            var slugger = HeadingAnchorSlugger()
            return slugger.slug(for: heading)
        }

        // Same-document heading form: [[#Heading]].
        if span.target.isEmpty, let headingAnchorID {
            let href = sameDocumentFragmentHref(for: headingAnchorID)
            return "<a class=\"md-wikilink\" href=\"\(href.escapedHTMLAttribute)\">\(span.displayText.escapedHTML)</a>"
        }

        if
            !span.isEmbed,
            let resolvedURL = wikiLinkIndex?.resolve(span.target),
            let wikiURL = WikiLinkURL.url(for: resolvedURL, anchorID: headingAnchorID)
        {
            return "<a class=\"md-wikilink\" href=\"\(wikiURL.absoluteString.escapedHTMLAttribute)\">\(span.displayText.escapedHTML)</a>"
        }

        return "<span class=\"md-wikilink-unresolved\">\(span.displayText.escapedHTML)</span>"
    }

    private func htmlByRenderingPlainInlineText(_ text: String) -> String {
        let segments = Autolinker.segments(in: text)
        guard segments.count > 1 || segments.first != .plain(text) else {
            return MarkdownInlineCompatibility.htmlByRenderingTextDecorations(in: text)
        }

        return segments.map { segment in
            switch segment {
            case let .plain(text):
                return MarkdownInlineCompatibility.htmlByRenderingTextDecorations(in: text)
            case let .link(text, href):
                return anchorHTML(href: resolvedLinkHref(for: href), bodyHTML: text.escapedHTML)
            }
        }.joined()
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br />"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(descend(strong))</strong>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(descend(emphasis))</em>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(descend(strikethrough))</del>"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let title = MarkdownSemanticSupport
            .strippedHTMLText(from: heading.plainText)
            .strippingKnownFootnoteReferences(knownLabels: Set(footnoteDefinitionsByLabel.keys))
            .collapsingWhitespace
        let idAttribute: String
        let aliasHTML: String
        if title.isEmpty {
            idAttribute = ""
            aliasHTML = ""
        } else {
            let slugs = headingSlugger.slugs(for: title)
            idAttribute = " id=\"\(slugs.primary.escapedHTMLAttribute)\""
            if let gitHubAlias = slugs.gitHubAlias {
                aliasHTML = "<a id=\"\(gitHubAlias.escapedHTMLAttribute)\" class=\"md-anchor-alias\" aria-hidden=\"true\"></a>"
            } else {
                aliasHTML = ""
            }
        }
        return "<h\(heading.level)\(idAttribute)>\(aliasHTML)\(descend(heading))</h\(heading.level)>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(inlineCode.code.escapedHTML)</code>"
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) -> String {
        let destination = symbolLink.destination ?? ""
        return "<code class=\"md-symbol-link\">\(destination.escapedHTML)</code>"
    }

    mutating func visitInlineAttributes(_ attributes: InlineAttributes) -> String {
        let content = descend(attributes)
        guard let className = MarkdownSemanticSupport.inlineAttributeClassName(from: attributes) else {
            return content
        }

        return "<span class=\"\(className.escapedHTMLAttribute)\">\(content)</span>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let normalizedLanguage = codeBlock.language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let code = codeBlock.code.trimmingCharacters(in: .newlines)
        if target == .reader, isMermaidLanguage(normalizedLanguage), WebKitHTMLRenderer.canRenderMermaid {
            return renderMermaidDiagram(source: code)
        }
        if target == .reader, isMathLanguage(normalizedLanguage), WebKitHTMLRenderer.canRenderMath {
            return renderMathDisplay(source: code)
        }

        let languageClass = normalizedLanguage.isEmpty ? "" : " language-\(normalizedLanguage.escapedHTMLAttribute)"

        let highlighted = codeSyntaxHighlighter.highlightedHTML(
            code: code,
            language: codeBlock.language
        )
        let languageAttribute = normalizedLanguage.isEmpty ? "" : " lang=\"\(normalizedLanguage.escapedHTMLAttribute)\""
        return "<pre class=\"md-fences\"\(languageAttribute)><code class=\"cm-s-inner\(languageClass)\">\(highlighted)</code></pre>"
    }

    mutating func visitLink(_ link: Link) -> String {
        let previousIsInsideLink = isInsideLink
        isInsideLink = true
        let bodyHTML = descend(link)
        isInsideLink = previousIsInsideLink
        return anchorHTML(href: resolvedLinkHref(for: link.destination ?? ""), bodyHTML: bodyHTML)
    }

    mutating func visitImage(_ image: Image) -> String {
        imageHTML(source: image.source, altText: image.plainText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private mutating func imageHTML(source: String?, altText: String) -> String {
        guard
            let source,
            let url = assetResolver.imageURL(for: source, relativeTo: baseURL)
        else {
            return "<p class=\"fallback-block\">[Missing image]</p>"
        }

        if assetResolver.isRemoteImageURL(url) {
            if target == .preview {
                return remoteImagePlaceholder(altText: altText)
            }
            let sourceURL = WebKitAssetURLs.remote(for: url)
            return "<img src=\"\(sourceURL.escapedHTMLAttribute)\" alt=\"\(altText.escapedHTMLAttribute)\" loading=\"lazy\" />"
        }

        if target == .preview {
            guard allowsPreviewLocalImages else { return "<span class=\"md-image-placeholder\">[Local image omitted]</span>" }
            guard let sourceURL = previewAttachmentStore.cidSource(
                for: url,
                allowedRootDirectory: readAccessDirectoryURL
            ) else {
                return "<p class=\"fallback-block\">[Missing image]</p>"
            }
            return "<img src=\"\(sourceURL.escapedHTMLAttribute)\" alt=\"\(altText.escapedHTMLAttribute)\" />"
        }

        let sourceURL = WebKitAssetURLs.local(for: url)
        return "<img src=\"\(sourceURL.escapedHTMLAttribute)\" alt=\"\(altText.escapedHTMLAttribute)\" />"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        if let alert = MarkdownSemanticSupport.gitHubAlert(for: blockQuote) {
            return calloutHTML(
                for: alert.definition,
                bodyHTML: renderGitHubAlertBody(for: blockQuote, alert: alert)
            )
        }

        return "<blockquote>\(descend(blockQuote))</blockquote>"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        let containsTasks = unorderedList.children.contains { child in
            guard let listItem = child as? ListItem else {
                return false
            }
            return taskListState(for: listItem) != nil
        }

        let classAttribute = containsTasks ? " class=\"task-list\"" : ""
        return "<ul\(classAttribute)>\(descend(unorderedList))</ul>"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        let startAttribute = orderedList.startIndex == 1 ? "" : " start=\"\(orderedList.startIndex)\""
        return "<ol\(startAttribute)>\(descend(orderedList))</ol>"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        let content = flattenLeadingParagraphIfPresent(descend(listItem))

        let lineAttribute = sourceLineAttribute(for: listItem)
        if let taskState = taskListState(for: listItem) {
            let checkedAttribute = taskState ? " checked" : ""
            return "<li class=\"md-task-list-item\"\(lineAttribute)><input type=\"checkbox\" disabled\(checkedAttribute) />\(content)</li>"
        }

        return "<li\(lineAttribute)>\(content)</li>"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr />"
    }

    mutating func visitTable(_ table: Table) -> String {
        guard !table.isEmpty, table.maxColumnCount > 0 else {
            return "<p class=\"fallback-block\">\(table.format().escapedHTML)</p>"
        }

        let rows = tableTextRows(for: table)
        let columnWidths = tableColumnWidthPercentages(for: rows, columnCount: table.maxColumnCount)
        let columns = columnWidths.map { width in
            "<col style=\"width: \(width)%\">"
        }.joined()

        let previousAlignments = currentTableColumnAlignments
        let previousColumn = currentTableColumn
        let previousInHead = inTableHead

        currentTableColumnAlignments = normalizedTableColumnAlignments(for: table)
        currentTableColumn = 0
        inTableHead = false
        let content = descend(table)

        currentTableColumnAlignments = previousAlignments
        currentTableColumn = previousColumn
        inTableHead = previousInHead

        return """
        <table>
          <colgroup>\(columns)</colgroup>
          \(content)
        </table>
        """
    }

    mutating func visitTableHead(_ tableHead: Table.Head) -> String {
        let previousInHead = inTableHead
        let previousColumn = currentTableColumn
        inTableHead = true
        currentTableColumn = 0
        let content = descend(tableHead)
        inTableHead = previousInHead
        currentTableColumn = previousColumn
        return "<thead><tr>\(content)</tr></thead>"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) -> String {
        guard !tableBody.isEmpty else {
            return ""
        }

        return "<tbody>\(descend(tableBody))</tbody>"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) -> String {
        let previousColumn = currentTableColumn
        currentTableColumn = 0
        let content = descend(tableRow)
        currentTableColumn = previousColumn
        return "<tr\(sourceLineAttribute(for: tableRow))>\(content)</tr>"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) -> String {
        guard tableCell.colspan > 0, tableCell.rowspan > 0 else {
            currentTableColumn += 1
            return ""
        }

        let element = inTableHead ? "th" : "td"
        let colspan = max(Int(tableCell.colspan), 1)
        let rowspan = max(Int(tableCell.rowspan), 1)
        let columnIndex = currentTableColumn
        currentTableColumn += colspan

        var attributes = ""
        if columnIndex < currentTableColumnAlignments.count,
           let alignment = currentTableColumnAlignments[columnIndex] {
            attributes += " align=\"\(htmlAlignmentValue(for: alignment))\""
        }
        if rowspan > 1 {
            attributes += " rowspan=\"\(rowspan)\""
        }
        if colspan > 1 {
            attributes += " colspan=\"\(colspan)\""
        }

        return "<\(element)\(attributes)>\(descend(tableCell))</\(element)>"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        let source = html.format()
        let sanitized = sanitizeRawHTML(source)
        let trimmedSanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSanitized.isEmpty else {
            return ""
        }
        if sanitized.contains("<") {
            return sanitized
        }

        return "<p class=\"fallback-block\">\(trimmedSanitized)</p>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        let source = inlineHTML.format()
        let sanitized = sanitizeRawHTML(source)
        if !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sanitized
        }

        return MarkdownSemanticSupport.strippedHTMLText(from: source).escapedHTML
    }

    mutating func visitBlockDirective(_ blockDirective: BlockDirective) -> String {
        if let callout = MarkdownSemanticSupport.calloutDefinition(for: blockDirective) {
            let body = descend(blockDirective)
            return calloutHTML(for: callout, bodyHTML: body)
        }

        return "<p class=\"fallback-block\">\(blockDirective.format().escapedHTML)</p>"
    }

    private mutating func descend(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    private mutating func renderGitHubAlertBody(for blockQuote: BlockQuote, alert: MarkdownGitHubAlert) -> String {
        let blockChildren = Array(blockQuote.children)
        guard let firstParagraph = blockChildren.first as? Paragraph else {
            return ""
        }

        let paragraphChildren = Array(firstParagraph.children)
        let firstParagraphBody = paragraphChildren
            .dropFirst(alert.firstParagraphInlineDropCount)
            .map { visit($0) }
            .joined()
        var bodyParts: [String] = []
        if !firstParagraphBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bodyParts.append("<p>\(firstParagraphBody)</p>")
        }
        bodyParts.append(contentsOf: blockChildren.dropFirst().map { visit($0) })
        return bodyParts.joined()
    }

    private func calloutHTML(for callout: MarkdownCalloutDefinition, bodyHTML: String) -> String {
        let body = bodyHTML.isEmpty ? "" : "<div class=\"md-callout-body\">\(bodyHTML)</div>"
        return """
        <aside class="md-callout \(callout.kind.cssClassName)">
        <div class="md-callout-label">\(callout.label.escapedHTML)</div>\(body)
        </aside>
        """
    }

    private func frontMatterTableRows(from frontMatter: String) -> String {
        frontMatter
            .components(separatedBy: .newlines)
            .map { line in
                if let separator = frontMatterKeyValueSeparator(in: line) {
                    let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                    let valueStart = line.index(after: separator)
                    let value = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
                    return "<tr><th>\(key.escapedHTML)</th><td>\(value.escapedHTML)</td></tr>"
                }

                return "<tr><td colspan=\"2\"><code>\(line.escapedHTML)</code></td></tr>"
            }
            .joined()
    }

    private func frontMatterKeyValueSeparator(in line: String) -> String.Index? {
        guard line.first?.isWhitespace != true, let separator = line.firstIndex(of: ":") else {
            return nil
        }

        let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : separator
    }

    private func tableColumnWidthPercentages(for rows: [[String]], columnCount: Int) -> [CGFloat] {
        guard columnCount > 0 else {
            return []
        }

        var weights = Array(repeating: CGFloat(1), count: columnCount)
        for row in rows {
            for columnIndex in 0..<columnCount {
                let text = columnIndex < row.count ? row[columnIndex] : ""
                let characterCount = text.count
                let longestWordCount = text
                    .split(whereSeparator: \.isWhitespace)
                    .map(\.count)
                    .max() ?? 0
                let weight = CGFloat(min(max(characterCount + (longestWordCount / 2), 8), 36))
                weights[columnIndex] = max(weights[columnIndex], weight)
            }
        }

        if let widestColumnIndex = weights.indices.max(by: { weights[$0] < weights[$1] }) {
            weights[widestColumnIndex] *= 1.15
        }

        let minimums = Array(repeating: CGFloat(12), count: columnCount)
        let totalMinimum = minimums.reduce(0, +)
        guard totalMinimum < 100 else {
            return Array(repeating: 100 / CGFloat(columnCount), count: columnCount)
        }

        let normalizedWeights = zip(weights, minimums).map { max($0 - $1, 1) }
        let normalizedWeightTotal = normalizedWeights.reduce(0, +)
        let distributableWidth = 100 - totalMinimum

        return zip(minimums, normalizedWeights).map { minimum, weight in
            minimum + (distributableWidth * weight / normalizedWeightTotal)
        }
    }

    private func tableTextRows(for table: Table) -> [[String]] {
        var rows = [tableTextRow(for: table.head, columnCount: table.maxColumnCount)]
        rows.append(contentsOf: table.body.rows.map { tableTextRow(for: $0, columnCount: table.maxColumnCount) })
        return rows
    }

    private func tableTextRow(for row: some Markup, columnCount: Int) -> [String] {
        let cells = row.children.compactMap { $0 as? Table.Cell }
        var texts: [String] = []

        for cell in cells {
            if cell.colspan == 0 || cell.rowspan == 0 {
                texts.append("")
                continue
            }

            let colspan = max(Int(cell.colspan), 1)
            texts.append(cell.plainText.collapsingWhitespace)
            if colspan > 1 {
                texts.append(contentsOf: repeatElement("", count: colspan - 1))
            }
        }

        if texts.count < columnCount {
            texts.append(contentsOf: repeatElement("", count: columnCount - texts.count))
        } else if texts.count > columnCount {
            texts = Array(texts.prefix(columnCount))
        }

        return texts
    }

    private func normalizedTableColumnAlignments(for table: Table) -> [Table.ColumnAlignment?] {
        var alignments = table.columnAlignments
        if alignments.count < table.maxColumnCount {
            alignments.append(contentsOf: repeatElement(nil, count: table.maxColumnCount - alignments.count))
        } else if alignments.count > table.maxColumnCount {
            alignments = Array(alignments.prefix(table.maxColumnCount))
        }
        return alignments
    }

    private func htmlAlignmentValue(for alignment: Table.ColumnAlignment) -> String {
        switch alignment {
        case .left:
            return "left"
        case .center:
            return "center"
        case .right:
            return "right"
        }
    }

    private func isMermaidLanguage(_ language: String) -> Bool {
        switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mermaid", "mmd":
            return true
        default:
            return false
        }
    }

    private func isMathLanguage(_ language: String) -> Bool {
        language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "math"
    }

    private mutating func renderMermaidDiagram(source: String) -> String {
        mermaidDiagramCount += 1
        let diagramID = "wafer-mermaid-\(mermaidDiagramCount)"
        return """
        <figure class="md-mermaid-diagram" data-wafer-mermaid-id="\(diagramID)">
          <button type="button" class="md-mermaid-open" \(ExportSanitizer.chromeAttributeName)="\(ExportSanitizer.chromeAttributeValue)" aria-label="Open Mermaid diagram inspector" hidden>Open</button>
          <div class="md-mermaid-output" aria-label="Mermaid diagram"></div>
          <p class="md-mermaid-error" hidden></p>
          <pre class="md-mermaid-source" lang="mermaid"><code>\(source.escapedHTML)</code></pre>
        </figure>
        """
    }

    private mutating func renderMathDisplay(source: String) -> String {
        mathDisplayCount += 1
        let mathID = "wafer-math-\(mathDisplayCount)"
        return """
        <figure class="md-math-display" data-wafer-math-id="\(mathID)">
          <div class="md-math-output" aria-label="Rendered math"></div>
          <p class="md-math-error" hidden></p>
          <pre class="md-math-source" lang="math"><code>\(source.escapedHTML)</code></pre>
        </figure>
        """
    }

    private func taskListState(for listItem: ListItem) -> Bool? {
        switch listItem.checkbox {
        case .checked?:
            true
        case .unchecked?:
            false
        case nil:
            nil
        }
    }

    private func flattenLeadingParagraphIfPresent(_ html: String) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<p>"), let closingRange = trimmed.range(of: "</p>") else {
            return html
        }

        let paragraphStart = trimmed.index(trimmed.startIndex, offsetBy: 3)
        let firstParagraph = String(trimmed[paragraphStart..<closingRange.lowerBound])
        let remainder = trimmed[closingRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? firstParagraph : firstParagraph + remainder
    }

    private func resolvedHTMLURLString(for url: URL?) -> String? {
        guard let url else {
            return nil
        }

        guard url.isFileURL else {
            return url.absoluteString
        }

        guard
            let readAccessDirectoryURL,
            readAccessDirectoryURL.isFileURL,
            let relativePath = relativePath(from: readAccessDirectoryURL, to: url)
        else {
            return url.absoluteString
        }

        return relativePath
    }

    private func relativePath(from directoryURL: URL, to fileURL: URL) -> String? {
        let standardizedDirectoryURL = directoryURL.standardizedFileURL
        let standardizedFileURL = fileURL.standardizedFileURLPreservingFragment()

        let directoryPath = standardizedDirectoryURL.path
        let filePath = standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"

        guard filePath.hasPrefix(prefix) else {
            return nil
        }

        let relativePath = String(filePath.dropFirst(prefix.count))
        let encodedPath = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { component in
                String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
            }
            .joined(separator: "/")

        if let fragment = standardizedFileURL.decodedFragment {
            let encodedFragment = fragment.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? fragment
            return encodedPath + "#" + encodedFragment
        }

        return encodedPath
    }

    private func resolvedLinkHref(for destination: String) -> String? {
        guard LinkURLPolicy.allows(destination),
              let url = assetResolver.resolve(destination: destination, relativeTo: baseURL),
              LinkURLPolicy.allows(url) else { return nil }
        return resolvedHTMLURLString(for: url)
    }

    private func footnoteBodyHTML(content: String, backref: String) -> String {
        // Match GitHub: the back-reference sits inline at the end of the
        // definition's last paragraph. Appending it after the closing block
        // tag wraps it onto its own orphan line. It is joined WITHOUT a space
        // so there is no line-break opportunity before the arrow (the visual
        // gap comes from the .md-footnote-backref margin) — a full-width last
        // line wraps the arrow together with the final word, never alone.
        guard
            let closingRange = content.range(of: "</p>", options: .backwards),
            content[closingRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "\(content)\(backref)"
        }

        return content.replacingCharacters(in: closingRange, with: "\(backref)</p>")
    }

    private func sameDocumentFragmentHref(for fragment: String) -> String {
        // The reader page loads with the document's DIRECTORY as its base URL,
        // so a plain "#fragment" click resolves to the folder URL and opens it
        // in Finder instead of scrolling. Resolve fragments to
        // "File.md#fragment" like every markdown anchor. Quick Look previews
        // have no file base URL (and baseURL-less renders cannot resolve), so
        // both keep the plain fragment for native in-page scrolling.
        guard target == .reader, baseURL != nil else {
            return "#\(fragment)"
        }

        return resolvedLinkHref(for: "#\(fragment)") ?? "#\(fragment)"
    }

    private func anchorHTML(href: String?, bodyHTML: String) -> String {
        guard let href else { return bodyHTML }
        return "<a href=\"\(href.escapedHTMLAttribute)\">\(bodyHTML)</a>"
    }

    private func htmlImageSource(for rawSource: String) -> String? {
        guard let url = assetResolver.imageURL(for: rawSource, relativeTo: baseURL) else {
            return nil
        }

        if assetResolver.isRemoteImageURL(url) {
            guard target == .reader else {
                return nil
            }
            return WebKitAssetURLs.remote(for: url)
        }

        if target == .preview {
            guard allowsPreviewLocalImages else { return nil }
            return previewAttachmentStore.cidSource(
                for: url,
                allowedRootDirectory: readAccessDirectoryURL
            )
        }

        return WebKitAssetURLs.local(for: url)
    }

    private func remoteImagePlaceholder(altText: String) -> String {
        let suffix = altText.isEmpty ? "" : ": \(altText)"
        return "<span class=\"md-image-placeholder\">[Remote image omitted\(suffix.escapedHTML)]</span>"
    }

    private func htmlLinkHref(for rawHref: String) -> String? {
        resolvedLinkHref(for: rawHref)
    }
}
