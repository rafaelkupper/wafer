import XCTest
@testable import WaferApp
import WaferCore

@MainActor
final class ReaderLivePreviewControllerTests: XCTestCase {
    @MainActor
    private final class Harness {
        struct Call {
            let script: String
            let arguments: [String: Any]
            let world: ReaderLivePreviewController.World
            let complete: @MainActor (Result<Any, Error>) -> Void
        }
        var calls: [Call] = []
        var reloads: [WebKitRenderOutput] = []
        var ready = true
        lazy var preview: ReaderLivePreviewController = ReaderLivePreviewController(evaluate: { [unowned self] script, arguments, world, complete in
            calls.append(Call(script: script, arguments: arguments, world: world, complete: complete))
        }, isContentReady: { [unowned self] in ready }, reload: { [unowned self] in
            reloads.append($0)
            preview.reset(for: $0)
        })
    }

    private func output(_ body: String = "<p>body</p>", mermaid: Bool = false, math: Bool = false) -> WebKitRenderOutput {
        WebKitRenderOutput(html: "page", baseURL: nil, bodyHTML: body, hasMermaidDiagrams: mermaid, hasMathDisplays: math)
    }

    private func position(_ line: Double, bottom: Double = 90) -> EditorScrollPosition {
        EditorScrollPosition(line: line, topLine: 1, bottomLine: bottom, visibleLines: 10, totalLines: 100)
    }

    func testPatchBaselineIsSeededOnceAndPatchUsesPageWorld() {
        let h = Harness()
        h.preview.reset(for: output("old"))
        var results: [Bool] = []
        h.preview.applyLiveUpdate(renderOutput: output("new")) { results.append($0) }
        XCTAssertEqual(h.calls.count, 1)
        XCTAssertEqual(h.calls[0].world, .page)
        XCTAssertEqual(h.calls[0].arguments["previous"] as? String, "old")
        XCTAssertEqual(h.calls[0].arguments["html"] as? String, "new")
        h.calls[0].complete(.success("patched"))
        h.preview.applyLiveUpdate(renderOutput: output("newest")) { results.append($0) }
        XCTAssertTrue(h.calls[1].arguments["previous"] is NSNull)
        h.calls[1].complete(.success("patched:2"))
        XCTAssertEqual(results, [true, true])
        XCTAssertTrue(h.reloads.isEmpty)
    }

    func testReloadWhenUnreadyMissingBodyOrNeededRendererIsAbsent() {
        for missing in ["readiness", "baseline", "body", "mermaid", "math"] {
            let h = Harness()
            h.preview.reset(for: missing == "baseline" ? nil : output())
            h.ready = missing != "readiness"
            let next = missing == "body" ? WebKitRenderOutput(html: "page", baseURL: nil)
                : output(mermaid: missing == "mermaid", math: missing == "math")
            var patched: Bool?
            h.preview.applyLiveUpdate(renderOutput: next) { patched = $0 }
            XCTAssertEqual(patched, false, missing)
            XCTAssertEqual(h.reloads.count, 1, missing)
            XCTAssertTrue(h.calls.isEmpty, missing)
        }
    }

    func testPatchFailureReloadsAndOldPageCompletionIsIgnored() {
        let h = Harness()
        h.preview.reset(for: output())
        var results: [Bool] = []
        h.preview.applyLiveUpdate(renderOutput: output("changed")) { results.append($0) }
        h.calls[0].complete(.success("reload"))
        XCTAssertEqual(results, [false])
        XCTAssertEqual(h.reloads.count, 1)
        h.preview.applyLiveUpdate(renderOutput: output("late")) { results.append($0) }
        h.preview.reset(for: output("replacement"))
        h.calls[1].complete(.success("patched"))
        XCTAssertEqual(results, [false])
        XCTAssertEqual(h.reloads.count, 1)
        h.preview.applyLiveUpdate(renderOutput: output("next"))
        XCTAssertEqual(h.calls[2].arguments["previous"] as? String, "replacement")
    }

    func testScrollRequestsCoalesceAndUseIsolatedWorld() {
        let h = Harness()
        h.preview.reset(for: output())
        h.preview.syncScroll(to: position(10))
        h.preview.syncScroll(to: position(20))
        h.preview.syncScroll(to: position(30))
        XCTAssertEqual(h.calls.count, 1)
        XCTAssertEqual(h.calls[0].world, .reader)
        XCTAssertEqual(h.calls[0].script, ReaderLivePreviewScript.scrollCall)
        h.calls[0].complete(.success(true))
        XCTAssertEqual(h.calls.count, 2)
        XCTAssertEqual(h.calls[1].arguments["line"] as? Double, 30)
        XCTAssertEqual(h.calls[1].script, ReaderLivePreviewScript.installedScrollCall)
        h.calls[1].complete(.success(true))
        XCTAssertEqual(h.calls.count, 2)
    }

    func testResetDropsPendingScrollAndReinstallsHelpersOnNextPage() {
        let h = Harness()
        h.preview.reset(for: output())
        h.preview.syncScroll(to: position(10))
        h.preview.syncScroll(to: position(20))
        h.preview.reset(for: output("next"))
        h.calls[0].complete(.success(true))
        XCTAssertEqual(h.calls.count, 1)
        h.preview.syncScroll(to: position(30))
        XCTAssertEqual(h.calls[1].script, ReaderLivePreviewScript.scrollCall)
        XCTAssertEqual(h.calls[1].arguments["line"] as? Double, 30)
    }

    func testNewPageScrollBeforeOldCompletionPreservesCurrentRequests() {
        let h = Harness()
        h.preview.reset(for: output())
        h.preview.syncScroll(to: position(10))
        h.preview.reset(for: output("next"))
        h.preview.syncScroll(to: position(30))
        h.preview.syncScroll(to: position(40))
        XCTAssertEqual(h.calls.count, 2, "The new page must not wait for the old page's callback")
        guard h.calls.count == 2 else { return }
        XCTAssertEqual(h.calls[1].script, ReaderLivePreviewScript.scrollCall)
        XCTAssertEqual(h.calls[1].arguments["line"] as? Double, 30)

        h.calls[0].complete(.success(true))
        XCTAssertEqual(h.calls.count, 2, "A stale callback must not drain the new page's pending request")
        h.calls[1].complete(.success(true))
        XCTAssertEqual(h.calls.count, 3, "The current callback must drain its pending request")
        guard h.calls.count == 3 else { return }
        XCTAssertEqual(h.calls[2].arguments["line"] as? Double, 40)
        XCTAssertEqual(h.calls[2].script, ReaderLivePreviewScript.installedScrollCall)

        h.preview.syncScroll(to: position(50))
        XCTAssertEqual(h.calls.count, 3)
        h.calls[2].complete(.success(true))
        XCTAssertEqual(h.calls.count, 4)
        XCTAssertEqual(h.calls.last?.arguments["line"] as? Double, 50)
    }

    func testMetricsOnlyUpdateWhenRangeChangesAndEditExitDropsPendingScroll() {
        let h = Harness()
        h.preview.reset(for: output())
        h.preview.updateScrollSyncMetrics(position(10))
        XCTAssertTrue(h.calls.isEmpty)
        h.preview.syncScroll(to: position(10))
        h.preview.updateScrollSyncMetrics(position(20))
        XCTAssertEqual(h.calls.count, 1)
        h.preview.updateScrollSyncMetrics(position(20, bottom: 80))
        XCTAssertEqual(h.calls[1].script, ReaderLivePreviewScript.updateMetricsCall)
        XCTAssertEqual(h.calls[1].world, .reader)
        h.preview.syncScroll(to: position(30))
        h.preview.endLivePreview()
        XCTAssertEqual(h.calls[2].script, ReaderLivePreviewScript.deactivateCall)
        h.calls[0].complete(.success(true))
        XCTAssertEqual(h.calls.count, 3)
    }

    func testPatchRealignsScrollAndLineAtTopDecodesOptionalResult() {
        let h = Harness()
        h.preview.reset(for: output())
        h.preview.applyLiveUpdate(renderOutput: output("new"), editorPosition: position(25))
        h.calls[0].complete(.success("patched"))
        XCTAssertEqual(h.calls[1].world, .reader)
        XCTAssertEqual(h.calls[1].arguments["line"] as? Double, 25)
        var line: Double?
        h.preview.sourceLineAtTop(for: position(25)) { line = $0 }
        h.calls[2].complete(.success(NSNumber(value: 26.5)))
        XCTAssertEqual(line, 26.5)
        h.preview.sourceLineAtTop(for: position(25)) { line = $0 }
        h.calls[3].complete(.success(NSNull()))
        XCTAssertNil(line)
        h.ready = false
        line = 10
        h.preview.sourceLineAtTop(for: position(25)) { line = $0 }
        XCTAssertNil(line)
        XCTAssertEqual(h.calls.count, 4)
    }
}
