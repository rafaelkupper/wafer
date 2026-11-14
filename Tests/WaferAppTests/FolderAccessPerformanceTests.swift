import XCTest
@testable import WaferApp
@testable import WaferCore

/// Opt-in measurements (`WAFER_PERF_TESTS=1 swift test --filter FolderAccessPerformanceTests`).
@MainActor
final class FolderAccessPerformanceTests: XCTestCase {
    /// The cost of one coverage query with 10 folder grants and 30 opened
    /// files, the shape of a long session. Sidebar summaries, the asset
    /// handler, and the notice ask this for every linked file and image.
    func testCoverageQueryCostWithManyGrantsAndOpenedFiles() throws {
        try XCTSkipUnless(PerformanceTesting.isEnabled, "set WAFER_PERF_TESTS=1 to measure")
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let access = installSandboxedFolderAccess()
        for index in 0..<10 {
            let folder = directory.url.appendingPathComponent("Granted\(index)/Notes", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            access.store.grantAccess(to: folder)
        }
        access.store.noteUserSelected((0..<30).map { directory.url.appendingPathComponent("Opened\($0).md") })
        // Outside every root, so each query checks all of them.
        let uncovered = directory.url.appendingPathComponent("Elsewhere/a/b/c/d/image.png")
        let covered = directory.url.appendingPathComponent("Granted9/Notes/x/y/z/image.png")
        XCTAssertFalse(access.store.covers(uncovered))
        XCTAssertTrue(access.store.covers(covered))

        let iterations = 2_000
        var samples: [Duration] = []
        for _ in 0..<5 {
            let clock = ContinuousClock()
            var hits = 0
            let elapsed = clock.measure {
                for _ in 0..<iterations {
                    if access.store.covers(uncovered) { hits += 1 }
                    if access.store.covers(covered) { hits += 1 }
                }
            }
            XCTAssertEqual(hits, iterations)
            samples.append(elapsed / (iterations * 2))
        }
        let median = samples.sorted()[samples.count / 2]
        print("WAFER_PERF folder-access covers median per query: \(median); samples: \(samples)")
    }
}
