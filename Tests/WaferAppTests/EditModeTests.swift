import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

// MARK: - Save session

@MainActor
final class MarkdownEditSessionTests: XCTestCase {
    private func makeSession(
        for url: URL,
        resolver: @escaping EditConflictResolver = { _, _ in XCTFail("unexpected conflict"); return .cancel },
        writer: @escaping MarkdownEditSession.FileWriter = MarkdownEditSession.replaceContents
    ) throws -> MarkdownEditSession {
        let data = try Data(contentsOf: url)
        let decoded = try XCTUnwrap(MarkdownTextFormat.decode(data))
        return MarkdownEditSession(
            fileURL: url,
            text: MarkdownTextFormat.normalizingLineEndings(decoded.text),
            fingerprint: FileFingerprint.sha256Hex(for: data),
            format: decoded.format,
            resolveConflict: resolver,
            worker: MarkdownSaveWorker(writer: writer)
        )
    }

    func testFailedReplacementKeepsTheOriginalAndReportsItsError() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Doc.md", contents: "original\n")
        let failure = CocoaError(.fileWriteOutOfSpace)
        var conflicts: [EditConflictKind] = []
        let session = try makeSession(for: url, resolver: { kind, _ in
            conflicts.append(kind)
            return .cancel
        }, writer: { _, _, beforeReplacing in
            try beforeReplacing()
            throw failure
        })

        XCTAssertEqual(session.save("mine\n", interactive: false), .keptInMemory)
        XCTAssertEqual(conflicts, [], "non-interactive saves never prompt")
        XCTAssertEqual(session.save("mine\n", interactive: true), .keptInMemory)
        XCTAssertEqual(conflicts, [.writeFailed(failure.localizedDescription)], "the original error reaches the prompt")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original\n")
        XCTAssertEqual(session.savedText, "original\n")
    }

    func testReplacementFailureNeverFallsBackToWritingInPlace() throws {
        try XCTSkipIf(getuid() == 0, "permissions do not apply to root")
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let folder = directory.url.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Doc.md")
        try Data("original\n".utf8).write(to: url)
        // The file stays writable, but its folder refuses the swap.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        XCTAssertThrowsError(try MarkdownEditSession.replaceContents(of: url, with: Data("new\n".utf8))) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Doc.md"])
    }

    func testDiskIsComparedAgainRightBeforeTheReplace() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Doc.md", contents: "one\n")
        var conflicts: [EditConflictKind] = []
        let session = try makeSession(for: url, resolver: { kind, _ in
            conflicts.append(kind)
            return .cancel
        }, writer: { target, data, beforeReplacing in
            try MarkdownEditSession.replaceContents(of: target, with: data) {
                // Another program writes after the new bytes were staged.
                try Data("theirs\n".utf8).write(to: target)
                try beforeReplacing()
            }
        })

        XCTAssertEqual(session.save("mine\n", interactive: true), .keptInMemory)
        XCTAssertEqual(conflicts, [.changedOnDisk])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs\n")
    }

    func testBackgroundSaveRunsOffTheMainThreadAndSkipsUnchangedText() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Doc.md", contents: "one\n")
        let writer = RecordingFileWriter()
        let session = try makeSession(for: url, writer: { try writer.write($0, $1, $2) })

        var outcomes: [MarkdownEditSession.BackgroundOutcome] = []
        XCTAssertTrue(session.saveInBackground(EditSnapshot(text: "one\ntwo\n", revision: 7)) { outcomes.append($0) })
        XCTAssertTrue(session.isSaving)
        XCTAssertFalse(session.saveInBackground(EditSnapshot(text: "other", revision: 8)) { _ in }, "one save at a time")
        let deadline = Date(timeIntervalSinceNow: 5)
        while outcomes.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        XCTAssertEqual(outcomes, [.saved])
        XCTAssertEqual(writer.writes, ["one\ntwo\n"])
        XCTAssertEqual(writer.wroteOnMainThread, [false])
        XCTAssertEqual(session.savedText, "one\ntwo\n")
        XCTAssertEqual(session.savedRevision, 7)
        XCTAssertEqual(session.save(EditSnapshot(text: "one\ntwo\n", revision: 7), interactive: true), .unchanged)
        XCTAssertEqual(session.save("one\ntwo\n", interactive: true), .unchanged)
        XCTAssertEqual(writer.writes.count, 1, "unchanged text writes nothing")
    }

    func testSaveKeepsByteOrderMarkAndLineEndingsAndSkipsUnchangedText() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createFile(named: "Doc.md", contents: Data([0xEF, 0xBB, 0xBF]) + Data("# A\r\nB\r\n".utf8))
        let session = try makeSession(for: url)

        XCTAssertEqual(session.save("# A\nB\n", interactive: true), .unchanged)
        XCTAssertEqual(session.save("# A\nB\nC\n", interactive: true), .saved)
        XCTAssertEqual(try Data(contentsOf: url), Data([0xEF, 0xBB, 0xBF]) + Data("# A\r\nB\r\nC\r\n".utf8))
        XCTAssertEqual(session.savedFingerprint, FileFingerprint.sha256Hex(for: try Data(contentsOf: url)))
    }

    func testReplacingContentsKeepsFilePermissions() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Private.md", contents: "secret")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let session = try makeSession(for: url)

        XCTAssertEqual(session.save("secret 2", interactive: true), .saved)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "secret 2")
    }

    func testDiskChangeIsAConflictAndNonInteractiveSavesNeverPrompt() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Doc.md", contents: "one")
        var conflicts: [EditConflictKind] = []
        let session = try makeSession(for: url) { kind, _ in
            conflicts.append(kind)
            return .discardMine
        }
        try Data("from agent\r\n".utf8).write(to: url)

        XCTAssertEqual(session.save("mine", interactive: false), .keptInMemory)
        XCTAssertEqual(conflicts, [])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "from agent\r\n")

        XCTAssertEqual(session.save("mine", interactive: true), .reverted("from agent\n"))
        XCTAssertEqual(conflicts, [.changedOnDisk])
        XCTAssertEqual(session.savedText, "from agent\n")
        XCTAssertEqual(session.format.lineEnding, .crlf)
    }

    func testKeepMineOverwritesChangedFile() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Doc.md", contents: "one")
        let session = try makeSession(for: url) { _, _ in .overwrite }
        try Data("theirs".utf8).write(to: url)

        XCTAssertEqual(session.save("mine", interactive: true), .saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine")
    }

    func testSaveCopyWritesEditsElsewhereAndTakesDiskVersion() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Doc.md", contents: "one")
        let copyURL = directory.url.appendingPathComponent("Doc copy.md")
        let session = try makeSession(for: url) { _, _ in .saveCopy(copyURL) }
        try Data("theirs".utf8).write(to: url)

        XCTAssertEqual(session.save("mine", interactive: true), .reverted("theirs"))
        XCTAssertEqual(try String(contentsOf: copyURL, encoding: .utf8), "mine")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs")
    }

    func testMissingFileReportsMissingAndOverwriteRecreatesIt() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Doc.md", contents: "one")
        var conflicts: [EditConflictKind] = []
        let session = try makeSession(for: url) { kind, _ in
            conflicts.append(kind)
            return .overwrite
        }
        try FileManager.default.removeItem(at: url)

        XCTAssertEqual(session.save("again", interactive: true), .saved)
        XCTAssertEqual(conflicts, [.missingOnDisk])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "again")
    }
}

// MARK: - Document edit mode

@MainActor
private final class EditTestFileMonitor: FileChangeMonitoring {
    let onChange: () -> Void
    init(onChange: @escaping () -> Void) { self.onChange = onChange }
    func start() {}
    func stop() {}
}

@MainActor
final class DocumentEditModeTests: XCTestCase {
    private var directory: TemporaryTestDirectory!
    private var monitors: [EditTestFileMonitor] = []
    private var renderedSources: [String] = []
    private var conflicts: [EditConflictKind] = []
    private var conflictResolution: EditConflictResolution = .overwrite
    /// Runs inside the conflict prompt, as events do while a modal alert is up.
    private var duringConflictPrompt: (() -> Void)?
    private var loadErrors: [Error] = []

    override func setUp() async throws {
        directory = try TemporaryTestDirectory()
        monitors = []
        renderedSources = []
        conflicts = []
        conflictResolution = .overwrite
        duringConflictPrompt = nil
        loadErrors = []
    }

    override func tearDown() async throws {
        directory.remove()
    }

    private func makeDocument(
        for url: URL,
        autosaveDelay: TimeInterval = 0.05,
        makesWindow: Bool = true,
        sourceLoader: @escaping MarkdownReaderDocument.SourceLoader = MarkdownReaderDocument.loadSource,
        fileWriter: @escaping MarkdownEditSession.FileWriter = MarkdownEditSession.replaceContents
    ) throws -> (MarkdownReaderDocument, RecordingReaderViewController) {
        let reader = RecordingReaderViewController()
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { [weak self] source, baseURL, _, _, completion in
                self?.renderedSources.append(source)
                completion(WebKitRenderOutput(html: "<html><body><div id=\"write\"></div></body></html>", baseURL: baseURL))
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            sourceLoader: sourceLoader,
            fileMonitorFactory: { [weak self] _, onChange in
                let monitor = EditTestFileMonitor(onChange: onChange)
                self?.monitors.append(monitor)
                return monitor
            },
            sourceLoadErrorHandler: { [weak self] in self?.loadErrors.append($0) },
            editConflictResolver: { [weak self] kind, _ in
                self?.conflicts.append(kind)
                self?.duringConflictPrompt?()
                return self?.conflictResolution ?? .cancel
            },
            editFileWriter: fileWriter,
            autosaveDelay: autosaveDelay,
            liveRenderInterval: 0.01
        )
        document.fileURL = url
        try document.read(from: Data(contentsOf: url), ofType: "dev.wafer.markdown")
        if makesWindow {
            document.makeWindowControllers()
        }
        return (document, reader)
    }

    private func type(_ text: String, in document: MarkdownReaderDocument) throws {
        let textView = try XCTUnwrap(document.editorControllerForTesting?.textViewForTesting)
        let end = (textView.string as NSString).length
        textView.insertText(text, replacementRange: NSRange(location: end, length: 0))
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(condition(), description)
    }

    func testEditingShowsEditorPaneAutosavesInOriginalFormatAndRestoresReader() throws {
        let url = try directory.createFile(named: "Doc.md", contents: Data([0xEF, 0xBB, 0xBF]) + Data("# A\r\nB\r\n".utf8))
        let (document, reader) = try makeDocument(for: url)
        defer { document.close() }
        let host = try XCTUnwrap(document.windowControllers.first as? DocumentHostWindowController)

        document.toggleEditing(nil)

        XCTAssertTrue(document.isEditing)
        XCTAssertTrue(host.hostedContentViewController === reader, "the reader is never re-hosted")
        XCTAssertTrue(host.editorPaneControllerForTesting === document.editorControllerForTesting)
        XCTAssertNotNil(host.editorPaneControllerForTesting)
        XCTAssertTrue(host.editButtonIsActiveForTesting)
        XCTAssertEqual(document.editorControllerForTesting?.text, "# A\nB\n")
        XCTAssertFalse(document.isDocumentEdited)

        try type("C", in: document)
        waitUntil("autosave wrote the edit") {
            (try? Data(contentsOf: url)) == Data([0xEF, 0xBB, 0xBF]) + Data("# A\r\nB\r\nC".utf8)
        }
        waitUntil("live render used editor text") { self.renderedSources.last == "# A\nB\nC" }
        XCTAssertFalse(document.isDocumentEdited, "edits never mark the NSDocument edited")

        XCTAssertTrue(document.endEditing())
        XCTAssertFalse(document.isEditing)
        XCTAssertTrue(host.hostedContentViewController === reader)
        XCTAssertNil(host.editorPaneControllerForTesting)
        XCTAssertFalse(host.editButtonIsActiveForTesting)
    }

    func testEditorPaneAndWindowWidthFollowTheSelectedTab() throws {
        let first = try directory.createTextFile(named: "First.md", contents: "first\n")
        let second = try directory.createTextFile(named: "Second.md", contents: "second\n")
        let (document, firstReader) = try makeDocument(for: first)
        let host = try XCTUnwrap(document.windowControllers.first as? DocumentHostWindowController)
        var secondReader: RecordingReaderViewController?
        host.tabDocumentFactoryForTesting = { [unowned self] url in
            let made = try? self.makeDocument(for: url, makesWindow: false)
            secondReader = made?.1
            return made?.0
        }
        defer { host.tabs.forEach { $0.document.close() } }
        let window = try XCTUnwrap(host.window)
        let readingFrame = window.frame
        let editingFrame = EditorPaneExpansion.plan(
            windowFrame: readingFrame,
            contentWidth: host.hostedContentWidthForTesting,
            visibleFrame: (window.screen ?? NSScreen.main)?.visibleFrame,
            canResize: true
        ).frame

        document.beginEditing()
        XCTAssertEqual(window.frame, editingFrame)
        XCTAssertTrue(host.editorPaneControllerForTesting === document.editorControllerForTesting)

        // A reading tab takes the window back to the reading width at once.
        host.openTab(for: second)
        XCTAssertTrue(host.hostedContentViewController === secondReader)
        XCTAssertNil(host.editorPaneControllerForTesting)
        XCTAssertEqual(window.frame, readingFrame)
        XCTAssertTrue(document.isEditing, "the other tab keeps editing")

        host.selectTab(at: 0)
        XCTAssertTrue(host.hostedContentViewController === firstReader)
        XCTAssertTrue(host.editorPaneControllerForTesting === document.editorControllerForTesting)
        XCTAssertEqual(window.frame, editingFrame)

        // Leaving edit mode in a background tab does not touch the window.
        host.selectTab(at: 1)
        XCTAssertTrue(document.endEditing())
        XCTAssertEqual(window.frame, readingFrame)
        host.selectTab(at: 0)
        XCTAssertNil(host.editorPaneControllerForTesting)
        XCTAssertEqual(window.frame, readingFrame)
    }

    func testEnteringAndLeavingWithoutChangesWritesNothing() throws {
        let url = try directory.createTextFile(named: "Doc.md", contents: "# Same\r\n")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let (document, _) = try makeDocument(for: url)
        defer { document.close() }

        document.beginEditing()
        XCTAssertTrue(document.endEditing())

        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
        XCTAssertEqual(try Data(contentsOf: url), Data("# Same\r\n".utf8))
    }

    func testExternalChangeWhileCleanReplacesEditorText() throws {
        let url = try directory.createTextFile(named: "Doc.md", contents: "one\n")
        let (document, _) = try makeDocument(for: url)
        defer { document.close() }
        document.beginEditing()

        try Data("two\n".utf8).write(to: url)
        monitors.last?.onChange()

        waitUntil("editor adopted the disk version") { document.editorControllerForTesting?.text == "two\n" }
        XCTAssertEqual(conflicts, [])
        XCTAssertEqual(document.editorControllerForTesting?.undoManagerForTesting.canUndo, false)
    }

    func testExternalChangeWhileDirtyAsksBeforeOverwriting() throws {
        let url = try directory.createTextFile(named: "Doc.md", contents: "one\n")
        let (document, _) = try makeDocument(for: url, autosaveDelay: 60)
        defer { document.close() }
        document.beginEditing()
        try type("mine", in: document)

        try Data("theirs\n".utf8).write(to: url)
        conflictResolution = .overwrite
        monitors.last?.onChange()

        waitUntil("conflict resolved") { self.conflicts == [.changedOnDisk] }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\nmine")
    }

    func testCancelledConflictBlocksClosingAndNavigation() throws {
        let url = try directory.createTextFile(named: "Doc.md", contents: "one\n")
        let other = try directory.createTextFile(named: "Other.md", contents: "other\n")
        let (document, _) = try makeDocument(for: url, autosaveDelay: 60)
        defer {
            conflictResolution = .discardMine
            document.close()
        }
        let host = try XCTUnwrap(document.windowControllers.first as? DocumentHostWindowController)
        document.beginEditing()
        try type("mine", in: document)
        try Data("theirs\n".utf8).write(to: url)
        conflictResolution = .cancel

        XCTAssertFalse(host.prepareToCloseWindow())
        document.navigateInCurrentWindow(to: other)
        XCTAssertEqual(document.fileURL, url)
        XCTAssertTrue(document.isEditing)
        XCTAssertEqual(conflicts, [.changedOnDisk, .changedOnDisk])
    }

    func testNavigationSavesFirstAndKeepsEditingTheNextFile() throws {
        let first = try directory.createTextFile(named: "First.md", contents: "first\n")
        let second = try directory.createTextFile(named: "Second.md", contents: "second\r\n")
        let (document, _) = try makeDocument(for: first, autosaveDelay: 60)
        defer { document.close() }
        document.beginEditing()
        try type("more", in: document)

        document.navigateInCurrentWindow(to: second)

        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first\nmore", "saved before leaving")
        waitUntil("second file loaded into the editor") {
            document.fileURL?.lastPathComponent == "Second.md" && document.editorControllerForTesting?.text == "second\n"
        }
        XCTAssertTrue(document.isEditing)
        XCTAssertEqual(document.editorControllerForTesting?.undoManagerForTesting.canUndo, false)
    }

    func testTextTypedWhileTheNextFileLoadsIsSavedBeforeTheEditorSwitches() throws {
        let first = try directory.createTextFile(named: "First.md", contents: "first\n")
        let second = try directory.createTextFile(named: "Second.md", contents: "second\n")
        let gate = SourceReadGate()
        let (document, _) = try makeDocument(for: first, autosaveDelay: 60, sourceLoader: { url in
            if url.lastPathComponent == "Second.md" { gate.wait() }
            return try MarkdownReaderDocument.loadSource(from: url)
        })
        defer { gate.release(); document.close() }
        document.beginEditing()
        try type("one", in: document)

        document.navigateInCurrentWindow(to: second)
        waitUntil("the next file is being read") { gate.isWaiting }
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first\none", "saved before the read")
        try type(" two", in: document)
        gate.release()

        waitUntil("navigated") { document.fileURL?.lastPathComponent == "Second.md" }
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first\none two", "text typed during the read was saved")
        XCTAssertEqual(document.editorControllerForTesting?.text, "second\n")
        XCTAssertEqual(conflicts, [])
    }

    func testFailedSaveWhenTheNextFileArrivesKeepsTheCurrentFile() throws {
        let first = try directory.createTextFile(named: "First.md", contents: "first\n")
        let second = try directory.createTextFile(named: "Second.md", contents: "second\n")
        let gate = SourceReadGate()
        let (document, _) = try makeDocument(for: first, autosaveDelay: 60, sourceLoader: { url in
            if url.lastPathComponent == "Second.md" { gate.wait() }
            return try MarkdownReaderDocument.loadSource(from: url)
        })
        defer { gate.release(); document.close() }
        document.beginEditing()

        document.navigateInCurrentWindow(to: second)
        waitUntil("the next file is being read") { gate.isWaiting }
        try type("mine", in: document)
        try Data("theirs\n".utf8).write(to: first)
        conflictResolution = .cancel
        gate.release()

        waitUntil("the commit tried to save") { self.conflicts == [.changedOnDisk] }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(document.fileURL?.lastPathComponent, "First.md", "navigation was abandoned")
        XCTAssertTrue(document.isEditing)
        XCTAssertEqual(document.editorControllerForTesting?.text, "first\nmine")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "theirs\n")
        XCTAssertTrue(document.navigationHistory.backEntries.isEmpty)
    }

    func testReloadStartedDuringTheCommitPromptCannotReplaceTheNextFile() throws {
        let first = try directory.createTextFile(named: "First.md", contents: "first\n")
        let second = try directory.createTextFile(named: "Second.md", contents: "second\n")
        let gate = SourceReadGate()
        let (document, _) = try makeDocument(for: first, autosaveDelay: 60, sourceLoader: { url in
            if url.lastPathComponent == "Second.md" { gate.wait() }
            return try MarkdownReaderDocument.loadSource(from: url)
        })
        defer { gate.release(); document.close() }
        document.beginEditing()
        document.navigateInCurrentWindow(to: second)
        waitUntil("the next file is being read") { gate.isWaiting }
        try type("mine", in: document)
        try Data("theirs\n".utf8).write(to: first)
        // The first file changes again while the commit's conflict prompt is open.
        duringConflictPrompt = { [weak self] in
            self?.duringConflictPrompt = nil
            self?.monitors.last?.onChange()
        }
        conflictResolution = .overwrite
        gate.release()

        waitUntil("navigated") { document.fileURL?.lastPathComponent == "Second.md" }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(document.editorControllerForTesting?.text, "second\n", "the stale reload of the first file was dropped")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first\nmine")
        XCTAssertEqual(conflicts, [.changedOnDisk])
    }

    func testFailedAutosaveKeepsTheFileAndReportsTheError() throws {
        let url = try directory.createTextFile(named: "Doc.md", contents: "one\n")
        let failure = CocoaError(.fileWriteVolumeReadOnly)
        let (document, _) = try makeDocument(for: url, fileWriter: { _, _, beforeReplacing in
            try beforeReplacing()
            throw failure
        })
        defer { document.close() }
        conflictResolution = .cancel
        document.beginEditing()
        try type("mine", in: document)

        waitUntil("the failed save was reported") { !self.conflicts.isEmpty }
        XCTAssertEqual(conflicts, [.writeFailed(failure.localizedDescription)])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\n")
        XCTAssertEqual(document.editorControllerForTesting?.text, "one\nmine")
        XCTAssertTrue(document.isEditing)
    }

    func testExplicitSaveWaitsForTheBackgroundSaveAndWritesTheRest() throws {
        let url = try directory.createTextFile(named: "Doc.md", contents: "one\n")
        let writer = RecordingFileWriter()
        let (document, _) = try makeDocument(for: url, autosaveDelay: 0.01, fileWriter: { try writer.write($0, $1, $2) })
        defer { writer.release(); document.close() }
        document.beginEditing()
        writer.holdNextWrite()
        try type("A", in: document)
        waitUntil("autosave is writing") { writer.isHolding }
        try type("B", in: document)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { writer.release() }
        XCTAssertTrue(document.flushEdits(interactive: true))

        XCTAssertEqual(writer.writes, ["one\nA", "one\nAB"])
        XCTAssertEqual(writer.wroteOnMainThread.first, false, "autosave writes off the main thread")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\nAB")
    }

    func testTextTypedDuringABackgroundSaveIsSavedNext() throws {
        let url = try directory.createTextFile(named: "Doc.md", contents: "one\n")
        let writer = RecordingFileWriter()
        let (document, _) = try makeDocument(for: url, autosaveDelay: 0.01, fileWriter: { try writer.write($0, $1, $2) })
        defer { writer.release(); document.close() }
        document.beginEditing()
        writer.holdNextWrite()
        try type("A", in: document)
        waitUntil("autosave is writing") { writer.isHolding }
        try type("B", in: document)
        // The next autosave comes due while the first save is still running.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        writer.release()

        waitUntil("the newer text was saved too") { (try? String(contentsOf: url, encoding: .utf8)) == "one\nAB" }
        XCTAssertEqual(writer.writes, ["one\nA", "one\nAB"])
        XCTAssertEqual(conflicts, [])
    }

    func testExternalChangeDuringABackgroundSaveIsAConflictNotALoss() throws {
        let url = try directory.createTextFile(named: "Doc.md", contents: "one\n")
        let writer = RecordingFileWriter()
        let (document, _) = try makeDocument(for: url, autosaveDelay: 0.01, fileWriter: { try writer.write($0, $1, $2) })
        defer { writer.release(); document.close() }
        document.beginEditing()
        writer.holdNextWrite()
        try type("A", in: document)
        waitUntil("autosave is writing") { writer.isHolding }
        try type("B", in: document)
        // The next autosave comes due while the first save is still running.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        try Data("theirs\n".utf8).write(to: url)
        conflictResolution = .overwrite

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { writer.release() }
        monitors.last?.onChange()

        waitUntil("the conflict was resolved") { (try? String(contentsOf: url, encoding: .utf8)) == "one\nAB" }
        XCTAssertEqual(conflicts, [.changedOnDisk], "asked once")
        XCTAssertEqual(document.editorControllerForTesting?.text, "one\nAB")
    }

    func testDeactivationSavesInTheBackgroundAndNeverPrompts() throws {
        let url = try directory.createTextFile(named: "Doc.md", contents: "one\n")
        let (document, _) = try makeDocument(for: url, autosaveDelay: 60)
        defer { document.close() }
        document.beginEditing()
        try type("A", in: document)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        waitUntil("saved on deactivation") { (try? String(contentsOf: url, encoding: .utf8)) == "one\nA" }

        try type("B", in: document)
        try Data("theirs\n".utf8).write(to: url)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(conflicts, [], "never prompts in the background")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs\n")
        XCTAssertEqual(document.editorControllerForTesting?.text, "one\nAB")
    }

    func testClosingWaitsForTheBackgroundSave() throws {
        let url = try directory.createTextFile(named: "Doc.md", contents: "one\n")
        let writer = RecordingFileWriter()
        let (document, _) = try makeDocument(for: url, autosaveDelay: 0.01, fileWriter: { try writer.write($0, $1, $2) })
        defer { writer.release() }
        document.beginEditing()
        writer.holdNextWrite()
        try type("A", in: document)
        waitUntil("autosave is writing") { writer.isHolding }
        try type("B", in: document)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { writer.release() }
        document.close()

        XCTAssertEqual(writer.writes, ["one\nA", "one\nAB"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\nAB")
    }

    func testPastedCRLFTextIsNormalizedAndSavedInTheFilesLineEnding() throws {
        let url = try directory.createTextFile(named: "Doc.md", contents: "x\r\ny\r\n")
        let (document, _) = try makeDocument(for: url, autosaveDelay: 60)
        defer { document.close() }
        document.beginEditing()
        let editor = try XCTUnwrap(document.editorControllerForTesting)
        let textView = editor.textViewForTesting
        XCTAssertEqual(editor.text, "x\ny\n")
        try type("z", in: document)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

        textView.setSelectedRange(NSRange(location: 5, length: 0))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("a\r\nb", forType: .string)
        XCTAssertTrue(textView.readSelection(from: pasteboard, type: .string))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

        XCTAssertEqual(editor.text, "x\ny\nza\nb")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 8, length: 0), "the insertion point follows the pasted text")
        XCTAssertTrue(document.flushEdits(interactive: true))
        XCTAssertEqual(try Data(contentsOf: url), Data("x\r\ny\r\nza\r\nb".utf8), "no CR is doubled")

        editor.undoManagerForTesting.undo()
        XCTAssertEqual(editor.text, "x\ny\nz", "one undo removes the paste and keeps the typing")
        editor.undoManagerForTesting.redo()
        XCTAssertEqual(editor.text, "x\ny\nza\nb")
    }

    func testReadOnlyFileRefusesEditMode() throws {
        let url = try directory.createTextFile(named: "Locked.md", contents: "locked\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let (document, _) = try makeDocument(for: url)
        defer { document.close() }

        document.beginEditing()

        XCTAssertFalse(document.isEditing)
        XCTAssertEqual((loadErrors.first as? CocoaError)?.code, .fileWriteNoPermission)
    }

    func testRevertEditsRestoresOpenedTextAsUndoableEdit() throws {
        let url = try directory.createTextFile(named: "Doc.md", contents: "start\n")
        let (document, _) = try makeDocument(for: url)
        defer { document.close() }
        document.beginEditing()
        try type("changed", in: document)
        // Let the typing undo group close, as it would between key events.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertTrue(document.validateUserInterfaceItem(NSMenuItem(title: "", action: #selector(MarkdownReaderDocument.revertEdits(_:)), keyEquivalent: "")))

        document.revertEdits(nil)

        XCTAssertEqual(document.editorControllerForTesting?.text, "start\n")
        waitUntil("revert saved") { (try? String(contentsOf: url, encoding: .utf8)) == "start\n" }
        document.editorControllerForTesting?.undoManagerForTesting.undo()
        XCTAssertEqual(document.editorControllerForTesting?.text, "start\nchanged")
    }

    func testEditMenuItemReflectsStateAndRequiresLoadedFile() throws {
        let url = try directory.createTextFile(named: "Doc.md", contents: "x\n")
        let (document, _) = try makeDocument(for: url)
        defer { document.close() }
        let item = NSMenuItem(title: "Edit Markdown", action: #selector(MarkdownReaderDocument.toggleEditing(_:)), keyEquivalent: "e")
        let saveItem = NSMenuItem(title: "Save", action: #selector(MarkdownReaderDocument.saveEdits(_:)), keyEquivalent: "s")

        XCTAssertTrue(document.validateUserInterfaceItem(item))
        XCTAssertEqual(item.state, .off)
        XCTAssertFalse(document.validateUserInterfaceItem(saveItem))

        document.beginEditing()
        XCTAssertTrue(document.validateUserInterfaceItem(item))
        XCTAssertEqual(item.state, .on)
        XCTAssertTrue(document.validateUserInterfaceItem(saveItem))
        document.endEditing()
    }
}

// MARK: - Editor

@MainActor
final class MarkdownSourceEditorTests: XCTestCase {
    private func color(at location: Int, in editor: MarkdownSourceEditorViewController) -> NSColor? {
        editor.textViewForTesting.textStorage?.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    func testHighlightingFollowsEditsThatOpenAFence() {
        let editor = MarkdownSourceEditorViewController()
        editor.loadViewIfNeeded()
        editor.load(text: "# Title\n\nplain words\n")
        let colors = MarkdownEditorColors(palette: ReaderTheme.current)

        XCTAssertEqual(color(at: 2, in: editor), colors.heading)
        let plainLocation = ("# Title\n\nplain words\n" as NSString).range(of: "plain").location
        XCTAssertEqual(color(at: plainLocation, in: editor), colors.text)

        // Typing a fence above turns the following line into code.
        editor.textViewForTesting.insertText("```\n", replacementRange: NSRange(location: plainLocation, length: 0))
        XCTAssertEqual(color(at: plainLocation + 4, in: editor), colors.syntaxVariable)
        XCTAssertEqual(color(at: plainLocation, in: editor), colors.secondaryText, "fence delimiter")
    }

    func testStructuralChangeDetectionIgnoresBlocksThatOnlyShift() {
        let highlighter = MarkdownSourceHighlighter()
        let before = highlighter.structure(of: "intro\n```\ncode\n```\n")
        let shifted = highlighter.structure(of: "intro more\n```\ncode\n```\n")
        XCTAssertNil(MarkdownSourceEditorViewController.firstStructuralChange(
            previous: before, current: shifted, editedRange: NSRange(location: 5, length: 5), delta: 5
        ))

        let opened = highlighter.structure(of: "```\nintro\n```\ncode\n```\n")
        XCTAssertNotNil(MarkdownSourceEditorViewController.firstStructuralChange(
            previous: before, current: opened, editedRange: NSRange(location: 0, length: 4), delta: 4
        ))
    }

    func testScrollPositionRoundTripsThroughSourceLines() throws {
        let editor = MarkdownSourceEditorViewController()
        let window = hostInWindow(editor, size: NSSize(width: 600, height: 400))
        defer { window.close() }
        editor.load(text: (1...400).map { "Line \($0)" }.joined(separator: "\n"))
        window.layoutIfNeeded()

        editor.scroll(toSourceLine: 120.5)
        let position = editor.currentScrollPosition
        XCTAssertEqual(position.line, 120.5, accuracy: 0.15)
        XCTAssertEqual(position.totalLines, 400)
        XCTAssertLessThan(position.topLine, 1, "the top inset counts as part of the range")
        XCTAssertGreaterThan(position.topLine, 0)
        XCTAssertGreaterThan(position.visibleLines, 10)
        XCTAssertEqual(position.bottomLine + position.visibleLines, 401, accuracy: 1.5)

        // Both ends of the range are reachable and report themselves.
        editor.scroll(toSourceLine: position.topLine)
        XCTAssertEqual(editor.textViewForTesting.enclosingScrollView?.contentView.bounds.minY, 0)
        XCTAssertEqual(editor.currentScrollPosition.line, position.topLine, accuracy: 0.01)
        editor.scroll(toSourceLine: position.bottomLine)
        XCTAssertEqual(editor.currentScrollPosition.line, position.bottomLine, accuracy: 0.05)
        editor.scroll(toSourceLine: 9_999)
        XCTAssertEqual(editor.currentScrollPosition.line, position.bottomLine, accuracy: 0.05)

        var reported: [EditorScrollPosition] = []
        editor.onScroll = { reported.append($0) }
        editor.scroll(toSourceLine: 50)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(reported, [], "programmatic scrolls are not reported back")
        editor.textViewForTesting.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 900))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(reported.count, 1)
    }

    func testInsertedCarriageReturnsBecomeLineFeeds() {
        let editor = MarkdownSourceEditorViewController()
        editor.loadViewIfNeeded()
        editor.load(text: "a\n")
        let revision = editor.revision

        editor.textViewForTesting.insertText("p\rq\r\nr", replacementRange: NSRange(location: 2, length: 0))

        XCTAssertEqual(editor.text, "a\np\nq\nr")
        XCTAssertEqual(editor.textViewForTesting.selectedRange(), NSRange(location: 7, length: 0))
        XCTAssertGreaterThan(editor.revision, revision, "the change counts as an edit")
    }

    func testEditorUndoIsPrivateAndClearedOnLoad() throws {
        let editor = MarkdownSourceEditorViewController()
        editor.loadViewIfNeeded()
        editor.load(text: "a")
        editor.textViewForTesting.insertText("b", replacementRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(editor.undoManagerForTesting.canUndo)
        XCTAssertTrue(editor.textViewForTesting.undoManager === editor.undoManagerForTesting)

        editor.load(text: "fresh")
        XCTAssertFalse(editor.undoManagerForTesting.canUndo)
    }

    func testLargeDocumentHighlightAndEditStayFast() {
        let section = "## Heading\n\nSome *emphasis*, **strong**, `code`, and a [link](x.md).\n\n```swift\nlet value = 1 // note\n```\n\n"
        let text = String(repeating: section, count: 1_500)
        let editor = MarkdownSourceEditorViewController()
        editor.loadViewIfNeeded()

        let loadStart = Date()
        editor.load(text: text)
        let loadDuration = Date().timeIntervalSince(loadStart)

        let editStart = Date()
        editor.textViewForTesting.insertText("x", replacementRange: NSRange(location: 20, length: 0))
        let editDuration = Date().timeIntervalSince(editStart)

        print("edit-mode highlight: \((text as NSString).length) UTF-16 units, load \(Int(loadDuration * 1000)) ms, keystroke \(Int(editDuration * 1000)) ms")
        XCTAssertEqual((editor.text as NSString).substring(with: NSRange(location: 20, length: 1)), "x")
        let colors = MarkdownEditorColors(palette: ReaderTheme.current)
        XCTAssertEqual(color(at: 3, in: editor), colors.heading, "the edited section keeps its coloring")
        if PerformanceTesting.isEnabled {
            XCTAssertLessThan(editDuration, 0.25, "a keystroke must only recolor nearby lines")
        }
    }
}

// MARK: - Live preview in WebKit

@MainActor
final class ReaderLivePreviewTests: XCTestCase {
    private func render(_ source: String, annotated: Bool = true) -> WebKitRenderOutput {
        WebKitHTMLRenderer(annotatesSourceLines: annotated).render(document: MarkdownParser().parse(source: source, baseURL: nil))
    }

    /// An editor geometry for a document of `totalLines`: 20 lines visible,
    /// scrolling from just above line 1 to 20 lines before the end.
    private func position(line: Double, totalLines: Int) -> EditorScrollPosition {
        EditorScrollPosition(
            line: line,
            topLine: 0.2,
            bottomLine: Double(totalLines) - 19,
            visibleLines: 20,
            totalLines: totalLines
        )
    }

    private func lineAtTop(of reader: WebKitReaderViewController, for position: EditorScrollPosition) -> Double? {
        let reported = expectation(description: "line at top")
        var line: Double?
        reader.sourceLineAtTop(for: position) { value in
            line = value
            reported.fulfill()
        }
        wait(for: [reported], timeout: 5)
        return line
    }

    private func load(_ output: WebKitRenderOutput, into reader: WebKitReaderViewController, settle: TimeInterval = 0.05) {
        let finished = expectation(description: "navigation finished")
        reader.onNavigationFinished = {
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { finished.fulfill() }
        }
        reader.apply(renderOutput: output, initialScrollFraction: nil)
        wait(for: [finished], timeout: 10)
        reader.onNavigationFinished = nil
    }

    private func evaluate(_ script: String, in reader: WebKitReaderViewController) -> Any? {
        let finished = expectation(description: "evaluate")
        let box = ResultBox()
        reader.evaluateJavaScriptForTesting(script) { value, _ in
            box.value = value
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        return box.value
    }

    private func patch(_ output: WebKitRenderOutput, in reader: WebKitReaderViewController) -> Bool {
        let finished = expectation(description: "patch")
        var patched = false
        reader.applyLiveUpdate(renderOutput: output) { result in
            patched = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        return patched
    }

    private func pause(_ seconds: TimeInterval) {
        let done = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    /// Waits until `condition` is true in the page, for asynchronous page
    /// work (diagram rendering, observers) whose duration varies with load.
    private func waitForScript(_ condition: String, in reader: WebKitReaderViewController, timeout: TimeInterval = 10) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while evaluate("Boolean(\(condition))", in: reader) as? Bool != true, Date() < deadline {
            pause(0.05)
        }
    }

    func testPatchKeepsUnchangedBlocksReplacesEditedOnesAndUpdatesLines() {
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader)
        defer { reader.invalidateForTesting(); window.close() }
        load(render("# One\n\nPara A\n\nPara B\n"), into: reader)
        _ = evaluate("document.querySelectorAll('#write p')[1].waferTestMarker = 'kept'; true", in: reader)

        XCTAssertTrue(patch(render("# One\n\nNew line\n\nPara A changed\n\nPara B\n"), in: reader))

        XCTAssertEqual(evaluate("document.querySelectorAll('#write p')[2].waferTestMarker || ''", in: reader) as? String, "kept")
        XCTAssertEqual(evaluate("document.querySelectorAll('#write p')[2].getAttribute('data-source-line')", in: reader) as? String, "7")
        XCTAssertEqual(evaluate("document.querySelectorAll('#write p')[1].textContent", in: reader) as? String, "Para A changed")
        XCTAssertEqual(evaluate("document.querySelectorAll('#write p').length", in: reader) as? Int, 3)
        XCTAssertEqual(reader.livePatchCountForTesting, 1)
        XCTAssertEqual(reader.liveFullReloadCountForTesting, 0)

        let exported = expectation(description: "export snapshot")
        var snapshot = ""
        reader.exportDOMSnapshot { result in
            snapshot = (try? result.get()) ?? ""
            exported.fulfill()
        }
        wait(for: [exported], timeout: 5)
        XCTAssertTrue(snapshot.contains("Para A changed"))
        XCTAssertFalse(snapshot.contains("data-source-line"), "exports never carry edit-mode annotations")
    }

    func testUnchangedMermaidDiagramSurvivesPatchAndNewDiagramRenders() {
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader)
        defer { reader.invalidateForTesting(); window.close() }
        let diagram = "```mermaid\ngraph TD; A-->B\n```\n"
        load(render("Intro\n\n" + diagram), into: reader, settle: 0.3)
        _ = evaluate("document.querySelector('.md-mermaid-diagram').waferTestMarker = 'kept'; true", in: reader)

        XCTAssertTrue(patch(render("Intro edited\n\n" + diagram + "\n```mermaid\ngraph LR; C-->D\n```\n"), in: reader))
        waitForScript("document.querySelectorAll('.md-mermaid-diagram .md-mermaid-output svg').length === 2", in: reader)

        XCTAssertEqual(evaluate("document.querySelectorAll('.md-mermaid-diagram')[0].waferTestMarker || ''", in: reader) as? String, "kept")
        XCTAssertEqual(evaluate("document.querySelectorAll('.md-mermaid-diagram .md-mermaid-output svg').length", in: reader) as? Int, 2)
        XCTAssertEqual(reader.liveFullReloadCountForTesting, 0)
    }

    func testPatchedCodeBlocksGetCopyButtons() {
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader)
        defer { reader.invalidateForTesting(); window.close() }
        load(render("Intro\n"), into: reader)

        XCTAssertTrue(patch(render("Intro\n\n```swift\nlet x = 1\n```\n"), in: reader))
        waitForScript("document.querySelectorAll('#write pre.md-fences .md-copy-button').length > 0", in: reader)

        XCTAssertEqual(evaluate("document.querySelectorAll('#write pre.md-fences .md-copy-button').length", in: reader) as? Int, 1)
    }

    func testFirstDiagramOnAPageWithoutMermaidFallsBackToFullLoad() {
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader)
        defer { reader.invalidateForTesting(); window.close() }
        load(render("Text only\n"), into: reader)

        let reloaded = expectation(description: "full load finished")
        reader.onNavigationFinished = { reloaded.fulfill() }
        XCTAssertFalse(patch(render("Text only\n\n```mermaid\ngraph TD; A-->B\n```\n"), in: reader))
        wait(for: [reloaded], timeout: 10)
        XCTAssertEqual(reader.liveFullReloadCountForTesting, 1)
    }

    func testEnteringAndLeavingEditModeAnnotatesThePageInPlace() {
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader)
        defer { reader.invalidateForTesting(); window.close() }
        let source = "# Title\n\n- one\n- two\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\n```mermaid\ngraph TD; A-->B\n```\n"
        load(render(source, annotated: false), into: reader, settle: 0.3)
        XCTAssertEqual(evaluate("document.querySelectorAll('[data-source-line]').length", in: reader) as? Int, 0)
        _ = evaluate("""
            document.querySelector('.md-mermaid-diagram').waferTestMarker = 'kept';
            document.querySelectorAll('#write li')[1].waferTestMarker = 'kept';
            true
            """, in: reader)

        XCTAssertTrue(patch(render(source), in: reader))

        XCTAssertEqual(reader.liveFullReloadCountForTesting, 0)
        XCTAssertEqual(evaluate("document.querySelector('#write h1').getAttribute('data-source-line')", in: reader) as? String, "1")
        XCTAssertEqual(evaluate("document.querySelectorAll('#write li')[1].getAttribute('data-source-line')", in: reader) as? String, "4")
        XCTAssertEqual(evaluate("document.querySelector('#write tbody tr').getAttribute('data-source-line')", in: reader) as? String, "8")
        XCTAssertEqual(evaluate("document.querySelector('.md-mermaid-diagram').getAttribute('data-source-line')", in: reader) as? String, "10")
        XCTAssertEqual(evaluate("document.querySelector('.md-mermaid-diagram').waferTestMarker || ''", in: reader) as? String, "kept")
        XCTAssertEqual(evaluate("document.querySelectorAll('#write li')[1].waferTestMarker || ''", in: reader) as? String, "kept")
        XCTAssertEqual(evaluate("document.querySelectorAll('.md-mermaid-diagram .md-mermaid-output svg').length", in: reader) as? Int, 1)

        // Leaving: the unannotated render strips the attributes, same nodes.
        XCTAssertTrue(patch(render(source, annotated: false), in: reader))

        XCTAssertEqual(reader.liveFullReloadCountForTesting, 0)
        XCTAssertEqual(evaluate("document.querySelectorAll('[data-source-line]').length", in: reader) as? Int, 0)
        XCTAssertEqual(evaluate("document.querySelector('.md-mermaid-diagram').waferTestMarker || ''", in: reader) as? String, "kept")
        XCTAssertEqual(evaluate("document.querySelectorAll('#write li')[1].waferTestMarker || ''", in: reader) as? String, "kept")
    }

    func testScrollSyncAlignsPreviewWithEditorLineAndReachesBothEnds() {
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader, size: NSSize(width: 800, height: 500))
        defer { reader.invalidateForTesting(); window.close() }
        let source = (1...200).map { "Paragraph \($0) with enough words to be a real line." }.joined(separator: "\n\n")
        load(render(source), into: reader)
        var reportedLines: [Double] = []
        reader.onLiveScroll = { reportedLines.append($0) }

        // Paragraph 51 starts on source line 101, far from either end.
        reader.syncScroll(to: position(line: 101, totalLines: 399))
        pause(0.2)
        let offset = evaluate("""
            Math.round(window.scrollY - (document.querySelector('[data-source-line="101"]').getBoundingClientRect().top + window.scrollY))
            """, in: reader) as? Int
        XCTAssertEqual(offset ?? 999, 0, accuracy: 2)
        XCTAssertEqual(lineAtTop(of: reader, for: position(line: 1, totalLines: 399)) ?? 0, 101, accuracy: 0.5)

        reader.syncScroll(to: position(line: 380, totalLines: 399))
        pause(0.2)
        let atBottom = evaluate("""
            (function() { const r = document.scrollingElement; return Math.abs(r.scrollHeight - window.innerHeight - window.scrollY) < 2; })()
            """, in: reader) as? Bool
        XCTAssertEqual(atBottom, true, "the editor's last position is the preview's last position")

        reader.syncScroll(to: position(line: 0.2, totalLines: 399))
        pause(0.2)
        XCTAssertEqual(evaluate("window.scrollY", in: reader) as? Double, 0)
        XCTAssertEqual(reportedLines, [], "the preview's own sync scrolls are not reported as the user's")
    }

    func testScrollMappingIsContinuousAndMonotonicOverTheWholeRange() throws {
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader, size: NSSize(width: 800, height: 500))
        defer { reader.invalidateForTesting(); window.close() }
        // Uneven content: a tall diagram, a table and a long code block, and
        // short paragraphs at both ends.
        let source = "# Start\n\nIntro\n\n```mermaid\ngraph TD; A-->B; B-->C; C-->D\n```\n\n"
            + (1...40).map { "Paragraph \($0)." }.joined(separator: "\n\n")
            + "\n\n| a | b |\n| - | - |\n" + (1...30).map { "| \($0) | x |" }.joined(separator: "\n")
            + "\n\n```\n" + (1...60).map { "code line \($0)" }.joined(separator: "\n") + "\n```\n\nEnd.\n"
        let totalLines = source.split(separator: "\n", omittingEmptySubsequences: false).count
        load(render(source), into: reader, settle: 0.4)
        reader.syncScroll(to: position(line: 1, totalLines: totalLines))
        pause(0.1)

        let result = try XCTUnwrap(evaluate("""
            (function() {
              var top = 0.2, bottom = \(totalLines - 19), offsets = [];
              for (var line = top; line <= bottom; line += 0.25) {
                window.waferLive.scrollToLine(line, top, bottom, 20, \(totalLines));
                offsets.push(window.scrollY);
              }
              window.waferLive.scrollToLine(bottom, top, bottom, 20, \(totalLines));
              offsets.push(window.scrollY);
              var largest = 0, backwards = 0;
              for (var index = 1; index < offsets.length; index++) {
                var delta = offsets[index] - offsets[index - 1];
                if (delta < -1) { backwards++; }
                largest = Math.max(largest, delta);
              }
              var root = document.scrollingElement;
              return [offsets[0], offsets[offsets.length - 1], root.scrollHeight - window.innerHeight, largest, backwards];
            })()
            """, in: reader) as? [Double])

        XCTAssertEqual(result[0], 0, "starts at the top")
        XCTAssertEqual(result[1], result[2], accuracy: 1.5, "ends at the bottom")
        XCTAssertGreaterThan(result[2], 1_000)
        XCTAssertEqual(result[4], 0, "never moves backwards")
        // A quarter of a line never moves the preview by more than a fraction
        // of the window: no jump when either end is reached.
        XCTAssertLessThan(result[3], 120)
    }

    func testUserScrollOfThePreviewReportsTheLineForTheEditor() throws {
        let reader = WebKitReaderViewController()
        let window = hostInWindow(reader, size: NSSize(width: 800, height: 500))
        defer { reader.invalidateForTesting(); window.close() }
        let source = (1...200).map { "Paragraph \($0) with enough words to be a real line." }.joined(separator: "\n\n")
        load(render(source), into: reader)
        var reportedLines: [Double] = []
        XCTAssertEqual(lineAtTop(of: reader, for: position(line: 1, totalLines: 399)) ?? 0, 0.2, accuracy: 0.01)
        let scrolled = expectation(description: "preview reports the target source line")
        var observedTarget = false
        reader.onLiveScroll = { line in
            reportedLines.append(line)
            if !observedTarget, abs(line - 151) < 0.5 {
                observedTarget = true
                scrolled.fulfill()
            }
        }

        // Anything that is not the sync's own scroll counts as the user's.
        let target = try XCTUnwrap(evaluate("""
            (function() {
              var y = document.querySelector('[data-source-line="151"]').getBoundingClientRect().top + window.scrollY;
              window.scrollTo(0, y);
              return y;
            })()
            """, in: reader) as? Double)
        wait(for: [scrolled], timeout: 15)

        let line = try XCTUnwrap(reportedLines.last)
        XCTAssertEqual(line, 151, accuracy: 0.5)
        // Sending the line back leaves the preview where the user put it.
        reader.syncScroll(to: position(line: line, totalLines: 399))
        pause(0.2)
        XCTAssertEqual(evaluate("window.scrollY", in: reader) as? Double ?? -1, target, accuracy: 1)
        // WebKit can deliver several scroll events for one position. Each
        // still has to describe the requested line, without changing position.
        XCTAssertEqual(reportedLines.last ?? -1, line, accuracy: 0.5)

        // After edit mode ends the page stops reporting.
        reader.endLivePreview()
        let unexpectedReport = expectation(description: "no report after leaving live preview")
        unexpectedReport.isInverted = true
        reader.onLiveScroll = { _ in unexpectedReport.fulfill() }
        _ = evaluate("window.scrollTo(0, 200); true", in: reader)
        wait(for: [unexpectedReport], timeout: 1)
    }
}

// MARK: - End to end

@MainActor
final class EditModeEndToEndTests: XCTestCase {
    fileprivate func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTAssertTrue(condition(), description)
    }

    fileprivate func evaluate(_ script: String, in reader: WebKitReaderViewController) -> Any? {
        let box = ResultBox()
        reader.evaluateJavaScriptForTesting(script) { value, _ in
            box.value = value
            box.finished = true
        }
        waitUntil("script finished", timeout: 5) { box.finished }
        return box.value
    }

    /// Real document, render worker, and WebKit reader: typing patches the
    /// preview in place, autosave writes the file, and leaving edit mode
    /// restores an unannotated reader.
    func testTypingPatchesRealPreviewAndSaves() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Live.md", contents: "# Title\n\nPara one\n\nPara two\n")
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            fileMonitorFactory: { _, _ in EditTestFileMonitor(onChange: {}) },
            autosaveDelay: 0.2,
            liveRenderInterval: 0.02
        )
        document.fileURL = url
        try document.read(from: Data(contentsOf: url), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let host = try XCTUnwrap(document.windowControllers.first as? DocumentHostWindowController)
        host.window?.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 700), display: false)
        host.showWindow(nil)
        let reader = host.activeTab.readerController
        waitUntil("initial render") { reader.isContentReadyForExport }
        XCTAssertEqual(host.window?.frame.width, 1100)

        let hostedWidth = host.hostedContentWidthForTesting
        _ = evaluate("document.querySelector('#write h1').waferTestMarker = 'kept'; true", in: reader)

        document.beginEditing()
        waitUntil("page annotated in place") {
            self.evaluate("document.querySelectorAll('#write [data-source-line]').length", in: reader) as? Int == 3
        }
        XCTAssertEqual(reader.liveFullReloadCountForTesting, 0, "entering edit mode does not reload the page")
        XCTAssertEqual(evaluate("document.querySelector('#write h1').waferTestMarker || ''", in: reader) as? String, "kept")
        waitUntil("editor pane open") { !host.isEditorPaneAnimatingForTesting }
        XCTAssertGreaterThan(host.editorPaneWidthForTesting, 200)
        XCTAssertEqual(host.editorPaneWidthForTesting + host.hostedContentWidthForTesting, host.window?.frame.width)

        let textView = try XCTUnwrap(document.editorControllerForTesting?.textViewForTesting)
        let insertion = (textView.string as NSString).range(of: "Para one").upperBound
        textView.insertText(" edited", replacementRange: NSRange(location: insertion, length: 0))

        // The first patch was the one that annotated the page.
        waitUntil("preview patched in place") { reader.livePatchCountForTesting >= 2 }
        XCTAssertEqual(reader.liveFullReloadCountForTesting, 0)
        XCTAssertEqual(evaluate("document.querySelectorAll('#write p')[0].textContent", in: reader) as? String, "Para one edited")
        waitUntil("autosaved") {
            (try? String(contentsOf: url, encoding: .utf8)) == "# Title\n\nPara one edited\n\nPara two\n"
        }

        XCTAssertTrue(document.endEditing())
        waitUntil("annotations removed in place") {
            self.evaluate("document.querySelectorAll('[data-source-line]').length", in: reader) as? Int == 0
        }
        XCTAssertEqual(reader.liveFullReloadCountForTesting, 0, "leaving edit mode does not reload the page")
        XCTAssertEqual(evaluate("document.querySelector('#write h1').waferTestMarker || ''", in: reader) as? String, "kept")
        XCTAssertEqual(evaluate("document.querySelectorAll('#write p')[0].textContent", in: reader) as? String, "Para one edited")
        waitUntil("editor pane closed") { !host.isEditorPaneAnimatingForTesting }
        XCTAssertTrue(host.hostedContentViewController === reader)
        XCTAssertNil(host.editorPaneControllerForTesting)
        XCTAssertEqual(host.hostedContentWidthForTesting, hostedWidth)
        XCTAssertEqual(host.window?.frame.width, 1100)
    }
}

extension EditModeEndToEndTests {
    /// Real document, editor and WebKit reader: entering edit mode leaves the
    /// reader where it was and brings the editor to the same line, then each
    /// pane follows the other.
    func testEnteringKeepsTheReaderInPlaceAndPanesFollowEachOther() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let source = (1...300).map { "Paragraph \($0) with enough words to be a real line." }.joined(separator: "\n\n")
        let url = try directory.createTextFile(named: "Long.md", contents: source)
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            fileMonitorFactory: { _, _ in EditTestFileMonitor(onChange: {}) },
            autosaveDelay: 60,
            liveRenderInterval: 0.02
        )
        document.fileURL = url
        try document.read(from: Data(contentsOf: url), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let host = try XCTUnwrap(document.windowControllers.first as? DocumentHostWindowController)
        host.setReducedMotionForTesting(true)
        host.window?.setFrame(NSRect(x: 0, y: 0, width: 700, height: 600), display: false)
        host.showWindow(nil)
        let reader = host.activeTab.readerController
        waitUntil("initial render") { reader.isContentReadyForExport }

        // The line whose paragraph starts at the top of the preview.
        func previewOffset(ofLine line: Int) -> Double {
            evaluate("document.querySelector('[data-source-line=\"\(line)\"]').getBoundingClientRect().top + window.scrollY", in: reader) as? Double ?? -1
        }
        func previewScrollY() -> Double {
            evaluate("window.scrollY", in: reader) as? Double ?? -1
        }

        _ = evaluate("window.scrollTo(0, 4000); true", in: reader)
        waitUntil("reader reported its scroll") { reader.currentScrollFraction > 0 }

        document.beginEditing()
        let editor = try XCTUnwrap(document.editorControllerForTesting)
        waitUntil("editor aligned with the reader") { editor.currentScrollPosition.line > 20 }
        XCTAssertEqual(reader.liveFullReloadCountForTesting, 0)
        XCTAssertEqual(previewScrollY(), 4000, accuracy: 1, "entering edit mode does not move the reader")
        let alignedLine = editor.currentScrollPosition.line
        let paragraphLine = Int(alignedLine.rounded(.down)) | 1
        XCTAssertEqual(previewOffset(ofLine: paragraphLine), 4000, accuracy: 60, "the editor shows the paragraph at the reader's top")

        // The user scrolls the editor: the preview follows to the same line.
        let clipView = try XCTUnwrap(editor.textViewForTesting.enclosingScrollView?.contentView)
        editor.scroll(toSourceLine: 201)
        let offset = clipView.bounds.minY
        editor.scroll(toSourceLine: 150)
        clipView.scroll(to: NSPoint(x: 0, y: offset))
        let target = previewOffset(ofLine: 201)
        waitUntil("preview followed the editor") { abs(previewScrollY() - target) < 2 }

        // The user scrolls the preview: the editor follows.
        let previewTarget = previewOffset(ofLine: 401)
        _ = evaluate("window.scrollTo(0, \(previewTarget)); true", in: reader)
        waitUntil("editor followed the preview") { abs(editor.currentScrollPosition.line - 401) < 0.5 }
        XCTAssertEqual(previewScrollY(), previewTarget, accuracy: 1, "following does not push the preview back")

        // Both reach their ends together.
        _ = evaluate("window.scrollTo(0, document.scrollingElement.scrollHeight); true", in: reader)
        waitUntil("editor reached its end") {
            abs(editor.currentScrollPosition.line - editor.currentScrollPosition.bottomLine) < 0.05
        }
        _ = evaluate("window.scrollTo(0, 0); true", in: reader)
        waitUntil("editor reached its start") { clipView.bounds.minY == 0 }
    }
}

extension EditModeEndToEndTests {
    /// Measures the pane animation with the real showcase document (diagrams,
    /// math, tables, long code): frames drawn, the slowest frame, and that
    /// the reader never changes width, so WebKit never reflows it.
    func testPaneAnimationWithRealDocumentStaysCheapPerFrame() throws {
        let showcase = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RenderingShowcase.md")
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createFile(named: "Showcase.md", contents: Data(contentsOf: showcase))
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            fileMonitorFactory: { _, _ in EditTestFileMonitor(onChange: {}) },
            autosaveDelay: 60
        )
        document.fileURL = url
        try document.read(from: Data(contentsOf: url), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let host = try XCTUnwrap(document.windowControllers.first as? DocumentHostWindowController)
        let window = try XCTUnwrap(host.window)
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        host.editorVisibleFrameForTesting = visible
        host.setReducedMotionForTesting(false)
        let frame = NSRect(x: visible.maxX - 740, y: visible.minY + 20, width: 720, height: 640)
        host.showWindow(nil)
        window.setFrame(frame, display: false)
        let reader = host.activeTab.readerController
        waitUntil("initial render") { reader.isContentReadyForExport }
        _ = evaluate("window.scrollTo(0, 6000); true", in: reader)
        waitUntil("reader reported its scroll") { reader.currentScrollFraction > 0 }
        let readerWidth = host.hostedContentWidthForTesting

        for opening in [true, false] {
            let toggled = Date()
            document.toggleEditing(nil)
            let toggleCost = Date().timeIntervalSince(toggled)
            XCTAssertTrue(host.isEditorPaneAnimatingForTesting)
            var widths: Set<CGFloat> = []
            while host.isEditorPaneAnimatingForTesting {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
                widths.insert(host.hostedContentWidthForTesting)
                XCTAssertEqual(window.frame.maxX, frame.maxX)
            }
            let stats = try XCTUnwrap(host.lastEditorPaneAnimationStatsForTesting)
            print("""
                edit-mode pane \(opening ? "open" : "close"): toggle \(Int(toggleCost * 1000)) ms before the first frame,                 \(stats.frames) frames, slowest step \(String(format: "%.1f", stats.slowestStep * 1000)) ms
                """)
            XCTAssertEqual(widths, [readerWidth], "the reader keeps its width in every frame")
            XCTAssertEqual(window.frame.width, opening ? 720 + readerWidth : 720)
            if PerformanceTesting.isEnabled {
                XCTAssertLessThan(stats.slowestStep, 0.05)
            }
            if opening {
                waitUntil("editor aligned") { (document.editorControllerForTesting?.currentScrollPosition.line ?? 0) > 20 }
                XCTAssertEqual(evaluate("window.scrollY", in: reader) as? Double ?? -1, 6000, accuracy: 1)
            }
        }
        XCTAssertEqual(reader.liveFullReloadCountForTesting, 0)
        XCTAssertEqual(window.frame, frame)
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: Any?
    var finished = false
}

/// Holds a background source read until released.
private final class SourceReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var waiting = false

    var isWaiting: Bool { lock.withLock { waiting } }

    func wait() {
        lock.withLock { waiting = true }
        _ = semaphore.wait(timeout: .now() + 10)
    }

    func release() {
        semaphore.signal()
    }
}

/// Writes through `MarkdownEditSession.replaceContents`, recording each
/// write's text and thread, and can hold the next write until released.
private final class RecordingFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var recordedWrites: [String] = []
    private var recordedMainThread: [Bool] = []
    private var holdsNext = false
    private var holding = false

    var writes: [String] { lock.withLock { recordedWrites } }
    var wroteOnMainThread: [Bool] { lock.withLock { recordedMainThread } }
    var isHolding: Bool { lock.withLock { holding } }

    func holdNextWrite() {
        lock.withLock { holdsNext = true }
    }

    func release() {
        gate.signal()
    }

    func write(_ url: URL, _ data: Data, _ beforeReplacing: () throws -> Void) throws {
        let holds = lock.withLock {
            defer { holdsNext = false }
            holding = holdsNext
            return holdsNext
        }
        if holds {
            _ = gate.wait(timeout: .now() + 10)
            lock.withLock { holding = false }
        }
        lock.withLock {
            recordedWrites.append(String(decoding: data, as: UTF8.self))
            recordedMainThread.append(Thread.isMainThread)
        }
        try MarkdownEditSession.replaceContents(of: url, with: data, beforeReplacing: beforeReplacing)
    }
}
