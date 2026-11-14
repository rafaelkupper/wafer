import XCTest
@testable import WaferApp

final class ReaderNavigationStateTests: XCTestCase {
    func testOnlyOwnLoadIsAuthorizedOnceAndFragmentsKeepTheDocument() {
        var state = ReaderNavigationState()
        state.reset(awaitsContentReady: false)
        let base = URL(string: "file:///notes/?existing=1")!
        let own = state.authorizeLoad(baseURL: base)
        XCTAssertTrue(own.absoluteString.contains("existing=1"))
        XCTAssertTrue(own.absoluteString.contains(state.id.uuidString))
        XCTAssertFalse(state.allowsNavigation(to: own, currentURL: nil, isMainFrame: false, isOther: true))
        XCTAssertFalse(state.allowsNavigation(to: own, currentURL: nil, isMainFrame: true, isOther: false))
        XCTAssertTrue(state.allowsNavigation(to: own, currentURL: nil, isMainFrame: true, isOther: true))
        XCTAssertFalse(state.allowsNavigation(to: own, currentURL: own, isMainFrame: true, isOther: true))
        let fragment = URL(string: own.absoluteString + "#heading")!
        XCTAssertTrue(state.allowsNavigation(to: fragment, currentURL: own, isMainFrame: true, isOther: true))
        for target in ["https://example.invalid/", "file:///notes/other.html#heading", "about:blank"] {
            XCTAssertFalse(state.allowsNavigation(to: URL(string: target)!, currentURL: own, isMainFrame: true, isOther: true))
        }
    }

    func testNewLoadReplacesAuthorizationAndUUID() {
        var state = ReaderNavigationState()
        let old = state.authorizeLoad(baseURL: nil)
        state.reset(awaitsContentReady: true)
        let new = state.authorizeLoad(baseURL: nil)
        XCTAssertNotEqual(old, new)
        XCTAssertFalse(state.allowsNavigation(to: old, currentURL: nil, isMainFrame: true, isOther: true))
        XCTAssertTrue(state.allowsNavigation(to: new, currentURL: nil, isMainFrame: true, isOther: true))
    }

    func testReadyBeforeOrAfterNavigationCompletesExactlyOnce() {
        for readyFirst in [false, true] {
            var state = ReaderNavigationState()
            state.reset(awaitsContentReady: true)
            XCTAssertFalse(state.contentReady(id: UUID().uuidString))
            XCTAssertTrue(state.awaitingContentReady)
            if readyFirst {
                XCTAssertFalse(state.contentReady(id: state.id.uuidString))
                XCTAssertFalse(state.isReady)
                XCTAssertTrue(state.navigationFinished())
            } else {
                XCTAssertFalse(state.navigationFinished())
                XCTAssertFalse(state.isReady)
                XCTAssertTrue(state.contentReady(id: state.id.uuidString))
            }
            XCTAssertTrue(state.isReady)
            XCTAssertFalse(state.navigationFinished())
            XCTAssertFalse(state.contentReady(id: state.id.uuidString))
        }
    }

    func testOldReadinessAndThemeCompletionsCannotFinishNewLoad() {
        var state = ReaderNavigationState()
        state.reset(awaitsContentReady: true)
        let oldID = state.id.uuidString
        let theme = state.beginThemeUpdate()
        state.reset(awaitsContentReady: true)
        XCTAssertFalse(state.contentReady(id: oldID))
        XCTAssertFalse(state.finishThemeUpdate(id: theme))
        XCTAssertFalse(state.navigationFinished())
        XCTAssertTrue(state.contentReady(id: state.id.uuidString))
        let first = state.beginThemeUpdate()
        let second = state.beginThemeUpdate()
        XCTAssertFalse(state.isReady)
        XCTAssertFalse(state.finishThemeUpdate(id: first))
        XCTAssertFalse(state.isReady)
        XCTAssertTrue(state.finishThemeUpdate(id: second))
        XCTAssertTrue(state.isReady)
    }
}
