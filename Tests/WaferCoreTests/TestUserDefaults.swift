import Foundation
import os
import XCTest

func makeTestUserDefaults(file: StaticString = #filePath, line: UInt = #line) -> UserDefaults {
    TestUserDefaultsSuites.shared.makeDefaults(testCase: nil, file: file, line: line)
}

extension XCTestCase {
    func makeTestUserDefaults(file: StaticString = #filePath, line: UInt = #line) -> UserDefaults {
        TestUserDefaultsSuites.shared.makeDefaults(testCase: self, file: file, line: line)
    }
}

// The inherited bool, string and data APIs dispatch through these overridden methods.
// Keep those values in memory so cfprefsd never receives a write to this suite.
// The lock preserves the thread safety expected by the injected preference stores.
private final class MemoryTestDefaults: UserDefaults {
    private let values = OSAllocatedUnfairLock(uncheckedState: [String: Any]())

    override func object(forKey defaultName: String) -> Any? {
        values.withLockUnchecked { $0[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        values.withLockUnchecked { $0[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        values.withLockUnchecked { _ = $0.removeValue(forKey: defaultName) }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        values.withLockUnchecked { $0 }
    }

    override func removePersistentDomain(forName domainName: String) {
        values.withLockUnchecked { $0.removeAll() }
    }

    override func synchronize() -> Bool { true }
}

private final class TestUserDefaultsSuites: NSObject, XCTestObservation, Sendable {
    static let shared: TestUserDefaultsSuites = {
        let observer = TestUserDefaultsSuites()
        XCTestObservationCenter.shared.addTestObserver(observer)
        return observer
    }()

    private struct State {
        var testCase: XCTestCase?
        var firstTestSuites: [Suite] = []
    }

    // Immutable reference to MemoryTestDefaults, whose values are protected by its lock.
    private struct Suite: @unchecked Sendable {
        let name: String
        let defaults: MemoryTestDefaults
        let file: StaticString
        let line: UInt

        func tearDown() throws {
            defaults.removePersistentDomain(forName: name)
            defaults.synchronize()
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
            for suffix in [".plist", ".plist.lockfile", ".lockfile"] {
                let url = directory.appendingPathComponent(name + suffix)
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "In-memory test preferences reached disk", file: file, line: line)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let prefix = "dev.wafer.tests.hygiene.\(UUID().uuidString)."

    func testCaseWillStart(_ testCase: XCTestCase) {
        state.withLockUnchecked { $0.testCase = testCase }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        let firstTestSuites = state.withLockUnchecked { state in
            state.testCase = nil
            defer { state.firstTestSuites.removeAll() }
            return state.firstTestSuites
        }
        // A free-function factory can install the observer after testCaseWillStart.
        for suite in firstTestSuites {
            do { try suite.tearDown() }
            catch { XCTFail("Cannot clear test preferences: \(error)") }
        }
    }

    func makeDefaults(testCase owner: XCTestCase?, file: StaticString, line: UInt) -> UserDefaults {
        let name = prefix + UUID().uuidString
        let defaults = MemoryTestDefaults(suiteName: name)!
        let suite = Suite(name: name, defaults: defaults, file: file, line: line)
        let testCase = state.withLockUnchecked { state in
            if let owner { state.testCase = owner }
            if state.testCase == nil { state.firstTestSuites.append(suite) }
            return state.testCase
        }
        print("WAFER_TEST_DEFAULTS_SUITE \(name)")
        testCase?.addTeardownBlock { try suite.tearDown() }
        return defaults
    }
}
