import AppKit
import Foundation
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class ReaderReliabilityTests: XCTestCase {
    func testExplicitReloadRefreshesUnchangedSourceAndPreservesScroll() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Note.md", contents: "# Note")
        let reader = RecordingReaderViewController()
        reader.stubbedCurrentScrollFraction = 0.4
        let refreshed = expectation(description: "explicit refresh renders unchanged source")
        var completions: [(WebKitRenderOutput) -> Void] = []
        let document = makeDocument(reader: reader, loader: { _ in loadedSource("# Note") }, scheduler: {
            _, _, _, _, completion in
            completions.append(completion)
            if completions.count == 2 { refreshed.fulfill() }
            return DispatchWorkItem {}
        })
        document.fileURL = url
        try document.read(from: Data("# Note".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        document.reloadDocument(nil)
        wait(for: [refreshed], timeout: 2)
        XCTAssertEqual(completions.count, 2)
        completions.last?(WebKitRenderOutput(html: "<html>note</html>", baseURL: directory.url))
        XCTAssertEqual(reader.appliedInitialScrollFractions.last!, 0.4)
    }

    func testHistoryRemainsCommittedWhileTraversalLoadsAndRepeatedBackIsIgnored() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let a = directory.url.appendingPathComponent("A.md")
        let b = directory.url.appendingPathComponent("B.md")
        let c = directory.url.appendingPathComponent("C.md")
        let gate = ReaderSourceGate()
        let document = makeDocument(loader: { url in
            if gate.enabled { gate.wait() }
            return loadedSource(url.lastPathComponent)
        })
        document.fileURL = a
        try document.read(from: Data("A.md".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { gate.release(); document.close() }
        document.navigateInCurrentWindow(to: b)
        waitUntil { document.fileURL == b }
        document.navigateInCurrentWindow(to: c)
        waitUntil { document.fileURL == c }
        let committedHistory = document.navigationHistory
        gate.enabled = true
        document.goBackInHistory(nil)
        XCTAssertEqual(document.navigationHistory, committedHistory)
        let backItem = NSMenuItem(title: "Back", action: #selector(MarkdownReaderDocument.goBackInHistory(_:)), keyEquivalent: "")
        XCTAssertFalse(document.validateUserInterfaceItem(backItem))
        document.goBackInHistory(nil)
        gate.release()
        waitUntil { document.fileURL != c }
        XCTAssertEqual(document.fileURL, b)
        XCTAssertEqual(document.navigationHistory.forwardEntries.map(\.fileURL), [c])
        XCTAssertTrue(document.validateUserInterfaceItem(backItem))
    }

    func testFailedHistoryTraversalKeepsCurrentFileAndBothStacks() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let a = directory.url.appendingPathComponent("A.md")
        let b = directory.url.appendingPathComponent("B.md")
        let failReads = ReaderSourceGate()
        let failed = expectation(description: "navigation error reported")
        let document = makeDocument(loader: { url in
            if failReads.enabled { throw CocoaError(.fileReadNoSuchFile) }
            return loadedSource(url.lastPathComponent)
        }, onError: { _ in failed.fulfill() })
        document.fileURL = a
        try document.read(from: Data("A".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        document.navigateInCurrentWindow(to: b)
        waitUntil { document.fileURL == b }
        let history = document.navigationHistory
        failReads.enabled = true
        document.goBackInHistory(nil)
        wait(for: [failed], timeout: 2)
        XCTAssertEqual(document.fileURL, b)
        XCTAssertEqual(document.navigationHistory, history)
        let item = NSMenuItem(title: "Back", action: #selector(MarkdownReaderDocument.goBackInHistory(_:)), keyEquivalent: "")
        XCTAssertTrue(document.validateUserInterfaceItem(item))
    }

    func testSupersededNavigationDiscardsItsErrorAndDoesNotPushHistory() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let a = directory.url.appendingPathComponent("A.md")
        let b = directory.url.appendingPathComponent("B.md")
        let c = directory.url.appendingPathComponent("C.md")
        let gate = ReaderSourceGate()
        let discardedError = expectation(description: "superseded error stays silent")
        discardedError.isInverted = true
        let document = makeDocument(loader: { url in
            if url == b {
                gate.wait()
                throw CocoaError(.fileReadNoSuchFile)
            }
            return loadedSource(url.lastPathComponent)
        }, onError: { _ in discardedError.fulfill() })
        document.fileURL = a
        try document.read(from: Data("A".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { gate.release(); document.close() }
        document.navigateInCurrentWindow(to: b)
        waitUntil { gate.isWaiting }
        document.navigateInCurrentWindow(to: c)
        waitUntil { document.fileURL == c }
        gate.release()
        wait(for: [discardedError], timeout: 0.1)
        XCTAssertEqual(document.fileURL, c)
        XCTAssertEqual(document.navigationHistory.backEntries.map(\.fileURL), [a])
    }

    func testAutomaticReloadSkipsUnchangedSourceButExplicitFailureIsReported() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let gate = ReaderSourceGate()
        let readCompleted = expectation(description: "automatic source read")
        let failed = expectation(description: "explicit reload error")
        var renderCount = 0
        let document = makeDocument(loader: { _ in
            if gate.enabled { throw CocoaError(.fileReadNoSuchFile) }
            readCompleted.fulfill()
            return loadedSource("# Note")
        }, onError: { _ in failed.fulfill() }, scheduler: { _, _, _, _, _ in
            renderCount += 1
            return DispatchWorkItem {}
        })
        document.fileURL = directory.url.appendingPathComponent("Note.md")
        try document.read(from: Data("# Note".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        document.reloadFromDiskIfNeeded()
        wait(for: [readCompleted], timeout: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(renderCount, 1)
        gate.enabled = true
        document.reloadDocument(nil)
        wait(for: [failed], timeout: 2)
        XCTAssertEqual(renderCount, 1)
    }

    func testNewWindowReadsInBackgroundReusesPendingDocumentAndPreservesAnchor() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = directory.url.appendingPathComponent("Slow.md")
        let gate = ReaderSourceGate()
        let reader = RecordingReaderViewController()
        var renders: [String] = []
        let document = makeDocument(reader: reader, loader: { _ in
            gate.wait()
            return loadedSource("# Slow\n\n## Section")
        }, scheduler: { source, _, _, _, completion in
            renders.append(source)
            completion(WebKitRenderOutput(html: "<html>slow</html>", baseURL: directory.url))
            return DispatchWorkItem {}
        })
        defer { gate.release(); document.close() }
        let retainedBefore = MarkdownDocumentOpener.retainedDocumentCountForTesting
        let start = ProcessInfo.processInfo.systemUptime
        try MarkdownDocumentOpener.open(url: url, anchorID: "section", documentFactory: { document })
        let openDuration = ProcessInfo.processInfo.systemUptime - start
        waitUntil { gate.isWaiting }
        XCTAssertFalse(gate.ranOnMainThread)
        XCTAssertNotNil(document.windowControllers.first?.window)
        XCTAssertTrue(renders.isEmpty)
        try MarkdownDocumentOpener.open(url: url, documentFactory: {
            XCTFail("Pending open should reuse its document")
            return document
        })
        document.navigateInCurrentWindow(to: url)
        XCTAssertEqual(MarkdownDocumentOpener.retainedDocumentCountForTesting, retainedBefore + 1)
        let serviced = expectation(description: "main queue runs while read waits")
        DispatchQueue.main.async { serviced.fulfill() }
        wait(for: [serviced], timeout: 1)
        XCTAssertFalse(gate.finished)
        print("Delayed-read window probe: open returned in \(Int(openDuration * 1_000)) ms; main queue serviced while source read remained blocked")
        gate.release()
        waitUntil { renders.count == 1 }
        reader.stubbedContentReady = true
        reader.onNavigationFinished?()
        XCTAssertEqual(reader.scrolledHeadingIDs, ["section"])
    }

    func testAutomaticEventCannotDiscardPendingExplicitRefresh() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let gate = ReaderSourceGate()
        gate.enabled = true
        let refreshed = expectation(description: "explicit refresh survives automatic event")
        var renders = 0
        let document = makeDocument(loader: { _ in
            if gate.enabled { gate.wait() }
            return loadedSource("# Note")
        }, scheduler: { _, _, _, _, _ in
            renders += 1
            if renders == 2 { refreshed.fulfill() }
            return DispatchWorkItem {}
        })
        document.fileURL = directory.url.appendingPathComponent("Note.md")
        try document.read(from: Data("# Note".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { gate.release(); document.close() }
        document.reloadDocument(nil)
        waitUntil { gate.isWaiting }
        document.reloadFromDiskIfNeeded()
        gate.enabled = false
        gate.release()
        wait(for: [refreshed], timeout: 2)
        XCTAssertEqual(renders, 2)
    }

    func testNewTabReadsInBackgroundAndCloseDiscardsCompletion() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let a = directory.url.appendingPathComponent("A.md")
        let b = directory.url.appendingPathComponent("B.md")
        let first = makeDocument(loader: { _ in loadedSource("# A") })
        first.fileURL = a
        try first.read(from: Data("# A".utf8), ofType: "dev.wafer.markdown")
        first.makeWindowControllers()
        let host = try XCTUnwrap(first.windowControllers.first as? DocumentHostWindowController)
        let gate = ReaderSourceGate()
        let unexpectedRender = expectation(description: "closed tab does not render")
        unexpectedRender.isInverted = true
        let second = makeDocument(loader: { _ in gate.wait(); return loadedSource("# B") }, scheduler: { _, _, _, _, _ in
            unexpectedRender.fulfill()
            return DispatchWorkItem {}
        })
        second.fileURL = b
        host.tabDocumentFactoryForTesting = { _ in second }
        defer { gate.release(); second.close(); first.close() }
        host.openTab(for: b)
        waitUntil { gate.isWaiting }
        XCTAssertFalse(gate.ranOnMainThread)
        XCTAssertEqual(host.tabs.count, 2)
        host.openTab(for: b)
        XCTAssertEqual(host.tabs.count, 2)
        host.closeTab(at: 1)
        XCTAssertTrue(host.activeTab.document === first)
        XCTAssertNil(OpenDocumentRegistry.shared.document(for: b))
        gate.release()
        wait(for: [unexpectedRender], timeout: 0.1)
    }

    func testFailedInitialWindowAndTabAreRemovedFromRegistryAndDocumentController() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let missing = directory.url.appendingPathComponent("Missing.md")
        let failedWindow = expectation(description: "window failure reported")
        let document = makeDocument(loader: { _ in throw CocoaError(.fileReadNoSuchFile) }, onError: { _ in failedWindow.fulfill() })
        try MarkdownDocumentOpener.open(url: missing, documentFactory: { document })
        wait(for: [failedWindow], timeout: 2)
        XCTAssertNil(OpenDocumentRegistry.shared.document(for: missing))
        XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === document })
        XCTAssertTrue(document.windowControllers.isEmpty)

        let first = makeDocument(loader: { _ in loadedSource("# A") })
        first.fileURL = directory.url.appendingPathComponent("A.md")
        try first.read(from: Data("# A".utf8), ofType: "dev.wafer.markdown")
        first.makeWindowControllers()
        defer { first.close() }
        let host = try XCTUnwrap(first.windowControllers.first as? DocumentHostWindowController)
        let failedTab = expectation(description: "tab failure reported")
        let tabDocument = makeDocument(loader: { _ in throw CocoaError(.fileReadNoSuchFile) }, onError: { _ in failedTab.fulfill() })
        tabDocument.fileURL = missing
        host.tabDocumentFactoryForTesting = { _ in tabDocument }
        host.openTab(for: missing)
        wait(for: [failedTab], timeout: 2)
        XCTAssertEqual(host.tabs.count, 1)
        XCTAssertTrue(host.activeTab.document === first)
        XCTAssertNil(OpenDocumentRegistry.shared.document(for: missing))
        XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === tabDocument })
    }

    func testFailedOpeningTabStillCleansUpWhenItBecomesTheLastTab() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let first = makeDocument(loader: { _ in loadedSource("# A") })
        first.fileURL = directory.url.appendingPathComponent("A.md")
        try first.read(from: Data("# A".utf8), ofType: "dev.wafer.markdown")
        first.makeWindowControllers()
        let host = try XCTUnwrap(first.windowControllers.first as? DocumentHostWindowController)
        let gate = ReaderSourceGate()
        let failed = expectation(description: "last opening tab failure")
        let missing = directory.url.appendingPathComponent("Missing.md")
        let second = makeDocument(loader: { _ in gate.wait(); throw CocoaError(.fileReadNoSuchFile) }, onError: { _ in failed.fulfill() })
        second.fileURL = missing
        host.tabDocumentFactoryForTesting = { _ in second }
        defer { gate.release(); second.close(); first.close() }
        host.openTab(for: missing)
        waitUntil { gate.isWaiting }
        host.closeTab(at: 0)
        XCTAssertEqual(host.tabs.count, 1)
        gate.release()
        wait(for: [failed], timeout: 2)
        XCTAssertNil(OpenDocumentRegistry.shared.document(for: missing))
        XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === second })
    }

    func testNavigationSupersedingInitialOpenCommitsOnlyTheLoadedFile() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let a = directory.url.appendingPathComponent("A.md")
        let b = directory.url.appendingPathComponent("B.md")
        let gate = ReaderSourceGate()
        let reader = RecordingReaderViewController()
        let document = makeDocument(reader: reader, loader: { url in
            if url == a { gate.wait() }
            return loadedSource(url.lastPathComponent)
        }, scheduler: { source, _, _, _, completion in
            completion(WebKitRenderOutput(html: source, baseURL: directory.url))
            return DispatchWorkItem {}
        })
        defer { gate.release(); document.close() }
        try MarkdownDocumentOpener.open(url: a, documentFactory: { document })
        waitUntil { gate.isWaiting }
        document.navigateInCurrentWindow(to: b)
        waitUntil { document.fileURL == b }
        gate.release()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(document.navigationHistory.backEntries.isEmpty)
        XCTAssertEqual(reader.appliedOutputs.map(\.html), ["B.md"])
    }

    func testFailedNavigationSupersedingInitialOpenRemovesThePlaceholder() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let a = directory.url.appendingPathComponent("A.md")
        let b = directory.url.appendingPathComponent("B.md")
        let gate = ReaderSourceGate()
        let failed = expectation(description: "superseding open failed")
        let document = makeDocument(loader: { url in
            if url == a { gate.wait(); return loadedSource("# A") }
            throw CocoaError(.fileReadNoSuchFile)
        }, onError: { _ in failed.fulfill() })
        defer { gate.release(); document.close() }
        try MarkdownDocumentOpener.open(url: a, documentFactory: { document })
        waitUntil { gate.isWaiting }
        document.navigateInCurrentWindow(to: b)
        wait(for: [failed], timeout: 2)
        gate.release()
        XCTAssertNil(OpenDocumentRegistry.shared.document(for: a))
        XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === document })
    }

    func testOldFileReloadCannotSupersedePendingNavigation() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let a = directory.url.appendingPathComponent("A.md")
        let b = directory.url.appendingPathComponent("B.md")
        let gate = ReaderSourceGate()
        let document = makeDocument(loader: { url in
            if url == b { gate.wait() }
            return loadedSource(url.lastPathComponent)
        })
        document.fileURL = a
        try document.read(from: Data("A.md".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { gate.release(); document.close() }
        document.navigateInCurrentWindow(to: b)
        document.reloadFromDiskIfNeeded()
        gate.release()
        waitUntil { document.fileURL == b }
    }

    func testUnavailableLibraryPreservesSnapshotAndSavedFolder() throws {
        let parent = try TemporaryTestDirectory()
        defer { parent.remove() }
        let folder = parent.url.appendingPathComponent("Library", isDirectory: true)
        let offline = parent.url.appendingPathComponent("Offline", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# Note".utf8).write(to: folder.appendingPathComponent("Note.md"))
        try Data("# Hub\n\n[[Note]]".utf8).write(to: folder.appendingPathComponent("Hub.md"))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = LibraryPreferenceStore(defaults: defaults)
        let library = LibraryController(preferenceStore: store, monitorFactory: { _, _ in NoLibraryMonitor() })
        try library.openLibrary(at: folder)
        waitUntil { !library.isScanning }
        let previous = library.snapshot
        try FileManager.default.moveItem(at: folder, to: offline)
        library.refreshLibrary()
        waitUntil { !library.isScanning }
        XCTAssertEqual(library.files, previous.files)
        XCTAssertEqual(library.backlinksByIdentity, previous.backlinksByIdentity)
        XCTAssertEqual(library.snapshot.wikiLinkIndex, previous.wikiLinkIndex)
        XCTAssertNotNil(library.scanFailure)
        let reopened = LibraryController(preferenceStore: store, monitorFactory: { _, _ in NoLibraryMonitor() })
        reopened.reopenPersistedLibraryIfAvailable()
        waitUntil { !reopened.isScanning }
        XCTAssertEqual(store.libraryFolderURL?.path, folder.path)
        XCTAssertTrue(reopened.hasLibrary)
        XCTAssertNotNil(reopened.scanFailure)

        try FileManager.default.moveItem(at: offline, to: folder)
        try Data("# Updated Note".utf8).write(to: folder.appendingPathComponent("Note.md"))
        let menuController = LibraryMenuController(libraryController: library)
        let retry = NSMenuItem(title: "Retry Library", action: #selector(LibraryMenuController.retryLibrary(_:)), keyEquivalent: "")
        XCTAssertTrue(menuController.validateMenuItem(retry))
        menuController.retryLibrary(retry)
        XCTAssertFalse(menuController.validateMenuItem(retry))
        waitUntil { !library.isScanning }
        XCTAssertNil(library.scanFailure)
        XCTAssertEqual(Set(library.files.map(\.displayTitle)), ["Hub", "Updated Note"])
        XCTAssertTrue(menuController.validateMenuItem(retry))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Hub.md"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Note.md"))
        library.refreshLibrary()
        waitUntil { !library.isScanning }
        XCTAssertNil(library.scanFailure)
        XCTAssertTrue(library.files.isEmpty)
        XCTAssertTrue(library.backlinksByIdentity.isEmpty)
        library.closeLibrary()
        reopened.closeLibrary()
        XCTAssertFalse(menuController.validateMenuItem(retry))
    }

    func testLibraryAvailabilityWarningKeepsTreeAndSearchResultsAndClearsOnRecovery() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let folder = directory.url.appendingPathComponent("Library", isDirectory: true)
        let offline = directory.url.appendingPathComponent("Offline", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# Note\n\nalpha".utf8).write(to: folder.appendingPathComponent("Note.md"))
        let library = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            monitorFactory: { _, _ in NoLibraryMonitor() }
        )
        let sidebar = DocumentSidebarViewController(libraryController: library)
        sidebar.loadViewIfNeeded()
        defer { library.closeLibrary() }
        try library.openLibrary(at: folder)
        waitUntil { !library.isScanning }
        sidebar.setMode(.library)
        try FileManager.default.moveItem(at: folder, to: offline)
        library.refreshLibrary()
        waitUntil { !library.isScanning }
        XCTAssertEqual(sidebar.libraryRowTitlesForTesting, ["Note"])
        XCTAssertEqual(sidebar.librarySearchNoResultTextsForTesting, ["Library unavailable. Results may be stale."])
        sidebar.setLibrarySearchQueryForTesting("alpha")
        waitUntil { sidebar.librarySearchResultTitlesForTesting == ["Note"] }
        XCTAssertEqual(sidebar.librarySearchNoResultTextsForTesting, ["Library unavailable. Results may be stale."])
        try FileManager.default.moveItem(at: offline, to: folder)
        library.refreshLibrary()
        waitUntil { !library.isScanning }
        XCTAssertEqual(sidebar.librarySearchResultTitlesForTesting, ["Note"])
        XCTAssertTrue(sidebar.librarySearchNoResultTextsForTesting.isEmpty)
    }

    func testWikiPathDestinationIsTheSameInReaderBacklinksAndExport() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let folder = directory.url.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("Guide Notes.md")
        try Data("# Guide Notes\n\n## Setup".utf8).write(to: target)
        let hub = try directory.createTextFile(named: "Hub.md", contents: "[[B/Guide Notes#Setup|Install]]")
        let snapshot = LibrarySnapshot(files: LibraryScanner.scan(rootURL: directory.url).files)
        let source = MarkdownParser().parse(source: "[[B/Guide Notes#Setup|Install]]", baseURL: hub)
        let output = WebKitHTMLRenderer(wikiLinkIndex: snapshot.wikiLinkIndex).render(document: source)
        let sanitized = try ExportSanitizer.sanitize(domHTML: output.html, policy: .init(
            inlineImage: { _ in nil },
            rewriteWikiLinkHref: { DocumentExportController.exportedWikiHref(for: $0, documentURL: hub) }
        ))
        XCTAssertTrue(sanitized.contains("href=\"B/Guide%20Notes.md#setup\""))
        XCTAssertFalse(sanitized.contains("wafer-wiki:"))
        XCTAssertEqual(snapshot.backlinksByIdentity[target.path]?.map(\.sourceFileURL), [hub])
    }

    private func makeDocument(
        reader: RecordingReaderViewController = RecordingReaderViewController(),
        loader: @escaping MarkdownReaderDocument.SourceLoader,
        onError: @escaping @MainActor (Error) -> Void = { XCTFail("Unexpected source error: \($0)") },
        scheduler: @escaping MarkdownReaderDocument.RenderScheduler = { _, _, _, _, _ in DispatchWorkItem {} }
    ) -> MarkdownReaderDocument {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return MarkdownReaderDocument(
            scrollStateStore: ScrollStateStore(defaults: defaults), renderScheduler: scheduler,
            readerControllerFactory: { reader },
            readerBehaviorPreferenceStore: ReaderBehaviorPreferenceStore(defaults: defaults),
            sourceLoader: loader, fileMonitorFactory: { _, _ in NoReaderMonitor() },
            wikiLinkIndexProvider: { nil }, sourceLoadErrorHandler: onError
        )
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition())
    }
}

private func loadedSource(_ source: String) -> LoadedMarkdownSource {
    LoadedMarkdownSource(sourceText: source, fingerprint: FileFingerprint.sha256Hex(for: Data(source.utf8)))
}

private final class ReaderSourceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isEnabled = false
    private var waiting = false
    private var completed = false
    private var wasMainThread = false
    private let semaphore = DispatchSemaphore(value: 0)
    var enabled: Bool {
        get { lock.withLock { isEnabled } }
        set { lock.withLock { isEnabled = newValue } }
    }
    var isWaiting: Bool { lock.withLock { waiting } }
    var finished: Bool { lock.withLock { completed } }
    var ranOnMainThread: Bool { lock.withLock { wasMainThread } }
    func wait() {
        lock.withLock { waiting = true; wasMainThread = Thread.isMainThread }
        _ = semaphore.wait(timeout: .now() + 3)
        lock.withLock { completed = true }
    }
    func release() { semaphore.signal() }
}

@MainActor private final class NoReaderMonitor: FileChangeMonitoring {
    func start() {}
    func stop() {}
}

@MainActor private final class NoLibraryMonitor: DirectoryMonitoring {
    func start() {}
    func stop() {}
}
