import Foundation
import XCTest
@testable import WaferCore

final class ExportSanitizerTests: XCTestCase {
    func testStripsScriptsRewritesCSPAndEnsuresDoctype() throws {
        let html = """
        <html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-abc';">
        </head><body><script nonce="abc">alert(1)</script><p>Safe</p><script src="wafer-local://asset?path=/tmp/mermaid.js"></script></body></html>
        """

        let sanitized = try sanitize(html)

        XCTAssertTrue(sanitized.hasPrefix("<!doctype html>"))
        XCTAssertEqual(sanitized.contentSecurityPolicyMetaContent(), ExportSanitizer.exportedContentSecurityPolicy)
        XCTAssertTrue(sanitized.contains("<p>Safe</p>"))
        XCTAssertFalse(sanitized.lowercased().contains("<script"))
        XCTAssertFalse(sanitized.contains("alert(1)"))
        XCTAssertFalse(sanitized.contains("nonce-abc"))
        XCTAssertFalse(sanitized.contains("wafer-local:"))
    }

    func testStripsChromeNodesUsingSharedContract() throws {
        let html = """
        <!doctype html><html><head></head><body>
        <figure><button type="button" data-wafer-chrome="true">Open</button><svg><text>Diagram</text></svg></figure>
        <div data-wafer-chrome="true"><div><span>Inspector</span></div></div>
        <p>Kept</p>
        </body></html>
        """

        let sanitized = try sanitize(html)

        XCTAssertTrue(sanitized.contains("<svg><text>Diagram</text></svg>"))
        XCTAssertTrue(sanitized.contains("<p>Kept</p>"))
        XCTAssertFalse(sanitized.contains("data-wafer-chrome"))
        XCTAssertFalse(sanitized.contains("Open"))
        XCTAssertFalse(sanitized.contains("Inspector"))
    }

    func testInlinesResolvableImagesAndDropsUnresolvableImages() throws {
        let html = """
        <!doctype html><html><head></head><body>
        <img src="wafer-local://asset?path=/tmp/ok.png" srcset="wafer-local://asset?path=/tmp/two.png 2x" data-preview="cached wafer-remote://image?url=https://example.com/a.png" alt="OK">
        <img src="wafer-local://asset?path=/tmp/missing.png" alt="Missing">
        </body></html>
        """

        let sanitized = try sanitize(html) { source in
            source.contains("ok.png") ? "data:image/png;base64,QUJD" : nil
        }

        XCTAssertTrue(sanitized.contains("<img src=\"data:image/png;base64,QUJD\" alt=\"OK\">"))
        XCTAssertFalse(sanitized.contains("Missing"))
        XCTAssertFalse(sanitized.contains("wafer-local:"))
        XCTAssertFalse(sanitized.contains("wafer-remote:"))
    }

    func testInlinesPictureSourceSrcSetCandidatesAndDiscoversRemoteSources() throws {
        let remoteSource = "wafer-remote://image?url=https://example.com/dark@2.png"
        let html = """
        <!doctype html><html><head></head><body>
        <picture>
        <source media="(prefers-color-scheme: dark)" type="image/png" srcset="wafer-local://asset?path=/tmp/dark.png 1x, \(remoteSource) 2x" data-preview="wafer-local://asset?path=/tmp/drop.png">
        <img src="wafer-local://asset?path=/tmp/light.png" alt="Logo">
        </picture>
        </body></html>
        """

        XCTAssertEqual(ExportSanitizer.remoteImageSources(in: html), [remoteSource])

        let sanitized = try sanitize(html) { source in
            if source.contains("dark.png") {
                return "data:image/png;base64,REFSSw=="
            }
            if source.contains("dark@2.png") {
                return "data:image/png;base64,REFSSzJY"
            }
            if source.contains("light.png") {
                return "data:image/png;base64,TElHSFQ="
            }
            return nil
        }

        XCTAssertTrue(sanitized.contains(#"<source media="(prefers-color-scheme: dark)" type="image/png" srcset="data:image/png;base64,REFSSw== 1x, data:image/png;base64,REFSSzJY 2x">"#))
        XCTAssertTrue(sanitized.contains(#"<img src="data:image/png;base64,TElHSFQ=" alt="Logo">"#))
        XCTAssertFalse(sanitized.contains("wafer-local:"))
        XCTAssertFalse(sanitized.contains("wafer-remote:"))
        XCTAssertFalse(sanitized.contains("data-preview"))
    }

    func testDropsPictureSourceWhenAnySrcSetCandidateCannotInline() throws {
        let html = """
        <!doctype html><html><head></head><body>
        <picture>
        <source media="(prefers-color-scheme: dark)" srcset="wafer-local://asset?path=/tmp/dark.png 1x, wafer-local://asset?path=/tmp/missing.png 2x">
        <img src="wafer-local://asset?path=/tmp/light.png" alt="Logo">
        </picture>
        </body></html>
        """

        let sanitized = try sanitize(html) { source in
            source.contains("missing.png") ? nil : "data:image/png;base64,SU1H"
        }

        XCTAssertFalse(sanitized.contains("<source"))
        XCTAssertTrue(sanitized.contains(#"<img src="data:image/png;base64,SU1H" alt="Logo">"#))
        XCTAssertFalse(sanitized.contains("wafer-local:"))
    }

    func testMermaidSVGPassesThroughUntouched() throws {
        let svg = #"<svg viewBox="0 0 10 10"><style>.node{fill:red}</style><path d="M0 0L10 10"></path><text>A --> B</text></svg>"#
        let html = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none';">
        </head><body><div class="md-mermaid-output">\(svg)</div></body></html>
        """

        let sanitized = try sanitize(html)

        XCTAssertTrue(sanitized.contains(svg))
    }

    func testDropsWaferSchemeAttributesOutsideImages() throws {
        let html = """
        <!doctype html><html><head></head><body>
        <a href="wafer-local://asset?path=/tmp/file.md" title="Local">Local link</a>
        <div data-preview="wafer-remote://image?url=https://example.com/a.png">Preview</div>
        </body></html>
        """

        let sanitized = try sanitize(html)

        XCTAssertTrue(sanitized.contains("<a title=\"Local\">Local link</a>"))
        XCTAssertTrue(sanitized.contains("<div>Preview</div>"))
        XCTAssertFalse(sanitized.contains("wafer-local:"))
        XCTAssertFalse(sanitized.contains("wafer-remote:"))
    }

    func testSanitizingAlreadySanitizedOutputIsNoOp() throws {
        let html = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none';">
        </head><body><img src="wafer-local://asset?path=/tmp/ok.png" alt="OK"><p>Done</p></body></html>
        """
        let once = try sanitize(html) { _ in "data:image/png;base64,QUJD" }
        let twice = try sanitize(once) { _ in XCTFail("Data images should not be re-inlined"); return nil }

        XCTAssertEqual(twice, once)
    }

    func testInjectsExportedCSPIntoHeadlessFragmentAfterEnsuringDoctype() throws {
        let sanitized = try sanitize("<main><p>Safe</p></main>")

        XCTAssertTrue(sanitized.hasPrefix("<!doctype html>\n<meta http-equiv=\"Content-Security-Policy\""))
        XCTAssertEqual(sanitized.contentSecurityPolicyMetaContent(), ExportSanitizer.exportedContentSecurityPolicy)
        XCTAssertEqual(sanitized.contentSecurityPolicyMetaCount, 1)
        XCTAssertTrue(sanitized.contains("<main><p>Safe</p></main>"))
    }

    func testInjectsExportedCSPAfterExistingDoctypeWhenHeadIsMissing() throws {
        let sanitized = try sanitize("<!doctype html>\n<main><p>Safe</p></main>")

        XCTAssertTrue(sanitized.hasPrefix("<!doctype html>\n<meta http-equiv=\"Content-Security-Policy\""))
        XCTAssertEqual(sanitized.contentSecurityPolicyMetaContent(), ExportSanitizer.exportedContentSecurityPolicy)
        XCTAssertEqual(sanitized.contentSecurityPolicyMetaCount, 1)
        XCTAssertTrue(sanitized.contains("<main><p>Safe</p></main>"))
    }

    private func sanitize(
        _ html: String,
        inlineImage: @escaping (String) throws -> String? = { _ in nil }
    ) throws -> String {
        try ExportSanitizer.sanitize(
            domHTML: html,
            policy: ExportSanitizer.ExportPolicy(inlineImage: inlineImage)
        )
    }
}

private extension String {
    var contentSecurityPolicyMetaCount: Int {
        let regex = try! NSRegularExpression(pattern: #"<meta http-equiv="Content-Security-Policy""#)
        return regex.numberOfMatches(in: self, range: NSRange(startIndex..<endIndex, in: self))
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
}
