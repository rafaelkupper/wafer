import Foundation
import XCTest
@testable import WaferApp

final class ReaderBehaviorPreferenceStoreTests: XCTestCase {
    func testAutomaticallyReloadsDocumentsDefaultsToTrueWhenUnset() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ReaderBehaviorPreferenceStore(defaults: defaults)

        XCTAssertTrue(store.automaticallyReloadsDocuments)
    }

    func testLoadsRemoteImagesDefaultsToTrueWhenUnset() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ReaderBehaviorPreferenceStore(defaults: defaults)

        XCTAssertTrue(store.loadsRemoteImages)
    }

    func testPersistsAutomaticallyReloadsDocumentsAndBroadcastsChange() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let notificationCenter = NotificationCenter()
        let store = ReaderBehaviorPreferenceStore(defaults: defaults, notificationCenter: notificationCenter)
        let expectation = expectation(description: "reader behavior preference change")

        let token = notificationCenter.addObserver(
            forName: .readerBehaviorPreferenceDidChange,
            object: nil,
            queue: nil
        ) { note in
            XCTAssertEqual(note.userInfo?["automaticallyReloadsDocuments"] as? Bool, false)
            expectation.fulfill()
        }

        store.automaticallyReloadsDocuments = false

        wait(for: [expectation], timeout: 2)
        XCTAssertFalse(defaults.bool(forKey: "automaticallyReloadsDocuments"))
        XCTAssertFalse(store.automaticallyReloadsDocuments)
        notificationCenter.removeObserver(token)
    }

    func testPersistsLoadsRemoteImagesAndBroadcastsChange() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let notificationCenter = NotificationCenter()
        let store = ReaderBehaviorPreferenceStore(defaults: defaults, notificationCenter: notificationCenter)
        let expectation = expectation(description: "remote image preference change")

        let token = notificationCenter.addObserver(
            forName: .readerBehaviorPreferenceDidChange,
            object: nil,
            queue: nil
        ) { note in
            XCTAssertEqual(note.userInfo?["loadsRemoteImages"] as? Bool, false)
            expectation.fulfill()
        }

        store.loadsRemoteImages = false

        wait(for: [expectation], timeout: 2)
        XCTAssertFalse(defaults.bool(forKey: "loadsRemoteImages"))
        XCTAssertFalse(store.loadsRemoteImages)
        notificationCenter.removeObserver(token)
    }
}
