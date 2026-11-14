import XCTest
import WaferCore
@testable import WaferQuickLookSupport

@MainActor
final class PreviewRequestCoordinatorTests: XCTestCase {
    func testSuccessAppliesBeforeCompletingExactlyOnce() {
        let coordinator = PreviewRequestCoordinator()
        var events: [String] = []
        let request = coordinator.begin { error in
            XCTAssertNil(error)
            events.append("complete")
        }
        coordinator.finish(request) { events.append("apply") }
        coordinator.finish(request) { XCTFail("Duplicate delivery") }
        XCTAssertEqual(events, ["apply", "complete"])
    }

    func testReplacementCompletesImmediatelyAndSuppressesLateResults() {
        let coordinator = PreviewRequestCoordinator()
        var events: [String] = []
        let first = coordinator.begin { error in
            XCTAssertTrue(error is CancellationError)
            events.append("first cancelled")
        }
        let second = coordinator.begin { error in
            XCTAssertNil(error)
            events.append("second complete")
        }
        XCTAssertTrue(first.cancellation.isCancelled)
        XCTAssertEqual(events, ["first cancelled"])
        coordinator.finish(second) { events.append("second applied") }
        coordinator.finish(first) { XCTFail("Stale result applied") }
        XCTAssertEqual(events, ["first cancelled", "second applied", "second complete"])
    }

    func testStaleFailureDoesNotDisplaceCurrentRequest() {
        let coordinator = PreviewRequestCoordinator()
        var completions = 0
        let first = coordinator.begin { _ in completions += 1 }
        let second = coordinator.begin { error in
            XCTAssertNil(error)
            completions += 1
        }
        coordinator.finish(first, error: CocoaError(.fileReadUnknown))
        coordinator.finish(second)
        XCTAssertEqual(completions, 2)
    }

    func testCompositionAndPresentationFailuresReachCompletion() {
        for failsDuringPresentation in [false, true] {
            let coordinator = PreviewRequestCoordinator()
            var delivered: Error?
            let request = coordinator.begin { delivered = $0 }
            if failsDuringPresentation {
                coordinator.finish(request) { throw CocoaError(.coderInvalidValue) }
            } else {
                coordinator.finish(request, error: CocoaError(.coderInvalidValue)) {
                    XCTFail("Failed composition applied")
                }
            }
            XCTAssertEqual((delivered as? CocoaError)?.code, .coderInvalidValue)
        }
    }

    func testCompletionCanReenterAndReplaceAnotherRequest() {
        let coordinator = PreviewRequestCoordinator()
        var events: [String] = []
        var newest: PreviewRequest?
        let first = coordinator.begin { _ in
            events.append("first")
            newest = coordinator.begin { _ in events.append("newest") }
        }
        let second = coordinator.begin { _ in events.append("second") }
        coordinator.finish(first) { XCTFail("Replaced first request applied") }
        coordinator.finish(second) { XCTFail("Replaced second request applied") }
        coordinator.finish(newest!) { events.append("apply newest") }
        XCTAssertEqual(events, ["first", "second", "apply newest", "newest"])
    }

    func testTeardownCancelsAndCompletesPendingRequestOnMainThread() async {
        let completed = expectation(description: "cancelled during teardown")
        var coordinator: PreviewRequestCoordinator? = PreviewRequestCoordinator()
        let request = coordinator!.begin { error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(error is CancellationError)
            completed.fulfill()
        }
        weak let released = coordinator
        coordinator = nil
        XCTAssertNil(released)
        XCTAssertTrue(request.cancellation.isCancelled)
        await fulfillment(of: [completed], timeout: 2)
    }
}
