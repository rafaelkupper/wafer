import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class DocumentEditingReviewTests: XCTestCase {
    func testReloadCapturedBeforeAutosaveCannotReplaceSavedEditorText() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Note.md", contents: "B")
        let captured = expectation(description: "reload captured B")
        let written = expectation(description: "autosave wrote C")
        let applied = expectation(description: "reload settled")
        let gate = ReloadDeliveryGate()
        let reader = RecordingReaderViewController()
        var awaitsReloadRender = false
        var renderedSources: [String] = []
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { source, _, _, _, completion in
                renderedSources.append(source)
                completion(WebKitRenderOutput(html: source, baseURL: nil))
                if awaitsReloadRender {
                    awaitsReloadRender = false
                    applied.fulfill()
                }
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            sourceLoader: { url in
                let loaded = try MarkdownReaderDocument.loadSource(from: url)
                if gate.beginRead() == 1 {
                    captured.fulfill()
                    gate.wait()
                }
                return loaded
            },
            fileMonitorFactory: { _, _ in DocumentReviewMonitor() },
            editConflictResolver: { kind, _ in XCTFail("Unexpected conflict: \(kind)"); return .cancel },
            editFileWriter: { url, data, beforeReplacing in
                try MarkdownEditSession.replaceContents(of: url, with: data, beforeReplacing: beforeReplacing)
                written.fulfill()
            },
            autosaveDelay: 0,
            liveRenderInterval: 0
        )
        document.fileURL = url
        try document.read(from: Data("B".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { gate.release(); document.close() }
        document.beginEditing()
        document.reloadDocument(nil)
        wait(for: [captured], timeout: 5)
        let editor = try XCTUnwrap(document.editorControllerForTesting)
        editor.replaceAllUndoably(with: "C")
        wait(for: [written], timeout: 5)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "C")
        awaitsReloadRender = true
        gate.release()
        wait(for: [applied], timeout: 5)
        XCTAssertEqual(editor.text, "C", "A reload captured before the completed save must not adopt B")
        XCTAssertEqual(renderedSources.last, "C")
        XCTAssertEqual(gate.readCount, 2, "Discard the stale read and repeat it against the saved disk state")
    }

}

private final class ReloadDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let delivery = DispatchSemaphore(value: 0)
    var readCount: Int { lock.withLock { reads } }
    func beginRead() -> Int { lock.withLock { reads += 1; return reads } }
    func wait() { _ = delivery.wait(timeout: .now() + 10) }
    func release() { delivery.signal() }
}

@MainActor
private final class DocumentReviewMonitor: FileChangeMonitoring {
    func start() {}
    func stop() {}
}
