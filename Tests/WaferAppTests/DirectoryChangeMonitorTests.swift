import XCTest
@testable import WaferApp

final class DirectoryChangeMonitorTests: XCTestCase {
    func testDeinitDoesNotUseMainActorAssumeIsolatedForTeardown() throws {
        let source = try String(contentsOf: directoryChangeMonitorSourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("MainActor.assumeIsolated"))
        XCTAssertTrue(source.contains("explicit-stop ownership contract"))
    }

    @MainActor
    func testStreamObservesMarkdownChangeAndCanRestart() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "note.md", contents: "Initial")
        let first = expectation(description: "first FSEvent")
        let second = expectation(description: "FSEvent after restart")
        var phase = 0
        let monitor = DirectoryChangeMonitor(rootURL: directory.url, latency: 0.05) {
            if phase == 0 { phase = 1; first.fulfill() }
            else if phase == 2 { phase = 3; second.fulfill() }
        }
        monitor.start()
        defer { monitor.stop() }
        try "Changed".write(to: fileURL, atomically: true, encoding: .utf8)
        wait(for: [first], timeout: 20)
        monitor.stop()
        phase = 2
        monitor.start()
        try "Changed again".write(to: fileURL, atomically: true, encoding: .utf8)
        wait(for: [second], timeout: 20)
    }

    @MainActor
    func testCallbackBoxDoesNotKeepReleasedMonitorAlive() {
        var monitor: DirectoryChangeMonitor? = DirectoryChangeMonitor(rootURL: URL(fileURLWithPath: "/tmp")) {}
        let box = DirectoryMonitorWeakBox(monitor!)
        weak var reference = monitor
        monitor = nil
        XCTAssertNil(reference)
        XCTAssertNil(box.monitor)
    }

    private var directoryChangeMonitorSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WaferApp/DirectoryChangeMonitor.swift")
    }
}
