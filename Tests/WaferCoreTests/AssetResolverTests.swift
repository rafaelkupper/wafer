import XCTest
@testable import WaferCore

final class AssetResolverTests: XCTestCase {
    private let resolver = AssetResolver()

    func testResolvesRelativeMarkdownLinkAgainstBaseURL() {
        let baseURL = URL(fileURLWithPath: "/tmp/docs/readme.md")

        let result = resolver.linkTarget(for: "guide/intro.md", relativeTo: baseURL)

        guard case let .markdownFile(url) = result else {
            return XCTFail("Expected markdown file target, got \(result)")
        }

        XCTAssertEqual(url.path, "/tmp/docs/guide/intro.md")
        XCTAssertNil(url.fragment)
    }

    func testRecognizesExternalHTTPLinks() {
        let result = resolver.linkTarget(for: "https://example.com", relativeTo: nil)

        XCTAssertEqual(result, .external(URL(string: "https://example.com")!))
    }

    func testImageResolutionAllowsHTTPSRemoteImagesOnly() {
        let remoteURL = resolver.imageURL(for: "https://example.com/image.png", relativeTo: nil)

        XCTAssertEqual(remoteURL, URL(string: "https://example.com/image.png"))
        XCTAssertTrue(remoteURL.map(resolver.isRemoteImageURL) == true)
        XCTAssertNil(resolver.imageURL(for: "http://example.com/image.png", relativeTo: nil))
        XCTAssertNil(resolver.imageURL(for: "ftp://example.com/image.png", relativeTo: nil))
        XCTAssertNil(resolver.imageURL(for: "data:image/png;base64,aaaa", relativeTo: nil))
    }

    func testResolvesFragmentOnlyLinksAgainstBaseDocument() {
        let baseURL = URL(fileURLWithPath: "/tmp/docs/readme.md")

        let resolved = resolver.resolve(destination: "#section-1", relativeTo: baseURL)

        XCTAssertEqual(resolved?.path, "/tmp/docs/readme.md")
        XCTAssertEqual(resolved?.fragment, "section-1")
    }

    func testResolvesAbsoluteFilePaths() {
        let resolved = resolver.resolve(destination: "/tmp/docs/notes.md", relativeTo: nil)

        XCTAssertEqual(resolved?.path, "/tmp/docs/notes.md")
        XCTAssertNil(resolved?.fragment)
    }

    func testClassifiesLocalNonMarkdownFiles() {
        let result = resolver.classify(URL(fileURLWithPath: "/tmp/docs/image.png"))

        XCTAssertEqual(result, .otherFile(URL(fileURLWithPath: "/tmp/docs/image.png")))
    }

    func testEmptyDestinationsRemainUnresolved() {
        let result = resolver.linkTarget(for: "   ", relativeTo: URL(fileURLWithPath: "/tmp/docs/readme.md"))

        XCTAssertEqual(result, .unresolved("   "))
    }

    func testRelativeMarkdownLinksPreserveFragments() {
        let baseURL = URL(fileURLWithPath: "/tmp/docs/readme.md")

        let result = resolver.linkTarget(for: "guide/intro.md#deep-link", relativeTo: baseURL)

        guard case let .markdownFile(url) = result else {
            return XCTFail("Expected markdown file target, got \(result)")
        }

        XCTAssertEqual(url.path, "/tmp/docs/guide/intro.md")
        XCTAssertEqual(url.fragment, "deep-link")
    }
}
