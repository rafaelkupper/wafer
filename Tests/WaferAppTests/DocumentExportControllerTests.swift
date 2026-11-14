import AppKit
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class DocumentExportControllerTests: XCTestCase {
    func testPrintInfoFactoryUsesSharedPaginationSettingsForPrint() {
        let printInfo = DocumentExportController.printInfo(for: .printDialog)

        XCTAssertEqual(printInfo.leftMargin, 36)
        XCTAssertEqual(printInfo.rightMargin, 36)
        XCTAssertEqual(printInfo.topMargin, 36)
        XCTAssertEqual(printInfo.bottomMargin, 36)
        XCTAssertEqual(printInfo.horizontalPagination, .fit)
        XCTAssertEqual(printInfo.verticalPagination, .automatic)
        XCTAssertFalse(printInfo.isVerticallyCentered)
        XCTAssertNotEqual(printInfo.jobDisposition, .save)
        XCTAssertNil(printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL])
    }

    func testPrintInfoFactorySetsPDFSaveDispositionAndURL() {
        let url = URL(fileURLWithPath: "/tmp/Export.pdf")

        let printInfo = DocumentExportController.printInfo(for: .pdf(url))

        XCTAssertEqual(printInfo.leftMargin, 36)
        XCTAssertEqual(printInfo.rightMargin, 36)
        XCTAssertEqual(printInfo.topMargin, 36)
        XCTAssertEqual(printInfo.bottomMargin, 36)
        XCTAssertEqual(printInfo.horizontalPagination, .fit)
        XCTAssertEqual(printInfo.verticalPagination, .automatic)
        XCTAssertFalse(printInfo.isVerticallyCentered)
        XCTAssertEqual(printInfo.jobDisposition, .save)
        XCTAssertEqual(printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] as? URL, url)
    }

    func testPanelConfigurationHidesPanelsForPDFOnly() {
        let url = URL(fileURLWithPath: "/tmp/Export.pdf")

        XCTAssertEqual(
            DocumentExportController.panelConfiguration(for: .printDialog),
            DocumentExportController.PanelConfiguration(showsPrintPanel: true, showsProgressPanel: true)
        )
        XCTAssertEqual(
            DocumentExportController.panelConfiguration(for: .pdf(url)),
            DocumentExportController.PanelConfiguration(showsPrintPanel: false, showsProgressPanel: false)
        )
    }

    func testSuggestedFileNameUsesDocumentDisplayNameAndExtension() {
        let documentURL = URL(fileURLWithPath: "/tmp/docs/RenderingShowcase.md")

        XCTAssertEqual(
            DocumentExportController.suggestedFileName(documentURL: documentURL, fileExtension: "pdf"),
            "RenderingShowcase.pdf"
        )
        XCTAssertEqual(
            DocumentExportController.suggestedFileName(documentURL: nil, fileExtension: "pdf"),
            "Wafer Export.pdf"
        )
    }

    func testExportHTMLWritesStandaloneSanitizedFileWithLocalImages() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let imageURL = try tempDirectory.createFile(named: "pixel.png", contents: tinyPNGData())
        let outputURL = tempDirectory.url.appendingPathComponent("Export.html")
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader)
        defer { close(window, reader: reader) }
        let panel = FakeExportSavePanel(url: outputURL, response: .OK)
        let controller = DocumentExportController(savePanelFactory: { panel })

        waitForNavigation(in: reader) {
            reader.loadHTMLForTesting(
                htmlDocument(
                    body: """
                    <script>window.bad = true</script>
                    <img src="\(assetURL(forPath: imageURL.path).absoluteString)" alt="Local">
                    <p>Exported</p>
                    """
                ),
                baseURL: tempDirectory.url
            )
        }

        controller.exportHTML(from: exportContext(reader: reader, window: window, documentURL: tempDirectory.url.appendingPathComponent("Doc.md")))
        waitForFile(at: outputURL)

        let html = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(html.lowercased().hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertTrue(html.contains("<p>Exported</p>"))
        XCTAssertFalse(html.lowercased().contains("<script"))
        XCTAssertFalse(html.contains("wafer-"))
        XCTAssertEqual(panel.allowedContentTypes, [.html])
        XCTAssertEqual(panel.nameFieldStringValue, "Doc.html")
    }

    func testExportFixtureBlocksHTTPAndHTTPSImagesWithReaderCSP() throws {
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader)
        defer { close(window, reader: reader) }
        waitForNavigation(in: reader) {
            reader.loadHTMLForTesting(htmlDocument(body: ""))
        }
        let webView = try XCTUnwrap(reader.webViewForExport)
        reader.additionalUserScriptsForTesting = [WKUserScript(
            source: """
            window.blockedImages = [];
            document.addEventListener('securitypolicyviolation', event => {
                window.blockedImages.push({uri: event.blockedURI, directive: event.effectiveDirective});
            });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .defaultClient
        )]
        waitForNavigation(in: reader) {
            reader.loadHTMLForTesting(htmlDocument(body: """
                <img src="https://example.com/blocked.png">
                <img src="http://example.com/blocked.png">
                """))
        }
        let checked = expectation(description: "CSP violations checked")
        webView.evaluateJavaScript("window.blockedImages", in: nil, in: .defaultClient) { result in
            defer { checked.fulfill() }
            do {
                let violations = try XCTUnwrap(try result.get() as? [[String: String]])
                XCTAssertEqual(violations.count, 2)
                XCTAssertTrue(violations.allSatisfy { $0["directive"] == "img-src" })
                XCTAssertTrue(violations.contains { $0["uri"]?.hasPrefix("https://example.com") == true })
                XCTAssertTrue(violations.contains { $0["uri"]?.hasPrefix("http://example.com") == true })
            } catch {
                XCTFail("Cannot inspect CSP violations: \(error)")
            }
        }
        wait(for: [checked], timeout: 5)
    }

    func testExportHTMLSkipsRemoteFetchWhenRemoteImagesAreDisabled() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let outputURL = tempDirectory.url.appendingPathComponent("RemoteDisabled.html")
        let defaults = makeTestUserDefaults()
        let preferenceStore = ReaderBehaviorPreferenceStore(defaults: defaults)
        preferenceStore.loadsRemoteImages = false
        let fetcher = RecordingRemoteImageFetcher()
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader)
        defer { close(window, reader: reader) }
        let controller = DocumentExportController(
            savePanelFactory: { FakeExportSavePanel(url: outputURL, response: .OK) },
            remoteImageFetcher: fetcher,
            preferenceStore: preferenceStore
        )

        waitForNavigation(in: reader) {
            reader.loadHTMLForTesting(htmlDocument(body: #"<img src="https://example.com/remote.png" alt="Remote">"#))
        }

        controller.exportHTML(from: exportContext(reader: reader, window: window))
        waitForFile(at: outputURL)

        let html = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(fetcher.requests.isEmpty)
        XCTAssertFalse(html.contains("https://example.com/remote.png"))
        XCTAssertFalse(html.contains("alt=\"Remote\""))
    }

    func testExportHTMLDropsRemoteImageWhenFetchFails() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let outputURL = tempDirectory.url.appendingPathComponent("RemoteFailure.html")
        let fetcher = RecordingRemoteImageFetcher()
        fetcher.results = [.failure(URLError(.timedOut))]
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader)
        defer { close(window, reader: reader) }
        let controller = DocumentExportController(
            savePanelFactory: { FakeExportSavePanel(url: outputURL, response: .OK) },
            remoteImageFetcher: fetcher
        )

        waitForNavigation(in: reader) {
            reader.loadHTMLForTesting(htmlDocument(body: #"<img src="https://example.com/missing.png" alt="Remote"><p>Kept</p>"#))
        }

        controller.exportHTML(from: exportContext(reader: reader, window: window))
        waitForFile(at: outputURL)

        let html = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(fetcher.requests.map(\.url), [URL(string: "https://example.com/missing.png")])
        XCTAssertFalse(html.contains("https://example.com/missing.png"))
        XCTAssertFalse(html.contains("alt=\"Remote\""))
        XCTAssertTrue(html.contains("<p>Kept</p>"))
    }

    func testExportHTMLRejectsHTTPRemoteImagesWithoutFetching() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let outputURL = tempDirectory.url.appendingPathComponent("HTTPRemote.html")
        let fetcher = RecordingRemoteImageFetcher()
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader)
        defer { close(window, reader: reader) }
        let controller = DocumentExportController(
            savePanelFactory: { FakeExportSavePanel(url: outputURL, response: .OK) },
            remoteImageFetcher: fetcher
        )

        waitForNavigation(in: reader) {
            reader.loadHTMLForTesting(htmlDocument(body: #"<img src="http://example.com/plain.png" alt="Remote"><p>Kept</p>"#))
        }

        controller.exportHTML(from: exportContext(reader: reader, window: window))
        waitForFile(at: outputURL)

        let html = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(fetcher.requests.isEmpty)
        XCTAssertFalse(html.contains("http://example.com/plain.png"))
        XCTAssertTrue(html.contains("<p>Kept</p>"))
    }

    func testExportHTMLPreparationAndWriteRunOffMainThread() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let outputURL = tempDirectory.url.appendingPathComponent("OffMain.html")
        let preparationRecorder = ThreadFlagRecorder()
        let writer = ThreadRecordingHTMLWriter()
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader)
        defer { close(window, reader: reader) }
        let controller = DocumentExportController(
            savePanelFactory: { FakeExportSavePanel(url: outputURL, response: .OK) },
            htmlFileWriter: { data, url in
                try writer.write(data: data, to: url)
            },
            htmlPreparationObserver: { ranOnMainThread in
                preparationRecorder.record(ranOnMainThread)
            }
        )

        waitForNavigation(in: reader) {
            reader.loadHTMLForTesting(htmlDocument(body: "<p>Prepared off-main</p>"))
        }

        controller.exportHTML(from: exportContext(reader: reader, window: window))
        waitForFile(at: outputURL)

        XCTAssertEqual(preparationRecorder.values, [false])
        XCTAssertEqual(writer.ranOnMainThread, false)
    }

    func testExportHTMLBlocksReentryWhileRunning() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let outputURL = tempDirectory.url.appendingPathComponent("Slow.html")
        let fetcher = RecordingRemoteImageFetcher(automaticallyCompletes: false)
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader)
        defer { close(window, reader: reader) }
        let controller = DocumentExportController(
            savePanelFactory: { FakeExportSavePanel(url: outputURL, response: .OK) },
            remoteImageFetcher: fetcher
        )

        waitForNavigation(in: reader) {
            reader.loadHTMLForTesting(htmlDocument(body: #"<img src="https://example.com/slow.png" alt="Remote">"#))
        }

        let context = exportContext(reader: reader, window: window)
        XCTAssertTrue(controller.canExportHTML(from: context))
        controller.exportHTML(from: context)
        waitUntil { fetcher.requests.count == 1 }
        XCTAssertFalse(controller.canExportHTML(from: context))

        fetcher.complete(.success(remoteImageResponse(url: URL(string: "https://example.com/slow.png")!, data: Data("ok".utf8))))
        waitForFile(at: outputURL)
        waitUntil { controller.canExportHTML(from: context) }
    }

    private func exportContext(
        reader: WebKitReaderViewController,
        window: NSWindow,
        documentURL: URL? = nil
    ) -> DocumentExportContext {
        DocumentExportContext(
            webView: reader.webViewForExport!,
            window: window,
            documentURL: documentURL,
            readerController: reader
        )
    }

    private func waitForNavigation(
        in reader: WebKitReaderViewController,
        action: () -> Void
    ) {
        let expectation = expectation(description: "navigation finished")
        reader.onNavigationFinished = {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                expectation.fulfill()
            }
        }
        action()
        wait(for: [expectation], timeout: 5)
        reader.onNavigationFinished = nil
    }

    private func waitForFile(at url: URL) {
        waitUntil {
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition())
    }

    private func close(_ window: NSWindow, reader: WebKitReaderViewController) {
        reader.invalidateForTesting()
        window.contentViewController = nil
        window.orderOut(nil)
        window.close()
    }

    private func htmlDocument(body: String) -> String {
        let policy = WebKitHTMLRenderer.contentSecurityPolicy(allowsPageScripts: false, scriptNonce: "")
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy" content="\(policy)">
          <style>body { color: #123456; }</style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    private func assetURL(forPath path: String) -> URL {
        var components = URLComponents()
        components.scheme = "wafer-local"
        components.host = "asset"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url!
    }

    private func remoteImageResponse(url: URL, data: Data) -> RemoteImageResponse {
        RemoteImageResponse(
            response: URLResponse(
                url: url,
                mimeType: "image/png",
                expectedContentLength: data.count,
                textEncodingName: nil
            ),
            data: data
        )
    }
}

@MainActor
private final class FakeExportSavePanel: ExportSavePanel {
    var allowedContentTypes: [UTType] = []
    var canCreateDirectories = false
    var nameFieldStringValue = ""
    var directoryURL: URL?
    let url: URL?

    private let response: NSApplication.ModalResponse

    init(url: URL?, response: NSApplication.ModalResponse) {
        self.url = url
        self.response = response
    }

    func beginSheetModal(
        for window: NSWindow,
        completionHandler: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        completionHandler(response)
    }
}

@MainActor
private final class RecordingRemoteImageFetcher: RemoteImageFetching {
    var results: [Result<RemoteImageResponse, Error>] = []
    var requests: [URLRequest] = []
    var completions: [@MainActor (Result<RemoteImageResponse, Error>) -> Void] = []
    var automaticallyCompletes: Bool

    init(automaticallyCompletes: Bool = true) {
        self.automaticallyCompletes = automaticallyCompletes
    }

    func fetch(
        _ request: URLRequest,
        completion: @escaping @MainActor (Result<RemoteImageResponse, Error>) -> Void
    ) -> RemoteImageFetchCancellable {
        requests.append(request)
        completions.append(completion)
        if automaticallyCompletes {
            let result = results.isEmpty
                ? .failure(URLError(.badServerResponse))
                : results.removeFirst()
            completion(result)
        }
        return RecordingRemoteImageToken()
    }

    func complete(_ result: Result<RemoteImageResponse, Error>, at index: Int = 0) {
        completions[index](result)
    }
}

private final class RecordingRemoteImageToken: RemoteImageFetchCancellable {
    func cancel() {}
}

private final class ThreadFlagRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Bool] = []

    var values: [Bool] {
        lock.withLock { recordedValues }
    }

    func record(_ value: Bool) {
        lock.withLock {
            recordedValues.append(value)
        }
    }
}

private final class ThreadRecordingHTMLWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMainThreadValue: Bool?

    var ranOnMainThread: Bool? {
        lock.withLock { recordedMainThreadValue }
    }

    func write(data: Data, to url: URL) throws {
        lock.withLock {
            recordedMainThreadValue = Thread.isMainThread
        }
        try data.write(to: url, options: .atomic)
    }
}
