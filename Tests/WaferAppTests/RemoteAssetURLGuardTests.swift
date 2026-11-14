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

    func testRejectsPrivateIPv4EmbeddedInTransitionAddresses() throws {
        let policy = RemoteAssetURLGuard()
        for address in ["64:ff9b::127.0.0.1", "64:ff9b::192.168.1.1",
                        "64:ff9b:1::a00:1", "64:ff9b:1:a00:0:100::",
                        "2002:7f00:1::", "2002:c0a8:101::",
                        "2001:0:808:808:0:0:3f57:fefe", "2001:0:a00:1:0:0:f7f7:f7f7"] {
            XCTAssertThrowsError(try policy.validate(URL(string: "https://[\(address)]/image.png")), address)
        }
        for address in ["64:ff9b::8.8.8.8", "2002:808:808::", "2001:0:808:808:0:0:f7f7:f7f7"] {
            try policy.validate(URL(string: "https://[\(address)]/image.png"))
        }
    }

    func testAllowsPublicAddressesAndRejectsOtherSchemes() throws {
        let guardPolicy = RemoteAssetURLGuard(resolve: { _ in ["8.8.8.8", "2606:4700:4700::1111"] })
        for host in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "[2606:4700:4700::1111]", "[::ffff:8.8.8.8]", "public.test"] {
            try guardPolicy.validate(URL(string: "https://\(host)/image.png"))
        }
        for url in ["file:///tmp/image.png", "ftp://public.test/image.png", "wafer-local://asset", "https:///", "data:image/png,abc"] {
            XCTAssertThrowsError(try guardPolicy.validate(URL(string: url)), url)
        }
    }

    func testRejectsHTTPBeforeResolvingHosts() {
        let policy = RemoteAssetURLGuard(resolve: { _ in
            XCTFail("HTTP URLs must be rejected before DNS")
            return ["8.8.8.8"]
        })
        for url in ["http://public.test/image.png", "http://8.8.8.8/image.png", "HTTP://[2606:4700:4700::1111]/image.png"] {
            XCTAssertThrowsError(try policy.validate(URL(string: url)), url) { error in
                guard case RemoteAssetURLGuard.Rejection.invalidURL = error else {
                    return XCTFail("Expected invalidURL for \(url), got \(error)")
                }
            }
        }
    }

    func testRejectsSpecialPurposeIPv4Ranges() {
        let ranges = [
            ("192.0.0.0/24", ["192.0.0.0", "192.0.0.9", "192.0.0.10", "192.0.0.255"]),
            ("192.0.2.0/24", ["192.0.2.0", "192.0.2.255"]),
            ("192.88.99.0/24", ["192.88.99.0", "192.88.99.2", "192.88.99.255"]),
            ("198.18.0.0/15", ["198.18.0.0", "198.19.255.255"]),
            ("198.51.100.0/24", ["198.51.100.0", "198.51.100.255"]),
            ("203.0.113.0/24", ["203.0.113.0", "203.0.113.255"]),
            ("240.0.0.0/4", ["240.0.0.0", "255.255.255.254"]),
            ("255.255.255.255/32", ["255.255.255.255"]),
        ]
        let literalPolicy = RemoteAssetURLGuard(resolve: { _ in
            XCTFail("Literal IPs must not use DNS")
            return []
        })
        for (range, addresses) in ranges {
            for address in addresses {
                XCTAssertThrowsError(try literalPolicy.validate(URL(string: "https://\(address)/image.png")), "\(range): \(address)")
                XCTAssertThrowsError(try literalPolicy.validate(URL(string: "https://[::ffff:\(address)]/image.png")), "mapped \(range): \(address)")
                let resolvedPolicy = RemoteAssetURLGuard(resolve: { _ in ["8.8.8.8", address] })
                XCTAssertThrowsError(try resolvedPolicy.validate(URL(string: "https://named.test/image.png")), "DNS \(range): \(address)")
            }
        }
    }

    func testRejectsSpecialPurposeIPv6Ranges() {
        let ranges = [
            ("100::/64", ["100::", "100::ffff:ffff:ffff:ffff"]),
            ("100:0:0:1::/64", ["100:0:0:1::", "100:0:0:1:ffff:ffff:ffff:ffff"]),
            ("2001:2::/48", ["2001:2::", "2001:2:0:ffff:ffff:ffff:ffff:ffff"]),
            ("2001:10::/28", ["2001:10::", "2001:1f:ffff:ffff:ffff:ffff:ffff:ffff"]),
            ("2001:db8::/32", ["2001:db8::", "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff"]),
            ("3fff::/20", ["3fff::", "3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff"]),
            ("5f00::/16", ["5f00::", "5f00:ffff:ffff:ffff:ffff:ffff:ffff:ffff"]),
        ]
        let literalPolicy = RemoteAssetURLGuard(resolve: { _ in
            XCTFail("Literal IPs must not use DNS")
            return []
        })
        for (range, addresses) in ranges {
            for address in addresses {
                XCTAssertThrowsError(try literalPolicy.validate(URL(string: "https://[\(address)]/image.png")), "\(range): \(address)")
                let resolvedPolicy = RemoteAssetURLGuard(resolve: { _ in ["2606:4700:4700::1111", address] })
                XCTAssertThrowsError(try resolvedPolicy.validate(URL(string: "https://named.test/image.png")), "DNS \(range): \(address)")
            }
        }
    }

    func testAllowsAddressesOutsideBlockedSpecialPurposeRanges() throws {
        let addresses = [
            "191.255.255.255", "192.0.1.0", "192.0.1.255", "192.0.3.0",
            "192.88.98.255", "192.88.100.0", "198.17.255.255", "198.20.0.0",
            "198.51.99.255", "198.51.101.0", "203.0.112.255", "203.0.114.0",
            "192.31.196.1", "192.52.193.1", "192.175.48.1",
            "2001:1::1", "2001:3::1", "2001:4:112::1", "2001:4860:4860::8888",
        ]
        for address in addresses {
            XCTAssertTrue(RemoteAssetURLGuard.isPublicAddress(address), address)
        }
        try RemoteAssetURLGuard().validate(URL(string: "HTTPS://8.8.8.8/image.png"))
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

    func testSlowRedirectResolutionDoesNotBlockSessionDelegateQueue() async {
        let entered = expectation(description: "redirect DNS entered")
        let returned = expectation(description: "delegate method returned while DNS waits")
        let resolved = expectation(description: "redirect completed")
        let gate = DispatchSemaphore(value: 0)
        let delegate = RemoteImageSessionDelegate(maximumByteCount: 1024, urlGuard: RemoteAssetURLGuard(resolve: { _ in
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return ["8.8.8.8"]
        }))
        let session = URLSession(configuration: .ephemeral)
        defer { gate.signal(); session.invalidateAndCancel() }
        let url = URL(string: "https://8.8.8.8/image.png")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let redirect = URLRequest(url: URL(string: "https://slow.test/image.png")!)
        let delegateQueue = DispatchQueue(label: "test.session-delegate")
        delegateQueue.async {
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirect) { request in
                XCTAssertEqual(request?.url, redirect.url)
                resolved.fulfill()
            }
            delegateQueue.async { returned.fulfill() }
        }
        await fulfillment(of: [entered, returned], timeout: 1)
        gate.signal()
        await fulfillment(of: [resolved], timeout: 5)
    }

    func testInitialAndRedirectLookupsShareTwoWorkerLimit() async {
        let firstTwo = expectation(description: "two lookups running")
        firstTwo.expectedFulfillmentCount = 2
        let excess = expectation(description: "no third concurrent lookup")
        excess.isInverted = true
        let completed = expectation(description: "all lookups complete")
        completed.expectedFulfillmentCount = 8
        let gate = DispatchSemaphore(value: 0)
        let counter = LookupCounter()
        let delegate = RemoteImageSessionDelegate(maximumByteCount: 1024, urlGuard: RemoteAssetURLGuard(resolve: { _ in
            let count = counter.begin()
            if (1...2).contains(count) { firstTwo.fulfill() } else if count == 3 { excess.fulfill() }
            _ = gate.wait(timeout: .now() + 5)
            counter.end()
            return ["8.8.8.8"]
        }))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuardImageURLProtocol.self]
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { for _ in 0..<8 { gate.signal() }; session.invalidateAndCancel() }
        let url = URL(string: "https://slow.test/image.png")!
        let tasks = (0..<8).map { _ in session.dataTask(with: url) }
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for (index, task) in tasks.enumerated() {
            if index < 4 {
                delegate.register(task: task, maximumByteCount: 1024) { result in
                    if case .failure(let error) = result { XCTFail("Stub image failed: \(error)") }
                    completed.fulfill()
                }
                delegate.start(task)
            } else {
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)) { _ in completed.fulfill() }
            }
        }
        await fulfillment(of: [firstTwo, excess], timeout: 0.1)
        counter.stopObservingStarts()
        for _ in 0..<8 { gate.signal() }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(counter.maximum, 2)
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

private final class LookupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var observing = true
    private var peak = 0
    var maximum: Int { lock.withLock { peak } }
    func begin() -> Int {
        lock.withLock {
            active += 1
            peak = max(peak, active)
            return observing ? active : 0
        }
    }
    func end() { lock.withLock { active -= 1 } }
    func stopObservingStarts() { lock.withLock { observing = false } }
}
