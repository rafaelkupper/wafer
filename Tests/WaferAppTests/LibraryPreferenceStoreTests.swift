import Foundation
import XCTest
@testable import WaferApp
@testable import WaferCore

final class LibraryPreferenceStoreTests: XCTestCase {
    func testLibraryFolderURLDefaultsToNilWhenUnset() {
        let store = LibraryPreferenceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        XCTAssertNil(store.libraryFolderURL)
    }

    func testLibraryFolderURLPersistsNormalizedPathAndBroadcastsChange() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let notificationCenter = NotificationCenter()
        let store = LibraryPreferenceStore(defaults: defaults, notificationCenter: notificationCenter)
        let url = URL(fileURLWithPath: "/tmp/../tmp/WaferLibrary", isDirectory: true)
        let expectation = expectation(description: "library preference change")

        let token = notificationCenter.addObserver(forName: .libraryPreferenceDidChange, object: nil, queue: nil) { note in
            XCTAssertEqual(note.userInfo?["libraryFolderURL"] as? URL, FileIdentity.normalized(url))
            expectation.fulfill()
        }

        store.libraryFolderURL = url

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(store.libraryFolderURL, FileIdentity.normalized(url))
        XCTAssertEqual(defaults.string(forKey: "libraryFolderPath"), FileIdentity.normalized(url).path)
        notificationCenter.removeObserver(token)
    }

    func testClearingLibraryFolderURLRemovesPersistedPath() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = LibraryPreferenceStore(defaults: defaults)
        store.libraryFolderURL = URL(fileURLWithPath: "/tmp/WaferLibrary", isDirectory: true)

        store.libraryFolderURL = nil

        XCTAssertNil(store.libraryFolderURL)
        XCTAssertNil(defaults.string(forKey: "libraryFolderPath"))
    }
}
