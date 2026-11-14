import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

/// Real document, render worker, and WebKit reader: clicking an in-page
/// link to a heading with a non-ASCII name scrolls to that heading.
@MainActor
final class AnchorLinkEndToEndTests: XCTestCase {
    private func waitUntil(_ description: String, timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTAssertTrue(condition(), description)
    }

    private func evaluate(_ script: String, in reader: WebKitReaderViewController) -> Any? {
        let box = AnchorScriptResult()
        reader.evaluateJavaScriptForTesting(script) { value, _ in
            box.value = value
            box.finished = true
        }
        waitUntil("script finished", timeout: 5) { box.finished }
        return box.value
    }

    /// Clicks the link at `index` from the top of the page and waits until
    /// the element with `id` is near the top of the view.
    private func click(linkAt index: Int, reaches id: String, in reader: WebKitReaderViewController) {
        _ = evaluate("window.scrollTo(0, 0); true", in: reader)
        _ = evaluate("document.querySelectorAll('#write a[href]')[\(index)].click(); true", in: reader)
        waitUntil("the link scrolled to \(id)", timeout: 2) {
            let top = self.evaluate("""
                (function() { const t = document.getElementById('\(id)'); return t ? t.getBoundingClientRect().top : 100000; })()
                """, in: reader) as? Double ?? 100000
            return abs(top) < 120
        }
    }

    /// The reader side alone: hrefs percent-encoded once, as a correct
    /// renderer emits them, reach the decoded heading IDs.
    func testClickedFragmentsEncodedOnceReachTheHeadings() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let filler = (1...60).map { "Paragraph \($0) with enough words to fill a line." }.joined(separator: "\n\n")
        let source = "# Start\n\n[one](#x) [two](#y)\n\n\(filler)\n\n## Café\n\n\(filler)\n\n## 日本語\n\n\(filler)\n"
        let url = try directory.createTextFile(named: "Encoded.md", contents: source)
        let document = MarkdownReaderDocument(
            scrollStateStore: makeTestScrollStateStore(),
            fileMonitorFactory: { _, _ in AnchorTestFileMonitor() },
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
        _ = evaluate("""
            (function() {
              const links = document.querySelectorAll('#write a[href]');
              links[0].setAttribute('href', 'Encoded.md#caf%C3%A9');
              links[1].setAttribute('href', 'Encoded.md#%E6%97%A5%E6%9C%AC%E8%AA%9E');
              return true;
            })()
            """, in: reader)

        click(linkAt: 0, reaches: "café", in: reader)
        click(linkAt: 1, reaches: "日本語", in: reader)
    }

    func testClickingLinksToNonASCIIHeadingsScrollsToThem() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let filler = (1...60).map { "Paragraph \($0) with enough words to fill a line." }.joined(separator: "\n\n")
        let source = """
            # Start

            [To the end](#the-end), [to café](#café), and [to 日本語](#日本語).

            \(filler)

            ## Café

            \(filler)

            ## 日本語

            \(filler)

            ## The End

            \(filler)
            """
        let url = try directory.createTextFile(named: "Anchors.md", contents: source)
        let document = MarkdownReaderDocument(
            scrollStateStore: makeTestScrollStateStore(),
            fileMonitorFactory: { _, _ in AnchorTestFileMonitor() },
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

        // Control: an ASCII anchor proves the click reaches the document.
        click(linkAt: 0, reaches: "the-end", in: reader)

        let hrefs = evaluate("Array.from(document.querySelectorAll('#write a[href]')).map(a => a.getAttribute('href')).join(' ')", in: reader) as? String ?? ""
        XCTAssertFalse(hrefs.contains("%25"), "fragment hrefs must be percent-encoded exactly once: \(hrefs)")
        click(linkAt: 1, reaches: "café", in: reader)
        click(linkAt: 2, reaches: "日本語", in: reader)
    }
}

private final class AnchorScriptResult: @unchecked Sendable {
    var value: Any?
    var finished = false
}

@MainActor
private final class AnchorTestFileMonitor: FileChangeMonitoring {
    func start() {}
    func stop() {}
}
