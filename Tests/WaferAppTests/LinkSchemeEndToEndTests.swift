import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

/// Real document, renderer, and WebKit reader: clicking every link in a
/// document with dangerous schemes reaches the system opener only for the
/// allowed web link, in both Markdown and raw HTML form.
@MainActor
final class LinkSchemeEndToEndTests: XCTestCase {
    func testOnlyAllowedSchemesReachTheOpenerWhenClicked() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let source = """
            # Links

            [js](javascript:alert(1)) [data](data:text/html,hi) [shortcut](shortcuts://run-shortcut?name=x)
            [ssh](ssh://host.example) [custom](x-wafer-test://payload) [web](https://example.com/page)

            <a href="javascript:alert(2)">raw-js</a> <a href="shortcuts://run">raw-shortcut</a>
            """
        let url = try directory.createTextFile(named: "Links.md", contents: source)
        var opened: [URL] = []
        let opener = LinkTargetOpener(
            openURL: { opened.append($0) },
            revealInFinder: { opened.append($0) },
            confirmOpeningFile: { _ in .cancel },
            openMarkdownFile: { opened.append($0) }
        )
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            linkTargetHandler: { opener.handle($0) },
            fileMonitorFactory: { _, _ in LinkSchemeTestFileMonitor() },
            wikiLinkIndexProvider: { nil }
        )
        document.fileURL = url
        try document.read(from: Data(contentsOf: url), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let host = try XCTUnwrap(document.windowControllers.first as? DocumentHostWindowController)
        host.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        host.showWindow(nil)
        let reader = host.activeTab.readerController
        waitUntil("initial render", timeout: 10) { reader.isContentReadyForExport }

        let hrefs = evaluate(
            "Array.from(document.querySelectorAll('#write a[href]')).map(a => a.getAttribute('href')).join(' ')",
            in: reader
        ) as? String ?? ""
        for scheme in ["javascript:", "data:", "shortcuts:", "ssh:", "x-wafer-test:"] {
            XCTAssertFalse(hrefs.lowercased().contains(scheme), "rendered an href with \(scheme): \(hrefs)")
        }

        _ = evaluate("document.querySelectorAll('#write a').forEach(a => a.click()); true", in: reader)
        waitUntil("the allowed link was handled", timeout: 3) { !opened.isEmpty }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertEqual(opened, [URL(string: "https://example.com/page")!])
    }

    private func waitUntil(_ description: String, timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTAssertTrue(condition(), description)
    }

    private func evaluate(_ script: String, in reader: WebKitReaderViewController) -> Any? {
        let box = LinkSchemeScriptResult()
        reader.evaluateJavaScriptForTesting(script) { value, _ in
            box.value = value
            box.finished = true
        }
        waitUntil("script finished", timeout: 5) { box.finished }
        return box.value
    }
}

private final class LinkSchemeScriptResult: @unchecked Sendable {
    var value: Any?
    var finished = false
}

@MainActor
private final class LinkSchemeTestFileMonitor: FileChangeMonitoring {
    func start() {}
    func stop() {}
}
