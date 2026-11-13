import Darwin
import Foundation
import XCTest
@testable import WaferApp

@MainActor
final class FileChangeMonitorTests: XCTestCase {
    private let debounceInterval: TimeInterval = 0.05
    private let rearmPollInterval: TimeInterval = 0.05

    func testInPlaceWriteFiresOnceAfterDebounce() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "note.md", contents: "Initial")
        let change = expectation(description: "file change")
        change.expectedFulfillmentCount = 1
        change.assertForOverFulfill = true

        let monitor = FileChangeMonitor(
            fileURL: fileURL,
            debounceInterval: debounceInterval,
            rearmPollInterval: rearmPollInterval
        ) {
            change.fulfill()
        }
        monitor.start()
        defer { monitor.stop() }

        try append(" update", to: fileURL)

        wait(for: [change], timeout: 15)
    }

    func testBurstWritesWithinDebounceWindowFireExactlyOnce() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "note.md", contents: "Initial")
        let change = expectation(description: "coalesced file change")
        change.expectedFulfillmentCount = 1
        change.assertForOverFulfill = true

        let monitor = FileChangeMonitor(
            fileURL: fileURL,
            debounceInterval: debounceInterval,
            rearmPollInterval: rearmPollInterval
        ) {
            change.fulfill()
        }
        monitor.start()
        defer { monitor.stop() }

        for index in 0..<5 {
            try append(" \(index)", to: fileURL)
        }
        wait(for: [change], timeout: 15)
    }

    func testAtomicReplaceFiresAndSubsequentInPlaceWriteStillFires() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "note.md", contents: "Initial")
        let replacementObserved = expectation(description: "atomic replacement observed")
        let subsequentWriteObserved = expectation(description: "subsequent in-place write observed")
        var callbackCount = 0
        var baselineAfterReplacement = Int.max

        let monitor = FileChangeMonitor(
            fileURL: fileURL,
            debounceInterval: debounceInterval,
            rearmPollInterval: rearmPollInterval
        ) {
            callbackCount += 1
            if callbackCount == 1 {
                replacementObserved.fulfill()
            }
            if callbackCount > baselineAfterReplacement {
                subsequentWriteObserved.fulfill()
            }
        }
        monitor.start()
        defer { monitor.stop() }

        let replacementURL = try directory.createTextFile(named: "replacement.md", contents: "Replacement")
        XCTAssertEqual(rename(replacementURL.path, fileURL.path), 0)

        wait(for: [replacementObserved], timeout: 15)
        baselineAfterReplacement = callbackCount
        try append(" after rearm", to: fileURL)

        wait(for: [subsequentWriteObserved], timeout: 15)
    }

    func testDeleteThenRecreateFiresChange() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "note.md", contents: "Initial")
        let recreated = expectation(description: "recreated file observed")

        let monitor = FileChangeMonitor(
            fileURL: fileURL,
            debounceInterval: debounceInterval,
            rearmPollInterval: rearmPollInterval
        ) {
            recreated.fulfill()
        }
        monitor.start()
        defer { monitor.stop() }

        try FileManager.default.removeItem(at: fileURL)
        try "Recreated".write(to: fileURL, atomically: true, encoding: .utf8)

        wait(for: [recreated], timeout: 15)
    }

    func testStopPreventsCallbacksAfterWrites() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "note.md", contents: "Initial")
        let change = expectation(description: "no callback after stop")
        change.isInverted = true

        let monitor = FileChangeMonitor(
            fileURL: fileURL,
            debounceInterval: debounceInterval,
            rearmPollInterval: rearmPollInterval
        ) {
            change.fulfill()
        }
        monitor.start()
        monitor.stop()

        try append(" update", to: fileURL)

        wait(for: [change], timeout: 0.3)
    }

    private func append(_ text: String, to fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
