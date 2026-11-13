import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

/// Wall-clock thresholds depend on the machine and its load, so they run only
/// with `WAFER_PERF_TESTS=1`. Functional assertions stay in the default suite.
enum PerformanceTesting {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WAFER_PERF_TESTS"] == "1"
    }
}

/// Opt-in measurements (`WAFER_PERF_TESTS=1 swift test --filter EditSavePerformanceTests`).
@MainActor
final class EditSavePerformanceTests: XCTestCase {
    /// How long a keystroke-triggered autosave blocks the main thread on a
    /// roughly 5 MB document. The main run loop is sampled while the save
    /// runs; any turn longer than the sampling interval is main-thread work.
    func testKeystrokeTriggeredSaveMainThreadTimeOnLargeDocument() throws {
        try XCTSkipUnless(PerformanceTesting.isEnabled, "set WAFER_PERF_TESTS=1 to measure")
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let section = "## Heading\n\nSome *emphasis*, **strong**, `code`, a [link](x.md), and café.\n\n```swift\nlet value = 1 // note\n```\n\n"
        let source = String(repeating: section, count: 5_000_000 / section.utf8.count)
        let url = try directory.createTextFile(named: "Large.md", contents: source)
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} },
            readerControllerFactory: { RecordingReaderViewController() },
            fileMonitorFactory: { _, _ in PerformanceTestFileMonitor() },
            autosaveDelay: 0.05,
            liveRenderInterval: 3_600
        )
        document.fileURL = url
        try document.read(from: Data(contentsOf: url), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        document.beginEditing()
        let textView = try XCTUnwrap(document.editorControllerForTesting?.textViewForTesting)
        // Keep TextKit and the spell checker from doing idle work while sampling.
        textView.layoutManager?.backgroundLayoutEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        settle(0.3)

        var longest: [TimeInterval] = []
        var total: [TimeInterval] = []
        for round in 0..<10 {
            let sizeBefore = fileSize(url)
            textView.insertText("x", replacementRange: NSRange(location: 20 + round, length: 0))
            let sample = sampleMainThread(until: { self.fileSize(url) == sizeBefore + 1 }, settle: 0.3)
            XCTAssertEqual(fileSize(url), sizeBefore + 1, "round \(round) saved")
            longest.append(sample.longest)
            total.append(sample.total)
        }

        textView.insertText("y", replacementRange: NSRange(location: 40, length: 0))
        let typed = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(document.flushEdits(interactive: true))
        let explicitSave = ProcessInfo.processInfo.systemUptime - typed

        func milliseconds(_ values: [TimeInterval]) -> String {
            let sorted = values.sorted()
            let list = values.map { String(format: "%.1f", $0 * 1_000) }.joined(separator: ", ")
            return String(format: "median %.1f, max %.1f", sorted[sorted.count / 2] * 1_000, sorted[sorted.count - 1] * 1_000) + " [\(list)]"
        }
        print("""
            edit-mode autosave on \(source.utf8.count) bytes: longest main-thread turn per save \(milliseconds(longest)) ms; \
            main-thread busy per save \(milliseconds(total)) ms; explicit save (Cmd-S) \(String(format: "%.1f", explicitSave * 1_000)) ms
            """)
    }

    private func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Runs the main run loop in 1 ms slices until `condition` holds, then
    /// for `settle` more seconds. Returns the longest slice and the summed
    /// excess of slices over 2 ms, both in seconds.
    private func sampleMainThread(until condition: () -> Bool, settle: TimeInterval) -> (longest: TimeInterval, total: TimeInterval) {
        var longest: TimeInterval = 0
        var total: TimeInterval = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var settleDeadline: TimeInterval?
        while ProcessInfo.processInfo.systemUptime < (settleDeadline ?? deadline) {
            let start = ProcessInfo.processInfo.systemUptime
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
            let slice = ProcessInfo.processInfo.systemUptime - start
            longest = max(longest, slice)
            if slice > 0.002 { total += slice - 0.001 }
            if settleDeadline == nil, condition() {
                settleDeadline = ProcessInfo.processInfo.systemUptime + settle
            }
        }
        return (longest, total)
    }
}

@MainActor
private final class PerformanceTestFileMonitor: FileChangeMonitoring {
    func start() {}
    func stop() {}
}
