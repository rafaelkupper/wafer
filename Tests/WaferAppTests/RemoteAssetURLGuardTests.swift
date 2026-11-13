import Foundation
import XCTest
@testable import WaferApp

@MainActor
final class RemoteAssetURLGuardTests: XCTestCase {
    func testRejectsNonPublicLiteralAddressesWithoutDNS() {
        let guardPolicy = RemoteAssetURLGuard(resolve: { _ in
            XCTFail("Literal IPs must not use DNS")
            return ["8.8.8.8"]
        })
        for host in ["127.0.0.1", "10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.0.1",
                     "169.254.1.1", "100.64.0.1", "100.127.255.255", "0.0.0.0", "0.1.2.3",
                     "224.0.0.1", "239.255.255.255", "255.255.255.255", "[::]", "[::1]",
                     "[fc00::1]", "[fdff::1]", "[fe80::1]", "[febf::1]", "[ff02::1]", "[::ffff:127.0.0.1]"] {
            XCTAssertThrowsError(try guardPolicy.validate(URL(string: "https://\(host)/image.png")), host)
        }
    }

    func testAllowsPublicAddressesAndRejectsOtherSchemes() throws {
        let guardPolicy = RemoteAssetURLGuard(resolve: { _ in ["8.8.8.8", "2606:4700:4700::1111"] })
        for host in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "[2606:4700:4700::1111]", "[::ffff:8.8.8.8]", "public.test"] {
            try guardPolicy.validate(URL(string: "https://\(host)/image.png"))
        }
        try guardPolicy.validate(URL(string: "http://public.test/image.png"))
        for url in ["file:///tmp/image.png", "ftp://public.test/image.png", "wafer-local://asset", "https:///", "data:image/png,abc"] {
            XCTAssertThrowsError(try guardPolicy.validate(URL(string: url)), url)
        }
    }

    func testRejectsNamesIfAnyResolvedAddressIsNonPublicOrResolutionFails() {
        for addresses in [[], ["8.8.8.8", "192.168.1.2"], ["::1"], ["not-an-IP"]] {
            XCTAssertThrowsError(try RemoteAssetURLGuard(resolve: { _ in addresses }).validate(URL(string: "https://named.test/image.png")))
        }
        XCTAssertThrowsError(try RemoteAssetURLGuard(resolve: { _ in throw URLError(.cannotFindHost) })
            .validate(URL(string: "https://named.test/image.png")))
    }

    func testFetcherRejectsPrivateInitialURLBeforeStubProtocolLoads() async {
        await assertRejected("https://127.0.0.1/image.png")
        await assertRejected("https://[::ffff:192.168.1.1]/image.png")
    }

    func testFetcherRejectsPrivateRedirectAtEveryHopWithoutNetwork() async {
        await assertRejected("https://8.8.8.8/private-redirect")
        await assertRejected("https://8.8.8.8/public-redirect")
        await assertRejected("https://8.8.8.8/scheme-redirect")
    }

    func testFetcherResolvesNamesAgainOnRedirectAndRejectsPrivateAnswer() async {
        let policy = RemoteAssetURLGuard(resolve: { host in host == "public.test" ? ["8.8.8.8"] : ["10.0.0.1"] })
        await assertRejected("https://public.test/name-redirect", policy: policy)
    }

    func testFetcherAcceptsPublicRedirectUsingStubProtocol() async {
        let fetcher = makeFetcher()
        let finished = expectation(description: "public image")
        _ = fetcher.fetch(URLRequest(url: URL(string: "https://8.8.8.8/allowed-redirect")!)) { result in
            guard case let .success(response) = result else { XCTFail("Expected public redirect success: \(result)"); finished.fulfill(); return }
            XCTAssertEqual(response.data, Data([1, 2, 3]))
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
    }

    func testExportLoaderOmitsPrivateInitialAndRedirectedImages() async {
        let fetcher = makeFetcher()
        let loader = RemoteExportAssetLoader(fetcher: fetcher,
            sources: ["https://127.0.0.1/image.png", "https://8.8.8.8/public-redirect"])
        let finished = expectation(description: "export rejects private assets")
        loader.start { result in
            guard case let .success(assets) = result else { XCTFail("Blocked images should be omitted"); finished.fulfill(); return }
            XCTAssertTrue(assets.isEmpty)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
    }

    private func assertRejected(_ url: String, policy: RemoteAssetURLGuard = RemoteAssetURLGuard()) async {
        let fetcher = makeFetcher(policy: policy)
        let finished = expectation(description: "reject \(url)")
        _ = fetcher.fetch(URLRequest(url: URL(string: url)!)) { result in
            guard case .failure = result else { XCTFail("Unsafe asset was fetched: \(url)"); finished.fulfill(); return }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
    }

    private func makeFetcher(policy: RemoteAssetURLGuard = RemoteAssetURLGuard()) -> RemoteImageURLSessionFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuardImageURLProtocol.self]
        return RemoteImageURLSessionFetcher(configuration: configuration, urlGuard: policy)
    }
}

private final class GuardImageURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let destination: String?
        switch url.path {
        case "/private-redirect": destination = "https://127.0.0.1/image.png"
        case "/public-redirect": destination = "https://1.1.1.1/private-redirect"
        case "/scheme-redirect": destination = "file:///tmp/image.png"
        case "/name-redirect": destination = "https://internal.test/image.png"
        case "/allowed-redirect": destination = "https://1.1.1.1/image.png"
        default: destination = nil
        }
        if let destination, let target = URL(string: destination) {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        } else {
            let data = Data([1, 2, 3])
            client?.urlProtocol(self, didReceive: URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
