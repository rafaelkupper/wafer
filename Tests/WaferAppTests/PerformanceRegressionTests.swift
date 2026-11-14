import AppKit
import CoreServices
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class PerformanceRegressionTests: XCTestCase {
    func testFileEventsFilterUnrelatedFilesAndRecoverAfterDroppedEvents() {
        let root = URL(fileURLWithPath: "/tmp/vault")
        let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let paths = ["/tmp/vault/Note.md", "/tmp/vault/image.png", "/tmp/vault/.git/hidden.md", "/tmp/vault/node_modules/note.md"]
        XCTAssertEqual(DirectoryChangeMonitor.relevantChanges(paths: paths, flags: Array(repeating: fileFlag, count: paths.count), rootURL: root), ["/tmp/vault/Note.md"])
        XCTAssertNil(DirectoryChangeMonitor.relevantChanges(paths: [paths[0]], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)], rootURL: root))
    }

    func testLargeSidebarRealizesOnlyVisibleRows() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let files = (0..<2000).map { index in
            LibraryFile(fileURL: directory.url.appendingPathComponent("Note-\(index).md"), relativePathComponents: ["Note-\(index).md"],
                displayTitle: "Note \(index)", outlineItems: [], plainText: "Text", searchableText: "Text",
                contentFingerprint: LibraryFileFingerprint(modificationDate: .distantPast, fileSize: 4))
        }
        let center = NotificationCenter()
        let defaults = makeTestUserDefaults()
        let library = LibraryController(preferenceStore: LibraryPreferenceStore(defaults: defaults), notificationCenter: center,
            scanner: { _ in LibraryScanner.Result(files: files, truncated: false) },
            monitorFactory: { _, _ in ReviewDirectoryMonitor() })
        defer { library.closeLibrary() }
        let sidebar = DocumentSidebarViewController(libraryController: library, notificationCenter: center)
        let window = hostInWindow(sidebar, size: NSSize(width: 270, height: 700))
        defer { window.contentViewController = nil; window.close() }
        let scanned = expectation(description: "scan")
        try library.openLibrary(at: directory.url) { _ in scanned.fulfill() }
        wait(for: [scanned], timeout: 5)
        sidebar.setMode(.library)
        sidebar.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(sidebar.libraryRowTitlesForTesting.count, 2000)
        XCTAssertGreaterThan(sidebar.realizedRowCountForTesting, 0)
        XCTAssertLessThan(sidebar.realizedRowCountForTesting, 25)
    }

    func testLinkedSummariesWaitUntilSidebarIsVisible() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let linked = try directory.createTextFile(named: "Linked.md", contents: "# Loaded title\n\nPreview")
        let sidebar = DocumentSidebarViewController()
        let window = hostInWindow(sidebar)
        defer { window.contentViewController = nil; window.close() }
        sidebar.view.isHidden = true
        sidebar.apply(sidebarEntries: [DocumentSidebarEntry(fileURL: linked, displayTitle: "Linked", previewText: "", isCurrent: false, isAvailable: true, needsSummary: true)], outlineItems: [])
        sidebar.refreshVisibleDocumentSummaries()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(sidebar.documentTitlesForTesting, ["Linked"])
        sidebar.view.isHidden = false
        sidebar.view.layoutSubtreeIfNeeded()
        sidebar.refreshVisibleDocumentSummaries()
        waitUntil { sidebar.documentTitlesForTesting == ["Loaded title"] }
    }

    func testLatestWorkCancelsObsoleteQueryAndDeliversOnlyNewestResult() {
        let queue = LatestWorkQueue<Int, Int>()
        let started = expectation(description: "first query started")
        let finished = expectation(description: "latest result")
        let release = DispatchSemaphore(value: 0)
        var results: [Int] = []
        queue.submit(1, delay: 0, work: { value, cancellation in
            started.fulfill()
            _ = release.wait(timeout: .now() + 10)
            XCTAssertTrue(cancellation.isCancelled)
            return value
        }, completion: { results.append($0) })
        wait(for: [started], timeout: 10)
        queue.submit(2, delay: 0, work: { value, _ in value }, completion: { results.append($0); finished.fulfill() })
        release.signal()
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(results, [2])
    }

    func testRemoteExportFetchesSeriallyWithRemainingBudgetAndCancels() {
        let fetcher = ReviewImageFetcher()
        let loader = RemoteExportAssetLoader(fetcher: fetcher, sources: ["https://fixture.invalid/one", "https://fixture.invalid/two", "https://fixture.invalid/three"], maximumByteCount: 5)
        let finished = expectation(description: "budget error")
        loader.start { result in
            guard case .failure(ExportHTMLPreparationError.assetBudgetExceeded) = result else { XCTFail("Expected aggregate budget failure"); return }
            finished.fulfill()
        }
        XCTAssertEqual(fetcher.budgets, [5])
        fetcher.completeNext(byteCount: 3)
        waitUntil { fetcher.budgets.count == 2 }
        XCTAssertEqual(fetcher.budgets, [5, 2])
        fetcher.completeNext(byteCount: 3)
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(fetcher.budgets.count, 2)

        let cancelled = RemoteExportAssetLoader(fetcher: fetcher, sources: ["https://fixture.invalid/cancel"])
        cancelled.start { _ in XCTFail("Cancelled job must not deliver") }
        let token = fetcher.tokens.last!
        cancelled.cancel()
        XCTAssertTrue(token.cancelled)
        fetcher.completeNext(byteCount: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    func testFetcherReleasesAfterACompletedRequestAndEnforcesPerRequestBudget() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewImageURLProtocol.self]
        weak var released: RemoteImageURLSessionFetcher?
        let finished = expectation(description: "URLSession request")
        var fetcher: RemoteImageURLSessionFetcher? = RemoteImageURLSessionFetcher(configuration: configuration, urlGuard: RemoteAssetURLGuard(resolve: { _ in ["8.8.8.8"] }))
        released = fetcher
        _ = fetcher?.fetch(URLRequest(url: URL(string: "https://fixture.invalid/image")!), maximumByteCount: 2) { result in
            guard case .failure(RemoteImageError.responseTooLarge) = result else { XCTFail("Expected bounded request failure"); return }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        fetcher = nil
        XCTAssertNil(released)
    }

    func testProductionExportRewritesWikiLinksRelativeToOutputAndBoundsLocalReads() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let destination = directory.url.appendingPathComponent("Note.md")
        let href = try XCTUnwrap(WikiLinkURL.url(for: destination, anchorID: "setup"))
        let output = try DocumentExportController.prepareHTMLExport(domHTML: "<a href=\"\(href.absoluteString)\">Note</a>", allowedRootDirectories: [], remoteAssets: [:], outputURL: directory.url.appendingPathComponent("Export.html"))
        XCTAssertTrue(String(decoding: output.data, as: UTF8.self).contains("href=\"Note.md#setup\""))
        let image = try directory.createFile(named: "large.png", contents: Data(repeating: 1, count: 11))
        var components = URLComponents(string: "wafer-local://asset")!
        components.queryItems = [URLQueryItem(name: "path", value: image.path)]
        let inliner = ExportAssetInliner(allowedRootDirectories: [directory.url], maximumInlinedByteCount: 10)
        XCTAssertThrowsError(try inliner.inlineImage(source: components.url!.absoluteString)) { error in
            guard case ExportHTMLPreparationError.assetBudgetExceeded = error else { XCTFail("Wrong error: \(error)"); return }
        }
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class ReviewDirectoryMonitor: DirectoryMonitoring {
    func start() {}
    func stop() {}
}

private final class ReviewImageToken: RemoteImageFetchCancellable {
    var cancelled = false
    func cancel() { cancelled = true }
}

@MainActor
private final class ReviewImageFetcher: RemoteImageFetching {
    var budgets: [Int] = []
    var tokens: [ReviewImageToken] = []
    var completions: [(Result<RemoteImageResponse, Error>) -> Void] = []
    func fetch(_ request: URLRequest, completion: @escaping @MainActor (Result<RemoteImageResponse, Error>) -> Void) -> RemoteImageFetchCancellable {
        fetch(request, maximumByteCount: 100, completion: completion)
    }
    func fetch(_ request: URLRequest, maximumByteCount: Int, completion: @escaping @MainActor (Result<RemoteImageResponse, Error>) -> Void) -> RemoteImageFetchCancellable {
        budgets.append(maximumByteCount)
        completions.append(completion)
        let token = ReviewImageToken()
        tokens.append(token)
        return token
    }
    func completeNext(byteCount: Int) {
        let callback = completions.removeFirst()
        callback(.success(RemoteImageResponse(response: URLResponse(url: URL(string: "https://fixture.invalid/image")!, mimeType: "image/png", expectedContentLength: byteCount, textEncodingName: nil), data: Data(repeating: 1, count: byteCount))))
    }
}

private final class ReviewImageURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: URLResponse(url: request.url!, mimeType: "image/png", expectedContentLength: -1, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
