import Foundation
import WebKit
import XCTest
@testable import WaferApp

@MainActor
final class RemoteImageSchemeHandlerTests: XCTestCase {
    func testUserAgentUsesBundleVersionAndMissingVersionFallback() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        func bundle(named name: String, info: [String: String]) throws -> Bundle {
            let url = directory.url.appendingPathComponent(name + ".bundle")
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return try XCTUnwrap(Bundle(url: url))
        }
        let versioned = try bundle(named: "Versioned", info: ["CFBundleShortVersionString": "1.2.3"])
        let missing = try bundle(named: "Missing", info: [:])
        XCTAssertEqual(RemoteImageSchemeHandler.userAgent(bundle: versioned), "Wafer/1.2.3 RemoteImageLoader")
        XCTAssertEqual(RemoteImageSchemeHandler.userAgent(bundle: missing), "Wafer/unknown RemoteImageLoader")
    }

    func testRejectsNonHTTPSRemoteURLWithoutFetching() {
        let fetcher = FakeRemoteImageFetcher()
        let handler = makeHandler(fetcher: fetcher)
        let task = FakeURLSchemeTask(url: proxyURL(for: "http://example.com/image.png"))

        handler.webView(WKWebView(), start: task)

        XCTAssertEqual(fetcher.requests.count, 0)
        XCTAssertNotNil(task.failedError)
        XCTAssertEqual(task.receivedData.count, 0)
        XCTAssertEqual(task.didFinishCount, 0)
    }

    func testDisabledRemoteImagesFailWithoutFetching() {
        let fetcher = FakeRemoteImageFetcher()
        let handler = makeHandler(fetcher: fetcher, loadsRemoteImages: false)
        let task = FakeURLSchemeTask(url: proxyURL(for: "https://example.com/image.png"))

        handler.webView(WKWebView(), start: task)

        XCTAssertEqual(fetcher.requests.count, 0)
        XCTAssertNotNil(task.failedError)
        XCTAssertEqual(task.didFinishCount, 0)
    }

    func testPreferenceChangeAppliesToSubsequentFetches() {
        let fetcher = FakeRemoteImageFetcher()
        let defaults = makeTestUserDefaults()
        let preferenceStore = ReaderBehaviorPreferenceStore(defaults: defaults)
        let handler = RemoteImageSchemeHandler(fetcher: fetcher, preferenceStore: preferenceStore)
        let task = FakeURLSchemeTask(url: proxyURL(for: "https://example.com/image.png"))

        preferenceStore.loadsRemoteImages = false
        handler.webView(WKWebView(), start: task)

        XCTAssertEqual(fetcher.requests.count, 0)
        XCTAssertNotNil(task.failedError)
        XCTAssertEqual(task.didFinishCount, 0)
    }

    func testRejectsNonImageMIMEType() {
        let fetcher = FakeRemoteImageFetcher()
        let handler = makeHandler(fetcher: fetcher)
        let task = FakeURLSchemeTask(url: proxyURL(for: "https://example.com/not-image"))

        handler.webView(WKWebView(), start: task)
        fetcher.complete(
            .success(RemoteImageResponse(
                response: response(mimeType: "text/html", expectedContentLength: 12),
                data: Data("<h1>x</h1>".utf8)
            ))
        )

        XCTAssertNotNil(task.failedError)
        XCTAssertEqual(task.receivedData.count, 0)
        XCTAssertEqual(task.didFinishCount, 0)
    }

    func testRejectsOversizedContentLengthAndAccumulatedData() {
        let contentLengthFetcher = FakeRemoteImageFetcher()
        let contentLengthHandler = makeHandler(fetcher: contentLengthFetcher, maximumByteCount: 4)
        let contentLengthTask = FakeURLSchemeTask(url: proxyURL(for: "https://example.com/large.png"))

        contentLengthHandler.webView(WKWebView(), start: contentLengthTask)
        contentLengthFetcher.complete(
            .success(RemoteImageResponse(
                response: response(mimeType: "image/png", expectedContentLength: 5),
                data: Data([1, 2, 3])
            ))
        )

        let streamedFetcher = FakeRemoteImageFetcher()
        let streamedHandler = makeHandler(fetcher: streamedFetcher, maximumByteCount: 4)
        let streamedTask = FakeURLSchemeTask(url: proxyURL(for: "https://example.com/streamed.png"))

        streamedHandler.webView(WKWebView(), start: streamedTask)
        streamedFetcher.complete(
            .success(RemoteImageResponse(
                response: response(mimeType: "image/png", expectedContentLength: -1),
                data: Data([1, 2, 3, 4, 5])
            ))
        )

        XCTAssertNotNil(contentLengthTask.failedError)
        XCTAssertEqual(contentLengthTask.didFinishCount, 0)
        XCTAssertNotNil(streamedTask.failedError)
        XCTAssertEqual(streamedTask.didFinishCount, 0)
    }

    func testHappyPathDeliversImageBytes() {
        let fetcher = FakeRemoteImageFetcher()
        let handler = makeHandler(fetcher: fetcher)
        let task = FakeURLSchemeTask(url: proxyURL(for: "https://example.com/image.png"))
        let imageData = tinyPNGData()

        handler.webView(WKWebView(), start: task)
        fetcher.complete(
            .success(RemoteImageResponse(
                response: response(mimeType: "image/png", expectedContentLength: Int64(imageData.count)),
                data: imageData
            ))
        )

        XCTAssertEqual(fetcher.requests.first?.url, URL(string: "https://example.com/image.png"))
        XCTAssertEqual(fetcher.requests.first?.value(forHTTPHeaderField: "User-Agent"), RemoteImageSchemeHandler.userAgent())
        XCTAssertEqual(task.responses.first?.mimeType, "image/png")
        XCTAssertEqual(task.receivedData, [imageData])
        XCTAssertEqual(task.didFinishCount, 1)
        XCTAssertNil(task.failedError)
    }

    func testStopBeforeCompletionCancelsAndSuppressesTaskCallbacks() {
        let fetcher = FakeRemoteImageFetcher()
        let handler = makeHandler(fetcher: fetcher)
        let task = FakeURLSchemeTask(url: proxyURL(for: "https://example.com/image.png"))

        handler.webView(WKWebView(), start: task)
        handler.webView(WKWebView(), stop: task)
        fetcher.complete(
            .success(RemoteImageResponse(
                response: response(mimeType: "image/png", expectedContentLength: 3),
                data: Data([1, 2, 3])
            ))
        )

        XCTAssertEqual(fetcher.tokens.first?.didCancel, true)
        XCTAssertEqual(task.responses.count, 0)
        XCTAssertEqual(task.receivedData.count, 0)
        XCTAssertEqual(task.didFinishCount, 0)
        XCTAssertNil(task.failedError)
    }

    func testLiveFetcherUsesEphemeralConfigurationWithoutCookiesOrCredentials() {
        let configuration = RemoteImageURLSessionFetcher.ephemeralConfiguration()

        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
    }

    func testLiveFetcherRejectsNonImageMIMEWithoutNetwork() async {
        let configuration = RemoteImageURLSessionFetcher.ephemeralConfiguration()
        configuration.protocolClasses = [NonImageURLProtocol.self]
        let fetcher = RemoteImageURLSessionFetcher(configuration: configuration, urlGuard: RemoteAssetURLGuard(resolve: { _ in ["8.8.8.8"] }))
        let failed = expectation(description: "non-image response fails")

        _ = fetcher.fetch(URLRequest(url: URL(string: "https://non-image.test/page")!)) { result in
            if case .success = result {
                XCTFail("Non-image MIME response should fail.")
            }
            failed.fulfill()
        }

        await fulfillment(of: [failed], timeout: 2)
    }

    func testLiveFetcherRejectsHTTPRedirectWithoutNetwork() async {
        let configuration = RemoteImageURLSessionFetcher.ephemeralConfiguration()
        configuration.protocolClasses = [HTTPRedirectURLProtocol.self]
        let fetcher = RemoteImageURLSessionFetcher(configuration: configuration, urlGuard: RemoteAssetURLGuard(resolve: { _ in ["8.8.8.8"] }))
        let failed = expectation(description: "http redirect fails")

        _ = fetcher.fetch(URLRequest(url: URL(string: "https://redirect.test/start.png")!)) { result in
            if case .success = result {
                XCTFail("HTTP redirect should fail.")
            }
            failed.fulfill()
        }

        await fulfillment(of: [failed], timeout: 2)
    }

    private func proxyURL(for remoteURL: String) -> URL {
        var components = URLComponents()
        components.scheme = "wafer-remote"
        components.host = "image"
        components.queryItems = [URLQueryItem(name: "url", value: remoteURL)]
        return components.url!
    }

    private func makeHandler(
        fetcher: RemoteImageFetching,
        maximumByteCount: Int = RemoteImageSchemeHandler.defaultMaximumByteCount,
        loadsRemoteImages: Bool = true
    ) -> RemoteImageSchemeHandler {
        let defaults = makeTestUserDefaults()
        let preferenceStore = ReaderBehaviorPreferenceStore(defaults: defaults)
        preferenceStore.loadsRemoteImages = loadsRemoteImages
        return RemoteImageSchemeHandler(
            fetcher: fetcher,
            maximumByteCount: maximumByteCount,
            preferenceStore: preferenceStore
        )
    }

    private func response(mimeType: String, expectedContentLength: Int64) -> URLResponse {
        URLResponse(
            url: URL(string: "https://example.com/image.png")!,
            mimeType: mimeType,
            expectedContentLength: Int(expectedContentLength),
            textEncodingName: nil
        )
    }
}

@MainActor
private final class FakeRemoteImageFetcher: RemoteImageFetching {
    var requests: [URLRequest] = []
    var completions: [@MainActor (Result<RemoteImageResponse, Error>) -> Void] = []
    var tokens: [FakeRemoteImageFetchToken] = []

    func fetch(
        _ request: URLRequest,
        completion: @escaping @MainActor (Result<RemoteImageResponse, Error>) -> Void
    ) -> RemoteImageFetchCancellable {
        let token = FakeRemoteImageFetchToken()
        requests.append(request)
        completions.append(completion)
        tokens.append(token)
        return token
    }

    func complete(_ result: Result<RemoteImageResponse, Error>, at index: Int = 0) {
        completions[index](result)
    }
}

private final class FakeRemoteImageFetchToken: RemoteImageFetchCancellable {
    var didCancel = false

    func cancel() {
        didCancel = true
    }
}

private final class FakeURLSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var responses: [URLResponse] = []
    var receivedData: [Data] = []
    var didFinishCount = 0
    var failedError: Error?

    init(url: URL) {
        self.request = URLRequest(url: url)
        super.init()
    }

    func didReceive(_ response: URLResponse) {
        responses.append(response)
    }

    func didReceive(_ data: Data) {
        receivedData.append(data)
    }

    func didFinish() {
        didFinishCount += 1
    }

    func didFailWithError(_ error: any Error) {
        failedError = error
    }
}

private final class NonImageURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "non-image.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let data = Data("<html></html>".utf8)
        let response = URLResponse(
            url: request.url!,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class HTTPRedirectURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "redirect.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.url?.scheme == "https" else {
            let data = tinyPNGData()
            let response = URLResponse(
                url: request.url!,
                mimeType: "image/png",
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let redirectURL = URL(string: "http://redirect.test/insecure.png")!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectURL.absoluteString]
        )!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectURL), redirectResponse: response)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
