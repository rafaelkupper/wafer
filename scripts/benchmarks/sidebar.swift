import Darwin
import Foundation
import AppKit
import WebKit
import WaferCore

@main struct Probe {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [FixtureURLProtocol.self]
        var fetcher: RemoteImageURLSessionFetcher? = RemoteImageURLSessionFetcher(configuration: sessionConfig)
        weak var weakFetcher = fetcher
        var done = false
        _ = fetcher!.fetch(URLRequest(url: URL(string: "https://fixture.invalid/image.png")!)) { _ in done = true }
        let deadline = Date().addingTimeInterval(3)
        while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        fetcher = nil
        print("remote fetch completed=\(done); fetcher retained after last external reference released=\(weakFetcher != nil)")
        for count in [100, 300, 500, 2000] {
            try autoreleasepool {
                let defaultsName = "wafer-review-sidebar-" + UUID().uuidString
                let defaults = UserDefaults(suiteName: defaultsName)!
                defer { defaults.removePersistentDomain(forName: defaultsName) }
                let files: [LibraryFile] = (0..<count).map { i in
                    let name = "Note-\(i).md"
                    return .init(fileURL: URL(fileURLWithPath: "/tmp/\(name)"), relativePathComponents: [name], displayTitle: "Note \(i)", outlineItems: [], plainText: "Text", searchableText: "text", contentFingerprint: .init(modificationDate: .distantPast, fileSize: 4))
                }
                let center = NotificationCenter()
                let library = LibraryController(preferenceStore: .init(defaults: defaults, notificationCenter: center), notificationCenter: center, scanner: { _ in .init(files: files, truncated: false) }, monitorFactory: { _, _ in NoDirectoryMonitor() })
                let sidebar = DocumentSidebarViewController(libraryController: library, notificationCenter: center)
                sidebar.loadViewIfNeeded()
                try library.openLibrary(at: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
                let deadline = Date().addingTimeInterval(3)
                while library.isScanning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
                let start = DispatchTime.now().uptimeNanoseconds
                sidebar.setMode(.library)
                sidebar.view.layoutSubtreeIfNeeded()
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                print("sidebar-build-and-layout-\(count) RELEASE ms=\(elapsed) rows=\(sidebar.libraryRowTitlesForTesting.count)")
                library.closeLibrary()
            }
        }
    }
}
@MainActor final class NoDirectoryMonitor: DirectoryMonitoring { func start() {} ; func stop() {} }
final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = URLResponse(url: request.url!, mimeType: "image/png", expectedContentLength: 3, textEncodingName: nil)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1,2,3]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
