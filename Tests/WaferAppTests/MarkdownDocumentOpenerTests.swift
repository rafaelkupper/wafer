import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class MarkdownDocumentOpenerTests: XCTestCase {
    func testSupportsRecognizedMarkdownExtensionsOnly() {
        XCTAssertTrue(MarkdownDocumentOpener.supports(url: URL(fileURLWithPath: "/tmp/docs/readme.md")))
        XCTAssertTrue(MarkdownDocumentOpener.supports(url: URL(fileURLWithPath: "/tmp/docs/readme.markdown")))
        XCTAssertFalse(MarkdownDocumentOpener.supports(url: URL(fileURLWithPath: "/tmp/docs/readme.txt")))
        XCTAssertFalse(MarkdownDocumentOpener.supports(url: URL(string: "https://example.com/readme.md")!))
    }

    func testNormalizedFileURLUsesSharedCoreIdentity() {
        let url = URL(fileURLWithPath: "/tmp/../tmp/Wafer.md")

        XCTAssertEqual(MarkdownDocumentOpener.normalizedFileURL(for: url), FileIdentity.normalized(url))
        XCTAssertEqual(OpenDocumentRegistry.identityForTesting(url), FileIdentity.identity(for: url))
    }

    func testAnchorIDsArePercentDecoded() throws {
        let base = URL(fileURLWithPath: "/tmp/docs/Guide.md")
        func link(_ fragment: String?) throws -> URL {
            var components = try XCTUnwrap(URLComponents(url: base, resolvingAgainstBaseURL: false))
            components.fragment = fragment
            return try XCTUnwrap(components.url)
        }

        XCTAssertEqual(MarkdownDocumentOpener.anchorID(in: try link("café")), "café")
        XCTAssertEqual(MarkdownDocumentOpener.anchorID(in: try link("日本語")), "日本語")
        XCTAssertEqual(MarkdownDocumentOpener.anchorID(in: try link("section-1")), "section-1")
        XCTAssertEqual(MarkdownDocumentOpener.anchorID(in: try XCTUnwrap(URL(string: "file:///tmp/docs/Guide.md#caf%C3%A9"))), "café")
        XCTAssertEqual(MarkdownDocumentOpener.anchorID(in: try XCTUnwrap(URL(string: "#%E6%97%A5%E6%9C%AC%E8%AA%9E", relativeTo: base))), "日本語")
        XCTAssertNil(MarkdownDocumentOpener.anchorID(in: try link("")))
        XCTAssertNil(MarkdownDocumentOpener.anchorID(in: base))
    }

    func testOpeningALinkWithAnEncodedFragmentScrollsToTheDecodedAnchor() throws {
        _ = NSApplication.shared
        defer { closeOpenMarkdownDocuments() }
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "Anchors.md", contents: "# Café\n\n## 日本語")
        let reader = RecordingReaderViewController()
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { _, baseURL, _, _, completion in
                completion(WebKitRenderOutput(html: "<html></html>", baseURL: baseURL))
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            fileMonitorFactory: { _, _ in OpenerTestFileMonitor() }
        )
        var components = try XCTUnwrap(URLComponents(url: fileURL, resolvingAgainstBaseURL: false))
        components.fragment = "café"

        try MarkdownDocumentOpener.open(url: try XCTUnwrap(components.url), documentFactory: { document })
        let deadline = Date(timeIntervalSinceNow: 10)
        while reader.appliedOutputs.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        reader.stubbedContentReady = true
        reader.onNavigationFinished?()
        XCTAssertEqual(reader.scrolledHeadingIDs, ["café"])

        // A second link into the open document scrolls it at once.
        components.fragment = "日本語"
        try MarkdownDocumentOpener.open(url: try XCTUnwrap(components.url))
        XCTAssertEqual(reader.scrolledHeadingIDs, ["café", "日本語"])
    }

    func testOpenRetainsDocumentUntilItCloses() throws {
        _ = NSApplication.shared
        defer { closeOpenMarkdownDocuments() }
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "Retain.md", contents: "# Retain\n\nBody")
        let initialRetainedCount = MarkdownDocumentOpener.retainedDocumentCountForTesting

        try MarkdownDocumentOpener.open(url: fileURL, documentFactory: { MarkdownReaderDocument(librarySnapshotProvider: emptyTestLibrarySnapshot, scrollStateStore: makeTestScrollStateStore()) })

        XCTAssertEqual(MarkdownDocumentOpener.retainedDocumentCountForTesting, initialRetainedCount + 1)

        let openedDocument = try XCTUnwrap(
            NSDocumentController.shared.documents
                .compactMap { $0 as? MarkdownReaderDocument }
                .last(where: { $0.fileURL == fileURL })
        )

        openedDocument.close()

        XCTAssertEqual(MarkdownDocumentOpener.retainedDocumentCountForTesting, initialRetainedCount)
    }

    func testAFileOutsideTheGrantsOpensOnlyAfterTheUserGrantsItsFolder() throws {
        _ = NSApplication.shared
        defer { closeOpenMarkdownDocuments() }
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "Linked.md", contents: "# Linked")
        let access = installSandboxedFolderAccess()
        let initialRetainedCount = MarkdownDocumentOpener.retainedDocumentCountForTesting
        let makeDocument = { MarkdownReaderDocument(librarySnapshotProvider: emptyTestLibrarySnapshot, scrollStateStore: makeTestScrollStateStore()) }

        FolderAccessFlow.chooseFolder = { _, _, completion in completion(nil) }
        try MarkdownDocumentOpener.open(url: fileURL, documentFactory: makeDocument)
        XCTAssertEqual(MarkdownDocumentOpener.retainedDocumentCountForTesting, initialRetainedCount)

        var requests: [FolderAccessRequest] = []
        FolderAccessFlow.chooseFolder = { request, _, completion in
            requests.append(request)
            completion(request.suggestedFolder)
        }
        try MarkdownDocumentOpener.open(url: fileURL, documentFactory: makeDocument)

        XCTAssertEqual(requests.map(\.suggestedFolder.path), [tempDirectory.url.path])
        XCTAssertEqual(MarkdownDocumentOpener.retainedDocumentCountForTesting, initialRetainedCount + 1)
        XCTAssertTrue(access.store.covers(fileURL))
    }

    func testOpeningSameFileTwiceReusesExistingDocument() throws {
        _ = NSApplication.shared
        defer { closeOpenMarkdownDocuments() }
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "Reuse.md", contents: "# Reuse")

        try MarkdownDocumentOpener.open(url: fileURL, documentFactory: { MarkdownReaderDocument(librarySnapshotProvider: emptyTestLibrarySnapshot, scrollStateStore: makeTestScrollStateStore()) })
        let initialDocuments = openMarkdownDocuments()
        let initialWindows = initialDocuments.flatMap(\.windowControllers).compactMap(\.window)

        try MarkdownDocumentOpener.open(url: fileURL, documentFactory: { MarkdownReaderDocument(librarySnapshotProvider: emptyTestLibrarySnapshot, scrollStateStore: makeTestScrollStateStore()) })

        let finalDocuments = openMarkdownDocuments()
        XCTAssertEqual(finalDocuments.count, 1)
        XCTAssertEqual(initialDocuments.first, finalDocuments.first)
        XCTAssertEqual(initialWindows.first, finalDocuments.first?.windowControllers.first?.window)
    }

    func testOpeningFileWithFragmentReusesExistingDocument() throws {
        _ = NSApplication.shared
        defer { closeOpenMarkdownDocuments() }
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "Fragment.md", contents: "# Fragment")
        var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
        components?.fragment = "section-1"
        let fileURLWithFragment = try XCTUnwrap(components?.url)

        try MarkdownDocumentOpener.open(url: fileURL, documentFactory: { MarkdownReaderDocument(librarySnapshotProvider: emptyTestLibrarySnapshot, scrollStateStore: makeTestScrollStateStore()) })
        try MarkdownDocumentOpener.open(url: fileURLWithFragment, documentFactory: { MarkdownReaderDocument(librarySnapshotProvider: emptyTestLibrarySnapshot, scrollStateStore: makeTestScrollStateStore()) })

        let documents = openMarkdownDocuments()
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents.first?.fileURL, MarkdownDocumentOpener.normalizedFileURL(for: fileURL))
    }

    func testOpeningDifferentFileCreatesSecondDocumentAndCascadesWindow() throws {
        _ = NSApplication.shared
        defer { closeOpenMarkdownDocuments() }
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let firstURL = try tempDirectory.createTextFile(named: "One.md", contents: "# One")
        let secondURL = try tempDirectory.createTextFile(named: "Two.md", contents: "# Two")

        try MarkdownDocumentOpener.open(url: firstURL, documentFactory: { MarkdownReaderDocument(librarySnapshotProvider: emptyTestLibrarySnapshot, scrollStateStore: makeTestScrollStateStore()) })
        let firstDocument = try XCTUnwrap(openMarkdownDocuments().last)
        let firstWindow = try XCTUnwrap(firstDocument.windowControllers.first?.window)

        try MarkdownDocumentOpener.open(url: secondURL, documentFactory: { MarkdownReaderDocument(librarySnapshotProvider: emptyTestLibrarySnapshot, scrollStateStore: makeTestScrollStateStore()) })

        let documents = openMarkdownDocuments()
        XCTAssertEqual(documents.count, 2)
        let secondDocument = try XCTUnwrap(documents.last(where: { $0.fileURL == secondURL }))
        let secondWindow = try XCTUnwrap(secondDocument.windowControllers.first?.window)
        let visibleFrame = try XCTUnwrap(
            secondWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        )
        let expectedFrame = DocumentWindowController.initialFrame(
            contentSize: secondWindow.frame.size,
            visibleFrame: visibleFrame,
            cascadeFrom: firstWindow.frame
        )

        XCTAssertEqual(secondWindow.frame.minX, expectedFrame.minX, accuracy: 1)
        XCTAssertEqual(secondWindow.frame.minY, expectedFrame.minY, accuracy: 1)
        XCTAssertTrue(secondWindow.isVisible)
        XCTAssertTrue(MarkdownDocumentOpener.currentMarkdownWindowForTesting() === secondWindow)
    }

    func testNormalOpenStillReusesPreferredWindowWhenMultipleDocumentsTrackSameFile() throws {
        _ = NSApplication.shared
        defer { closeOpenMarkdownDocuments() }
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let firstURL = try tempDirectory.createTextFile(named: "One.md", contents: "# One")
        let secondURL = try tempDirectory.createTextFile(named: "Two.md", contents: "# Two")

        try MarkdownDocumentOpener.open(url: firstURL, documentFactory: { MarkdownReaderDocument(librarySnapshotProvider: emptyTestLibrarySnapshot, scrollStateStore: makeTestScrollStateStore()) })
        try MarkdownDocumentOpener.open(url: secondURL, documentFactory: { MarkdownReaderDocument(librarySnapshotProvider: emptyTestLibrarySnapshot, scrollStateStore: makeTestScrollStateStore()) })

        let secondDocument = try XCTUnwrap(
            openMarkdownDocuments().first(where: { $0.fileURL == secondURL })
        )
        secondDocument.navigateInCurrentWindow(to: firstURL)

        // The navigation reads the file in the background; wait for it
        // rather than for a fixed time, which a cold first run can exceed.
        let deadline = Date(timeIntervalSinceNow: 10)
        while openMarkdownDocuments().filter({ $0.fileURL == firstURL }).count < 2, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        XCTAssertEqual(openMarkdownDocuments().filter { $0.fileURL == firstURL }.count, 2)

        try MarkdownDocumentOpener.open(url: firstURL, documentFactory: { MarkdownReaderDocument(librarySnapshotProvider: emptyTestLibrarySnapshot, scrollStateStore: makeTestScrollStateStore()) })

        XCTAssertEqual(openMarkdownDocuments().count, 2)
    }

    private func openMarkdownDocuments() -> [MarkdownReaderDocument] {
        NSDocumentController.shared.documents.compactMap { $0 as? MarkdownReaderDocument }
    }

    private func closeOpenMarkdownDocuments() {
        openMarkdownDocuments().forEach { $0.close() }
    }
}

@MainActor
private final class OpenerTestFileMonitor: FileChangeMonitoring {
    func start() {}
    func stop() {}
}
