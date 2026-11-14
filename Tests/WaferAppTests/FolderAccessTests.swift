import AppKit
import WebKit
import XCTest
@testable import WaferApp
@testable import WaferCore

/// Fake app-scoped bookmarks: the data names the folder; resolution can be
/// made stale or fail per folder.
@MainActor
final class FakeSecurityScopedBookmarks: SecurityScopedBookmarking {
    var stalePaths: Set<String> = []
    var unresolvablePaths: Set<String> = []
    var failsToCreate = false
    private(set) var createdPaths: [String] = []
    private(set) var started: [String] = []
    private(set) var stopped: [String] = []

    static func bookmark(for url: URL) -> Data {
        Data(("bookmark:" + url.path).utf8)
    }

    func bookmarkData(for url: URL) throws -> Data {
        if failsToCreate { throw CocoaError(.fileWriteNoPermission) }
        createdPaths.append(url.path)
        return Self.bookmark(for: url)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        guard let text = String(data: bookmark, encoding: .utf8), text.hasPrefix("bookmark:") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let path = String(text.dropFirst("bookmark:".count))
        guard !unresolvablePaths.contains(path) else { throw CocoaError(.fileNoSuchFile) }
        return (URL(fileURLWithPath: path, isDirectory: true), stalePaths.contains(path))
    }

    func startAccessing(_ url: URL) -> Bool {
        started.append(url.path)
        return true
    }

    func stopAccessing(_ url: URL) {
        stopped.append(url.path)
    }
}

@MainActor
struct SandboxedFolderAccess {
    let store: FolderAccessStore
    let bookmarks: FakeSecurityScopedBookmarks
    let defaults: UserDefaults
}

/// Swaps the shared store and the flow's panel for the length of a test.
@MainActor
enum FolderAccessTestSupport {
    private static var saved: (FolderAccessStore, FolderAccessFlow.FolderChooser, FolderAccessFlow.DocumentRefresher)?

    static func install(_ store: FolderAccessStore) {
        if saved == nil {
            saved = (FolderAccessStore.shared, FolderAccessFlow.chooseFolder, FolderAccessFlow.refreshDocuments)
        }
        FolderAccessStore.shared = store
        FolderAccessFlow.chooseFolder = { request, _, completion in
            XCTFail("Unexpected folder request: \(request.message)")
            completion(nil)
        }
        FolderAccessFlow.refreshDocuments = { _ in }
    }

    static func restore() {
        guard let (store, chooser, refresher) = saved else { return }
        FolderAccessStore.shared = store
        FolderAccessFlow.chooseFolder = chooser
        FolderAccessFlow.refreshDocuments = refresher
        saved = nil
    }
}

extension XCTestCase {
    /// Makes the shared store sandboxed, with fake bookmarks, in-memory
    /// preferences, and no always-readable folders. Folder requests fail the
    /// test unless the test replaces `FolderAccessFlow.chooseFolder`.
    @MainActor
    func installSandboxedFolderAccess(
        defaults: UserDefaults? = nil,
        bookmarks: FakeSecurityScopedBookmarks = FakeSecurityScopedBookmarks()
    ) -> SandboxedFolderAccess {
        let defaults = defaults ?? makeTestUserDefaults()
        let store = FolderAccessStore(defaults: defaults, bookmarks: bookmarks, isSandboxed: true, alwaysReadableRoots: [])
        FolderAccessTestSupport.install(store)
        addTeardownBlock {
            await MainActor.run { FolderAccessTestSupport.restore() }
        }
        return SandboxedFolderAccess(store: store, bookmarks: bookmarks, defaults: defaults)
    }
}

@MainActor
private final class FolderAccessChangeRecorder: NSObject {
    private(set) var count = 0

    init(store: FolderAccessStore) {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(record(_:)), name: .folderAccessDidChange, object: store)
    }

    @objc private func record(_ notification: Notification) {
        count += 1
    }
}

@MainActor
final class FolderAccessStoreTests: XCTestCase {
    private func storedPaths(_ defaults: UserDefaults) -> [String]? {
        (defaults.array(forKey: "folderAccessGrants") as? [[String: Any]])?.compactMap { $0["path"] as? String }
    }

    func testOutsideTheSandboxEveryPathIsReadableAndNothingIsStored() {
        let defaults = makeTestUserDefaults()
        let bookmarks = FakeSecurityScopedBookmarks()
        let store = FolderAccessStore(defaults: defaults, bookmarks: bookmarks, isSandboxed: false)
        let folder = URL(fileURLWithPath: "/tmp/wafer-unsandboxed", isDirectory: true)
        let document = folder.appendingPathComponent("Note.md")

        XCTAssertTrue(store.covers(document))
        XCTAssertTrue(store.grantAccess(to: folder).isEmpty)
        store.recordUnreadableFile(folder.appendingPathComponent("image.png"), forDocumentAt: document)
        store.recordLinkedFiles([folder.appendingPathComponent("Other.md")], forDocumentAt: document)

        XCTAssertTrue(store.unreadableFiles(neededByDocumentAt: document).isEmpty)
        XCTAssertNil(defaults.object(forKey: "folderAccessGrants"))
        XCTAssertTrue(bookmarks.createdPaths.isEmpty)
    }

    func testGrantCoversTheFolderTreeAndStoresAnAppScopedBookmark() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let access = installSandboxedFolderAccess()
        let nested = directory.url.appendingPathComponent("Guides/Setup.md")
        XCTAssertFalse(access.store.covers(nested))

        access.store.grantAccess(to: directory.url)

        XCTAssertTrue(access.store.covers(nested))
        XCTAssertTrue(access.store.covers(directory.url))
        XCTAssertFalse(access.store.covers(directory.url.deletingLastPathComponent().appendingPathComponent("Other.md")))
        XCTAssertEqual(storedPaths(access.defaults), [FileIdentity.identity(for: directory.url)])
        let record = try XCTUnwrap((access.defaults.array(forKey: "folderAccessGrants") as? [[String: Any]])?.first)
        XCTAssertEqual(record["bookmark"] as? Data, FakeSecurityScopedBookmarks.bookmark(for: directory.url))
        XCTAssertEqual(access.bookmarks.started, [directory.url.path])
        XCTAssertEqual(access.store.grantedFolders.map(\.path), [directory.url.path])
    }

    func testRestoreStartsAccessRefreshesStaleBookmarksAndKeepsUnresolvedOnes() throws {
        let first = try TemporaryTestDirectory()
        defer { first.remove() }
        let second = try TemporaryTestDirectory()
        defer { second.remove() }
        let unmounted = URL(fileURLWithPath: "/Volumes/WaferTestUnmounted-\(UUID().uuidString)/Notes", isDirectory: true)
        let defaults = makeTestUserDefaults()
        let records: [[String: Any]] = [first.url, second.url, unmounted].map {
            ["path": FileIdentity.identity(for: $0), "bookmark": FakeSecurityScopedBookmarks.bookmark(for: $0)]
        }
        defaults.set(records, forKey: "folderAccessGrants")
        let bookmarks = FakeSecurityScopedBookmarks()
        bookmarks.stalePaths = [second.url.path]
        bookmarks.unresolvablePaths = [unmounted.path]
        let access = installSandboxedFolderAccess(defaults: defaults, bookmarks: bookmarks)

        access.store.restoreGrants()
        access.store.restoreGrants()

        XCTAssertEqual(bookmarks.started, [first.url.path, second.url.path])
        XCTAssertEqual(bookmarks.createdPaths, [second.url.path], "only the stale bookmark is made again")
        XCTAssertTrue(access.store.covers(first.url.appendingPathComponent("A.md")))
        XCTAssertTrue(access.store.covers(second.url.appendingPathComponent("B.md")))
        XCTAssertFalse(access.store.covers(unmounted.appendingPathComponent("C.md")))
        XCTAssertEqual(storedPaths(defaults), records.compactMap { $0["path"] as? String }, "an unresolved grant is kept for a later launch")
    }

    func testAParentGrantReplacesNarrowerOnesAndAGrantInsideOneAddsNothing() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let child = directory.url.appendingPathComponent("Child", isDirectory: true)
        let grandchild = child.appendingPathComponent("Grandchild", isDirectory: true)
        try FileManager.default.createDirectory(at: grandchild, withIntermediateDirectories: true)
        let access = installSandboxedFolderAccess()

        access.store.grantAccess(to: child)
        access.store.grantAccess(to: directory.url)
        access.store.grantAccess(to: grandchild)

        XCTAssertEqual(storedPaths(access.defaults), [FileIdentity.identity(for: directory.url)])
        XCTAssertEqual(access.bookmarks.createdPaths, [child.path, directory.url.path])
        XCTAssertEqual(access.bookmarks.stopped, [child.path])
        XCTAssertTrue(access.store.covers(grandchild.appendingPathComponent("Note.md")))

        access.store.stopAccessingAll()
        XCTAssertEqual(access.bookmarks.stopped, [child.path, directory.url.path])
        XCTAssertFalse(access.store.covers(grandchild.appendingPathComponent("Note.md")))
    }

    func testABookmarkThatCannotBeMadeStillCoversTheFolderThisSession() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let bookmarks = FakeSecurityScopedBookmarks()
        bookmarks.failsToCreate = true
        let access = installSandboxedFolderAccess(bookmarks: bookmarks)

        access.store.grantAccess(to: directory.url)

        XCTAssertTrue(access.store.covers(directory.url.appendingPathComponent("Note.md")))
        XCTAssertNil(access.defaults.array(forKey: "folderAccessGrants"))
    }

    func testFilesTheUserOpenedCoverOnlyThemselvesUntilAReadFails() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let note = directory.url.appendingPathComponent("Note.md")
        let access = installSandboxedFolderAccess()

        access.store.noteUserSelected([note])

        XCTAssertTrue(access.store.covers(note))
        XCTAssertFalse(access.store.covers(directory.url.appendingPathComponent("image.png")))
        access.store.recordUnreadableFile(note, forDocumentAt: note)
        XCTAssertFalse(access.store.covers(note))
        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: note), [FileIdentity.normalized(note)])
    }

    func testNeededFilesSuggestTheirClosestCommonFolderAndClearAfterAGrant() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let notes = directory.url.appendingPathComponent("Notes", isDirectory: true)
        let document = notes.appendingPathComponent("Plan.md")
        let image = notes.appendingPathComponent("image.png")
        let linked = directory.url.appendingPathComponent("Archive/Old.md")
        let access = installSandboxedFolderAccess()
        let changes = FolderAccessChangeRecorder(store: access.store)

        XCTAssertEqual(access.store.suggestedFolder(forDocumentAt: document).path, notes.path)
        access.store.recordUnreadableFile(image, forDocumentAt: document)
        XCTAssertEqual(access.store.suggestedFolder(forDocumentAt: document).path, notes.path)
        access.store.recordLinkedFiles([linked], forDocumentAt: document)

        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: document).map(\.path), [linked.path, image.path].sorted())
        XCTAssertEqual(access.store.suggestedFolder(forDocumentAt: document).path, directory.url.path)
        XCTAssertEqual(changes.count, 2)

        XCTAssertEqual(access.store.grantAccess(to: directory.url), [FileIdentity.identity(for: document)])
        XCTAssertTrue(access.store.unreadableFiles(neededByDocumentAt: document).isEmpty)
        XCTAssertEqual(changes.count, 3)
    }

    func testLinkedFilesAreReplacedOnEveryRender() {
        let access = installSandboxedFolderAccess()
        let document = URL(fileURLWithPath: "/tmp/wafer-links/Plan.md")
        let first = URL(fileURLWithPath: "/tmp/wafer-links/A.md")
        let second = URL(fileURLWithPath: "/tmp/wafer-links/B.md")

        access.store.recordLinkedFiles([first, second], forDocumentAt: document)
        access.store.recordLinkedFiles([second], forDocumentAt: document)
        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: document), [second])

        access.store.recordLinkedFiles([], forDocumentAt: document)
        XCTAssertTrue(access.store.unreadableFiles(neededByDocumentAt: document).isEmpty)
    }

    func testTheSuggestionNeverWidensToAFolderJustBelowTheRoot() {
        let access = installSandboxedFolderAccess()
        let document = URL(fileURLWithPath: "/Users/someone/Notes/Plan.md")

        access.store.recordUnreadableFile(URL(fileURLWithPath: "/Volumes/Drive/Image.png"), forDocumentAt: document)
        XCTAssertEqual(access.store.suggestedFolder(forDocumentAt: document).path, "/Users/someone/Notes")

        access.store.recordLinkedFiles([URL(fileURLWithPath: "/Users/other/Shared.md")], forDocumentAt: document)
        XCTAssertEqual(access.store.suggestedFolder(forDocumentAt: document).path, "/Users/someone/Notes")
    }
}

@MainActor
final class FolderAccessFlowTests: XCTestCase {
    func testEnsureAccessAsksForTheFilesFolderAndResumesOnceItIsReadable() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let target = directory.url.appendingPathComponent("Other/Linked.md")
        let document = directory.url.appendingPathComponent("Plan.md")
        _ = installSandboxedFolderAccess()
        var requests: [FolderAccessRequest] = []
        var refreshed: [Set<String>] = []
        FolderAccessFlow.chooseFolder = { request, _, completion in
            requests.append(request)
            completion(directory.url)
        }
        FolderAccessFlow.refreshDocuments = { refreshed.append($0) }
        var resumed = 0

        XCTAssertFalse(FolderAccessFlow.ensureAccess(to: target, requestedBy: document, window: nil) { resumed += 1 })

        XCTAssertEqual(requests.map(\.suggestedFolder.path), [target.deletingLastPathComponent().path])
        XCTAssertEqual(requests.first?.prompt, "Grant Access")
        XCTAssertTrue(try XCTUnwrap(requests.first).message.contains("to open “Linked.md”"))
        XCTAssertEqual(resumed, 1)
        XCTAssertEqual(refreshed, [[FileIdentity.identity(for: document)]])
        XCTAssertTrue(FolderAccessFlow.ensureAccess(to: target, requestedBy: document, window: nil) { XCTFail("asked again") })
        XCTAssertEqual(requests.count, 1)
    }

    func testCancelledOrUnrelatedChoicesDoNotResume() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let unrelated = try TemporaryTestDirectory()
        defer { unrelated.remove() }
        let target = directory.url.appendingPathComponent("Linked.md")
        let document = directory.url.appendingPathComponent("Plan.md")
        let access = installSandboxedFolderAccess()

        FolderAccessFlow.chooseFolder = { _, _, completion in completion(nil) }
        XCTAssertFalse(FolderAccessFlow.ensureAccess(to: target, requestedBy: document, window: nil) { XCTFail("resumed after cancel") })
        FolderAccessFlow.chooseFolder = { _, _, completion in completion(unrelated.url) }
        XCTAssertFalse(FolderAccessFlow.ensureAccess(to: target, requestedBy: document, window: nil) { XCTFail("resumed for another folder") })

        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: document), [FileIdentity.normalized(target)])
    }

    func testGrantAccessForADocumentOffersItsSuggestedFolder() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let document = directory.url.appendingPathComponent("Plan.md")
        let access = installSandboxedFolderAccess()
        access.store.recordUnreadableFile(directory.url.appendingPathComponent("image.png"), forDocumentAt: document)
        var requests: [FolderAccessRequest] = []
        FolderAccessFlow.chooseFolder = { request, _, completion in
            requests.append(request)
            completion(request.suggestedFolder)
        }
        var granted: [Bool] = []

        FolderAccessFlow.requestAccess(forDocumentAt: document, window: nil) { granted.append($0) }

        XCTAssertEqual(requests.map(\.suggestedFolder.path), [directory.url.path])
        XCTAssertTrue(try XCTUnwrap(requests.first).message.contains("images and linked files in “Plan.md”"))
        XCTAssertTrue(try XCTUnwrap(requests.first).message.contains("Choosing a parent folder covers more of your documents."))
        XCTAssertEqual(granted, [true])
        XCTAssertTrue(access.store.unreadableFiles(neededByDocumentAt: document).isEmpty)
    }

    func testSandboxDenialsAreRecognizedAndTheirErrorOffersGrantAccess() {
        let sandboxDenial = CocoaError(.fileReadNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM) as NSError])
        XCTAssertTrue(FolderAccessDeniedError.isPermissionDenied(sandboxDenial))
        XCTAssertTrue(FolderAccessDeniedError.isPermissionDenied(POSIXError(.EPERM)))
        XCTAssertFalse(FolderAccessDeniedError.isPermissionDenied(
            CocoaError(.fileReadNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES) as NSError])
        ), "ordinary file permissions are not a missing grant")
        XCTAssertFalse(FolderAccessDeniedError.isPermissionDenied(CocoaError(.fileReadNoSuchFile)))

        let error = FolderAccessDeniedError(fileURL: URL(fileURLWithPath: "/tmp/Note.md")) as NSError
        XCTAssertEqual(error.localizedDescription, "Wafer doesn't have permission to read “Note.md”.")
        XCTAssertEqual(error.localizedRecoveryOptions, ["Grant Access…", "Cancel"])
        XCTAssertNotNil(error.recoveryAttempter)
        XCTAssertEqual((error.userInfo[NSURLErrorKey] as? URL)?.path, "/tmp/Note.md")
    }

    func testRefusedReadsBecomeGrantAccessErrorsAndRefusedReloadsAreRecorded() {
        let access = installSandboxedFolderAccess()
        let url = URL(fileURLWithPath: "/tmp/wafer-denied/Plan.md")
        let refusing = MarkdownSourceLoader(load: { _ in
            throw CocoaError(.fileReadNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM) as NSError])
        })
        let missing = MarkdownSourceLoader(load: { _ in throw CocoaError(.fileReadNoSuchFile) })
        var offersGrant: [Bool] = []
        func read(_ loader: MarkdownSourceLoader, _ state: MarkdownSourceLoader.LoadState) {
            let finished = expectation(description: "read finished")
            loader.read(state) { result in
                if case .failure(let error) = result { offersGrant.append(error is FolderAccessDeniedError) }
                finished.fulfill()
            }
            wait(for: [finished], timeout: 10)
        }

        read(refusing, .opening(url))
        XCTAssertTrue(access.store.unreadableFiles(neededByDocumentAt: url).isEmpty)
        read(refusing, .reloading(url))
        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: url), [url])
        read(missing, .opening(url))

        XCTAssertEqual(offersGrant, [true, true, false], "other read failures keep their own error")
    }
}

/// The window notice, sidebar summaries, and in-window navigation under a
/// sandboxed store.
@MainActor
final class FolderAccessNoticeTests: XCTestCase {
    private func makeHostedDocument(_ fileURL: URL) throws -> (MarkdownReaderDocument, DocumentHostWindowController, RecordingReaderViewController) {
        let reader = RecordingReaderViewController()
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { _, baseURL, _, _, completion in
                completion(WebKitRenderOutput(html: "<html></html>", baseURL: baseURL))
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            fileMonitorFactory: { _, _ in FolderAccessTestFileMonitor() }
        )
        document.fileURL = fileURL
        try document.read(from: Data("# Plan".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        let host = try XCTUnwrap(document.windowControllers.first as? DocumentHostWindowController)
        return (document, host, reader)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(condition())
    }

    func testTheWindowShowsTheNoticeWhileTheDocumentNeedsFilesAndHidesItAfterAGrant() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "Plan.md", contents: "# Plan")
        let access = installSandboxedFolderAccess()
        access.store.noteUserSelected([fileURL])
        let (document, host, _) = try makeHostedDocument(fileURL)
        defer { document.close() }
        XCTAssertFalse(host.isFolderAccessNoticeVisibleForTesting)
        let window = try XCTUnwrap(host.window)
        let contentHeight = window.contentLayoutRect.height

        access.store.recordUnreadableFile(directory.url.appendingPathComponent("image.png"), forDocumentAt: fileURL)
        window.layoutIfNeeded()

        XCTAssertTrue(host.isFolderAccessNoticeVisibleForTesting)
        let noticeHeight = try XCTUnwrap(host.folderAccessNoticeForTesting?.view.frame.height)
        XCTAssertGreaterThanOrEqual(noticeHeight, FolderAccessNoticeViewController.height - 2, "an accessory with no height would be invisible")
        XCTAssertEqual(window.contentLayoutRect.height, contentHeight - noticeHeight, accuracy: 1,
                       "the bar takes its height below the titlebar instead of covering the reader")
        XCTAssertEqual(
            host.folderAccessNoticeForTesting?.message,
            "Allow Wafer to read the folder “\(directory.url.lastPathComponent)” to show linked files and images."
        )
        XCTAssertEqual(host.folderAccessNoticeForTesting?.layoutAttribute, .bottom)
        var requests: [FolderAccessRequest] = []
        var refreshed: [Set<String>] = []
        FolderAccessFlow.chooseFolder = { request, _, completion in
            requests.append(request)
            completion(request.suggestedFolder)
        }
        FolderAccessFlow.refreshDocuments = { refreshed.append($0) }

        host.folderAccessNoticeForTesting?.triggerGrantAccessForTesting()

        XCTAssertEqual(requests.map(\.suggestedFolder.path), [directory.url.path])
        XCTAssertEqual(refreshed, [[FileIdentity.identity(for: fileURL)]])
        XCTAssertFalse(host.isFolderAccessNoticeVisibleForTesting)
    }

    func testDismissingTheNoticeHidesItForThatDocument() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "Plan.md", contents: "# Plan")
        let access = installSandboxedFolderAccess()
        let (document, host, _) = try makeHostedDocument(fileURL)
        defer { document.close() }
        access.store.recordUnreadableFile(directory.url.appendingPathComponent("image.png"), forDocumentAt: fileURL)
        XCTAssertTrue(host.isFolderAccessNoticeVisibleForTesting)

        host.folderAccessNoticeForTesting?.triggerDismissForTesting()
        access.store.recordUnreadableFile(directory.url.appendingPathComponent("other.png"), forDocumentAt: fileURL)

        XCTAssertFalse(host.isFolderAccessNoticeVisibleForTesting)
    }

    func testLinkedDocumentsAndRefusedImagesAreRecordedForTheirOwnTab() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "Plan.md", contents: "# Plan")
        let linked = directory.url.appendingPathComponent("Next.md")
        let image = directory.url.appendingPathComponent("image.png")
        let access = installSandboxedFolderAccess()
        access.store.noteUserSelected([fileURL])
        let (document, host, reader) = try makeHostedDocument(fileURL)
        defer { document.close() }

        host.apply(sidebarEntries: [
            DocumentSidebarEntry(fileURL: fileURL, displayTitle: "Plan", previewText: "", isCurrent: true, isAvailable: true),
            DocumentSidebarEntry(fileURL: linked, displayTitle: "Next", previewText: "", isCurrent: false, isAvailable: true, needsSummary: true),
        ], outlineItems: [])
        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: fileURL), [linked])
        XCTAssertTrue(host.isFolderAccessNoticeVisibleForTesting)

        let webView = try XCTUnwrap(Self.webView(in: reader.view))
        NotificationCenter.default.post(name: .localAssetAccessDenied, object: WKWebView(), userInfo: ["fileURL": image])
        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: fileURL), [linked], "another reader's image is not this tab's")
        NotificationCenter.default.post(name: .localAssetAccessDenied, object: webView, userInfo: ["fileURL": image])
        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: fileURL), [linked, image])
    }

    func testLinkedNotesOutsideTheGrantsAreNotReadAndAskForAccessWhenSelected() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let linked = try directory.createTextFile(named: "Linked.md", contents: "# Real title\n\nBody")
        _ = installSandboxedFolderAccess()
        let sidebar = DocumentSidebarViewController()
        let window = hostInWindow(sidebar)
        defer {
            window.contentViewController = nil
            window.close()
        }
        var selected: [URL] = []
        sidebar.onSelectDocument = { selected.append($0) }

        sidebar.apply(sidebarEntries: [
            DocumentSidebarEntry(fileURL: linked, displayTitle: "Linked", previewText: "", isCurrent: false, isAvailable: true, needsSummary: true),
        ], outlineItems: [])
        sidebar.view.layoutSubtreeIfNeeded()
        sidebar.refreshVisibleDocumentSummaries()

        waitUntil { sidebar.documentPreviewTextsForTesting == [DocumentSidebarViewController.needsFolderAccessPreview] }
        XCTAssertEqual(sidebar.documentTitlesForTesting, ["Linked"])
        FolderAccessFlow.chooseFolder = { _, _, completion in completion(nil) }
        sidebar.activateDocumentRowForTesting(linked)
        XCTAssertEqual(selected, [])
        FolderAccessFlow.chooseFolder = { request, _, completion in completion(request.suggestedFolder) }
        sidebar.activateDocumentRowForTesting(linked)
        XCTAssertEqual(selected, [linked])
    }

    func testNavigatingToAFileOutsideTheGrantsResumesAfterTheGrant() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "Plan.md", contents: "# Plan")
        let nextFolder = directory.url.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: nextFolder, withIntermediateDirectories: true)
        let next = nextFolder.appendingPathComponent("Next.md")
        try Data("# Next".utf8).write(to: next)
        let access = installSandboxedFolderAccess()
        access.store.noteUserSelected([fileURL])
        let (document, _, _) = try makeHostedDocument(fileURL)
        defer { document.close() }

        FolderAccessFlow.chooseFolder = { _, _, completion in completion(nil) }
        document.navigateInCurrentWindow(to: next)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(document.fileURL, fileURL)

        var requests: [FolderAccessRequest] = []
        FolderAccessFlow.chooseFolder = { request, _, completion in
            requests.append(request)
            completion(request.suggestedFolder)
        }
        document.navigateInCurrentWindow(to: next)

        XCTAssertEqual(requests.map(\.suggestedFolder.path), [nextFolder.path])
        waitUntil { document.fileURL == FileIdentity.normalized(next) }
    }

    private static func webView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view.subviews.lazy.compactMap { webView(in: $0) }.first
    }
}

@MainActor
private final class FolderAccessTestFileMonitor: FileChangeMonitoring {
    func start() {}
    func stop() {}
}
