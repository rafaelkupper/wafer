import Foundation
import WebKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class WebKitLocalAssetSchemeHandlerTests: XCTestCase {
    func testReadQueueHasProcessWideConcurrencyLimit() {
        XCTAssertEqual(WebKitLocalAssetSchemeHandler.readConcurrencyForTesting, 2)
    }

    func testDeliversAssetAtBudgetAndRejectsOversizedAsset() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = directory.url.appendingPathComponent("image.png")
        try Data([1, 2, 3, 4]).write(to: url)
        let handler = WebKitLocalAssetSchemeHandler(maximumByteCount: 4)
        handler.documentRootDirectory = directory.url
        let completed = expectation(description: "asset delivered")
        let task = LocalAssetTestTask(fileURL: url, completion: { completed.fulfill() })
        let webView = WKWebView()
        handler.webView(webView, start: task)
        wait(for: [completed], timeout: 15)
        XCTAssertEqual(task.data, Data([1, 2, 3, 4]))
        XCTAssertNil(task.error)
        XCTAssertTrue(task.finished)

        try Data([1, 2, 3, 4, 5]).write(to: url)
        let rejected = expectation(description: "oversized asset rejected")
        let oversized = LocalAssetTestTask(fileURL: url, completion: { rejected.fulfill() })
        handler.webView(webView, start: oversized)
        wait(for: [rejected], timeout: 15)
        XCTAssertNotNil(oversized.error)
        XCTAssertTrue(oversized.data.isEmpty)
        XCTAssertFalse(oversized.finished)
    }

    func testStoppedPendingReadIsCancelledAndNeverDelivers() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = directory.url.appendingPathComponent("image.png")
        try Data([1]).write(to: url)
        let queue = OperationQueue()
        queue.isSuspended = true
        let handler = WebKitLocalAssetSchemeHandler(queue: queue)
        handler.documentRootDirectory = directory.url
        let task = LocalAssetTestTask(fileURL: url) { XCTFail("Stopped task received a callback") }
        let webView = WKWebView()
        handler.webView(webView, start: task)
        let operation = try XCTUnwrap(queue.operations.first)
        handler.webView(webView, stop: task)
        XCTAssertTrue(operation.isCancelled)
        let drained = expectation(description: "cancelled read drained")
        let barrier = BlockOperation { DispatchQueue.main.async { drained.fulfill() } }
        barrier.addDependency(operation)
        queue.addOperation(barrier)
        queue.isSuspended = false
        wait(for: [drained], timeout: 15)
        XCTAssertTrue(operation.isFinished)
        XCTAssertTrue(task.data.isEmpty)
        XCTAssertNil(task.error)
    }

    func testRejectsAssetOutsideDocumentRoot() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let handler = WebKitLocalAssetSchemeHandler()
        handler.documentRootDirectory = directory.url
        let rejected = expectation(description: "outside-root request rejected")
        let task = LocalAssetTestTask(fileURL: directory.url.deletingLastPathComponent().appendingPathComponent("secret.png")) {
            rejected.fulfill()
        }
        handler.webView(WKWebView(), start: task)
        wait(for: [rejected], timeout: 15)
        XCTAssertNotNil(task.error)
    }

    func testRequestOutsideTheSandboxScopeFailsWithoutReadingAndNamesItsWebView() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = directory.url.appendingPathComponent("image.png")
        try Data([1]).write(to: url)
        let queue = OperationQueue()
        queue.isSuspended = true
        let handler = WebKitLocalAssetSchemeHandler(queue: queue, accessScope: { FolderAccessScope(roots: []) })
        handler.documentRootDirectory = directory.url
        let webView = WKWebView()
        let refused = expectation(description: "refused at once")
        let reported = expectation(forNotification: .localAssetAccessDenied, object: webView) { notification in
            (notification.userInfo?["fileURL"] as? URL)?.lastPathComponent == "image.png"
        }
        let task = LocalAssetTestTask(fileURL: url) { refused.fulfill() }

        handler.webView(webView, start: task)

        wait(for: [refused, reported], timeout: 5)
        XCTAssertTrue(task.error is FolderAccessDeniedError)
        XCTAssertTrue(task.data.isEmpty)
        XCTAssertTrue(queue.operations.isEmpty, "nothing was scheduled to read")
    }

    func testEachNewPageOfAServedReaderIsAnnounced() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = directory.url.appendingPathComponent("image.png")
        try Data([1]).write(to: url)
        let handler = WebKitLocalAssetSchemeHandler(accessScope: { FolderAccessScope(roots: []) })
        let webView = WKWebView()
        var announced: [ObjectIdentifier] = []
        let token = NotificationCenter.default.addObserver(forName: .localAssetPageWillLoad, object: nil, queue: nil) { notification in
            if let object = notification.object as AnyObject? { announced.append(ObjectIdentifier(object)) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        handler.documentRootDirectory = directory.url
        XCTAssertTrue(announced.isEmpty, "nothing served yet, so nothing to reconcile")
        let refused = expectation(description: "refused")
        handler.webView(webView, start: LocalAssetTestTask(fileURL: url) { refused.fulfill() })
        wait(for: [refused], timeout: 5)
        handler.documentRootDirectory = directory.url
        handler.documentRootDirectory = nil

        XCTAssertEqual(announced, [ObjectIdentifier(webView), ObjectIdentifier(webView)])
    }

    func testRequestInsideTheSandboxScopeIsRead() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = directory.url.appendingPathComponent("image.png")
        try Data([1, 2]).write(to: url)
        let handler = WebKitLocalAssetSchemeHandler(accessScope: { FolderAccessScope(roots: [FileContainment(rootDirectory: directory.url)]) })
        handler.documentRootDirectory = directory.url
        let delivered = expectation(description: "delivered")
        let task = LocalAssetTestTask(fileURL: url) { delivered.fulfill() }

        handler.webView(WKWebView(), start: task)

        wait(for: [delivered], timeout: 15)
        XCTAssertEqual(task.data, Data([1, 2]))
        XCTAssertTrue(task.finished)
    }
}

private final class LocalAssetTestTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var data = Data()
    var error: Error?
    var finished = false
    private let completion: () -> Void

    init(fileURL: URL, completion: @escaping () -> Void) {
        var components = URLComponents()
        components.scheme = "wafer-local"
        components.host = "asset"
        components.queryItems = [URLQueryItem(name: "path", value: fileURL.path)]
        request = URLRequest(url: components.url!)
        self.completion = completion
    }

    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { finished = true; completion() }
    func didFailWithError(_ error: Error) { self.error = error; completion() }
}
