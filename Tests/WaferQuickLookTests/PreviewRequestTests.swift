import XCTest
@testable import WaferCore

final class PreviewRequestTests: XCTestCase {
    func testAppearanceMatchTakesPrecedenceAndUnknownUsesFallback() {
        XCTAssertFalse(PreviewAppearance.isDark(matchedAppearanceIsDark: false, interfaceStyle: "Dark"))
        XCTAssertTrue(PreviewAppearance.isDark(matchedAppearanceIsDark: true, interfaceStyle: nil))
        XCTAssertTrue(PreviewAppearance.isDark(matchedAppearanceIsDark: nil, interfaceStyle: "Dark"))
        XCTAssertFalse(PreviewAppearance.isDark(matchedAppearanceIsDark: nil, interfaceStyle: nil))
    }

    @MainActor func testCompletesOnceAfterApplyingSuccessfulResult() {
        var events: [String] = []
        let request = PreviewRequest { error in
            XCTAssertNil(error)
            events.append("complete")
        }
        request.finish { events.append("apply") }
        request.finish { XCTFail("Duplicate delivery") }
        XCTAssertEqual(events, ["apply", "complete"])
    }

    @MainActor func testCancellationSuppressesDeliveryAndCompletesOnce() {
        var count = 0
        let request = PreviewRequest { error in
            XCTAssertTrue(error is CancellationError)
            count += 1
        }
        request.cancel()
        XCTAssertTrue(request.cancellation.isCancelled)
        request.finish { XCTFail("Cancelled preview applied") }
        request.finish()
        XCTAssertEqual(count, 1)
    }

    @MainActor func testFailureCompletesWithoutApplyingHTML() {
        var delivered: Error?
        let request = PreviewRequest { delivered = $0 }
        request.finish(error: CocoaError(.fileReadNoPermission)) { XCTFail("Failed preview applied") }
        XCTAssertEqual((delivered as? CocoaError)?.code, .fileReadNoPermission)
    }
}
