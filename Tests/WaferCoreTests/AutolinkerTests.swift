import XCTest
@testable import WaferCore

final class AutolinkerTests: XCTestCase {
    func testSegmentsBareHTTPAndHTTPSURLs() {
        assertSegments(
            "Visit https://example.com/docs and http://example.org.",
            [
                .plain("Visit "),
                .link(text: "https://example.com/docs", href: "https://example.com/docs"),
                .plain(" and "),
                .link(text: "http://example.org", href: "http://example.org"),
                .plain("."),
            ]
        )
    }

    func testSegmentsWWWURLsWithHTTPHref() {
        assertSegments(
            "Open www.example.com/docs.",
            [
                .plain("Open "),
                .link(text: "www.example.com/docs", href: "http://www.example.com/docs"),
                .plain("."),
            ]
        )
    }

    func testSegmentsBareEmailsWithMailtoHref() {
        assertSegments(
            "Email hello@example.com, not hello@example.",
            [
                .plain("Email "),
                .link(text: "hello@example.com", href: "mailto:hello@example.com"),
                .plain(", not hello@example."),
            ]
        )
    }

    func testTrimsTrailingPunctuation() {
        assertSegments(
            #"See https://example.com/path?q=1, then "https://example.org";"#,
            [
                .plain("See "),
                .link(text: "https://example.com/path?q=1", href: "https://example.com/path?q=1"),
                .plain(#", then ""#),
                .link(text: "https://example.org", href: "https://example.org"),
                .plain(#"";"#),
            ]
        )
    }

    func testKeepsBalancedParenthesesAndTrimsUnbalancedClosingParen() {
        assertSegments(
            "(see https://example.com/a_(b)) and https://example.com/path_(ok)",
            [
                .plain("(see "),
                .link(text: "https://example.com/a_(b)", href: "https://example.com/a_(b)"),
                .plain(") and "),
                .link(text: "https://example.com/path_(ok)", href: "https://example.com/path_(ok)"),
            ]
        )
    }

    func testDoesNotLinkInvalidURLs() {
        assertSegments(
            "Leave https:// and www. alone.",
            [
                .plain("Leave https:// and www. alone."),
            ]
        )
    }

    func testDoesNotLinkURLsEmbeddedInWords() {
        assertSegments(
            "prefixhttps://example.com and awordwww.example.com stay plain.",
            [
                .plain("prefixhttps://example.com and awordwww.example.com stay plain."),
            ]
        )
    }

    func testKeepsUnicodePathCharactersInsideURL() {
        assertSegments(
            "Read https://example.com/привет.",
            [
                .plain("Read "),
                .link(text: "https://example.com/привет", href: "https://example.com/привет"),
                .plain("."),
            ]
        )
    }

    private func assertSegments(
        _ text: String,
        _ expected: [Autolinker.Segment],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(Autolinker.segments(in: text), expected, file: file, line: line)
    }
}
