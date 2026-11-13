import Foundation
import os
import XCTest
import WaferCore

/// Every suite belongs to one test and is removed when that test finishes,
/// including stores created inside nested document factories.
func makeTestScrollStateStore() -> ScrollStateStore {
    let suites = TestScrollStateSuites.shared
    let name = "dev.wafer.tests.scroll-state.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    suites.names.withLock { $0.append(name) }
    return ScrollStateStore(defaults: defaults)
}

private final class TestScrollStateSuites: NSObject, XCTestObservation, Sendable {
    static let shared: TestScrollStateSuites = {
        let observer = TestScrollStateSuites()
        XCTestObservationCenter.shared.addTestObserver(observer)
        return observer
    }()
    let names = OSAllocatedUnfairLock(initialState: [String]())

    func testCaseDidFinish(_ testCase: XCTestCase) {
        let suites = names.withLock { names in
            defer { names.removeAll() }
            return names
        }
        for name in suites {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
    }
}
