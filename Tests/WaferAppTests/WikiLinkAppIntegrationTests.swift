import AppKit
import Foundation
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class WikiLinkAppIntegrationTests: XCTestCase {
    func testWikiLinkClickNavigatesInTabAndPushesHistory() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A\n\n[[B]]")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B\n\n## Setup")

        let reader = RecordingReaderViewController()
        var renderExpectations: [String: XCTestExpectation] = [:]
        let document = MarkdownReaderDocument(
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { _, baseURL, _, _, _ in
                if let name = baseURL?.lastPathComponent {
                    renderExpectations.removeValue(forKey: name)?.fulfill()
                }
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = fileA
        try document.read(from: Data("# A\n\n[[B]]".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }

        let wikiURL = try XCTUnwrap(WikiLinkURL.url(for: fileB, anchorID: "setup"))
        let navigated = expectation(description: "wiki navigation to B")
        renderExpectations["B.md"] = navigated
        reader.onOpenLink?(wikiURL)
        wait(for: [navigated], timeout: 5)

        XCTAssertEqual(document.fileURL, fileB)
        XCTAssertTrue(document.navigationHistory.canGoBack)
        XCTAssertEqual(
            document.navigationHistory.backEntries.last,
            WindowNavigationHistoryEntry(fileURL: fileA)
        )
    }

    func testModifierClickOnWikiOrMarkdownLinkOpensNewTab() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A\n\n[[B]]")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")
        let fileC = try tempDirectory.createTextFile(named: "C.md", contents: "# C")

        let reader = RecordingReaderViewController()
        var externalTargets: [LinkTarget] = []
        let document = MarkdownReaderDocument(
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} },
            linkTargetHandler: { externalTargets.append($0) },
            readerControllerFactory: { reader }
        )
        document.fileURL = fileA
        try document.read(from: Data("# A\n\n[[B]]".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()

        let host = try XCTUnwrap(document.windowControllers.first as? DocumentHostWindowController)
        host.tabDocumentFactoryForTesting = { url in
            let tabReader = RecordingReaderViewController()
            let tabDocument = MarkdownReaderDocument(
                scrollStateStore: makeTestScrollStateStore(),
                renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} },
                readerControllerFactory: { tabReader }
            )
            tabDocument.fileURL = url
            try? tabDocument.read(from: Data("# \(url.lastPathComponent)".utf8), ofType: "dev.wafer.markdown")
            return tabDocument
        }
        defer {
            for tab in host.tabs {
                tab.document.close()
            }
        }

        // A wiki destination opens as a NEW tab; the originating tab stays put.
        let wikiURL = try XCTUnwrap(WikiLinkURL.url(for: fileB, anchorID: nil))
        reader.onOpenLinkInNewTab?(wikiURL)
        XCTAssertEqual(host.tabs.count, 2)
        XCTAssertEqual(document.fileURL, fileA)
        XCTAssertEqual(host.activeTab.document.fileURL, fileB)

        // Plain local markdown links behave the same way.
        reader.onOpenLinkInNewTab?(fileC)
        XCTAssertEqual(host.tabs.count, 3)
        XCTAssertEqual(host.activeTab.document.fileURL, fileC)

        // External links keep the plain-click path and never grow the strip.
        reader.onOpenLinkInNewTab?(URL(string: "https://example.com")!)
        XCTAssertEqual(host.tabs.count, 3)
        XCTAssertEqual(externalTargets.count, 1)
    }

    func testLibraryChangeRerendersOnlyWikiBearingDocumentsOnRealIndexChange() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "See [[Guide]]")

        let reader = RecordingReaderViewController()
        var renderCount = 0
        var completions: [(WebKitRenderOutput) -> Void] = []
        var currentIndex: WikiLinkIndex? = nil
        let document = MarkdownReaderDocument(
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { _, _, _, _, completion in
                renderCount += 1
                completions.append(completion)
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            wikiLinkIndexProvider: { currentIndex }
        )
        document.fileURL = fileA
        try document.read(from: Data("See [[Guide]]".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        XCTAssertEqual(renderCount, 1)

        // Output without wiki links: library changes never re-render.
        completions[0](WebKitRenderOutput(html: "<html>plain</html>", baseURL: nil, hasWikiLinks: false))
        currentIndex = WikiLinkIndex(entries: [(fileA, "A")])
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        XCTAssertEqual(renderCount, 1)

        // Wiki-bearing output + a CHANGED index: exactly one re-render.
        try Data("See [[Guide]] updated".utf8).write(to: fileA)
        document.reloadDocument(nil)
        let reloaded = expectation(description: "reload scheduled")
        Task { @MainActor in
            while renderCount < 2 {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            reloaded.fulfill()
        }
        wait(for: [reloaded], timeout: 5)
        completions[1](WebKitRenderOutput(html: "<html>wiki</html>", baseURL: nil, hasWikiLinks: true))

        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        XCTAssertEqual(renderCount, 2, "unchanged index must not re-render")

        MainActor.assumeIsolated { currentIndex = WikiLinkIndex(entries: [(fileA, "A"), (fileA.deletingLastPathComponent().appendingPathComponent("Guide.md"), "Guide")]) }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        XCTAssertEqual(renderCount, 3, "changed index with wiki-bearing output re-renders")
    }

    func testExportedWikiHrefRelativizesAgainstDocumentDirectory() throws {
        let documentURL = URL(fileURLWithPath: "/vault/docs/Current.md")
        let inVault = try XCTUnwrap(
            WikiLinkURL.url(for: URL(fileURLWithPath: "/vault/docs/Guide Notes.md"), anchorID: "setup")
        )
        XCTAssertEqual(
            DocumentExportController.exportedWikiHref(for: inVault.absoluteString, documentURL: documentURL),
            "Guide%20Notes.md#setup"
        )

        let outside = try XCTUnwrap(
            WikiLinkURL.url(for: URL(fileURLWithPath: "/elsewhere/Note.md"), anchorID: nil)
        )
        XCTAssertEqual(
            DocumentExportController.exportedWikiHref(for: outside.absoluteString, documentURL: documentURL),
            URL(fileURLWithPath: "/elsewhere/Note.md").absoluteString
        )

        XCTAssertNil(DocumentExportController.exportedWikiHref(for: "https://example.com", documentURL: documentURL))
    }

    func testExportSanitizerRewritesWikiHrefsAndDropsUnrewritables() throws {
        let html = #"<p><a class="md-wikilink" href="wafer-wiki://open?path=/vault/Guide.md">Guide</a> and <a class="md-wikilink" href="wafer-wiki://open?path=/gone/Nope.md">Nope</a></p>"#

        let rewritten = try ExportSanitizer.sanitize(
            domHTML: html,
            policy: ExportSanitizer.ExportPolicy(
                inlineImage: { _ in nil },
                rewriteWikiLinkHref: { href in
                    href.contains("/vault/") ? "Guide.md" : nil
                }
            )
        )

        XCTAssertTrue(rewritten.contains(#"<a class="md-wikilink" href="Guide.md">Guide</a>"#))
        XCTAssertTrue(rewritten.contains(#"<a class="md-wikilink">Nope</a>"#))
        XCTAssertFalse(rewritten.contains("wafer-wiki"))
    }
}
