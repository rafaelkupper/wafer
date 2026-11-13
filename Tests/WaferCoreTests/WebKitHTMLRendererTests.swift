import Foundation
import XCTest
@testable import WaferCore

final class WebKitHTMLRendererTests: XCTestCase {
    private let parser = MarkdownParser()

    func testRendererProducesHTMLForCommonMarkdownFeatures() {
        let baseURL = URL(fileURLWithPath: "/tmp/rendering/Showcase.md")
        let source = """
        # Title

        Paragraph with [link](https://example.com) and <kbd>Cmd</kbd> + <kbd>O</kbd>.

        > Quoted line

        - [x] done

        ```swift
        struct ReaderTheme {
            let readableWidth = 760
        }
        ```

        | Name | Value |
        | --- | --- |
        | One | 1 |

        ![Preview](App/Resources/Wafer-preview.png)

        ---

        <aside>raw html</aside>

        @Note {
        Hello
        }
        """

        let output = render(source, baseURL: baseURL)

        XCTAssertEqual(output.baseURL, baseURL.deletingLastPathComponent())
        XCTAssertGreaterThan(output.statistics.words, 0)
        XCTAssertGreaterThan(output.statistics.lines, 0)
        XCTAssertTrue(output.html.contains("<div id=\"write\">"))
        XCTAssertTrue(output.html.contains("--bg-color: #383E44;"))
        XCTAssertTrue(output.html.contains("--text-color: #BCC3CA;"))
        XCTAssertTrue(output.html.contains("--link-color: #D7DDE3;"))
        XCTAssertTrue(output.html.contains("--rule-color: #4C525A;"))
        XCTAssertTrue(output.html.contains("--code-block-bg: #2F3135;"))
        XCTAssertTrue(output.html.contains("font-family: \"Helvetica Neue\", Helvetica, Arial, \"Segoe UI Emoji\", \"SF Pro\", sans-serif;"))
        XCTAssertTrue(output.html.contains("font-family: \"Lucida Grande\", \"Corbel\", sans-serif;"))
        XCTAssertTrue(output.html.contains("font-family: Monaco, Consolas, \"Andale Mono\", \"DejaVu Sans Mono\", monospace;"))
        XCTAssertTrue(output.html.contains("max-width: 928px;"))
        XCTAssertTrue(output.html.contains("@media only screen and (min-width: 1400px)"))
        XCTAssertTrue(output.html.contains("line-height: 1.66rem;"))
        XCTAssertTrue(output.html.contains("padding: 11px 11px 11px 31px;"))
        XCTAssertTrue(output.html.contains(".cm-s-inner .cm-property {"))
        XCTAssertTrue(output.html.contains(".cm-s-inner .cm-atom {"))
        XCTAssertTrue(output.html.contains(".cm-s-inner .cm-variable-2 {"))
        XCTAssertTrue(output.html.contains("<h1 id=\"title\">Title</h1>"))
        XCTAssertTrue(output.html.contains("<blockquote>"))
        XCTAssertTrue(output.html.contains("border-left: solid 2px var(--rule-color);"))
        XCTAssertTrue(output.html.contains("class=\"task-list\""))
        XCTAssertTrue(output.html.contains("class=\"md-task-list-item\""))
        XCTAssertTrue(output.html.contains("type=\"checkbox\" disabled checked"))
        XCTAssertTrue(output.html.contains("<table>"))
        XCTAssertTrue(output.html.contains("<hr />"))
        XCTAssertTrue(output.html.contains("<kbd>Cmd</kbd>"))
        XCTAssertTrue(output.html.contains("border: 1px solid var(--kbd-border-color);"))
        XCTAssertTrue(output.html.contains("<pre class=\"md-fences\""))
        XCTAssertTrue(output.html.contains("class=\"cm-s-inner"))
        XCTAssertTrue(output.html.contains("href=\"https://example.com\""))
        XCTAssertTrue(output.html.contains("src=\"wafer-local://asset?path="))
        XCTAssertTrue(output.html.contains("Wafer-preview.png"))
        XCTAssertTrue(output.html.contains("raw html"))
        XCTAssertTrue(output.html.contains("class=\"md-callout md-callout-note\""))
        XCTAssertTrue(output.html.contains("<div class=\"md-callout-label\">Note</div>"))
        XCTAssertEqual(output.outlineItems.first?.anchorID, "title")
    }

    func testRendererInlinesDarkPaletteCSSVariables() {
        let output = render("# Theme")

        assertCSSVariable("--bg-color", equals: "#383E44", in: output.html)
        assertCSSVariable("--text-color", equals: "#BCC3CA", in: output.html)
        assertCSSVariable("--link-color", equals: "#D7DDE3", in: output.html)
        assertCSSVariable("--inline-code-bg", equals: "#30343A", in: output.html)
        assertCSSVariable("--kbd-shadow-color", equals: "rgba(0, 0, 0, 0.22)", in: output.html)
        assertCSSVariable("--callout-note-bg", equals: "rgba(125, 161, 188, 0.11)", in: output.html)
        assertCSSVariable("--mermaid-container-bg", equals: "rgba(47, 49, 53, 0.78)", in: output.html)
        assertCSSVariable("--diagram-inspector-backdrop", equals: "rgba(18, 20, 22, 0.86)", in: output.html)
        assertCSSVariable("--syntax-keyword-color", equals: "#CB94D4", in: output.html)
        XCTAssertNil(output.html.styleSheetBody.range(of: #"#[0-9A-Fa-f]{3,8}|rgba?\("#, options: .regularExpression))
    }

    func testRendererInlinesLightPaletteCSSAndMermaidVariables() {
        let output = render(
            """
            ```mermaid
            graph TD
              A --> B
            ```
            """,
            palette: .light
        )

        assertCSSVariable("--bg-color", equals: "#FFFFFF", in: output.html)
        assertCSSVariable("--text-color", equals: "#1F2328", in: output.html)
        assertCSSVariable("--link-color", equals: "#0969DA", in: output.html)
        assertCSSVariable("--inline-code-bg", equals: "#F6F8FA", in: output.html)
        assertCSSVariable("--mermaid-container-bg", equals: "rgba(246, 248, 250, 0.86)", in: output.html)
        XCTAssertTrue(output.html.contains("&quot;theme&quot;:&quot;base&quot;"))
        XCTAssertTrue(output.html.contains("&quot;background&quot;:&quot;#FFFFFF&quot;"))
        XCTAssertTrue(output.html.contains("&quot;mainBkg&quot;:&quot;#FFFFFF&quot;"))
        XCTAssertTrue(output.html.contains("&quot;textColor&quot;:&quot;#24292F&quot;"))
        XCTAssertFalse(output.html.contains("&quot;mainBkg&quot;:&quot;#252A2E&quot;"))
        XCTAssertFalse(output.html.contains("--bg-color: #383E44;"))
    }

    func testRendererIncludesStrictContentSecurityPolicyForNonMermaidDocuments() {
        let output = render("# Title\n\nBody")
        let policy = output.html.contentSecurityPolicyMetaContent()

        XCTAssertNotNil(policy)
        XCTAssertTrue(policy?.contains("default-src 'none'") == true)
        XCTAssertTrue(policy?.contains("img-src wafer-local: wafer-remote:") == true)
        XCTAssertTrue(policy?.contains("style-src 'unsafe-inline'") == true)
        XCTAssertTrue(policy?.contains("font-src wafer-local:") == true)
        XCTAssertTrue(policy?.contains("connect-src 'none'") == true)
        XCTAssertTrue(policy?.contains("object-src 'none'") == true)
        XCTAssertTrue(policy?.contains("base-uri 'none'") == true)
        XCTAssertTrue(policy?.contains("form-action 'none'") == true)
        XCTAssertTrue(policy?.contains("script-src 'none'") == true)
        XCTAssertFalse(output.html.contains("<script"))
    }

    func testExplicitReaderTargetMatchesDefaultReaderOutput() {
        let source = """
        # Reader

        Paragraph with **formatting** and [link](guide.md#section).

        ```swift
        let value = "reader"
        ```
        """
        let document = parser.parse(source: source, baseURL: URL(fileURLWithPath: "/tmp/docs/Reader.md"))
        let defaultOutput = WebKitHTMLRenderer().render(document: document)
        let explicitReaderOutput = WebKitHTMLRenderer(target: .reader).render(document: document)

        XCTAssertEqual(explicitReaderOutput, defaultOutput)
    }

    func testBareURLsAndEmailsAutolinkInReaderPreviewAndExport() throws {
        let source = """
        Visit https://example.com/docs?q=1&lang=swift, open www.example.org, or email hello@example.com.
        """

        let readerOutput = render(source, target: .reader)
        let previewOutput = render(source, target: .preview)
        let exportedHTML = try ExportSanitizer.sanitize(
            domHTML: readerOutput.html,
            policy: ExportSanitizer.ExportPolicy(inlineImage: { _ in nil })
        )

        for html in [readerOutput.html, previewOutput.html, exportedHTML] {
            XCTAssertTrue(html.contains(#"<a href="https://example.com/docs?q=1&amp;lang=swift">https://example.com/docs?q=1&amp;lang=swift</a>,"#))
            XCTAssertTrue(html.contains(#"<a href="http://www.example.org">www.example.org</a>,"#))
            XCTAssertTrue(html.contains(#"<a href="mailto:hello@example.com">hello@example.com</a>."#))
        }
    }

    func testAutolinksDoNotFireInsideInlineCodeCodeFencesOrExistingLinks() {
        let output = render(
            """
            `https://inline.example`

            ```text
            https://fenced.example
            ```

            [https://linked.example](https://target.example)
            """
        )

        XCTAssertTrue(output.html.contains("<code>https://inline.example</code>"))
        XCTAssertTrue(output.html.contains("<code class=\"cm-s-inner language-text\">https://fenced.example</code>"))
        XCTAssertTrue(output.html.contains(#"<a href="https://target.example">https://linked.example</a>"#))
        XCTAssertFalse(output.html.contains("href=\"https://inline.example\""))
        XCTAssertFalse(output.html.contains("href=\"https://fenced.example\""))
        XCTAssertEqual(output.html.numberOfMatches(of: "<a "), 1)
    }

    func testEmojiShortcodesAndHighlightsRenderInReaderPreviewAndExport() throws {
        let source = """
        Known :rocket: unknown :wafer_unknown: and ==marked :sparkles: text==.

        Code `:rocket: ==marked==`.

        [:rocket: ==raw link text==](https://example.com)
        """
        let readerOutput = render(source, target: .reader)
        let previewOutput = render(source, target: .preview)
        let exportedHTML = try ExportSanitizer.sanitize(
            domHTML: readerOutput.html,
            policy: ExportSanitizer.ExportPolicy(inlineImage: { _ in nil })
        )

        for html in [readerOutput.html, previewOutput.html, exportedHTML] {
            XCTAssertTrue(html.contains("Known 🚀 unknown :wafer_unknown: and <mark>marked ✨ text</mark>."))
            XCTAssertTrue(html.contains("<code>:rocket: ==marked==</code>"))
            XCTAssertTrue(html.contains(#"<a href="https://example.com">:rocket: ==raw link text==</a>"#))
        }
    }

    func testHighlightsRequireMatchedIsolatedPairs() {
        let output = render(
            """
            ==marked==

            Unmatched ==literal.

            === heading-like line stays literal

            ===x== and ==x=== stay literal.

            ==unmatched then ==marked==.
            """
        )

        XCTAssertTrue(output.html.contains("<mark>marked</mark>"))
        XCTAssertEqual(output.html.numberOfMatches(of: "<mark>"), 2)
        XCTAssertTrue(output.html.contains("Unmatched ==literal."))
        XCTAssertTrue(output.html.contains("=== heading-like line stays literal"))
        XCTAssertTrue(output.html.contains("===x== and ==x=== stay literal."))
        XCTAssertTrue(output.html.contains("==unmatched then <mark>marked</mark>."))
    }

    func testFootnotesRenderInReaderPreviewAndExport() throws {
        let source = """
        Intro[^b] and again[^b], then alpha[^a] and missing[^missing].

        Code `[^b]`.

        [^a]: Alpha **definition** with [link](https://example.com/a).
        [^b]: Beta definition with https://example.com/b.
        [^unused]: Unused definition.
        """
        let readerOutput = render(source, target: .reader)
        let previewOutput = render(source, target: .preview)
        let exportedHTML = try ExportSanitizer.sanitize(
            domHTML: readerOutput.html,
            policy: ExportSanitizer.ExportPolicy(inlineImage: { _ in nil })
        )

        for html in [readerOutput.html, previewOutput.html, exportedHTML] {
            XCTAssertTrue(html.contains(##"<sup class="md-footnote-ref"><a href="#fn-1" id="fnref-1" aria-label="Footnote 1">1</a></sup>"##))
            XCTAssertEqual(html.numberOfMatches(of: #"id="fnref-1""#), 1)
            XCTAssertEqual(html.numberOfMatches(of: ##"href="#fn-1""##), 2)
            XCTAssertTrue(html.contains(##"<sup class="md-footnote-ref"><a href="#fn-2" id="fnref-2" aria-label="Footnote 2">2</a></sup>"##))
            XCTAssertTrue(html.contains("[^missing]"))
            XCTAssertTrue(html.contains("<code>[^b]</code>"))
            XCTAssertTrue(html.contains(#"<section class="md-footnotes" aria-label="Footnotes">"#))
            XCTAssertTrue(html.contains(#"<li id="fn-1">"#))
            XCTAssertTrue(html.contains("Beta definition with <a href=\"https://example.com/b\">https://example.com/b</a>."))
            XCTAssertTrue(html.contains(#"<li id="fn-2">"#))
            XCTAssertTrue(html.contains("Alpha <strong>definition</strong> with <a href=\"https://example.com/a\">link</a>."))
            XCTAssertTrue(html.contains(##"https://example.com/b</a>.<a class="md-footnote-backref" href="#fnref-1""##))
            XCTAssertTrue(html.contains(##"with <a href="https://example.com/a">link</a>.<a class="md-footnote-backref" href="#fnref-2""##))
            XCTAssertFalse(html.contains(##"</p><a class="md-footnote-backref""##))
            XCTAssertFalse(html.contains("Unused definition"))
        }
    }

    func testFootnoteBackrefStaysInsideLastParagraphOfMultiParagraphDefinition() {
        let source = """
        Ref[^m].

        [^m]: First paragraph.

            Second paragraph.
        """
        let html = render(source).html

        XCTAssertTrue(html.contains(##"Second paragraph.<a class="md-footnote-backref""##))
        XCTAssertFalse(html.contains(##"First paragraph.<a class="md-footnote-backref""##))
        XCTAssertFalse(html.contains(##"</p><a class="md-footnote-backref""##))
    }

    func testFootnoteLinksResolveAgainstDocumentForReaderTarget() {
        // The reader page's base URL is the document's DIRECTORY, so a plain
        // "#fn-1" href navigates to the folder (opened in Finder) instead of
        // scrolling. Reader-target footnote links must carry the filename like
        // every markdown same-document anchor; previews keep plain fragments.
        let source = """
        Intro[^a].

        [^a]: Alpha definition.
        """
        let baseURL = URL(fileURLWithPath: "/docs/Note.md")
        let readerHTML = render(source, baseURL: baseURL).html
        let previewHTML = render(source, baseURL: baseURL, target: .preview).html

        XCTAssertTrue(readerHTML.contains(##"<a href="Note.md#fn-1" id="fnref-1" aria-label="Footnote 1">1</a>"##))
        XCTAssertTrue(readerHTML.contains(##"class="md-footnote-backref" href="Note.md#fnref-1""##))
        XCTAssertFalse(readerHTML.contains(##"href="#fn-1""##))
        XCTAssertFalse(readerHTML.contains(##"href="#fnref-1""##))
        XCTAssertTrue(previewHTML.contains(##"href="#fn-1""##))
        XCTAssertTrue(previewHTML.contains(##"class="md-footnote-backref" href="#fnref-1""##))
    }

    func testFootnoteReferencesInHeadingsDoNotPolluteOutlineAnchors() {
        let output = render(
            """
            # Title [^one]

            Body.

            [^one]: Heading note.
            """
        )

        XCTAssertEqual(output.outlineItems.map(\.title), ["Title"])
        XCTAssertEqual(output.outlineItems.map(\.anchorID), ["title"])
        XCTAssertTrue(output.html.contains(##"<h1 id="title">Title <sup class="md-footnote-ref"><a href="#fn-1" id="fnref-1" aria-label="Footnote 1">1</a></sup></h1>"##))
        XCTAssertTrue(output.html.contains("Heading note."))
    }

    func testExtractedFootnoteDefinitionsKeepAdjacentParagraphsSeparate() {
        let output = render(
            """
            First paragraph.[^one]
            [^one]: Footnote body.
            Second paragraph.
            """
        )

        XCTAssertTrue(output.html.contains(#"<p>First paragraph.<sup class="md-footnote-ref">"#))
        XCTAssertTrue(output.html.contains("</sup></p><p>Second paragraph.</p>"), output.html.bodyContent)
    }

    func testReaderGoldenOutputMatchesCheckedInHTML() throws {
        let source = try String(contentsOf: readerGoldenFixtureURL, encoding: .utf8)
        let document = parser.parse(source: source, baseURL: nil)
        let renderer = WebKitHTMLRenderer(palette: .dark)
        let rendered = renderer.render(document: document).html
        XCTAssertEqual(rendered, renderer.render(document: document).html)
        let html = rendered.replacingOccurrences(of: #"(?m)[ \t]+$"#, with: "", options: .regularExpression)
        if ProcessInfo.processInfo.environment["WAFER_UPDATE_GOLDENS"] == "1" {
            let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/Fixtures/WaferCore/Goldens/reader-golden.html")
            try html.write(to: destination, atomically: true, encoding: .utf8)
        } else {
            let expectedURL = readerGoldenFixtureURL.deletingLastPathComponent().appendingPathComponent("Goldens/reader-golden.html")
            XCTAssertEqual(html, try String(contentsOf: expectedURL, encoding: .utf8))
        }
    }

    func testFrontMatterRendersMetadataDetailsBeforeBodyInReaderPreviewAndExport() throws {
        let source = """
        ---
        title: Metadata Title
        tags:
          - swift
        ---
        # Body Title

        Body text.
        """
        let readerOutput = render(source, target: .reader)
        let previewOutput = render(source, target: .preview)
        let exportedHTML = try ExportSanitizer.sanitize(
            domHTML: readerOutput.html,
            policy: ExportSanitizer.ExportPolicy(inlineImage: { _ in nil })
        )

        for html in [readerOutput.html, previewOutput.html, exportedHTML] {
            XCTAssertTrue(html.contains(#"<details class="md-front-matter">"#))
            XCTAssertTrue(html.contains("<summary>Document metadata</summary>"))
            XCTAssertTrue(html.contains("<tr><th>title</th><td>Metadata Title</td></tr>"))
            XCTAssertTrue(html.contains("<tr><th>tags</th><td></td></tr>"))
            XCTAssertTrue(html.contains(#"<tr><td colspan="2"><code>  - swift</code></td></tr>"#))
            XCTAssertTrue(html.contains("<h1 id=\"body-title\">Body Title</h1>"))
            XCTAssertFalse(html.contains("title: Metadata Title"))
        }

        XCTAssertLessThan(
            readerOutput.html.range(of: #"<details class="md-front-matter">"#)!.lowerBound,
            readerOutput.html.range(of: #"<h1 id="body-title">Body Title</h1>"#)!.lowerBound
        )
    }

    func testUnclosedFrontMatterSourceStillRendersAsMarkdown() {
        let output = render(
            """
            ---
            title: Missing closer

            Body text.
            """
        )

        XCTAssertFalse(output.html.contains(#"<details class="md-front-matter">"#))
        XCTAssertTrue(output.html.contains("Missing closer"))
    }

    func testMermaidContentSecurityPolicyUsesNonceOnAllPageScripts() {
        let output = render(
            """
            ```mermaid
            flowchart LR
              A --> B
            ```
            """
        )
        let policy = output.html.contentSecurityPolicyMetaContent()
        let nonce = policy?.firstMatch(for: #"script-src 'nonce-([a-z0-9]+)'"#)

        XCTAssertNotNil(policy)
        XCTAssertEqual(nonce?.count, 32)
        XCTAssertTrue(policy?.contains("default-src 'none'") == true)
        XCTAssertTrue(policy?.contains("object-src 'none'") == true)
        XCTAssertFalse(policy?.contains("script-src 'none'") == true)
        XCTAssertEqual(output.html.numberOfMatches(of: "<script"), 2)
        XCTAssertEqual(output.html.numberOfMatches(of: "nonce=\"\(nonce ?? "")\""), 2)
        XCTAssertTrue(output.html.contains("mermaid.min.js"))
        XCTAssertTrue(output.html.contains("window.mermaid.initialize"))
    }

    func testSupportedBlockDirectivesRenderAsSemanticCalloutsAndPreserveNestedMarkdown() {
        let output = render(
            """
            @Warning(title: "Heads up") {
            Body with **strong** emphasis and `inline code`.
            }
            """
        )

        XCTAssertTrue(output.html.contains("<aside class=\"md-callout md-callout-warning\">"))
        XCTAssertTrue(output.html.contains("<div class=\"md-callout-label\">Heads up</div>"))
        XCTAssertTrue(output.html.contains("<strong>strong</strong>"))
        XCTAssertTrue(output.html.contains("<code>inline code</code>"))
    }

    func testGitHubAlertsRenderAsExistingCalloutKinds() {
        let cases = [
            ("[!NOTE]", "md-callout-note", "Note"),
            ("[!TIP]", "md-callout-tip", "Tip"),
            ("[!IMPORTANT]", "md-callout-important", "Important"),
            ("[!WARNING]", "md-callout-warning", "Warning"),
            ("[!CAUTION]", "md-callout-caution", "Caution"),
        ]

        for (marker, className, label) in cases {
            let output = render(
                """
                > \(marker)
                > Body with **strong** text.
                """
            )

            XCTAssertTrue(output.html.contains("<aside class=\"md-callout \(className)\">"), marker)
            XCTAssertTrue(output.html.contains("<div class=\"md-callout-label\">\(label)</div>"), marker)
            XCTAssertTrue(output.html.contains("<p>Body with <strong>strong</strong> text.</p>"), marker)
            XCTAssertFalse(output.html.contains(marker), marker)
        }
    }

    func testGitHubAlertsAreCaseInsensitiveAndMarkerMustBeAlone() {
        let alertOutput = render(
            """
            > [!note]
            > Lowercase marker works.
            """
        )
        let blockquoteOutput = render(
            """
            > [!NOTE] extra words
            > Stays quoted.
            """
        )

        XCTAssertTrue(alertOutput.html.contains("<aside class=\"md-callout md-callout-note\">"))
        XCTAssertTrue(alertOutput.html.contains("<p>Lowercase marker works.</p>"))
        XCTAssertFalse(alertOutput.html.contains("[!note]"))
        XCTAssertTrue(blockquoteOutput.html.contains("<blockquote>"))
        XCTAssertTrue(blockquoteOutput.html.contains("[!NOTE] extra words"))
        XCTAssertFalse(blockquoteOutput.html.contains("<aside class=\"md-callout md-callout-note\">"))
    }

    func testGitHubAlertWithSecondParagraphAndNestedBlockquoteKeepsNestedQuote() {
        let output = render(
            """
            > [!IMPORTANT]
            >
            > First body paragraph.
            >
            > > Nested quote.
            """
        )

        XCTAssertTrue(output.html.contains("<aside class=\"md-callout md-callout-important\">"))
        XCTAssertTrue(output.html.contains("<p>First body paragraph.</p>"))
        XCTAssertTrue(output.html.contains("<blockquote><p>Nested quote.</p></blockquote>"))
        XCTAssertFalse(output.html.contains("[!IMPORTANT]"))
    }

    func testGitHubAlertsRenderInReaderPreviewAndSurviveExport() throws {
        let source = """
        > [!WARNING]
        > Export-visible body.
        """
        let readerOutput = render(source, target: .reader)
        let previewOutput = render(source, target: .preview)
        let exportedHTML = try ExportSanitizer.sanitize(
            domHTML: readerOutput.html,
            policy: ExportSanitizer.ExportPolicy(inlineImage: { _ in nil })
        )

        for html in [readerOutput.html, previewOutput.html, exportedHTML] {
            XCTAssertTrue(html.contains("<aside class=\"md-callout md-callout-warning\">"))
            XCTAssertTrue(html.contains("<div class=\"md-callout-label\">Warning</div>"))
            XCTAssertTrue(html.contains("<p>Export-visible body.</p>"))
            XCTAssertFalse(html.contains("[!WARNING]"))
        }
    }

    func testUnknownBlockDirectivesRemainFallbackBlocks() {
        let output = render(
            """
            @Custom(style: "glass") {
            Mystery block
            }
            """
        )

        XCTAssertTrue(output.html.contains("<p class=\"fallback-block\">"))
        XCTAssertTrue(output.html.contains("@Custom"))
        XCTAssertTrue(output.html.contains("Mystery block"))
    }

    func testSymbolLinksRenderAsCodeVoice() {
        let output = render("Use ``ReaderTheme.styleSheet`` for preview.")

        XCTAssertTrue(output.html.contains("<code class=\"md-symbol-link\">ReaderTheme.styleSheet</code>"))
    }

    func testInlineAttributesPreserveClassOnlyAndIgnoreOtherKeys() {
        let output = render(#"^[chip text](class: "md-inline-chip", demo: "ignored")"#)

        XCTAssertTrue(output.html.contains("<span class=\"md-inline-chip\">chip text</span>"))
        XCTAssertFalse(output.html.contains("demo="))
    }

    func testMalformedInlineAttributesFallBackToChildrenWithoutWrapper() {
        let output = render(#"^[plain text](class: )"#)

        XCTAssertTrue(output.html.contains("<p>plain text</p>"))
        XCTAssertFalse(output.html.contains("<span class="))
    }

    func testTaggedCodeBlocksEmitTokenSpansWhilePlainCodeRemainsUnstyled() {
        let swiftOutput = render(
            """
            ```swift
            struct Theme {
                let title = "Wafer"
            }
            ```
            """
        )
        let plainOutput = render(
            """
            ```
            plain code
            ```
            """
        )

        XCTAssertTrue(swiftOutput.html.contains("<span class=\"cm-keyword\">"))
        XCTAssertTrue(swiftOutput.html.contains("<span class=\"cm-def\">"))
        XCTAssertTrue(swiftOutput.html.contains("<span class=\"cm-string\">"))
        XCTAssertTrue(swiftOutput.html.contains("<pre class=\"md-fences\" lang=\"swift\"><code class=\"cm-s-inner language-swift\">"))
        XCTAssertFalse(plainOutput.html.contains("<span class=\"cm-keyword\">"))
        XCTAssertFalse(plainOutput.html.contains("<span class=\"cm-def\">"))
    }

    func testMermaidCodeBlocksRenderAsAsyncDiagramFigures() {
        let output = render(
            """
            ```mermaid
            flowchart LR
              A["<Start>"] --> B[Done]
            ```
            """
        )

        XCTAssertTrue(output.waitsForContentReady)
        XCTAssertTrue(output.html.contains("<figure class=\"md-mermaid-diagram\" data-wafer-mermaid-id=\"wafer-mermaid-1\">"))
        XCTAssertTrue(output.html.contains("<button type=\"button\" class=\"md-mermaid-open\" data-wafer-chrome=\"true\" aria-label=\"Open Mermaid diagram inspector\" hidden>Open</button>"))
        XCTAssertTrue(output.html.contains("<div class=\"md-mermaid-output\" aria-label=\"Mermaid diagram\"></div>"))
        XCTAssertTrue(output.html.contains("<pre class=\"md-mermaid-source\" lang=\"mermaid\"><code>flowchart LR"))
        XCTAssertTrue(output.html.contains("A[&quot;&lt;Start&gt;&quot;] --&gt; B[Done]"))
        XCTAssertTrue(output.html.contains("mermaid.min.js"))
        XCTAssertTrue(output.html.contains("securityLevel: 'strict'"))
        XCTAssertTrue(output.html.contains("suppressErrorRendering: true"))
        XCTAssertTrue(output.html.contains("&quot;attributeBackgroundColorOdd&quot;:&quot;#30363B&quot;"))
        XCTAssertTrue(output.html.contains("&quot;mainBkg&quot;:&quot;#252A2E&quot;"))
        XCTAssertTrue(output.html.contains("&quot;altSectionBkgColor&quot;:&quot;#2A3035&quot;"))
        XCTAssertTrue(output.html.contains("&quot;taskTextDarkColor&quot;:&quot;#F1F3F5&quot;"))
        XCTAssertTrue(output.html.contains("waferContentReady"))
        XCTAssertTrue(output.html.contains("role', 'dialog'"))
        XCTAssertTrue(output.html.contains("overlay.setAttribute(configuration.chromeAttributeName, configuration.chromeAttributeValue);"))
        XCTAssertTrue(output.html.contains("data-action=\"copy\""))
        XCTAssertTrue(output.html.contains("addEventListener('wheel', handleWheel"))
        XCTAssertFalse(output.html.contains("<pre class=\"md-fences\" lang=\"mermaid\""))
    }

    func testMathFenceEmitsKaTeXMountStyleAndScriptsWithNonce() {
        let output = render(
            """
            ```math
            c = \\pm\\sqrt{a^2 + b^2}
            ```
            """
        )
        let policy = output.html.contentSecurityPolicyMetaContent()
        let nonce = policy?.firstMatch(for: #"script-src 'nonce-([a-z0-9]+)'"#)

        XCTAssertTrue(output.waitsForContentReady)
        XCTAssertEqual(nonce?.count, 32)
        XCTAssertTrue(policy?.contains("style-src 'unsafe-inline' wafer-local:") == true)
        XCTAssertTrue(policy?.contains("font-src wafer-local:") == true)
        XCTAssertTrue(output.html.contains("<figure class=\"md-math-display\" data-wafer-math-id=\"wafer-math-1\">"))
        XCTAssertTrue(output.html.contains("<div class=\"md-math-output\" aria-label=\"Rendered math\"></div>"))
        XCTAssertTrue(output.html.contains("<pre class=\"md-math-source\" lang=\"math\"><code>c = \\pm\\sqrt{a^2 + b^2}</code></pre>"))
        XCTAssertTrue(output.html.contains("katex.min.js"))
        XCTAssertTrue(output.html.contains("window.katex.render"))
        XCTAssertTrue(output.html.contains("displayMode: true"))
        XCTAssertTrue(output.html.contains("throwOnError: false"))
        XCTAssertTrue(output.html.contains(".md-math-output .katex"))
        XCTAssertTrue(output.html.contains("@font-face"))
        XCTAssertTrue(output.html.contains("wafer-local://asset?path="))
        XCTAssertTrue(output.html.contains("KaTeX_Main-Regular.woff2"))
        XCTAssertEqual(output.html.numberOfMatches(of: "<script"), 2)
        XCTAssertEqual(output.html.numberOfMatches(of: "nonce=\"\(nonce ?? "")\""), 2)
        XCTAssertFalse(output.html.contains("mermaid.min.js"))
    }

    func testInvalidMathKeepsSourceVisibleThroughKaTeXErrorRendering() {
        let output = render(
            """
            ```math
            \\definitelynotacommand{
            ```
            """
        )

        XCTAssertTrue(output.waitsForContentReady)
        XCTAssertTrue(output.html.contains("throwOnError: false"))
        XCTAssertTrue(output.html.contains("errorColor: errorColor"))
        XCTAssertTrue(output.html.contains("\\definitelynotacommand{"))
        XCTAssertTrue(output.html.contains("class=\"md-math-error\" hidden"))
    }

    func testPreviewMermaidCodeBlocksRenderScriptlessFences() {
        let output = render(
            """
            ```mermaid
            flowchart LR
              A["<Start>"] --> B[Done]
            ```
            """,
            target: .preview
        )
        let body = output.html.bodyContent

        XCTAssertFalse(output.waitsForContentReady)
        XCTAssertNil(output.html.contentSecurityPolicyMetaContent())
        XCTAssertTrue(output.previewAttachments.isEmpty)
        XCTAssertTrue(output.html.contains("<pre class=\"md-fences\" lang=\"mermaid\"><code class=\"cm-s-inner language-mermaid\">"))
        XCTAssertTrue(output.html.contains("A[&quot;&lt;Start&gt;&quot;] --&gt; B[Done]"))
        XCTAssertFalse(output.html.contains("<script"))
        XCTAssertFalse(output.html.contains("wafer-local:"))
        XCTAssertFalse(output.html.contains("wafer-remote:"))
        XCTAssertFalse(body.contains("md-mermaid-diagram"))
        XCTAssertFalse(body.contains("md-mermaid-open"))
        XCTAssertFalse(body.contains("md-diagram-inspector"))
    }

    func testPreviewMathCodeBlocksRenderScriptlessFences() {
        let output = render(
            """
            ```math
            c = \\pm\\sqrt{a^2 + b^2}
            ```
            """,
            target: .preview
        )
        let body = output.html.bodyContent

        XCTAssertFalse(output.waitsForContentReady)
        XCTAssertNil(output.html.contentSecurityPolicyMetaContent())
        XCTAssertTrue(output.previewAttachments.isEmpty)
        XCTAssertTrue(output.html.contains("<pre class=\"md-fences\" lang=\"math\"><code class=\"cm-s-inner language-math\">"))
        XCTAssertTrue(output.html.contains("c = \\pm\\sqrt{a^2 + b^2}"))
        XCTAssertFalse(output.html.contains("<script"))
        XCTAssertFalse(output.html.contains("katex.min.js"))
        XCTAssertFalse(output.html.contains("wafer-local:"))
        XCTAssertFalse(body.contains("md-math-display"))
        XCTAssertFalse(body.contains("md-math-output"))
    }

    func testMermaidAliasAndMultipleDiagramsUseStableIDsAndOneBootstrap() {
        let output = render(
            """
            ```mmd
            pie title Pets
              "Cats" : 2
              "Dogs" : 3
            ```

            ```mermaid
            sequenceDiagram
              Alice->>Bob: Hi
            ```
            """
        )

        XCTAssertTrue(output.waitsForContentReady)
        XCTAssertTrue(output.html.contains("data-wafer-mermaid-id=\"wafer-mermaid-1\""))
        XCTAssertTrue(output.html.contains("data-wafer-mermaid-id=\"wafer-mermaid-2\""))
        XCTAssertEqual(output.html.numberOfMatches(of: "mermaid.min.js"), 1)
        XCTAssertEqual(output.html.numberOfMatches(of: "window.mermaid.initialize"), 1)
    }

    func testMermaidAndMathShareOneReadinessCoordinator() {
        let output = render(
            """
            ```mermaid
            flowchart LR
              A --> B
            ```

            ```math
            E = mc^2
            ```
            """
        )

        XCTAssertTrue(output.waitsForContentReady)
        XCTAssertEqual(output.html.numberOfMatches(of: "window.waferAsyncRenderer ="), 1)
        XCTAssertTrue(output.html.contains("waferContentReady.postMessage(document.querySelector"))
        XCTAssertEqual(output.html.numberOfMatches(of: "mermaid.min.js"), 1)
        XCTAssertEqual(output.html.numberOfMatches(of: "katex.min.js"), 1)
        XCTAssertEqual(output.html.numberOfMatches(of: "<script"), 3)
        XCTAssertTrue(output.html.contains("window.mermaid.render"))
        XCTAssertTrue(output.html.contains("window.katex.render"))
    }

    func testNonMermaidCodeBlocksDoNotLoadDiagramBootstrap() {
        let output = render(
            """
            ```swift
            let graph = "A --> B"
            ```
            """
        )

        XCTAssertFalse(output.waitsForContentReady)
        XCTAssertTrue(output.html.contains("<pre class=\"md-fences\" lang=\"swift\"><code class=\"cm-s-inner language-swift\">"))
        XCTAssertFalse(output.html.contains("class=\"md-mermaid-diagram\""))
        XCTAssertFalse(output.html.contains("class=\"md-mermaid-open\""))
        XCTAssertFalse(output.html.contains("window.waferDiagramInspector"))
        XCTAssertFalse(output.html.contains("waferContentReady"))
        XCTAssertFalse(output.html.contains("katex.min.js"))
        XCTAssertFalse(output.html.contains("window.katex.render"))
        XCTAssertFalse(output.html.bodyContent.contains("md-math-display"))
    }

    func testAliasTaggedCodeBlocksHighlightAndPreserveOriginalLanguageTag() {
        let jsxOutput = render(
            """
            ```jsx
            const renderCard = (props) => props.title
            ```
            """
        )
        let tsxOutput = render(
            """
            ```tsx
            interface Props { title: string }
            const renderCard = (props: Props) => props.title
            ```
            """
        )

        XCTAssertTrue(jsxOutput.html.contains("<pre class=\"md-fences\" lang=\"jsx\"><code class=\"cm-s-inner language-jsx\">"))
        XCTAssertTrue(jsxOutput.html.contains("cm-keyword"))
        XCTAssertTrue(jsxOutput.html.contains("cm-variable-2"))
        XCTAssertTrue(jsxOutput.html.contains("cm-property"))

        XCTAssertTrue(tsxOutput.html.contains("<pre class=\"md-fences\" lang=\"tsx\"><code class=\"cm-s-inner language-tsx\">"))
        XCTAssertTrue(tsxOutput.html.contains("cm-keyword"))
        XCTAssertTrue(tsxOutput.html.contains("cm-def"))
        XCTAssertTrue(tsxOutput.html.contains("cm-variable-2"))
        XCTAssertTrue(tsxOutput.html.contains("cm-property"))
    }

    func testTableColumnWidthsUseStructuralContentHeuristics() {
        let threeColumnOutput = render(
            """
            | Short | Long description | End |
            | - | - | - |
            | A | This middle column has substantially more text | Z |
            """
        )
        let fourColumnOutput = render(
            """
            | A | B | Long description | D |
            | - | - | - | - |
            | 1 | 2 | This third column has substantially more text | 4 |
            """
        )
        let heuristicOutput = render(
            """
            | Feature | Description | Impact | Area | Score |
            | --- | --- | --- | --- | --- |
            | Rendering | Longer descriptive copy to widen the column | High | Reader | 9 |
            """
        )
        let threeColumnWidths = threeColumnOutput.html.tableColumnWidths()
        let fourColumnWidths = fourColumnOutput.html.tableColumnWidths()
        let heuristicWidths = heuristicOutput.html.tableColumnWidths()

        assertColumnWidthsAreNormalized(threeColumnWidths, expectedCount: 3)
        assertColumnWidthsAreNormalized(fourColumnWidths, expectedCount: 4)
        assertColumnWidthsAreNormalized(heuristicWidths, expectedCount: 5)
        XCTAssertEqual(threeColumnWidths.widestColumnIndex, 1)
        XCTAssertEqual(fourColumnWidths.widestColumnIndex, 2)
        XCTAssertEqual(heuristicWidths.widestColumnIndex, 1)
    }

    func testTableColumnWidthsAllowLongLastColumnToBeWidest() {
        let output = render(
            """
            | A | B | C | Long final notes |
            | - | - | - | - |
            | 1 | 2 | 3 | The final column carries the longest content and should not be clamped |
            """
        )
        let widths = output.html.tableColumnWidths()

        assertColumnWidthsAreNormalized(widths, expectedCount: 4)
        XCTAssertEqual(widths.widestColumnIndex, 3)
    }

    func testTableCellsRenderInlineMarkdownInsteadOfEscapedSourceText() {
        let output = render(
            #"""
            | **Name** | Value |
            | :-- | --: |
            | `code` and [link](https://example.com) | **bold** with *emphasis* and ~~gone~~ |
            """#
        )

        XCTAssertTrue(output.html.contains("<th align=\"left\"><strong>Name</strong></th>"))
        XCTAssertTrue(output.html.contains("<th align=\"right\">Value</th>"))
        XCTAssertTrue(output.html.contains("<td align=\"left\"><code>code</code> and <a href=\"https://example.com\">link</a></td>"))
        XCTAssertTrue(output.html.contains("<td align=\"right\"><strong>bold</strong> with <em>emphasis</em> and <del>gone</del></td>"))
        XCTAssertFalse(output.html.contains("**bold**"))
        XCTAssertFalse(output.html.contains("`code`"))
        XCTAssertFalse(output.html.contains("~~gone~~"))
    }

    func testNestedListsAndTaskListsRenderNestedHTML() {
        let output = render(
            """
            - Top level
              - Nested bullet
              - [x] Nested task
            - [ ] Top task
              - [x] Nested checked task
            """
        )

        XCTAssertGreaterThanOrEqual(output.html.numberOfMatches(of: "<ul"), 3)
        XCTAssertGreaterThanOrEqual(output.html.numberOfMatches(of: "class=\"task-list\""), 2)
        XCTAssertGreaterThanOrEqual(output.html.numberOfMatches(of: "class=\"md-task-list-item\""), 3)
    }

    func testRelativeMarkdownLinksPreserveFragmentsInHTML() {
        let baseURL = URL(fileURLWithPath: "/tmp/docs/README.md")
        let output = render(
            """
            [Guide](guide/intro.md#deep-link)
            [Here](#top)
            """,
            baseURL: baseURL
        )

        XCTAssertTrue(output.html.contains("href=\"guide/intro.md#deep-link\""))
        XCTAssertTrue(output.html.contains("href=\"README.md#top\""))
    }

    func testMissingImagesFallBackAndRemoteImagesUseProxy() {
        let output = render(
            """
            ![Missing]()
            ![Remote <badge>](https://example.com/image.png?size=1&label="x")
            """
        )

        XCTAssertEqual(output.html.numberOfMatches(of: "[Missing image]"), 1)
        XCTAssertTrue(output.html.contains("src=\"wafer-remote://image?url=https://example.com/image.png"))
        XCTAssertTrue(output.html.contains("size"))
        XCTAssertTrue(output.html.contains("%26label"))
        XCTAssertTrue(output.html.contains("alt=\"Remote &lt;badge&gt;\""))
        XCTAssertTrue(output.html.contains("loading=\"lazy\""))
        XCTAssertFalse(output.html.contains("src=\"https://example.com"))
    }

    func testLocalImagesStillUseLocalAssetSchemeWithoutLazyLoading() {
        let output = render("![Preview](App/Resources/Wafer-preview.png)")

        XCTAssertTrue(output.html.contains("src=\"wafer-local://asset?path="))
        XCTAssertTrue(output.html.contains("Wafer-preview.png"))
        XCTAssertFalse(output.html.contains("loading=\"lazy\""))
    }

    func testPreviewLocalImagesUseCIDAttachments() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("Preview.md")
        let imageURL = temporaryDirectory.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        let output = render("![Local image](image.png)", baseURL: documentURL, target: .preview)

        XCTAssertEqual(output.previewAttachments, ["preview-asset-1": imageURL.standardizedFileURL.resolvingSymlinksInPath()])
        XCTAssertTrue(output.html.contains("src=\"cid:preview-asset-1\""))
        XCTAssertTrue(output.html.contains("alt=\"Local image\""))
        XCTAssertFalse(output.html.contains("wafer-local://"))
        XCTAssertFalse(output.html.contains("loading=\"lazy\""))
    }

    func testPreviewRejectsLocalImagesOutsideDocumentDirectory() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documentDirectory = temporaryDirectory.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = documentDirectory.appendingPathComponent("Preview.md")
        let secretImageURL = temporaryDirectory.appendingPathComponent("secret.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: secretImageURL)

        let output = render("![Secret](../secret.png)", baseURL: documentURL, target: .preview)

        XCTAssertTrue(output.previewAttachments.isEmpty)
        XCTAssertTrue(output.html.contains("[Missing image]"))
        XCTAssertFalse(output.html.contains("cid:"))
        XCTAssertFalse(output.html.contains("secret.png"))
    }

    func testPreviewRemoteImagesRenderAsPlaceholdersWithoutNetworkSources() {
        let output = render(
            "![Remote badge](https://example.com/image.png?size=1)",
            target: .preview
        )

        XCTAssertTrue(output.previewAttachments.isEmpty)
        XCTAssertTrue(output.html.contains("[Remote image omitted: Remote badge]"))
        XCTAssertFalse(output.html.contains("<img src=\"https://"))
        XCTAssertFalse(output.html.contains("https://example.com"))
        XCTAssertFalse(output.html.contains("wafer-remote://"))
        XCTAssertFalse(output.html.contains("loading=\"lazy\""))
    }

    func testRendererEscapesTextAttributesAndCode() {
        let output = render(
            """
            5 < 7 & 9 > 3

            [Params](https://example.com?q=chips&lang=md)

            ```
            <div class="notice">& "quoted"</div>
            ```
            """
        )

        XCTAssertTrue(output.html.contains("5 &lt; 7 &amp; 9 &gt; 3"))
        XCTAssertTrue(output.html.contains("href=\"https://example.com?q=chips&amp;lang=md\""))
        XCTAssertTrue(output.html.contains("&lt;div class=&quot;notice&quot;&gt;&amp; &quot;quoted&quot;&lt;/div&gt;"))
    }

    func testRawHTMLUnknownDirectivesAndKbdHandlingRemainVisible() {
        let output = render(
            """
            Raw <span>inline</span> html and <kbd>Cmd</kbd>.

            <aside>block html</aside>

            @Unknown {
            Important
            }
            """
        )

        XCTAssertTrue(output.html.contains("Raw <span>inline</span> html and <kbd>Cmd</kbd>."))
        XCTAssertTrue(output.html.contains("<p class=\"fallback-block\">block html</p>"))
        XCTAssertTrue(output.html.contains("@Unknown"))
        XCTAssertTrue(output.html.contains("Important"))
    }

    func testSanitizedHTMLBlockRendersAllowedSubsetAndRemoteImageProxy() {
        let output = render(
            #"""
            <div align="center" style="color:red"><img src="https://example.com/a.png?x=1&y=2" alt="A" onerror="alert(1)"></div>
            """#
        )

        XCTAssertTrue(output.html.contains("<div align=\"center\"><img src=\"wafer-remote://image?url=https://example.com/a.png"))
        XCTAssertTrue(output.html.contains("x%3D1%26y%3D2"))
        XCTAssertTrue(output.html.contains("alt=\"A\""))
        XCTAssertTrue(output.html.contains("</div>"))
        XCTAssertFalse(output.html.contains("onerror"))
        XCTAssertFalse(output.html.contains("src=\"https://example.com"))
    }

    func testPictureSourceSetReaderPreviewAndExportTriangle() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("Logo.md")
        let fallbackImageURL = temporaryDirectory.appendingPathComponent("light.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fallbackImageURL)

        let source = #"""
        <picture>
        <source media="(prefers-color-scheme: dark)" type="image/png" srcset="dark.png 1x, https://example.com/dark@2.png 2x">
        <img src="light.png" alt="Logo">
        </picture>
        """#

        let readerOutput = render(source, baseURL: documentURL, target: .reader)
        let previewOutput = render(source, baseURL: documentURL, target: .preview)
        let exportedHTML = try ExportSanitizer.sanitize(
            domHTML: readerOutput.html,
            policy: ExportSanitizer.ExportPolicy { rawSource in
                if rawSource.contains("dark.png") {
                    return "data:image/png;base64,REFSSw=="
                }
                if rawSource.contains("dark@2.png") {
                    return "data:image/png;base64,REFSSzJY"
                }
                if rawSource.contains("light.png") {
                    return "data:image/png;base64,TElHSFQ="
                }
                return nil
            }
        )

        XCTAssertTrue(readerOutput.html.contains("<picture>"))
        XCTAssertTrue(readerOutput.html.contains(#"<source media="(prefers-color-scheme: dark)" type="image/png" srcset="wafer-local://asset?path="#))
        XCTAssertTrue(readerOutput.html.contains("dark.png 1x"))
        XCTAssertTrue(readerOutput.html.contains("wafer-remote://image?url=https://example.com/dark@2.png"))
        XCTAssertTrue(readerOutput.html.contains(#"<img src="wafer-local://asset?path="#))

        XCTAssertTrue(previewOutput.html.contains("<picture>"))
        XCTAssertFalse(previewOutput.html.contains("<source"))
        XCTAssertTrue(previewOutput.html.contains(#"<img src="cid:preview-asset-1" alt="Logo" />"#))
        XCTAssertEqual(previewOutput.previewAttachments, ["preview-asset-1": fallbackImageURL.standardizedFileURL.resolvingSymlinksInPath()])

        XCTAssertTrue(exportedHTML.contains(#"<source media="(prefers-color-scheme: dark)" type="image/png" srcset="data:image/png;base64,REFSSw== 1x, data:image/png;base64,REFSSzJY 2x">"#))
        XCTAssertTrue(exportedHTML.contains(#"<img src="data:image/png;base64,TElHSFQ=" alt="Logo">"#))
        XCTAssertFalse(exportedHTML.contains("wafer-local:"))
        XCTAssertFalse(exportedHTML.contains("wafer-remote:"))
    }

    func testSanitizedHTMLNeutralizesScriptURLsAndRawTextElements() {
        let output = render(
            #"""
            <script>alert(1)</script>safe
            <a href="javascript:alert(1)" onclick="alert(1)">click</a>
            <iframe src="https://evil.test">fallback</iframe>
            <img src="data:image/svg+xml,<svg onload=alert(1)>">
            """#
        )

        XCTAssertTrue(output.html.contains("click"))
        XCTAssertTrue(output.html.contains("safe"))
        XCTAssertFalse(output.html.contains("<script"))
        XCTAssertFalse(output.html.contains("<iframe"))
        XCTAssertFalse(output.html.contains("javascript:"))
        XCTAssertFalse(output.html.contains("data:image"))
        XCTAssertFalse(output.html.contains("onload"))
        XCTAssertFalse(output.html.contains("onclick"))
        XCTAssertFalse(output.html.contains("alert(1)"))
    }

    func testCrossBlockDetailsHTMLWrapsRenderedMarkdownContent() {
        let output = render(
            """
            <details>
            <summary>Click</summary>

            - hidden

            </details>
            """
        )

        let html = output.html
        let detailsStart = try! XCTUnwrap(html.range(of: "<details>")?.lowerBound)
        let summaryStart = try! XCTUnwrap(html.range(of: "<summary>Click</summary>")?.lowerBound)
        let listStart = try! XCTUnwrap(html.range(of: "<ul>")?.lowerBound)
        let detailsEnd = try! XCTUnwrap(html.range(of: "</details>")?.lowerBound)

        XCTAssertLessThan(detailsStart, summaryStart)
        XCTAssertLessThan(summaryStart, listStart)
        XCTAssertLessThan(listStart, detailsEnd)
        XCTAssertTrue(html.contains("<li>hidden</li>"))
    }

    func testSanitizedHTMLKeepsRenderedMetadataTextOnly() {
        let output = render(
            """
            # Title <kbd>Cmd</kbd>

            <details><summary>Click</summary>Hidden</details>
            """
        )

        XCTAssertEqual(output.outlineItems.first?.title, "Title Cmd")
        XCTAssertEqual(output.outlineItems.first?.anchorID, "title-cmd")
        XCTAssertGreaterThan(output.statistics.words, 0)
        XCTAssertTrue(output.html.contains("<details><summary>Click</summary>Hidden</details>"))
    }

    func testRendererProducesSidebarMetadataForCurrentDocumentAndLinkedMarkdownFiles() {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let linkedURL = temporaryDirectory.appendingPathComponent("Guide.md")
        try? Data("# Linked Guide\n\nLinked preview text.".utf8).write(to: linkedURL)
        let currentURL = temporaryDirectory.appendingPathComponent("Showcase.md")
        let source = """
        # Showcase Title

        Current preview text.

        [Guide](Guide.md)
        [Guide Again](Guide.md#section)
        [License](LICENSE)
        """
        let output = render(source, baseURL: currentURL)

        XCTAssertEqual(output.sidebarEntries.map(\.displayTitle), ["Guide", "Showcase Title"])
        XCTAssertEqual(output.sidebarEntries.first?.needsSummary, true)
        let summary = DocumentSidebarDataBuilder.summary(for: linkedURL)
        XCTAssertEqual(summary.displayTitle, "Linked Guide")
        XCTAssertEqual(summary.previewText, "Linked preview text.")
        XCTAssertEqual(output.sidebarEntries.last?.previewText, "Current preview text.")
        XCTAssertEqual(output.outlineItems.map(\.anchorID), ["showcase-title"])
    }

    func testPreviewAndReaderShareHeadingAnchorsAndOutline() {
        let source = """
        # Section

        ## Section

        Body.
        """
        let readerOutput = render(source, target: .reader)
        let previewOutput = render(source, target: .preview)

        XCTAssertEqual(previewOutput.outlineItems, readerOutput.outlineItems)
        XCTAssertTrue(previewOutput.html.contains("<h1 id=\"section\">Section</h1>"))
        XCTAssertTrue(previewOutput.html.contains(#"<h2 id="section-2"><a id="section-1" class="md-anchor-alias" aria-hidden="true"></a>Section</h2>"#))
    }

    func testGitHubAnchorAliasesRenderWithoutChangingPrimaryOutlineIDs() throws {
        let source = """
        # What's New?

        See [GitHub-style anchor](#whats-new).

        ## Héllo Wörld

        ## Ready, set, GO!
        """
        let documentURL = URL(fileURLWithPath: "/tmp/Anchors.md")
        let readerOutput = render(source, baseURL: documentURL, target: .reader)
        let previewOutput = render(source, baseURL: documentURL, target: .preview)
        let exportedHTML = try ExportSanitizer.sanitize(
            domHTML: readerOutput.html,
            policy: ExportSanitizer.ExportPolicy(inlineImage: { _ in nil })
        )

        XCTAssertEqual(readerOutput.outlineItems.map(\.anchorID), ["what-s-new", "hello-world", "ready-set-go"])
        XCTAssertTrue(
            readerOutput.html.contains(#"<h1 id="what-s-new"><a id="whats-new" class="md-anchor-alias" aria-hidden="true"></a>What’s New?</h1>"#),
            readerOutput.html.bodyContent
        )
        XCTAssertTrue(readerOutput.html.contains(#"<h2 id="hello-world"><a id="héllo-wörld" class="md-anchor-alias" aria-hidden="true"></a>Héllo Wörld</h2>"#))
        XCTAssertTrue(readerOutput.html.contains(#"<h2 id="ready-set-go">Ready, set, GO!</h2>"#))
        XCTAssertTrue(readerOutput.html.contains("href=\"Anchors.md#whats-new\""), readerOutput.html.bodyContent)
        XCTAssertTrue(previewOutput.html.contains(#"<a id="whats-new" class="md-anchor-alias" aria-hidden="true"></a>"#))
        XCTAssertTrue(exportedHTML.contains(#"<a id="whats-new" class="md-anchor-alias" aria-hidden="true"></a>"#))
    }

    func testHeadingAnchorAliasesKeepPageIDsUniqueThroughCollisionsAndDuplicates() {
        let output = render(
            """
            # a_b
            # a b
            # What's New?
            # What's New?
            # Héllo Wörld
            # a.b
            # ab
            # H1!
            # H1
            """
        )

        let ids = output.html.idAttributeValues
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertTrue(ids.contains("a-b"))
        XCTAssertTrue(ids.contains("a_b"))
        XCTAssertTrue(ids.contains("a-b-2"))
        XCTAssertTrue(ids.contains("whats-new"))
        XCTAssertTrue(ids.contains("whats-new-1"))
        XCTAssertTrue(ids.contains("héllo-wörld"))
        XCTAssertTrue(ids.contains("ab"))
        XCTAssertTrue(ids.contains("ab-1"))
        XCTAssertFalse(output.html.contains(#"<a id="a-b" class="md-anchor-alias""#))
        XCTAssertFalse(output.html.contains(#"<a id="ab" class="md-anchor-alias""#))
    }

    private func render(
        _ source: String,
        baseURL: URL? = nil,
        palette: ReaderThemePalette = .dark,
        target: RenderTarget = .reader
    ) -> WebKitRenderOutput {
        let document = parser.parse(source: source, baseURL: baseURL)
        return WebKitHTMLRenderer(palette: palette, target: target).render(document: document)
    }

    private var readerGoldenFixtureURL: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WaferCore/reader-golden.md")
    }



    private func assertCSSVariable(
        _ name: String,
        equals expectedValue: String,
        in html: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(html.cssVariable(name), expectedValue, file: file, line: line)
    }

    private func assertColumnWidthsAreNormalized(
        _ widths: [Double],
        expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(widths.count, expectedCount, file: file, line: line)
        XCTAssertEqual(widths.reduce(0, +), 100, accuracy: 0.5, file: file, line: line)
        XCTAssertTrue(widths.allSatisfy { $0 >= 12 }, file: file, line: line)
    }
}

private extension String {
    func numberOfMatches(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }

    func contentSecurityPolicyMetaContent() -> String? {
        firstMatch(for: #"<meta http-equiv="Content-Security-Policy" content="([^"]+)">"#)?.decodedHTMLAttribute
    }

    func firstMatch(for pattern: String) -> String? {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(startIndex..<endIndex, in: self)
        guard
            let match = regex.firstMatch(in: self, range: range),
            let matchRange = Range(match.range(at: 1), in: self)
        else {
            return nil
        }

        return String(self[matchRange])
    }

    var decodedHTMLAttribute: String {
        replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    func cssVariable(_ name: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let regex = try! NSRegularExpression(pattern: #"\#(escapedName):\s*([^;]+);"#)
        let range = NSRange(startIndex..<endIndex, in: self)
        guard
            let match = regex.firstMatch(in: self, range: range),
            let valueRange = Range(match.range(at: 1), in: self)
        else {
            return nil
        }

        return String(self[valueRange])
    }

    var styleSheetBody: String {
        guard
            let styleStart = range(of: "<style>")?.upperBound,
            let styleEnd = range(of: "</style>")?.lowerBound
        else {
            return ""
        }

        let style = self[styleStart..<styleEnd]
        guard let rootEnd = style.range(of: "\n}\n")?.upperBound else {
            return String(style)
        }

        return String(style[rootEnd...])
    }

    func tableColumnWidths() -> [Double] {
        let regex = try! NSRegularExpression(pattern: #"<col style="width: ([0-9.]+)%">"#)
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, range: range).compactMap { match in
            guard
                let widthRange = Range(match.range(at: 1), in: self)
            else {
                return nil
            }
            return Double(self[widthRange])
        }
    }

    var bodyContent: String {
        guard
            let bodyStart = range(of: "<body>")?.upperBound,
            let bodyEnd = range(of: "</body>")?.lowerBound
        else {
            return ""
        }

        return String(self[bodyStart..<bodyEnd])
    }

    var idAttributeValues: [String] {
        let regex = try! NSRegularExpression(pattern: #"\sid="([^"]+)""#)
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, range: range).compactMap { match in
            guard let idRange = Range(match.range(at: 1), in: self) else {
                return nil
            }
            return String(self[idRange])
        }
    }
}

private extension Array where Element == Double {
    var widestColumnIndex: Int? {
        indices.max { self[$0] < self[$1] }
    }
}
