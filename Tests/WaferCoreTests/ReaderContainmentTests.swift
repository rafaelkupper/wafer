import WebKit
import XCTest
@testable import WaferCore

@MainActor
final class ReaderContainmentTests: XCTestCase {
    func testRawHTMLAcrossMarkdownContainersCannotCloseReaderColumn() async throws {
        let sources = [
            "> <div>\n> inside\n\n</div>\n\nAfter boundary.",
            "<div>\n\n- </div>\n\n</div>\n\nAfter boundary.",
            "> <div>\n> inside\n\n- </div>\n\nAfter boundary.",
        ]
        try await assertContained(sources.map { source in
            WebKitHTMLRenderer().render(document: MarkdownParser().parse(source: source, baseURL: nil)).html
        })
    }

    func testSeededHTMLAndMarkdownPreserveSanitizerInvariants() async throws {
        var random = SeededGenerator(state: 0x5741464552)
        let fragments = [
            "<div>", "</div>", "<blockquote>", "</blockquote>", "<ul><li>", "</li></ul>",
            "<table><tr><td>", "</td></tr></table>", "<p>", "</p>", "<b><i>", "</b></i>",
            "<details><summary>Title</summary>", "</details>", "</main></body></html>",
            "<script>alert(1)</script>", "<ScRiPt src='x'>bad</ScRiPt>",
            "<img src='javascript:alert(1)' onerror='bad()'>",
            "<a href='jav&#x61;script:bad()' onclick='bad()'>bad</a>",
            "<a href='java&#10;script:bad()'>bad</a>",
            "<img src='image%20one.png' onload=bad()>",
            "<svg onload='bad()'><script>bad()</script></svg>",
            "<span title='x > y' ONMOUSEOVER='bad()'>ok</span>", "<!-- <script> -->", "<", "&lt;script&gt;",
        ]
        let sanitizer = HTMLSanitizer(policy: .init(
            resolveImageSource: { source in
                guard LinkURLPolicy.allows(source) else { return nil }
                return AssetResolver().imageURL(for: source, relativeTo: URL(fileURLWithPath: "/tmp/note.md"))?.absoluteString
            },
            resolveLinkHref: { LinkURLPolicy.allows($0) ? $0 : nil }
        ))
        var documents: [String] = []
        for _ in 0..<128 {
            let html = (0..<16).map { _ in fragments[random.next(fragments.count)] }.joined()
            documents.append("<main id=\"write\">" + sanitizer.sanitize(html) + "<p>After boundary.</p></main>")
            let markdown = "> " + html + "\n\n- " + fragments[random.next(fragments.count)] +
                "\n\n[bad](javascript:alert(1)) ![bad](javascript:alert(1))\n\nAfter boundary."
            for target in [RenderTarget.reader, .preview] {
                documents.append(WebKitHTMLRenderer(target: target).render(
                    document: MarkdownParser().parse(source: markdown, baseURL: nil)).html)
            }
        }
        try await assertContained(documents)
    }

    private func assertContained(_ documents: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        let webView = WKWebView()
        // A DOMParser exercises WebKit's HTML tree builder without fetching document assets.
        let result = try await webView.callAsyncJavaScript("""
        return documents.map(html => {
            const doc = new DOMParser().parseFromString(html, 'text/html');
            const write = doc.getElementById('write');
            return !!write && write.textContent.includes('After boundary.') &&
                [...doc.body.children].every(node => node === write) &&
                !doc.querySelector('script') && [...doc.querySelectorAll('*')].every(node =>
                    [...node.attributes].every(attribute => !/^on/i.test(attribute.name) &&
                        (!['href', 'src', 'srcset', 'action', 'xlink:href'].includes(attribute.name) ||
                         !attribute.value.replace(/[\\u0000-\\u0020]/g, '').toLowerCase().includes('javascript:'))));
        });
        """, arguments: ["documents": documents], in: nil, contentWorld: .page)
        let contained = try XCTUnwrap(result as? [Bool], file: file, line: line)
        XCTAssertEqual(contained, Array(repeating: true, count: documents.count), file: file, line: line)
    }
}

private struct SeededGenerator {
    var state: UInt64
    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 32) % UInt64(upperBound))
    }
}
