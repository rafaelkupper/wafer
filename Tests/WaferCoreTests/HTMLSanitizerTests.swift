import XCTest
@testable import WaferCore

final class HTMLSanitizerTests: XCTestCase {
    func testBalancesDetailsSummaryAndUnclosedAllowedTags() {
        XCTAssertEqual(
            sanitize("<details><summary>x</summary>body</details>"),
            "<details><summary>x</summary>body</details>"
        )
        XCTAssertEqual(
            sanitize("<details><summary>x</summary>"),
            "<details><summary>x</summary></details>"
        )
    }

    func testNormalizesVoidTagsAndAllowedFormatting() {
        XCTAssertEqual(sanitize("<br><br/><hr>"), "<br /><br /><hr />")
        XCTAssertEqual(
            sanitize("<DIV align=\"center\" onclick=\"x\">ok</DIV>"),
            "<div align=\"center\">ok</div>"
        )
        XCTAssertEqual(
            sanitize("<span align=\"expression(alert(1))\" style=\"color:red\" class=\"x\">ok</span>"),
            "<span>ok</span>"
        )
        XCTAssertEqual(
            sanitize("<abbr title=\"a &quot;tip&quot;\" data-x=\"1\">API</abbr>"),
            "<abbr title=\"a &quot;tip&quot;\">API</abbr>"
        )
    }

    func testSanitizesRemoteImagesThroughPolicy() {
        let output = sanitize(#"<img src="https://h/a.png?x=1&y=2" alt="a &quot;q&quot;" onerror="alert(1)" width="320" height="bad">"#)

        XCTAssertEqual(
            output,
            #"<img src="wafer-remote://image?url=https://h/a.png?x=1&amp;y=2" alt="a &quot;q&quot;" width="320" />"#
        )
        XCTAssertFalse(output.contains("onerror"))
        XCTAssertFalse(output.contains("height="))
    }

    func testDropsUnsafeImages() {
        XCTAssertEqual(sanitize(#"<img src="javascript:alert(1)" alt="x">"#), "")
        XCTAssertEqual(sanitize(#"<img src="data:image/svg+xml,<svg onload=alert(1)>">"#), "")
        XCTAssertEqual(sanitize(#"<img src="http://h/a.png">"#), "")
    }

    func testSanitizesLinksAndSuppressesEmptyUnsafeAnchors() {
        XCTAssertEqual(
            sanitize(#"<a href="https://h" title="a&quot; onclick=&quot;x">x</a>"#),
            #"<a href="https://h" title="a&quot; onclick=&quot;x">x</a>"#
        )
        XCTAssertEqual(sanitize(#"<a href="mailto:hello@example.com">mail</a>"#), #"<a href="mailto:hello@example.com">mail</a>"#)
        XCTAssertEqual(sanitize(#"<a href="javascript:alert(1)" onclick="x">x</a>"#), "x")
        XCTAssertEqual(sanitize(#"<a href="data:text/html,x">x</a>"#), "x")
    }

    func testDropsRawTextAndDangerousContainersWithContent() {
        XCTAssertEqual(sanitize(#"<script>alert(1)</script>"#), "")
        XCTAssertEqual(sanitize(#"<ScRiPt >alert(1)</sCriPt>"#), "")
        XCTAssertEqual(sanitize(#"<style>body{background:url(https://evil)}</style>"#), "")
        XCTAssertEqual(sanitize(#"<iframe src="https://evil">fallback</iframe>"#), "")
        XCTAssertEqual(sanitize(#"<object>fallback</object><form>submit</form>"#), "")
    }

    func testDropsDangerousVoidAndMetadataTagsWithoutDroppingSiblings() {
        XCTAssertEqual(
            sanitize(#"<meta http-equiv="refresh"><base href="https://evil"><link rel="preload"><embed src="x">safe"#),
            "safe"
        )
    }

    func testTableAttributesAreAllowlisted() {
        XCTAssertEqual(
            sanitize(#"<table><tr><th align="right" colspan="2" rowspan="x" style="x">H</th><td align="justify">C</td></tr></table>"#),
            #"<table><tr><th align="right" colspan="2">H</th><td align="justify">C</td></tr></table>"#
        )
    }

    func testW4StructuralTagsAndExactAttributesAreAllowlisted() {
        let html = #"""
        <h1 onclick="x">Title</h1><blockquote cite="x">Quote</blockquote>
        <figure class="hero"><figcaption>Fig</figcaption></figure>
        <table><caption align="center">Cap</caption><colgroup><col span="2" style="width:1px"></colgroup><tfoot><tr><td>F</td></tr></tfoot></table>
        <dl><dt>Term</dt><dd>Definition</dd></dl><small>Fine</small><u>under</u><q cite="x">quote</q><cite>Cite</cite>
        <time datetime="2026-07-08" onclick="x">date</time><wbr>
        """#

        XCTAssertEqual(
            sanitize(html),
            """
            <h1>Title</h1><blockquote>Quote</blockquote>
            <figure><figcaption>Fig</figcaption></figure>
            <table><caption>Cap</caption><colgroup><col span="2" /></colgroup><tfoot><tr><td>F</td></tr></tfoot></table>
            <dl><dt>Term</dt><dd>Definition</dd></dl><small>Fine</small><u>under</u><q>quote</q><cite>Cite</cite>
            <time datetime="2026-07-08">date</time><wbr />
            """
        )
    }

    func testOrderedListAndSourceSetAttributesFailClosed() {
        XCTAssertEqual(
            sanitize(#"<ol start="3" onclick="x"><li value="7">item</li></ol>"#),
            #"<ol start="3"><li>item</li></ol>"#
        )

        let html = #"""
        <picture class="x">
        <source media="(prefers-color-scheme: dark)" type="image/png" srcset="dark.png 1x, https://cdn.test/dark@2.png 2x, javascript:bad 3x">
        <source media="screen;evil" type="text/html" srcset="light.png 480w">
        <source srcset="javascript:bad 1x">
        <img src="fallback.png" alt="Fallback">
        </picture>
        """#

        XCTAssertEqual(
            sanitize(html),
            """
            <picture>
            <source media="(prefers-color-scheme: dark)" type="image/png" srcset="wafer-local://asset?path=dark.png 1x, wafer-remote://image?url=https://cdn.test/dark@2.png 2x" />
            <source srcset="wafer-local://asset?path=light.png 480w" />

            <img src="wafer-local://asset?path=fallback.png" alt="Fallback" />
            </picture>
            """
        )
    }

    func testPreviewPolicyDropsSourceElementsAndKeepsPictureFallback() {
        let html = #"""
        <picture><source media="(prefers-color-scheme: dark)" srcset="dark.png 1x"><img src="fallback.png" alt="Fallback"></picture>
        """#

        XCTAssertEqual(
            sanitize(html, allowsSourceElements: false),
            #"<picture><img src="wafer-local://asset?path=fallback.png" alt="Fallback" /></picture>"#
        )
    }

    func testW4ExplicitlyBannedTagsStayBanned() {
        XCTAssertEqual(
            sanitize(#"<video src="x">video</video><audio src="x">audio</audio><iframe>iframe</iframe><center>center</center><font>font</font><form>form</form><style>body{}</style>"#),
            "videoaudiocenterfont"
        )
    }

    func testMalformedTagsFailClosedAsText() {
        XCTAssertEqual(sanitize("<"), "&lt;")
        XCTAssertEqual(sanitize("<b onmouseover"), "&lt;b onmouseover")
        XCTAssertEqual(sanitize("<img src="), "&lt;img src=")
        XCTAssertEqual(sanitize("<<script>script>"), "&lt;")
    }

    func testCommentsAreDroppedAndEntitiesRemainText() {
        XCTAssertEqual(sanitize("a<!-- hidden -->&mdash;<mark>b</mark>"), "a&mdash;<mark>b</mark>")
    }

    private func sanitize(_ html: String, allowsSourceElements: Bool = true) -> String {
        HTMLSanitizer(policy: HTMLSanitizerPolicy(
            resolveImageSource: { rawSource in
                if rawSource.hasPrefix("https://") {
                    return "wafer-remote://image?url=\(rawSource)"
                }
                if !rawSource.contains(":") {
                    return "wafer-local://asset?path=\(rawSource)"
                }
                return nil
            },
            resolveLinkHref: { rawHref in
                if rawHref.hasPrefix("http://")
                    || rawHref.hasPrefix("https://")
                    || rawHref.hasPrefix("mailto:")
                    || !rawHref.contains(":") {
                    return rawHref
                }
                return nil
            },
            allowsSourceElements: allowsSourceElements
        )).sanitize(html)
    }
}
