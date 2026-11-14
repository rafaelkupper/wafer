import XCTest
@testable import WaferApp
import WaferCore

@MainActor
final class DocumentRenderCoordinatorTests: XCTestCase {
    @MainActor
    private final class Harness {
        var requests: [DocumentRenderCoordinator.Request] = []
        var completions: [DocumentRenderCoordinator.Completion] = []
        var items: [DispatchWorkItem] = []
        var applied: [String] = []
        var text = "first"
        var editing = false
        var palette = ReaderThemePalette.dark
        lazy var coordinator = DocumentRenderCoordinator { [unowned self] request, completion in
            requests.append(request)
            completions.append(completion)
            let item = DispatchWorkItem {}
            items.append(item)
            return item
        }

        func request(live: Bool = false) {
            coordinator.request(live: live) { [unowned self] in
                .init(source: text, baseURL: nil, palette: palette, wikiLinkIndex: nil,
                      annotatesSourceLines: editing) { [unowned self] output in
                    applied.append(output.html)
                }
            }
        }

        func complete(_ index: Int) {
            completions[index](WebKitRenderOutput(html: requests[index].source, baseURL: nil))
        }
    }

    func testNewFullRenderSupersedesOldCompletion() {
        let h = Harness()
        h.request()
        h.text = "new"
        h.request()
        XCTAssertTrue(h.items[0].isCancelled)
        h.complete(0)
        XCTAssertTrue(h.applied.isEmpty)
        XCTAssertTrue(h.coordinator.isRendering)
        h.complete(1)
        XCTAssertEqual(h.applied, ["new"])
        XCTAssertFalse(h.coordinator.isRendering)
    }

    func testThemeChangedDuringRenderRepairsArrivingPageAfterReadiness() {
        let h = Harness()
        h.request()
        h.complete(0)
        var themes: [String] = []
        h.text = "second"
        h.request()
        h.coordinator.applyThemeIfNeeded(.light, isContentReady: true) { themes.append($0.name) }
        XCTAssertEqual(themes, ["Light"])
        h.complete(1)
        XCTAssertEqual(h.coordinator.renderedPalette, .dark)
        h.coordinator.applyThemeIfNeeded(.light, isContentReady: false) { themes.append($0.name) }
        XCTAssertEqual(themes.count, 1)
        h.coordinator.applyThemeIfNeeded(.light, isContentReady: true) { themes.append($0.name) }
        h.coordinator.applyThemeIfNeeded(.light, isContentReady: true) { themes.append($0.name) }
        XCTAssertEqual(themes, ["Light", "Light"])
    }

    func testTypingLetsActiveRenderFinishThenSnapshotsNewestTextAndPalette() {
        let h = Harness()
        h.request()
        h.complete(0)
        h.editing = true
        h.text = "a"
        h.request(live: true)
        h.text = "ab"
        h.request(live: true)
        h.text = "abc"
        h.request(live: true)
        h.palette = .light
        XCTAssertEqual(h.requests.count, 2)
        XCTAssertFalse(h.items[1].isCancelled)
        h.complete(1)
        XCTAssertEqual(h.applied, ["first", "a"])
        XCTAssertEqual(h.requests.map(\.source), ["first", "a", "abc"])
        XCTAssertEqual(h.requests[2].palette, .light)
        h.complete(2)
        XCTAssertEqual(h.applied, ["first", "a", "abc"])
        XCTAssertEqual(h.coordinator.renderedPalette, .dark, "Body patches preserve the page palette")
    }

    func testFullReloadDuringLiveRenderDiscardsPendingTypingAndOldCompletion() {
        let h = Harness()
        h.editing = true
        h.request(live: true)
        h.text = "typing"
        h.request(live: true)
        h.text = "disk reload"
        h.request()
        h.complete(0)
        h.complete(1)
        XCTAssertEqual(h.requests.map(\.source), ["first", "disk reload"])
        XCTAssertEqual(h.applied, ["disk reload"])
        XCTAssertFalse(h.coordinator.isRendering)
    }

    func testEditModeEnterAndExitCarryAnnotationsPerRequest() {
        let h = Harness()
        h.request()
        h.complete(0)
        h.editing = true
        h.request(live: true)
        h.editing = false
        h.request(live: true)
        h.complete(1)
        h.complete(2)
        XCTAssertEqual(h.requests.map(\.annotatesSourceLines), [false, true, false])
        XCTAssertEqual(h.applied.count, 3)
    }

    func testCancelInvalidatesCompletionAndQueuedLiveRequest() {
        let h = Harness()
        h.request()
        h.request(live: true)
        h.coordinator.cancel()
        h.complete(0)
        XCTAssertTrue(h.items[0].isCancelled)
        XCTAssertTrue(h.applied.isEmpty)
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertFalse(h.coordinator.isRendering)
    }

    func testSynchronousSchedulerCompletionDoesNotLeaveRenderActive() {
        let coordinator = DocumentRenderCoordinator { _, complete in
            complete(WebKitRenderOutput(html: "done", baseURL: nil))
            return DispatchWorkItem {}
        }
        var outputs: [String] = []
        coordinator.request(live: false) {
            .init(source: "source", baseURL: nil, palette: .dark, wikiLinkIndex: nil,
                  annotatesSourceLines: false) { outputs.append($0.html) }
        }
        XCTAssertEqual(outputs, ["done"])
        XCTAssertFalse(coordinator.isRendering)
    }
}
