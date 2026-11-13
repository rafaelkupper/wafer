import XCTest
@testable import WaferApp

final class DirectoryChangeMonitorTests: XCTestCase {
    func testDeinitDoesNotUseMainActorAssumeIsolatedForTeardown() throws {
        let source = try String(contentsOf: directoryChangeMonitorSourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("MainActor.assumeIsolated"))
        XCTAssertTrue(source.contains("explicit-stop ownership contract"))
    }

    private var directoryChangeMonitorSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WaferApp/DirectoryChangeMonitor.swift")
    }
}
