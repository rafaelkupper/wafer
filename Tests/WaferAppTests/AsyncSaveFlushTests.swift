import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class AsyncSaveFlushTests: XCTestCase {
    private func makeDocument(
        at url: URL, gate: ControlledSaveWriter, makesWindow: Bool = true,
        sourceLoader: @escaping MarkdownReaderDocument.SourceLoader = MarkdownReaderDocument.loadSource,
        onRender: @escaping (String) -> Void = { _ in },
        resolveConflict: @escaping EditConflictResolver = { kind, _ in
            XCTFail("Unexpected conflict: \(kind)"); return .cancel
        }
    ) throws -> MarkdownReaderDocument {
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { source, _, _, _, completion in
                onRender(source)
                completion(WebKitRenderOutput(html: source, baseURL: nil))
                return DispatchWorkItem {}
            },
            readerControllerFactory: { RecordingReaderViewController() },
            statisticPreferenceStore: DocumentStatisticPreferenceStore(defaults: makeTestUserDefaults()),
            appearancePreferenceStore: AppearancePreferenceStore(defaults: makeTestUserDefaults()),
            readerBehaviorPreferenceStore: ReaderBehaviorPreferenceStore(defaults: makeTestUserDefaults()),
            sourceLoader: sourceLoader,
            fileMonitorFactory: { _, _ in AsyncSaveMonitor() },
            editConflictResolver: resolveConflict,
            editFileWriter: gate.write,
            autosaveDelay: 3_600, liveRenderInterval: 3_600
        )
        document.fileURL = url
        try document.read(from: Data(contentsOf: url), ofType: "dev.wafer.markdown")
        if makesWindow { document.makeWindowControllers() }
        document.beginEditing()
        return document
    }

    // This test also runs unchanged against 0bba9cd: the writer times out
    // there because saveEdits prevents the main turn that releases it.
    func testExplicitSaveReturnsBeforeWriterReleased() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Note.md", contents: "old")
        let gate = ControlledSaveWriter()
        let document = try makeDocument(at: url, gate: gate)
        defer { gate.release(); document.close() }
        document.editorControllerForTesting?.replaceAllUndoably(with: "new")

        document.saveEdits(nil)
        wait(for: [gate.entered], timeout: 5)
        XCTAssertEqual(gate.writes, [])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old")
        let responsive = expectation(description: "main actor responds while save is blocked")
        DispatchQueue.main.async {
            responsive.fulfill()
            gate.release()
        }
        wait(for: [responsive, gate.finished], timeout: 5)
        XCTAssertFalse(gate.timedOut, "The save action must return while the disk writer is blocked")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        let settled = expectation(description: "save bookkeeping delivered")
        document.flushEdits(interactive: true) { _ in settled.fulfill() }
        wait(for: [settled], timeout: 5)
    }

    func testNavigationWaitsForWriteWithoutBlockingMainActor() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Note.md", contents: "old")
        let target = try directory.createTextFile(named: "Target.md", contents: "target")
        let gate = ControlledSaveWriter()
        let targetRead = expectation(description: "navigation read starts after save")
        let navigated = expectation(description: "navigation shows the new file after saving")
        let document = try makeDocument(at: url, gate: gate, sourceLoader: { url in
            XCTAssertEqual(try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("Note.md"), encoding: .utf8), "newer")
            targetRead.fulfill()
            return try MarkdownReaderDocument.loadSource(from: url)
        }, onRender: { source in
            if source == "target" { navigated.fulfill() }
        })
        defer { gate.release(); document.close() }
        document.editorControllerForTesting?.replaceAllUndoably(with: "new")
        document.navigateInCurrentWindow(to: target)
        wait(for: [gate.entered], timeout: 5)
        XCTAssertEqual(document.fileURL, url)
        XCTAssertEqual(document.editorControllerForTesting?.text, "new")
        // The later revision must be written before navigation can continue.
        document.editorControllerForTesting?.replaceAllUndoably(with: "newer")
        gate.release()
        wait(for: [targetRead, navigated], timeout: 5)
        XCTAssertEqual(document.fileURL, target)
        XCTAssertEqual(document.editorControllerForTesting?.text, "target")
        XCTAssertEqual(gate.writes, ["new", "newer"])
    }

    func testRepeatedCloseAndQuitShareFlushAndWaitForNewerText() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Note.md", contents: "old")
        let gate = ControlledSaveWriter()
        let document = try makeDocument(at: url, gate: gate)
        defer { gate.release(); document.close() }
        document.editorControllerForTesting?.replaceAllUndoably(with: "new")
        document.close()
        document.close()
        wait(for: [gate.entered], timeout: 5)
        XCTAssertFalse(document.windowControllers.isEmpty, "Close must defer while the write runs")
        document.editorControllerForTesting?.replaceAllUndoably(with: "newer")
        let delegate = AppDelegate(openURLs: { _ in }, reopenPersistedLibrary: {},
                                   scrollStateStore: makeTestScrollStateStore(),
                                   appearancePreferenceStore: AppearancePreferenceStore(defaults: makeTestUserDefaults()))
        var flushes = 0
        var replies: [Bool] = []
        let quitCompleted = expectation(description: "deferred quit replied once")
        delegate.flushForTermination = { completion in
            flushes += 1
            MarkdownReaderDocument.flushEdits(in: [document], completion: completion)
        }
        delegate.replyToTermination = { _, success in
            replies.append(success)
            XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "newer")
            quitCompleted.fulfill()
        }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertEqual(replies, [])
        gate.release()
        wait(for: [quitCompleted], timeout: 5)
        XCTAssertEqual(flushes, 1)
        XCTAssertEqual(replies, [true])
        XCTAssertTrue(document.windowControllers.isEmpty)
        XCTAssertEqual(gate.writes, ["new", "newer"])
    }

    func testConcurrentTabClosesRecheckWhichTabIsLast() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let firstURL = try directory.createTextFile(named: "First.md", contents: "old")
        let secondURL = try directory.createTextFile(named: "Second.md", contents: "two")
        let firstGate = ControlledSaveWriter()
        let secondGate = ControlledSaveWriter()
        let first = try makeDocument(at: firstURL, gate: firstGate)
        let second = try makeDocument(at: secondURL, gate: secondGate, makesWindow: false)
        defer { firstGate.release(); secondGate.release(); first.close(); second.close() }
        let host = try XCTUnwrap(first.windowControllers.first as? DocumentHostWindowController)
        host.tabDocumentFactoryForTesting = { _ in second }
        host.openTab(for: secondURL)
        second.beginEditing()
        first.editorControllerForTesting?.replaceAllUndoably(with: "new")
        second.editorControllerForTesting?.replaceAllUndoably(with: "two-new")

        host.closeTab(at: 0)
        host.closeTab(at: 1)
        wait(for: [firstGate.entered, secondGate.entered], timeout: 5)
        XCTAssertEqual(host.tabs.count, 2)
        let firstClosed = expectation(description: "first tab closes after its write")
        first.flushEdits(interactive: true) { success in
            XCTAssertTrue(success)
            XCTAssertEqual(host.tabs.count, 1)
            firstClosed.fulfill()
        }
        firstGate.release()
        wait(for: [firstClosed], timeout: 5)
        let lastClosed = expectation(description: "last tab closes through the window hook")
        second.flushEdits(interactive: true) { success in
            XCTAssertTrue(success)
            XCTAssertTrue(second.windowControllers.isEmpty)
            lastClosed.fulfill()
        }
        secondGate.release()
        wait(for: [lastClosed], timeout: 5)
        XCTAssertEqual(firstGate.writes, ["new"])
        XCTAssertEqual(secondGate.writes, ["two-new"])
    }

    func testQuitIncludesDocumentOpenedWhileEarlierSaveIsBlocked() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let controller = NSDocumentController.shared
        XCTAssertTrue(controller.documents.isEmpty, "Only disposable test documents may be flushed")
        let firstURL = try directory.createTextFile(named: "First.md", contents: "old")
        let secondURL = try directory.createTextFile(named: "Second.md", contents: "two")
        let firstGate = ControlledSaveWriter()
        let secondGate = ControlledSaveWriter()
        let first = try makeDocument(at: firstURL, gate: firstGate)
        let second = try makeDocument(at: secondURL, gate: secondGate)
        defer { firstGate.release(); secondGate.release(); first.close(); second.close() }
        controller.addDocument(first)
        first.editorControllerForTesting?.replaceAllUndoably(with: "new")
        let quitFlushed = expectation(description: "all documents saved including the later one")
        MarkdownReaderDocument.flushAllEdits { success in
            XCTAssertTrue(success)
            XCTAssertEqual(try? String(contentsOf: secondURL, encoding: .utf8), "two-new")
            quitFlushed.fulfill()
        }
        wait(for: [firstGate.entered], timeout: 5)
        controller.addDocument(second)
        second.editorControllerForTesting?.replaceAllUndoably(with: "two-new")
        firstGate.release()
        wait(for: [secondGate.entered], timeout: 5)
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "new")
        secondGate.release()
        wait(for: [quitFlushed], timeout: 5)
        XCTAssertEqual(firstGate.writes, ["new"])
        XCTAssertEqual(secondGate.writes, ["two-new"])
    }

    func testCancelledCloseAlsoCancelsConcurrentQuitWithoutLosingText() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Note.md", contents: "old")
        let gate = ControlledSaveWriter()
        var conflicts: [EditConflictKind] = []
        let document = try makeDocument(at: url, gate: gate, resolveConflict: { kind, _ in
            conflicts.append(kind)
            return .cancel
        })
        defer {
            gate.release()
            // Test-owned cleanup: clear unsaved text without touching the external bytes.
            document.editorControllerForTesting?.load(text: "old")
            XCTAssertTrue(document.flushEditsAndWait(interactive: true))
            document.close()
        }
        document.editorControllerForTesting?.replaceAllUndoably(with: "mine")
        try Data("external".utf8).write(to: url)
        document.close()
        wait(for: [gate.entered], timeout: 5)
        let delegate = AppDelegate(openURLs: { _ in }, reopenPersistedLibrary: {},
                                   scrollStateStore: makeTestScrollStateStore(),
                                   appearancePreferenceStore: AppearancePreferenceStore(defaults: makeTestUserDefaults()))
        let replied = expectation(description: "quit cancelled after close conflict")
        delegate.flushForTermination = { MarkdownReaderDocument.flushEdits(in: [document], completion: $0) }
        delegate.replyToTermination = { _, success in
            XCTAssertFalse(success)
            replied.fulfill()
        }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        gate.release()
        wait(for: [replied], timeout: 5)
        XCTAssertEqual(conflicts, [.changedOnDisk])
        XCTAssertEqual(document.editorControllerForTesting?.text, "mine")
        XCTAssertFalse(document.windowControllers.isEmpty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
        XCTAssertEqual(gate.writes, [])
    }

    func testUseDiskVersionKeepsTheDiskTextWhenTypingRacedTheConflict() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Note.md", contents: "old")
        let gate = ControlledSaveWriter()
        gate.release()
        var document: MarkdownReaderDocument?
        var conflicts = 0
        let created = try makeDocument(at: url, gate: gate, resolveConflict: { _, _ in
            conflicts += 1
            // Typing that landed while the conflicting write was on the worker.
            if conflicts == 1 { document?.editorControllerForTesting?.replaceAllUndoably(with: "mine, then more") }
            return .discardMine
        })
        document = created
        defer { gate.release(); created.close() }
        created.editorControllerForTesting?.replaceAllUndoably(with: "mine")
        try Data("theirs".utf8).write(to: url)

        XCTAssertTrue(created.flushEditsAndWait(interactive: true))
        XCTAssertEqual(conflicts, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs",
                       "the disk version the user chose must not be overwritten")
        XCTAssertEqual(created.editorControllerForTesting?.text, "theirs")
        XCTAssertEqual(gate.writes, [])
    }

    func testUnsupportedNavigationLeavesAnInFlightNavigationAlone() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Note.md", contents: "old")
        let target = try directory.createTextFile(named: "Target.md", contents: "target")
        let picture = try directory.createTextFile(named: "Picture.png", contents: "not markdown")
        let gate = ControlledSaveWriter()
        let navigated = expectation(description: "the first navigation still completes")
        let document = try makeDocument(at: url, gate: gate, onRender: { source in
            if source == "target" { navigated.fulfill() }
        })
        defer { gate.release(); document.close() }
        document.editorControllerForTesting?.replaceAllUndoably(with: "new")
        document.navigateInCurrentWindow(to: target)
        wait(for: [gate.entered], timeout: 5)

        document.navigateInCurrentWindow(to: picture)
        gate.release()
        wait(for: [navigated], timeout: 5)
        XCTAssertEqual(document.fileURL, target)
    }

    func testRepeatedFlushesCompleteOnlyAfterNewestRevision() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Note.md", contents: "old")
        let gate = ControlledSaveWriter()
        let document = try makeDocument(at: url, gate: gate)
        defer { gate.release(); document.close() }
        document.editorControllerForTesting?.replaceAllUndoably(with: "new")
        let completions = expectation(description: "both flush requests complete")
        completions.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            document.flushEdits(interactive: true) { success in
                XCTAssertTrue(success)
                XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "newer")
                completions.fulfill()
            }
        }
        wait(for: [gate.entered], timeout: 5)
        document.editorControllerForTesting?.replaceAllUndoably(with: "newer")
        gate.release()
        wait(for: [completions], timeout: 5)
        XCTAssertEqual(gate.writes, ["new", "newer"])
    }
}

private final class ControlledSaveWriter: @unchecked Sendable {
    let entered = XCTestExpectation(description: "writer entered")
    let finished = XCTestExpectation(description: "first write completed")
    private let permit = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started = false
    private var recorded: [String] = []
    private var expired = false
    var writes: [String] { lock.withLock { recorded } }
    var timedOut: Bool { lock.withLock { expired } }

    func release() { permit.signal() }

    func write(_ url: URL, _ data: Data, _ beforeReplacing: () throws -> Void) throws {
        XCTAssertFalse(Thread.isMainThread)
        let first = lock.withLock { let first = !started; started = true; return first }
        if first {
            entered.fulfill()
            // Failure recovery only, never the mechanism that advances a passing test.
            guard permit.wait(timeout: .now() + 5) == .success else {
                lock.withLock { expired = true }
                finished.fulfill()
                throw CocoaError(.userCancelled)
            }
        }
        try MarkdownEditSession.replaceContents(of: url, with: data, beforeReplacing: beforeReplacing)
        lock.withLock { recorded.append(String(decoding: data, as: UTF8.self)) }
        if first { finished.fulfill() }
    }
}

@MainActor
private final class AsyncSaveMonitor: FileChangeMonitoring {
    func start() {}
    func stop() {}
}
