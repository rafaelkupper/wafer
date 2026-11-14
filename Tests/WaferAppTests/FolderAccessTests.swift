import AppKit
import WebKit
import XCTest
@testable import WaferApp
@testable import WaferCore

/// Fake app-scoped bookmarks: the data names the folder; resolution can be
/// made stale, moved to another folder, or fail per folder.
@MainActor
final class FakeSecurityScopedBookmarks: SecurityScopedBookmarking {
    var stalePaths: Set<String> = []
    var unresolvablePaths: Set<String> = []
    /// Folders that resolve somewhere else, as a moved or renamed folder does.
    var movedPaths: [String: String] = [:]
    var failsToCreate = false
    private(set) var createdPaths: [String] = []
    /// Whether each bookmark in `createdPaths` was made read-only.
    private(set) var createdReadOnly: [Bool] = []
    private(set) var started: [String] = []
    private(set) var stopped: [String] = []

    static func bookmark(for url: URL) -> Data {
        Data(("bookmark:" + url.path).utf8)
    }

    func bookmarkData(for url: URL, readOnly: Bool) throws -> Data {
        if failsToCreate { throw CocoaError(.fileWriteNoPermission) }
        createdPaths.append(url.path)
        createdReadOnly.append(readOnly)
        return Self.bookmark(for: url)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        guard let text = String(data: bookmark, encoding: .utf8), text.hasPrefix("bookmark:") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let path = String(text.dropFirst("bookmark:".count))
        guard !unresolvablePaths.contains(path) else { throw CocoaError(.fileNoSuchFile) }
        if let moved = movedPaths[path] {
            return (URL(fileURLWithPath: moved, isDirectory: true), true)
        }
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
        bookmarks: FakeSecurityScopedBookmarks = FakeSecurityScopedBookmarks(),
        range: FolderAccessRange = .current,
        imageSettleDelay: TimeInterval = 0.05,
        canOpenForReading: @escaping @MainActor (URL) -> Bool = { _ in true }
    ) -> SandboxedFolderAccess {
        let defaults = defaults ?? makeTestUserDefaults()
        let store = FolderAccessStore(
            defaults: defaults, bookmarks: bookmarks, isSandboxed: true, alwaysReadableRoots: [], alwaysWritableRoots: [],
            range: range, imageSettleDelay: imageSettleDelay, canOpenForReading: canOpenForReading
        )
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
        store.recordRefusedImage(folder.appendingPathComponent("image.png"), forDocumentAt: document)
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

    func testGrantsOnADriveConnectedAfterLaunchResolveWhenItMounts() {
        let away = URL(fileURLWithPath: "/Volumes/WaferTestLater-\(UUID().uuidString)/Notes", isDirectory: true)
        let defaults = makeTestUserDefaults()
        defaults.set([["id": "away", "path": away.path, "bookmark": FakeSecurityScopedBookmarks.bookmark(for: away), "readOnly": true]],
                     forKey: "folderAccessGrants")
        let bookmarks = FakeSecurityScopedBookmarks()
        bookmarks.unresolvablePaths = [away.path]
        let access = installSandboxedFolderAccess(defaults: defaults, bookmarks: bookmarks)
        let document = URL(fileURLWithPath: "/tmp/wafer-mount/Plan.md")
        access.store.recordRefusedImage(away.appendingPathComponent("image.png"), forDocumentAt: document)
        XCTAssertFalse(access.store.covers(away.appendingPathComponent("image.png")))

        XCTAssertFalse(access.store.resolveUnavailableGrants().didResolve, "still not connected")
        bookmarks.unresolvablePaths = []
        let result = access.store.resolveUnavailableGrants()

        XCTAssertTrue(result.didResolve)
        XCTAssertEqual(result.documents, [FileIdentity.identity(for: document)])
        XCTAssertTrue(access.store.covers(away.appendingPathComponent("image.png")))
        XCTAssertEqual(bookmarks.started, [away.path])
        XCTAssertFalse(access.store.resolveUnavailableGrants().didResolve, "nothing left to resolve")
    }

    func testTheAppRetriesUnavailableGrantsWheneverAVolumeMounts() {
        let away = URL(fileURLWithPath: "/Volumes/WaferTestLater-\(UUID().uuidString)/Notes", isDirectory: true)
        let defaults = makeTestUserDefaults()
        defaults.set([["id": "away", "path": away.path, "bookmark": FakeSecurityScopedBookmarks.bookmark(for: away)]],
                     forKey: "folderAccessGrants")
        let bookmarks = FakeSecurityScopedBookmarks()
        bookmarks.unresolvablePaths = [away.path]
        let access = installSandboxedFolderAccess(defaults: defaults, bookmarks: bookmarks)
        let workspace = NotificationCenter()
        var retries = 0
        let delegate = AppDelegate(openURLs: { _ in }, reopenPersistedLibrary: {}, workspaceNotificationCenter: workspace,
                                   retryUnavailableAccess: { retries += 1 })

        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        workspace.post(name: NSWorkspace.didMountNotification, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(retries, 1)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        workspace.post(name: NSWorkspace.didMountNotification, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(retries, 1, "no retries after quitting")

        bookmarks.unresolvablePaths = []
        AppDelegate.retryUnavailableAccess()
        XCTAssertTrue(access.store.covers(away.appendingPathComponent("Plan.md")), "the default retry resolves the grant")
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

    func testGrantsForReadingAreReadOnlyBookmarksAndReadWriteGrantsAllowSaving() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let images = directory.url.appendingPathComponent("Images", isDirectory: true)
        let library = directory.url.appendingPathComponent("Library", isDirectory: true)
        let access = installSandboxedFolderAccess()

        access.store.grantAccess(to: images)
        access.store.grantAccess(to: library, mode: .readWrite)

        XCTAssertEqual(access.bookmarks.createdPaths, [images.path, library.path])
        XCTAssertEqual(access.bookmarks.createdReadOnly, [true, false], "read-only bookmarks unless the grant is read-write")
        XCTAssertTrue(access.store.covers(images.appendingPathComponent("a.png")))
        XCTAssertFalse(access.store.allowsWriting(images.appendingPathComponent("Note.md")))
        XCTAssertTrue(access.store.allowsWriting(library.appendingPathComponent("Note.md")))
        let records = try XCTUnwrap(access.defaults.array(forKey: "folderAccessGrants") as? [[String: Any]])
        XCTAssertEqual(records.compactMap { $0["readOnly"] as? Bool }, [true, false])
        XCTAssertEqual(Set(records.compactMap { $0["id"] as? String }).count, 2)
        XCTAssertEqual(access.store.folderGrants.map(\.mode), [.readOnly, .readWrite])

        let opened = directory.url.appendingPathComponent("Opened.md")
        access.store.noteUserSelected([opened])
        XCTAssertTrue(access.store.allowsWriting(opened), "a file the user opened can be saved")
    }

    func testReadOnlyAndReadWriteGrantsCombineByWhatTheyAllow() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let parent = directory.url.appendingPathComponent("Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        let note = child.appendingPathComponent("Note.md")
        let access = installSandboxedFolderAccess()
        func grants() -> [String] { access.store.folderGrants.map { "\($0.folderURL.lastPathComponent):\($0.mode.rawValue)" } }

        access.store.grantAccess(to: parent, mode: .readWrite)
        access.store.grantAccess(to: child)
        XCTAssertEqual(grants(), ["Parent:readWrite"], "a read-only grant inside a read-write one adds nothing")

        access.store.revoke(grantID: try XCTUnwrap(access.store.folderGrants.first?.id))
        access.store.grantAccess(to: parent)
        access.store.grantAccess(to: child, mode: .readWrite)
        XCTAssertEqual(grants(), ["Parent:readOnly", "Child:readWrite"], "a read-write grant inside a read-only one is kept")
        XCTAssertTrue(access.store.allowsWriting(note))
        XCTAssertFalse(access.store.allowsWriting(parent.appendingPathComponent("Other.md")))

        access.store.grantAccess(to: parent, mode: .readWrite)
        XCTAssertEqual(grants(), ["Parent:readWrite"], "a read-write grant replaces what it contains")

        access.store.grantAccess(to: directory.url)
        XCTAssertEqual(grants(), [directory.url.lastPathComponent + ":readOnly", "Parent:readWrite"],
                       "a read-only grant never replaces a read-write one")
        XCTAssertTrue(access.store.allowsWriting(note))
    }

    func testRestoreKeepsModesAndTreatsRecordsWithoutOneAsReadWrite() throws {
        let readOnly = try TemporaryTestDirectory()
        defer { readOnly.remove() }
        let older = try TemporaryTestDirectory()
        defer { older.remove() }
        let defaults = makeTestUserDefaults()
        defaults.set([
            ["id": "kept", "path": readOnly.url.path, "bookmark": FakeSecurityScopedBookmarks.bookmark(for: readOnly.url), "readOnly": true],
            // Stored before grants had an identity and a mode: those bookmarks were read-write.
            ["path": older.url.path, "bookmark": FakeSecurityScopedBookmarks.bookmark(for: older.url)],
        ], forKey: "folderAccessGrants")
        let bookmarks = FakeSecurityScopedBookmarks()
        bookmarks.stalePaths = [readOnly.url.path]
        let access = installSandboxedFolderAccess(defaults: defaults, bookmarks: bookmarks)

        access.store.restoreGrants()

        XCTAssertEqual(access.store.folderGrants.first { $0.folderURL.path == readOnly.url.path }?.mode, .readOnly)
        XCTAssertEqual(access.store.folderGrants.first { $0.folderURL.path == older.url.path }?.mode, .readWrite)
        XCTAssertEqual(bookmarks.createdReadOnly, [true], "a stale bookmark is made again in its own mode")
        let records = try XCTUnwrap(defaults.array(forKey: "folderAccessGrants") as? [[String: Any]])
        XCTAssertEqual(records.first?["id"] as? String, "kept")
        XCTAssertNotNil(records.last?["id"] as? String, "an identity is assigned and stored")
        XCTAssertEqual(records.last?["readOnly"] as? Bool, false)
    }

    func testRevokingAGrantStopsItsAccessAndDeletesItsBookmark() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let unmounted = URL(fileURLWithPath: "/Volumes/WaferTestUnmounted-\(UUID().uuidString)/Notes", isDirectory: true)
        let defaults = makeTestUserDefaults()
        defaults.set([["id": "away", "path": unmounted.path, "bookmark": FakeSecurityScopedBookmarks.bookmark(for: unmounted)]],
                     forKey: "folderAccessGrants")
        let bookmarks = FakeSecurityScopedBookmarks()
        bookmarks.unresolvablePaths = [unmounted.path]
        let access = installSandboxedFolderAccess(defaults: defaults, bookmarks: bookmarks)
        access.store.grantAccess(to: directory.url)
        let changes = FolderAccessChangeRecorder(store: access.store)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: access.store.folderGrants.map { ($0.folderURL.path, $0.isAvailable) }),
                       [unmounted.path: false, directory.url.path: true])

        let granted = try XCTUnwrap(access.store.folderGrants.first { $0.folderURL.path == directory.url.path })
        access.store.revoke(grantID: granted.id)

        XCTAssertFalse(access.store.covers(directory.url.appendingPathComponent("Note.md")))
        XCTAssertEqual(bookmarks.stopped, [directory.url.path])
        XCTAssertEqual((defaults.array(forKey: "folderAccessGrants") as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["away"])
        XCTAssertEqual(changes.count, 1)

        access.store.revoke(grantID: "away")
        XCTAssertTrue(access.store.folderGrants.isEmpty, "an unavailable grant can be removed too")
        XCTAssertEqual((defaults.array(forKey: "folderAccessGrants") as? [[String: Any]])?.count, 0)
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

        XCTAssertEqual(access.store.suggestion(forDocumentAt: document), .folder(notes, isWidened: false), "nothing needed: its own folder")
        access.store.recordRefusedImage(image, forDocumentAt: document)
        XCTAssertEqual(access.store.suggestion(forDocumentAt: document), .folder(notes, isWidened: false))
        access.store.recordLinkedFiles([linked], forDocumentAt: document)

        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: document).map(\.path), [linked.path, image.path].sorted())
        XCTAssertEqual(access.store.suggestion(forDocumentAt: document), .folder(directory.url, isWidened: true))
        XCTAssertEqual(changes.count, 2)

        XCTAssertEqual(access.store.grantAccess(to: directory.url), [FileIdentity.identity(for: document)])
        XCTAssertTrue(access.store.unreadableFiles(neededByDocumentAt: document).isEmpty)
        XCTAssertEqual(changes.count, 3)
    }

    func testForgettingADocumentReleasesEverythingItNeeded() {
        let access = installSandboxedFolderAccess()
        let document = URL(fileURLWithPath: "/tmp/wafer-forget/Plan.md")
        access.store.recordLinkedFiles([URL(fileURLWithPath: "/tmp/wafer-forget/A.md")], forDocumentAt: document)
        access.store.recordRefusedImage(URL(fileURLWithPath: "/tmp/wafer-forget/i.png"), forDocumentAt: document)
        access.store.recordUnreadableFile(URL(fileURLWithPath: "/tmp/wafer-forget/T.md"), forDocumentAt: document)
        XCTAssertEqual(access.store.recordedDocumentCountForTesting, 1)
        let changes = FolderAccessChangeRecorder(store: access.store)

        access.store.forgetDocument(at: document)

        XCTAssertEqual(access.store.recordedDocumentCountForTesting, 0)
        XCTAssertTrue(access.store.unreadableFiles(neededByDocumentAt: document).isEmpty)
        XCTAssertEqual(changes.count, 1)
        access.store.forgetDocument(at: document)
        XCTAssertEqual(changes.count, 1, "forgetting nothing changes nothing")
    }

    func testLinkTargetsLastUntilTheNextRenderAndTheOwnFileUntilItReadsAgain() {
        let access = installSandboxedFolderAccess()
        let document = URL(fileURLWithPath: "/tmp/wafer-targets/Plan.md")
        let target = URL(fileURLWithPath: "/tmp/wafer-targets/Far/Next.md")
        access.store.recordUnreadableFile(target, forDocumentAt: document)
        access.store.recordUnreadableFile(document, forDocumentAt: document)
        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: document), [target, document].sorted { $0.path < $1.path })

        access.store.recordLinkedFiles([], forDocumentAt: document)
        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: document), [document], "the next render no longer links to it")

        let loader = MarkdownSourceLoader(load: { _ in LoadedMarkdownSource(sourceText: "# Plan", fingerprint: "f") })
        let finished = expectation(description: "read finished")
        loader.read(.reloading(document)) { _ in finished.fulfill() }
        wait(for: [finished], timeout: 10)
        XCTAssertTrue(access.store.unreadableFiles(neededByDocumentAt: document).isEmpty, "it read again")
        XCTAssertEqual(access.store.recordedDocumentCountForTesting, 0)
    }

    func testRefusedImagesAreReconciledOnEveryReaderPage() {
        let access = installSandboxedFolderAccess(imageSettleDelay: 0.05)
        let document = URL(fileURLWithPath: "/tmp/wafer-pages/Plan.md")
        let kept = URL(fileURLWithPath: "/tmp/wafer-pages/kept.png")
        let removed = URL(fileURLWithPath: "/tmp/wafer-pages/removed.png")
        access.store.recordRefusedImage(kept, forDocumentAt: document)
        access.store.recordRefusedImage(removed, forDocumentAt: document)
        let changes = FolderAccessChangeRecorder(store: access.store)
        func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2)) }

        access.store.beginReaderPage(forDocumentAt: document)
        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: document), [kept, removed],
                       "the previous page's images count while the new one loads, so the notice does not flicker")
        access.store.recordRefusedImage(kept, forDocumentAt: document)
        settle()
        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: document), [kept], "an image the new page no longer shows stops counting")
        XCTAssertEqual(changes.count, 1)

        access.store.beginReaderPage(forDocumentAt: document)
        access.store.beginReaderPage(forDocumentAt: document)
        settle()
        XCTAssertTrue(access.store.unreadableFiles(neededByDocumentAt: document).isEmpty)
        XCTAssertEqual(access.store.recordedDocumentCountForTesting, 0)
    }

    func testSessionSelectionsKeepOnlyTheMostRecent() {
        let access = installSandboxedFolderAccess()
        let limit = FolderAccessStore.maximumUserSelections
        let files = (0..<(limit + 10)).map { URL(fileURLWithPath: "/tmp/wafer-selections/\($0).md") }

        access.store.noteUserSelected(files)

        XCTAssertEqual(access.store.userSelectionCountForTesting, limit)
        XCTAssertFalse(access.store.covers(files[9]))
        XCTAssertTrue(access.store.covers(files[10]))
        XCTAssertTrue(access.store.covers(files[limit + 9]))
        access.store.noteUserSelected([files[10]])
        access.store.noteUserSelected([URL(fileURLWithPath: "/tmp/wafer-selections/new.md")])
        XCTAssertTrue(access.store.covers(files[10]), "opening a file again makes it recent")
        XCTAssertFalse(access.store.covers(files[11]))
        XCTAssertEqual(access.store.userSelectionCountForTesting, limit)
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

    func testTheSuggestionWidensAtMostTwoLevelsAndNeverToAFolderTooBroadToOffer() {
        let access = installSandboxedFolderAccess(range: someoneRange)
        let home = "/Users/someone"
        let document = URL(fileURLWithPath: "\(home)/Notes/Projects/Plan.md")
        func suggestion(needing paths: [String]) -> FolderAccessSuggestion? {
            access.store.recordLinkedFiles(paths.map { URL(fileURLWithPath: $0) }, forDocumentAt: document)
            return access.store.suggestion(forDocumentAt: document)
        }
        func folder(_ path: String, widened: Bool) -> FolderAccessSuggestion {
            .folder(URL(fileURLWithPath: path, isDirectory: true), isWidened: widened)
        }

        XCTAssertEqual(suggestion(needing: ["\(home)/Notes/Projects/img/a.md"]), folder("\(home)/Notes/Projects", widened: false))
        XCTAssertEqual(suggestion(needing: ["\(home)/Notes/Projects/img/a.md", "\(home)/Notes/Areas/b.md"]),
                       folder("\(home)/Notes", widened: true), "the closest folder holding the document and both files")
        XCTAssertEqual(suggestion(needing: ["\(home)/Notes/Areas/b.md", "\(home)/Other/c.md"]), folder("\(home)/Notes", widened: true),
                       "a common ancestor at the home folder is never offered; the nearby files come first")
        XCTAssertEqual(suggestion(needing: ["\(home)/Other/c.md"]), folder("\(home)/Other", widened: false),
                       "a file outside the window gets only its own folder")
        XCTAssertEqual(suggestion(needing: ["\(home)/c.md"]),
                       .outOfRange(file: URL(fileURLWithPath: "\(home)/c.md"), folder: URL(fileURLWithPath: home, isDirectory: true)))
        XCTAssertEqual(suggestion(needing: ["/Volumes/Drive/Image.md", "/Users/other/Shared.md"]),
                       .outOfRange(file: URL(fileURLWithPath: "/Users/other/Shared.md"), folder: URL(fileURLWithPath: "/Users/other", isDirectory: true)),
                       "volume roots and other homes are never offered either")

        let deep = URL(fileURLWithPath: "\(home)/A/B/C/D/Plan.md")
        access.store.recordLinkedFiles([URL(fileURLWithPath: "\(home)/A/B/x.md")], forDocumentAt: deep)
        XCTAssertEqual(access.store.suggestion(forDocumentAt: deep), folder("\(home)/A/B", widened: true), "two levels above the document")
        access.store.recordLinkedFiles([URL(fileURLWithPath: "\(home)/A/x.md")], forDocumentAt: deep)
        XCTAssertEqual(access.store.suggestion(forDocumentAt: deep), folder("\(home)/A", widened: false),
                       "three levels above: only the file's own folder")

        let inHome = URL(fileURLWithPath: "\(home)/Plan.md")
        access.store.recordLinkedFiles([URL(fileURLWithPath: "\(home)/Pictures/i.md")], forDocumentAt: inHome)
        XCTAssertEqual(access.store.suggestion(forDocumentAt: inHome), folder("\(home)/Pictures", widened: false),
                       "a document in the home folder never widens to it")
    }
}

/// The user `someone`, whose home is /Users/someone.
let someoneRange = FolderAccessRange(homeDirectory: URL(fileURLWithPath: "/Users/someone", isDirectory: true), isVolumeRoot: { _ in false })

final class FolderAccessRangeTests: XCTestCase {
    func testTheHomeFolderVolumesTopLevelFoldersAndEverythingAboveThemAreTooBroad() throws {
        let range = FolderAccessRange(homeDirectory: URL(fileURLWithPath: "/Users/someone", isDirectory: true),
                                      isVolumeRoot: { $0.path == "/Users/someone/Mounts/Share" })
        for path in [
            "/", "/Users", "/Volumes", "/Library", "/Applications", "/System", "/private", "/tmp", "/private/var",
            "/Users/someone", "/Users/someone/", "/USERS/SOMEONE", "/Users/someone/Library", "/Users/other", "/Users/Shared",
            "/Volumes/Drive", "/System/Volumes/Data/Users/someone", "/System/Volumes/Data/Users",
            "/Users/someone/Mounts/Share", "/Users/someone/Notes/../../..",
        ] {
            XCTAssertTrue(range.isTooBroad(URL(fileURLWithPath: path, isDirectory: true)), path)
        }
        for path in [
            "/Users/someone/Notes", "/Users/someone/Library/Mobile Documents", "/Volumes/Drive/Notes",
            "/Users/Shared/Notes", "/System/Volumes/Data/Users/someone/Notes", "/Users/someone/Mounts",
        ] {
            XCTAssertFalse(range.isTooBroad(URL(fileURLWithPath: path, isDirectory: true)), path)
        }

        let temporary = try TemporaryTestDirectory()
        defer { temporary.remove() }
        XCTAssertFalse(FolderAccessRange.current.isTooBroad(temporary.url))
        XCTAssertTrue(FolderAccessRange.current.isTooBroad(FolderAccessRange.realHomeDirectory()))
        XCTAssertTrue(FolderAccessRange.current.isTooBroad(URL(fileURLWithPath: "/", isDirectory: true)))
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

        XCTAssertEqual(requests.map(\.suggestedFolder?.path), [target.deletingLastPathComponent().path])
        XCTAssertEqual(requests.first?.prompt, "Grant Access")
        XCTAssertTrue(try XCTUnwrap(requests.first).message.contains(
            "To open “Linked.md”, grant access to its folder, “Other” (\(target.deletingLastPathComponent().path))."
        ))
        XCTAssertEqual(resumed, 1)
        XCTAssertEqual(refreshed, [[FileIdentity.identity(for: document)]])
        XCTAssertTrue(FolderAccessFlow.ensureAccess(to: target, requestedBy: document, window: nil) { XCTFail("asked again") })
        XCTAssertEqual(requests.count, 1)
    }

    func testHostileLinksNeverOpenThePanelAtAFolderTooBroadToOffer() {
        _ = installSandboxedFolderAccess(range: someoneRange)
        let documentFolder = URL(fileURLWithPath: "/Users/someone/Notes", isDirectory: true)
        let document = documentFolder.appendingPathComponent("Plan.md")
        var requests: [FolderAccessRequest] = []
        FolderAccessFlow.chooseFolder = { request, _, completion in
            requests.append(request)
            completion(nil)
        }
        let hostile = [
            URL(fileURLWithPath: "/x.md"),
            FileIdentity.normalized(URL(fileURLWithPath: "../../../x.md", relativeTo: documentFolder)),
            URL(fileURLWithPath: "/Users/someone/x.md"),
            URL(fileURLWithPath: "/Users/x.md"),
            URL(fileURLWithPath: "/Users/other/x.md"),
            URL(fileURLWithPath: "/Volumes/X/x.md"),
            URL(fileURLWithPath: "/System/Volumes/Data/Users/someone/x.md"),
            URL(fileURLWithPath: "/Users/someone/Library/x.md"),
        ]

        for target in hostile {
            XCTAssertFalse(FolderAccessFlow.ensureAccess(to: target, requestedBy: document, window: nil) { XCTFail("resumed") })
        }

        XCTAssertEqual(requests.count, hostile.count)
        for (request, target) in zip(requests, hostile) {
            XCTAssertNil(request.suggestedFolder, "\(target.path) suggests no folder")
            XCTAssertEqual(request.outOfRange?.startingFolder, documentFolder,
                           "a panel the user asks for anyway opens at the document's folder, not \(target.path)")
            XCTAssertTrue(request.message.contains("(\(target.path)) is outside the folders Wafer offers"), request.message)
            XCTAssertTrue(request.message.contains("open it with File > Open…"), "a document can be opened by itself")
        }

        requests = []
        XCTAssertFalse(FolderAccessFlow.ensureAccess(to: URL(fileURLWithPath: "/Volumes/X/Notes/x.md"), requestedBy: document, window: nil) {})
        XCTAssertEqual(requests.map(\.suggestedFolder?.path), ["/Volumes/X/Notes"], "below a volume root, the file's own folder")
        XCTAssertTrue(try XCTUnwrap(requests.first).message.contains("(/Volumes/X/Notes)"))
        XCTAssertFalse(try XCTUnwrap(requests.first).message.contains("parent folder"), "its parent is the volume root")

        requests = []
        let inHome = URL(fileURLWithPath: "/Users/someone/Plan.md")
        XCTAssertFalse(FolderAccessFlow.ensureAccess(to: URL(fileURLWithPath: "/x.md"), requestedBy: inHome, window: nil) {})
        XCTAssertNotNil(requests.first?.outOfRange)
        XCTAssertNil(requests.first?.outOfRange?.startingFolder, "a document in the home folder offers no starting folder either")
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
        access.store.recordRefusedImage(directory.url.appendingPathComponent("image.png"), forDocumentAt: document)
        var requests: [FolderAccessRequest] = []
        FolderAccessFlow.chooseFolder = { request, _, completion in
            requests.append(request)
            completion(request.suggestedFolder)
        }
        var granted: [Bool] = []

        FolderAccessFlow.requestAccess(forDocumentAt: document, window: nil) { granted.append($0) }

        XCTAssertEqual(requests.map(\.suggestedFolder?.path), [directory.url.path])
        XCTAssertTrue(try XCTUnwrap(requests.first).message.contains("images and linked files in “Plan.md”"))
        XCTAssertTrue(try XCTUnwrap(requests.first).message.contains("grant access to “\(directory.url.lastPathComponent)” (\(directory.url.path))."))
        XCTAssertTrue(try XCTUnwrap(requests.first).message.contains("Choosing a parent folder instead covers more of your documents."))
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

    /// Recents saved by the unsandboxed 2.1.1 have no sandbox bookmark, so
    /// a session selection can claim a file the sandbox still refuses.
    func testARefusedReadOfACoveredFileDropsTheStaleSelectionAndOffersGrantAccess() {
        let access = installSandboxedFolderAccess()
        let url = URL(fileURLWithPath: "/tmp/wafer-stale-recent/Plan.md")
        let refusing = MarkdownSourceLoader(load: { _ in
            throw CocoaError(.fileReadNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM) as NSError])
        })

        for state in [MarkdownSourceLoader.LoadState.opening(url), .navigating(url), .reloading(url)] {
            access.store.noteUserSelected([url])
            XCTAssertTrue(access.store.covers(url))
            var result: Result<LoadedMarkdownSource, Error>?
            let finished = expectation(description: "read finished")
            refusing.read(state) { result = $0; finished.fulfill() }
            wait(for: [finished], timeout: 10)

            guard case .failure(let error)? = result else { return XCTFail("\(state): the read succeeded") }
            XCTAssertTrue(error is FolderAccessDeniedError, "\(state) offers Grant Access…, not \(error)")
            XCTAssertFalse(access.store.covers(url), "\(state) drops the stale selection")
        }
    }

    func testOpenRecentTrustsOnlyARecentDocumentThatIsReadableNow() throws {
        NSDocumentController.shared.clearRecentDocuments(nil)
        defer { NSDocumentController.shared.clearRecentDocuments(nil) }
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let recent = try directory.createTextFile(named: "Recent.md", contents: "# Recent")
        NSDocumentController.shared.noteNewRecentDocumentURL(recent)
        // Saved by Wafer 2.1.1 without the sandbox: AppKit has no bookmark for it.
        let access = installSandboxedFolderAccess(canOpenForReading: { _ in false })
        var requests: [FolderAccessRequest] = []
        FolderAccessFlow.chooseFolder = { request, _, completion in
            requests.append(request)
            completion(nil)
        }
        let menu = AppMenuBuilder.makeMainMenu(windowsMenu: NSMenu(title: "Window"), appDelegate: AppDelegate(openURLs: { _ in }))
        let openRecent = try XCTUnwrap(menu.items[1].submenu?.items[1].submenu)
        openRecent.delegate?.menuNeedsUpdate?(openRecent)
        let item = try XCTUnwrap(openRecent.items.first { $0.title == "Recent.md" })

        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))

        XCTAssertFalse(access.store.covers(recent), "an unreadable recent is not a session selection")
        XCTAssertEqual(requests.map { $0.suggestedFolder?.resolvingSymlinksInPath().path },
                       [directory.url.resolvingSymlinksInPath().path], "opening it asks for its folder")
        XCTAssertEqual(MarkdownDocumentOpener.retainedDocumentCountForTesting, 0)

        let readable = installSandboxedFolderAccess(canOpenForReading: { _ in true })
        readable.store.noteRecentDocumentOpened(recent)
        XCTAssertTrue(readable.store.covers(recent), "a recent AppKit restored access to counts as opened")
    }

    func testGrantAccessRecoveryReopensTheFileFromTheGrantEvenWhenThePanelIsASheet() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "Plan.md", contents: "# Plan")
        let access = installSandboxedFolderAccess()
        // Covered as far as the store knows; the refused read asks anyway.
        access.store.noteUserSelected([fileURL])
        var pendingChoice: (@MainActor (URL?) -> Void)?
        var requests: [FolderAccessRequest] = []
        FolderAccessFlow.chooseFolder = { request, _, completion in
            requests.append(request)
            pendingChoice = completion  // a sheet: the choice arrives later
        }
        let loads = FolderAccessLoadCounter()
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} },
            readerControllerFactory: { RecordingReaderViewController() },
            sourceLoader: { url in
                loads.increment()
                return try MarkdownSourceLoader.loadSource(from: url)
            },
            fileMonitorFactory: { _, _ in FolderAccessTestFileMonitor() }
        )
        document.fileURL = fileURL
        try document.read(from: Data("# Plan".utf8), ofType: "dev.wafer.markdown")
        OpenDocumentRegistry.shared.retain(document)
        defer { document.close() }

        XCTAssertFalse(FolderAccessDeniedError(fileURL: fileURL).attemptRecovery(optionIndex: 0))
        XCTAssertEqual(requests.count, 1)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(loads.value, 0, "nothing reopens before the choice")

        pendingChoice?(directory.url)
        let deadline = Date(timeIntervalSinceNow: 5)
        while loads.value == 0, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(loads.value, 1, "the grant reopens the file")
    }
}

/// Counts source loads from the background read queue.
private final class FolderAccessLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

@MainActor
final class FolderAccessWindowControllerTests: XCTestCase {
    func testTheWindowListsGrantsWithTheirAccessAndRemovesTheSelectedOne() throws {
        let notes = try TemporaryTestDirectory()
        defer { notes.remove() }
        let library = try TemporaryTestDirectory()
        defer { library.remove() }
        let unmounted = URL(fileURLWithPath: "/Volumes/WaferTestUnmounted-\(UUID().uuidString)/Notes", isDirectory: true)
        let defaults = makeTestUserDefaults()
        defaults.set([["id": "away", "path": unmounted.path, "bookmark": FakeSecurityScopedBookmarks.bookmark(for: unmounted), "readOnly": true]],
                     forKey: "folderAccessGrants")
        let bookmarks = FakeSecurityScopedBookmarks()
        bookmarks.unresolvablePaths = [unmounted.path]
        let access = installSandboxedFolderAccess(defaults: defaults, bookmarks: bookmarks)
        access.store.grantAccess(to: notes.url)
        access.store.grantAccess(to: library.url, mode: .readWrite)
        let controller = FolderAccessWindowController()
        defer { controller.windowForTesting?.close() }

        controller.showFolderAccess(nil)

        XCTAssertEqual(controller.windowForTesting?.title, "Folder Access")
        XCTAssertEqual(Set(controller.rowsForTesting), [
            [notes.url.path, "Read only", ""], [library.url.path, "Read and write", ""], [unmounted.path, "Read only", "Not available"],
        ])
        XCTAssertFalse(controller.isRemoveEnabledForTesting, "nothing selected")
        let row = try XCTUnwrap(controller.rowsForTesting.firstIndex { $0[0] == notes.url.path })
        controller.selectRowForTesting(row)
        XCTAssertTrue(controller.isRemoveEnabledForTesting)

        controller.removeSelectedForTesting()

        XCTAssertFalse(controller.rowsForTesting.contains { $0[0] == notes.url.path })
        XCTAssertFalse(access.store.covers(notes.url.appendingPathComponent("Plan.md")))
        XCTAssertEqual(bookmarks.stopped, [notes.url.path])
        XCTAssertFalse((defaults.array(forKey: "folderAccessGrants") as? [[String: Any]] ?? []).contains { $0["path"] as? String == notes.url.path },
                       "the bookmark is deleted")

        access.store.grantAccess(to: notes.url)
        XCTAssertTrue(controller.rowsForTesting.contains { $0[0] == notes.url.path }, "the list follows new grants")
    }

    func testOutsideTheSandboxTheWindowExplainsThatNothingIsGranted() {
        let store = FolderAccessStore(defaults: makeTestUserDefaults(), bookmarks: FakeSecurityScopedBookmarks(), isSandboxed: false)
        let controller = FolderAccessWindowController(store: { store })
        defer { controller.windowForTesting?.close() }

        controller.showFolderAccess(nil)

        XCTAssertTrue(controller.rowsForTesting.isEmpty)
        XCTAssertTrue(controller.summaryForTesting.contains("not sandboxed"))
        XCTAssertFalse(controller.isRemoveEnabledForTesting)
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

        access.store.recordRefusedImage(directory.url.appendingPathComponent("image.png"), forDocumentAt: fileURL)
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

        XCTAssertEqual(requests.map(\.suggestedFolder?.path), [directory.url.path])
        XCTAssertEqual(refreshed, [[FileIdentity.identity(for: fileURL)]])
        XCTAssertFalse(host.isFolderAccessNoticeVisibleForTesting)
    }

    func testANeededFileOutsideTheRangeIsExplainedInsteadOfOffered() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "Plan.md", contents: "# Plan")
        let access = installSandboxedFolderAccess()
        access.store.noteUserSelected([fileURL])
        let (document, host, _) = try makeHostedDocument(fileURL)
        defer { document.close() }

        access.store.recordRefusedImage(URL(fileURLWithPath: "/image.png"), forDocumentAt: fileURL)

        XCTAssertTrue(host.isFolderAccessNoticeVisibleForTesting)
        XCTAssertEqual(host.folderAccessNoticeForTesting?.message, "“Plan.md” needs files outside the folders Wafer offers.")
        var requests: [FolderAccessRequest] = []
        FolderAccessFlow.chooseFolder = { request, _, completion in
            requests.append(request)
            completion(nil)
        }
        host.folderAccessNoticeForTesting?.triggerGrantAccessForTesting()
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.suggestedFolder)
        XCTAssertEqual(requests.first?.outOfRange?.startingFolder, FileIdentity.normalized(fileURL).deletingLastPathComponent())
        XCTAssertTrue(host.isFolderAccessNoticeVisibleForTesting, "cancelled: the document still needs the file")
    }

    func testDismissingTheNoticeHidesItForThatDocument() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "Plan.md", contents: "# Plan")
        let access = installSandboxedFolderAccess()
        let (document, host, _) = try makeHostedDocument(fileURL)
        defer { document.close() }
        access.store.recordRefusedImage(directory.url.appendingPathComponent("image.png"), forDocumentAt: fileURL)
        XCTAssertTrue(host.isFolderAccessNoticeVisibleForTesting)

        host.folderAccessNoticeForTesting?.triggerDismissForTesting()
        access.store.recordRefusedImage(directory.url.appendingPathComponent("other.png"), forDocumentAt: fileURL)

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

        XCTAssertEqual(requests.map(\.suggestedFolder?.path), [nextFolder.path])
        waitUntil { document.fileURL == FileIdentity.normalized(next) }
    }

    func testClosingTheLastDocumentShowingAFileForgetsWhatItNeeded() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "Plan.md", contents: "# Plan")
        let access = installSandboxedFolderAccess()
        access.store.noteUserSelected([fileURL])
        let (first, _, _) = try makeHostedDocument(fileURL)
        let (second, _, _) = try makeHostedDocument(fileURL)
        OpenDocumentRegistry.shared.retain(first)
        OpenDocumentRegistry.shared.retain(second)
        access.store.recordRefusedImage(directory.url.appendingPathComponent("image.png"), forDocumentAt: fileURL)

        first.close()
        XCTAssertEqual(access.store.unreadableFiles(neededByDocumentAt: fileURL).count, 1, "another window still shows the file")
        second.close()
        XCTAssertTrue(access.store.unreadableFiles(neededByDocumentAt: fileURL).isEmpty)
        XCTAssertEqual(access.store.recordedDocumentCountForTesting, 0)
    }

    func testNavigatingAwayForgetsWhatTheDepartingFileNeeded() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "Plan.md", contents: "# Plan")
        let next = try directory.createTextFile(named: "Next.md", contents: "# Next")
        let access = installSandboxedFolderAccess()
        access.store.noteUserSelected([fileURL, next])
        let (document, _, _) = try makeHostedDocument(fileURL)
        OpenDocumentRegistry.shared.retain(document)
        defer { document.close() }
        access.store.recordRefusedImage(directory.url.appendingPathComponent("image.png"), forDocumentAt: fileURL)

        document.navigateInCurrentWindow(to: next)
        waitUntil { document.fileURL == FileIdentity.normalized(next) }

        XCTAssertTrue(access.store.unreadableFiles(neededByDocumentAt: fileURL).isEmpty)
    }

    func testANewReaderPageStopsCountingImagesItNoLongerShows() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "Plan.md", contents: "# Plan")
        let access = installSandboxedFolderAccess(imageSettleDelay: 0.05)
        access.store.noteUserSelected([fileURL])
        let (document, host, reader) = try makeHostedDocument(fileURL)
        defer { document.close() }
        let webView = try XCTUnwrap(Self.webView(in: reader.view))
        NotificationCenter.default.post(name: .localAssetAccessDenied, object: webView,
                                        userInfo: ["fileURL": directory.url.appendingPathComponent("image.png")])
        XCTAssertTrue(host.isFolderAccessNoticeVisibleForTesting)

        // The edited document no longer shows the image; its next page asks for nothing.
        NotificationCenter.default.post(name: .localAssetPageWillLoad, object: webView)
        XCTAssertTrue(host.isFolderAccessNoticeVisibleForTesting, "still shown while the page loads")
        waitUntil { !host.isFolderAccessNoticeVisibleForTesting }
    }

    func testALinkFollowedWhileEditingAsksForAReadWriteGrant() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "Plan.md", contents: "# Plan")
        let nextFolder = directory.url.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: nextFolder, withIntermediateDirectories: true)
        let next = nextFolder.appendingPathComponent("Next.md")
        try Data("# Next".utf8).write(to: next)
        let access = installSandboxedFolderAccess()
        access.store.noteUserSelected([fileURL])
        // Read-only already: reading is covered, saving is not.
        access.store.grantAccess(to: nextFolder)
        let (document, _, _) = try makeHostedDocument(fileURL)
        OpenDocumentRegistry.shared.retain(document)
        defer { document.close() }
        document.beginEditing()
        XCTAssertTrue(document.isEditing)
        var requests: [FolderAccessRequest] = []
        FolderAccessFlow.chooseFolder = { request, _, completion in
            requests.append(request)
            completion(request.suggestedFolder)
        }

        XCTAssertEqual(FolderAccessFlow.accessMode(requestedBy: fileURL), .readWrite)
        document.navigateInCurrentWindow(to: next)

        XCTAssertEqual(requests.map(\.suggestedFolder?.path), [nextFolder.path])
        XCTAssertTrue(try XCTUnwrap(requests.first).message.contains("in the editor and save your changes"))
        XCTAssertEqual(access.bookmarks.createdReadOnly, [true, false])
        XCTAssertTrue(access.store.allowsWriting(next))
        waitUntil { document.fileURL == FileIdentity.normalized(next) }
        XCTAssertTrue(document.isEditing)
    }

    func testEditModeRefusedUnderAReadOnlyGrantOffersAReadWriteGrantAndThenEdits() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fileURL = try directory.createTextFile(named: "Plan.md", contents: "# Plan")
        let access = installSandboxedFolderAccess()
        // Reached through a link: only the read-only folder grant covers it.
        access.store.grantAccess(to: directory.url)
        let (document, _, _) = try makeHostedDocument(fileURL)
        OpenDocumentRegistry.shared.retain(document)
        defer { document.close() }
        let refusal = CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: fileURL])

        let presented = AppDelegate(openURLs: { _ in }).application(NSApplication.shared, willPresentError: refusal)

        let explained = try XCTUnwrap(presented as? FolderAccessDeniedError)
        XCTAssertEqual(explained.purpose, .editing)
        XCTAssertEqual((presented as NSError).localizedRecoveryOptions, ["Grant Access…", "Cancel"])
        var requests: [FolderAccessRequest] = []
        FolderAccessFlow.chooseFolder = { request, _, completion in
            requests.append(request)
            completion(request.suggestedFolder)
        }
        XCTAssertFalse(explained.attemptRecovery(optionIndex: 0))
        XCTAssertEqual(requests.map(\.suggestedFolder?.path), [directory.url.path])
        XCTAssertTrue(access.store.allowsWriting(fileURL))
        XCTAssertTrue(document.isEditing, "the read-write grant starts edit mode")

        let elsewhere = URL(fileURLWithPath: "/tmp/wafer-unrelated/Note.md")
        XCTAssertNil(FolderAccessDeniedError.explainingWriteRefusal(refusal), "now writable: the file's own permissions refused it")
        XCTAssertNil(FolderAccessDeniedError.explainingWriteRefusal(CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: elsewhere])),
                     "a file Wafer cannot even read keeps its own error")
        XCTAssertNil(FolderAccessDeniedError.explainingWriteRefusal(CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: fileURL])))
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
