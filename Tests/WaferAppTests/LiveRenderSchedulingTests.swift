import AppKit
import XCTest
@testable import WaferApp
import WaferCore

@MainActor
final class LiveRenderSchedulingTests: XCTestCase {
    func testContinuousLiveRequestsFinishInFlightRenderThenRenderNewestText() throws {
        let reader = LiveRenderRecordingReader()
        var sources: [String] = []
        var completions: [(WebKitRenderOutput) -> Void] = []
        var items: [DispatchWorkItem] = []
        let document = MarkdownReaderDocument(
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { source, _, _, _, completion in
                sources.append(source)
                completions.append(completion)
                let item = DispatchWorkItem {}
                items.append(item)
                return item
            },
            readerControllerFactory: { reader }
        )
        defer { document.close() }
        try document.read(from: Data("initial".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        completions[0](WebKitRenderOutput(html: "initial", baseURL: nil))
        let coordinator = MarkdownEditCoordinator(configuration: .init(
            resolveConflict: { _, _ in .cancel }, autosaveDelay: 1, liveRenderInterval: 0.1
        ))
        // Each call represents a throttle tick. The injected render queue is
        // deliberately held until several more ticks arrive, without sleeps.
        document.editCoordinator(coordinator, renderLive: "first")
        for text in ["second", "third", "newest"] {
            document.editCoordinator(coordinator, renderLive: text)
        }
        XCTAssertEqual(sources, ["initial", "first"])
        XCTAssertFalse(items[1].isCancelled)
        completions[1](WebKitRenderOutput(html: "first", baseURL: nil))
        XCTAssertEqual(reader.liveHTML, ["first"], "The in-flight result must reach the preview")
        XCTAssertEqual(sources, ["initial", "first", "newest"])
        // Use last so the unfixed implementation fails assertions, not indexing.
        completions.last?(WebKitRenderOutput(html: "newest", baseURL: nil))
        XCTAssertEqual(reader.liveHTML, ["first", "newest"])
    }
}

@MainActor
private final class LiveRenderRecordingReader: WebKitReaderViewController {
    var liveHTML: [String] = []
    override func displayLoading(for fileName: String) {}
    override func apply(renderOutput: WebKitRenderOutput, initialScrollFraction: Double?) {}
    override func applyLiveUpdate(
        renderOutput: WebKitRenderOutput,
        editorPosition: EditorScrollPosition? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        liveHTML.append(renderOutput.html)
        completion?(true)
    }
}
