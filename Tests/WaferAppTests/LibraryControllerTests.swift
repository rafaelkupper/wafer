import Foundation
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class LibraryControllerTests: XCTestCase {
    func testOpenLibraryScansFilesAndPersistsPreference() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        _ = try tempDirectory.createTextFile(named: "Guide.md", contents: "# Guide")
        let defaults = makeTestUserDefaults()
        let store = LibraryPreferenceStore(defaults: defaults)
        let controller = LibraryController(
            preferenceStore: store,
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) }
        )

        try controller.openLibrary(at: tempDirectory.url)
        waitForLibraryIdle(controller)

        XCTAssertEqual(controller.files.map(\.displayTitle), ["Guide"])
        XCTAssertEqual(store.libraryFolderURL, FileIdentity.normalized(tempDirectory.url))
        XCTAssertFalse(controller.truncated)
    }

    func testReopenPersistedLibraryLoadsExistingFolderAndRetainsUnavailableFolder() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        _ = try tempDirectory.createTextFile(named: "Guide.md", contents: "# Guide")
        let defaults = makeTestUserDefaults()
        let store = LibraryPreferenceStore(defaults: defaults)
        store.libraryFolderURL = tempDirectory.url
        let controller = LibraryController(
            preferenceStore: store,
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) }
        )

        controller.reopenPersistedLibraryIfAvailable()
        waitForLibraryIdle(controller)

        XCTAssertEqual(controller.files.map(\.displayTitle), ["Guide"])

        let missingStore = LibraryPreferenceStore(defaults: makeTestUserDefaults())
        missingStore.libraryFolderURL = tempDirectory.url.appendingPathComponent("Missing", isDirectory: true)
        let missingController = LibraryController(preferenceStore: missingStore)

        missingController.reopenPersistedLibraryIfAvailable()
        waitForLibraryIdle(missingController)

        XCTAssertEqual(missingStore.libraryFolderURL?.path, tempDirectory.url.appendingPathComponent("Missing").path)
        XCTAssertTrue(missingController.hasLibrary)
        XCTAssertNotNil(missingController.scanFailure)
        missingController.closeLibrary()
    }

    func testCloseLibraryClearsStatePreferenceAndMonitor() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let store = LibraryPreferenceStore(defaults: makeTestUserDefaults())
        var monitor: FakeDirectoryMonitor?
        let controller = LibraryController(
            preferenceStore: store,
            monitorFactory: { rootURL, onChange in
                let fake = FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange)
                monitor = fake
                return fake
            }
        )

        try controller.openLibrary(at: tempDirectory.url)
        waitForLibraryIdle(controller)

        controller.closeLibrary()

        XCTAssertFalse(controller.hasLibrary)
        XCTAssertTrue(controller.files.isEmpty)
        XCTAssertNil(store.libraryFolderURL)
        XCTAssertEqual(monitor?.stopCount, 1)
    }

    func testOpeningNewLibraryStopsPreviousMonitorBeforeReplacingIt() throws {
        let firstDirectory = try TemporaryTestDirectory()
        defer { firstDirectory.remove() }
        let secondDirectory = try TemporaryTestDirectory()
        defer { secondDirectory.remove() }
        var monitors: [FakeDirectoryMonitor] = []
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: makeTestUserDefaults()),
            scanner: { _ in LibraryScanner.Result(files: [], truncated: false) },
            monitorFactory: { rootURL, onChange in
                let fake = FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange)
                monitors.append(fake)
                return fake
            }
        )

        try controller.openLibrary(at: firstDirectory.url)
        waitForLibraryIdle(controller)

        try controller.openLibrary(at: secondDirectory.url)
        waitForLibraryIdle(controller)

        XCTAssertEqual(monitors.count, 2)
        XCTAssertEqual(monitors[0].stopCount, 1)
        XCTAssertEqual(monitors[1].stopCount, 0)
    }

    func testMonitorBurstTriggersOneDebouncedRescan() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        _ = try tempDirectory.createTextFile(named: "Guide.md", contents: "# Guide")
        let scanner = RecordingLibraryScanner()
        var monitor: FakeDirectoryMonitor?
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: makeTestUserDefaults()),
            scanner: scanner.scan(rootURL:),
            monitorFactory: { rootURL, onChange in
                let fake = FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange)
                monitor = fake
                return fake
            },
            monitorDebounceInterval: 0.02
        )

        try controller.openLibrary(at: tempDirectory.url)
        waitForLibraryIdle(controller)
        XCTAssertEqual(scanner.count, 1)

        for _ in 0..<5 {
            monitor?.fire()
        }
        waitUntil(timeout: 2) {
            scanner.count >= 2 && !controller.isScanning
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        XCTAssertEqual(scanner.count, 2)
    }

    func testContinuousMonitorChangesStartRescanWithinMaximumWait() async throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let clock = ManualLibraryRescanClock()
        var monitor: FakeDirectoryMonitor?
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: makeTestUserDefaults()),
            scanner: { _ in LibraryScanner.Result(files: [], truncated: false) },
            monitorFactory: { rootURL, onChange in
                let fake = FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange)
                monitor = fake
                return fake
            },
            rescanScheduler: clock.scheduler
        )
        defer { controller.closeLibrary() }
        let initialScan = expectation(description: "initial scan complete")
        try controller.openLibrary(at: directory.url) { _ in initialScan.fulfill() }
        await fulfillment(of: [initialScan], timeout: 2)

        monitor?.fire()
        // Keep writing more often than the 0.5 s quiet period, through the 2 s deadline.
        for _ in 0..<7 {
            clock.advance(by: 0.25)
            monitor?.fire()
            XCTAssertFalse(controller.isScanning)
        }
        clock.advance(by: 0.25)
        XCTAssertTrue(controller.isScanning, "continuous writes must start a rescan by 2 seconds")
    }

    func testOpenLibraryRunsScannerOffMainThread() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let scanner = ThreadRecordingLibraryScanner()
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: makeTestUserDefaults()),
            scanner: scanner.scan(rootURL:),
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) }
        )

        try controller.openLibrary(at: tempDirectory.url)
        waitForLibraryIdle(controller)

        XCTAssertEqual(scanner.count, 1)
        XCTAssertFalse(scanner.ranOnMainThread)
    }

    func testContinuousChangesPublishEachActiveScanBeforeOneFollowUp() async throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let clock = ManualLibraryRescanClock()
        let versions = ["First", "Second", "Third"].map {
            libraryFile(url: directory.url.appendingPathComponent("\($0).md"), title: $0)
        }
        let started = versions.map { expectation(description: "\($0.displayTitle) scan started") }
        let scanner = GatedLibraryScanner(files: versions, started: started)
        defer { scanner.releaseAll() }
        var monitor: FakeDirectoryMonitor?
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: makeTestUserDefaults()),
            scanner: scanner.scan(rootURL:),
            monitorFactory: { rootURL, onChange in
                let fake = FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange)
                monitor = fake
                return fake
            },
            rescanScheduler: clock.scheduler
        )
        defer { controller.closeLibrary() }
        var firstCompletions: [[LibraryFile]] = []
        try controller.openLibrary(at: directory.url) { firstCompletions.append($0) }
        await fulfillment(of: [started[0]], timeout: 2)

        for index in 0..<2 {
            if index == 0 { controller.refreshLibrary() }
            // Simulate a scan taking longer than the maximum wait, with no quiet period.
            for _ in 0..<12 {
                monitor?.fire(paths: [versions[index].identity])
                clock.advance(by: 0.25)
            }
            XCTAssertEqual(scanner.count, index + 1, "only one scan may run at a time")
            scanner.release(index)
            await fulfillment(of: [started[index + 1]], timeout: 2)
            XCTAssertEqual(controller.files.map(\.displayTitle), [versions[index].displayTitle], "writes must not discard the active scan")
            XCTAssertEqual(firstCompletions.map { $0.map(\.displayTitle) }, [["First"]], "the initial scan must publish before its follow-up")
        }

        let finished = expectation(description: "final scan published")
        let token = NotificationCenter.default.addObserver(forName: .libraryDidChange, object: nil, queue: nil) { note in
            if let change = LibraryChange.value(from: note), change.files == [versions[2]], !change.isScanning {
                finished.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        scanner.release(2)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(scanner.count, 3, "all intervening requests coalesce into one follow-up")
        XCTAssertEqual(controller.files, [versions[2]])
    }

    func testChangeDuringDebounceSurvivesActiveScanPublication() async throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let clock = ManualLibraryRescanClock()
        let file = libraryFile(url: directory.url.appendingPathComponent("Note.md"), title: "Note")
        let started = [expectation(description: "initial scan"), expectation(description: "follow-up scan")]
        let scanner = GatedLibraryScanner(files: [file, file], started: started)
        defer { scanner.releaseAll() }
        var monitor: FakeDirectoryMonitor?
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: makeTestUserDefaults()),
            scanner: scanner.scan(rootURL:),
            monitorFactory: { rootURL, onChange in
                let fake = FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange)
                monitor = fake
                return fake
            },
            rescanScheduler: clock.scheduler
        )
        defer { controller.closeLibrary() }
        let published = expectation(description: "initial scan published during debounce")
        try controller.openLibrary(at: directory.url) { _ in published.fulfill() }
        await fulfillment(of: [started[0]], timeout: 2)
        monitor?.fire()
        clock.advance(by: 0.25)
        scanner.release(0)
        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(scanner.count, 1)
        clock.advance(by: 0.25)
        await fulfillment(of: [started[1]], timeout: 2)
    }

    func testOpenLibraryFirstScanCompletionFiresOnceWithScannedFiles() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let firstFile = libraryFile(
            url: tempDirectory.url.appendingPathComponent("A.md"),
            title: "A"
        )
        let scanner = StaticLibraryScanner(result: LibraryScanner.Result(files: [firstFile], truncated: false))
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: makeTestUserDefaults()),
            scanner: scanner.scan(rootURL:),
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) }
        )
        var completedFileLists: [[LibraryFile]] = []

        try controller.openLibrary(at: tempDirectory.url) { files in
            completedFileLists.append(files)
        }
        waitForLibraryIdle(controller)

        XCTAssertEqual(completedFileLists, [[firstFile]])

        controller.refreshLibrary()
        waitForLibraryIdle(controller)

        XCTAssertEqual(completedFileLists, [[firstFile]])
    }

    func testFirstScanCompletionDoesNotFireAfterCloseLibrarySupersedesScan() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let scanner = BlockingLibraryScanner(
            result: LibraryScanner.Result(
                files: [libraryFile(url: tempDirectory.url.appendingPathComponent("A.md"), title: "A")],
                truncated: false
            )
        )
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: makeTestUserDefaults()),
            scanner: scanner.scan(rootURL:),
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) }
        )
        var completedFileLists: [[LibraryFile]] = []

        try controller.openLibrary(at: tempDirectory.url) { files in
            completedFileLists.append(files)
        }
        XCTAssertTrue(scanner.waitUntilStarted(timeout: 2))

        controller.closeLibrary()
        scanner.release()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(completedFileLists.isEmpty)
    }

    func testFirstScanCompletionDoesNotFireForScanSupersededBySecondOpenLibrary() throws {
        let firstDirectory = try TemporaryTestDirectory()
        defer { firstDirectory.remove() }
        let secondDirectory = try TemporaryTestDirectory()
        defer { secondDirectory.remove() }
        let firstFile = libraryFile(url: firstDirectory.url.appendingPathComponent("A.md"), title: "A")
        let secondFile = libraryFile(url: secondDirectory.url.appendingPathComponent("B.md"), title: "B")
        let scanner = SupersedingLibraryScanner(
            firstResult: LibraryScanner.Result(files: [firstFile], truncated: false),
            secondResult: LibraryScanner.Result(files: [secondFile], truncated: false)
        )
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: makeTestUserDefaults()),
            scanner: scanner.scan(rootURL:),
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) }
        )
        var firstCompletions: [[LibraryFile]] = []
        var secondCompletions: [[LibraryFile]] = []

        try controller.openLibrary(at: firstDirectory.url) { files in
            firstCompletions.append(files)
        }
        XCTAssertTrue(scanner.waitUntilFirstScanStarted(timeout: 2))

        try controller.openLibrary(at: secondDirectory.url) { files in
            secondCompletions.append(files)
        }
        // Scans are serialized: the replacement starts after the cancelled scan exits.
        XCTAssertTrue(secondCompletions.isEmpty)
        scanner.releaseFirstScan()
        waitUntil(timeout: 2) {
            secondCompletions == [[secondFile]] && !controller.isScanning
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(firstCompletions.isEmpty)
        XCTAssertEqual(secondCompletions, [[secondFile]])
    }

    func testLibraryNotificationsExposeTypedScanAndClosePayloads() async throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        _ = try directory.createTextFile(named: "Guide.md", contents: "# Guide")
        let center = NotificationCenter()
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: makeTestUserDefaults()),
            notificationCenter: center,
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) }
        )
        let scanned = expectation(description: "typed content notification")
        let closed = expectation(description: "typed close notification")
        let token = center.addObserver(forName: .libraryDidChange, object: nil, queue: nil) { notification in
            guard let change = LibraryChange.value(from: notification) else {
                XCTFail("library notification must carry its typed payload")
                return
            }
            XCTAssertFalse(change.truncated)
            XCTAssertFalse(change.availabilityChanged)
            XCTAssertEqual(notification.userInfo?.count, 1)
            XCTAssertNotNil(notification.userInfo?.values.first as? LibraryChange)
            if change.rootURL == nil {
                XCTAssertTrue(change.files.isEmpty)
                XCTAssertFalse(change.isScanning)
                XCTAssertTrue(change.contentChanged)
                XCTAssertNil(change.diff)
                closed.fulfill()
            } else if !change.isScanning, !change.files.isEmpty {
                XCTAssertEqual(change.rootURL, FileIdentity.normalized(directory.url))
                XCTAssertEqual(change.files.map(\.displayTitle), ["Guide"])
                XCTAssertTrue(change.contentChanged)
                XCTAssertEqual(change.diff?.added.count, 1)
                scanned.fulfill()
            }
        }
        defer { center.removeObserver(token) }
        try controller.openLibrary(at: directory.url)
        await fulfillment(of: [scanned], timeout: 2)
        controller.closeLibrary()
        await fulfillment(of: [closed], timeout: 2)
    }

    func testLibraryChangeRejectsUnrelatedAndUntypedNotifications() {
        let change = LibraryChange(
            rootURL: nil, files: [], truncated: false, isScanning: false,
            contentChanged: true, availabilityChanged: false, diff: nil
        )
        XCTAssertNil(LibraryChange.value(from: Notification(
            name: Notification.Name("unrelated"), userInfo: change.userInfo
        )))
        XCTAssertNil(LibraryChange.value(from: Notification(name: .libraryDidChange)))
        XCTAssertNil(LibraryChange.value(from: Notification(
            name: .libraryDidChange, userInfo: ["change": "invalid"]
        )))
    }

    func testOpeningNonDirectoryThrows() {
        let controller = LibraryController()

        XCTAssertThrowsError(try controller.openLibrary(at: URL(fileURLWithPath: "/tmp/DefinitelyMissing-\(UUID())")))
    }

    func testOpeningALibraryUnderTheSandboxStoresAFolderGrant() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        _ = try tempDirectory.createTextFile(named: "Guide.md", contents: "# Guide")
        let access = installSandboxedFolderAccess()
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: makeTestUserDefaults()),
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) },
            chooseLibraryFolder: { _, _, _ in XCTFail("A chosen library needs no second choice") }
        )

        try controller.openLibrary(at: tempDirectory.url)
        waitForLibraryIdle(controller)

        XCTAssertEqual(access.store.grantedFolders.map(\.path), [tempDirectory.url.path])
        XCTAssertEqual(controller.files.map(\.displayTitle), ["Guide"])
        controller.closeLibrary()
    }

    func testASavedLibraryPathWithoutAGrantAsksOnceToChooseTheFolderAgain() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        _ = try tempDirectory.createTextFile(named: "Guide.md", contents: "# Guide")
        let access = installSandboxedFolderAccess()
        let defaults = makeTestUserDefaults()
        let store = LibraryPreferenceStore(defaults: defaults)
        store.libraryFolderURL = tempDirectory.url
        var requests: [(folder: String, explainFirst: Bool)] = []
        let asked = expectation(description: "asked to choose the library folder again")
        let controller = LibraryController(
            preferenceStore: store,
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) },
            chooseLibraryFolder: { folder, explainFirst, completion in
                requests.append((folder.path, explainFirst))
                asked.fulfill()
                completion(folder)
            }
        )

        controller.reopenPersistedLibraryIfAvailable()
        XCTAssertTrue(requests.isEmpty, "the prompt waits until launch finishes")
        wait(for: [asked], timeout: 5)
        waitForLibraryIdle(controller)

        XCTAssertEqual(requests.map(\.folder), [tempDirectory.url.path])
        XCTAssertEqual(requests.map(\.explainFirst), [true])
        XCTAssertTrue(store.hasAskedForLibraryAccess)
        XCTAssertTrue(access.store.covers(tempDirectory.url.appendingPathComponent("Guide.md")))
        XCTAssertEqual(controller.files.map(\.displayTitle), ["Guide"])

        let relaunched = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: defaults),
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) },
            chooseLibraryFolder: { _, _, _ in XCTFail("asked twice") }
        )
        relaunched.reopenPersistedLibraryIfAvailable()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        waitForLibraryIdle(relaunched)
        relaunched.closeLibrary()
        controller.closeLibrary()
    }

    func testASavedLibraryCoveredByAGrantReopensWithoutAsking() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let library = tempDirectory.url.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("# Guide".utf8).write(to: library.appendingPathComponent("Guide.md"))
        let access = installSandboxedFolderAccess()
        access.store.grantAccess(to: tempDirectory.url, mode: .readWrite)
        let store = LibraryPreferenceStore(defaults: makeTestUserDefaults())
        store.libraryFolderURL = library
        let controller = LibraryController(
            preferenceStore: store,
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) },
            chooseLibraryFolder: { _, _, _ in XCTFail("asked although a grant covers the library") }
        )

        controller.reopenPersistedLibraryIfAvailable()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        waitForLibraryIdle(controller)

        XCTAssertFalse(store.hasAskedForLibraryAccess)
        XCTAssertEqual(controller.files.map(\.displayTitle), ["Guide"])
        let libraryGrant = try XCTUnwrap(access.store.folderGrants.first(where: \.isLibrary), "the library gets a grant of its own")
        XCTAssertEqual(libraryGrant.folderURL.path, library.path)
        XCTAssertEqual(store.libraryGrantID, libraryGrant.id)
        controller.closeLibrary()
    }

    func testALibraryWhoseFolderMovedReopensAtItsNewPlaceThroughItsGrant() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let oldFolder = tempDirectory.url.appendingPathComponent("Vault", isDirectory: true)
        let newFolder = tempDirectory.url.appendingPathComponent("Renamed Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try Data("# Guide".utf8).write(to: newFolder.appendingPathComponent("Guide.md"))
        let defaults = makeTestUserDefaults()
        defaults.set([[
            "id": "library-grant", "path": FileIdentity.identity(for: oldFolder),
            "bookmark": FakeSecurityScopedBookmarks.bookmark(for: oldFolder), "readOnly": false, "library": true,
        ]], forKey: "folderAccessGrants")
        let bookmarks = FakeSecurityScopedBookmarks()
        bookmarks.movedPaths = [oldFolder.path: newFolder.path]
        _ = installSandboxedFolderAccess(defaults: defaults, bookmarks: bookmarks)
        let preferences = LibraryPreferenceStore(defaults: makeTestUserDefaults())
        preferences.libraryFolderURL = oldFolder
        preferences.libraryGrantID = "library-grant"
        let controller = LibraryController(
            preferenceStore: preferences,
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) },
            chooseLibraryFolder: { _, _, _ in XCTFail("asked although the library's grant found the moved folder") }
        )

        controller.reopenPersistedLibraryIfAvailable()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        waitForLibraryIdle(controller)

        XCTAssertEqual(controller.rootURL, FileIdentity.normalized(newFolder))
        XCTAssertEqual(controller.files.map(\.displayTitle), ["Guide"])
        XCTAssertNil(controller.scanFailure)
        XCTAssertEqual(preferences.libraryFolderURL, FileIdentity.normalized(newFolder), "the saved path follows the grant")
        XCTAssertEqual(preferences.libraryGrantID, "library-grant")
        controller.closeLibrary()
    }

    func testTheLibraryKeepsAGrantOfItsOwnInsideAndUnderBroaderGrantsUntilItCloses() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let library = tempDirectory.url.appendingPathComponent("Notes/Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let access = installSandboxedFolderAccess()
        access.store.grantAccess(to: library.deletingLastPathComponent(), mode: .readWrite)
        let preferences = LibraryPreferenceStore(defaults: makeTestUserDefaults())
        let controller = LibraryController(
            preferenceStore: preferences,
            scanner: { _ in LibraryScanner.Result(files: [], truncated: false) },
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) }
        )
        func libraryGrants() -> [FolderGrantInfo] { access.store.folderGrants.filter(\.isLibrary) }

        try controller.openLibrary(at: library)
        XCTAssertEqual(libraryGrants().map(\.folderURL.path), [library.path], "stored although a broader grant covers it")
        XCTAssertEqual(libraryGrants().first?.mode, .readWrite)
        XCTAssertEqual(preferences.libraryGrantID, libraryGrants().first?.id)

        access.store.grantAccess(to: tempDirectory.url, mode: .readWrite)
        XCTAssertEqual(libraryGrants().map(\.folderURL.path), [library.path], "a parent grant does not replace it")
        XCTAssertEqual(access.store.folderGrants.count, 2)

        controller.closeLibrary()
        XCTAssertTrue(libraryGrants().isEmpty)
        XCTAssertTrue(access.store.folderGrants.contains { $0.folderURL.path == library.path }, "Close Library keeps the folder granted")
        XCTAssertNil(preferences.libraryGrantID)
    }

    /// The one-time prompt to choose the library again is for libraries saved
    /// before the App Sandbox. A library whose grant waits for its drive is
    /// not asked for; it stays selected and is scanned once the drive mounts.
    func testALibraryOnADisconnectedDriveIsNotAskedForAndIsScannedOnceItsGrantResolves() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let library = tempDirectory.url.appendingPathComponent("Drive/Library", isDirectory: true)
        let defaults = makeTestUserDefaults()
        defaults.set([[
            "id": "library-grant", "path": FileIdentity.identity(for: library),
            "bookmark": FakeSecurityScopedBookmarks.bookmark(for: library), "readOnly": false, "library": true,
        ]], forKey: "folderAccessGrants")
        let bookmarks = FakeSecurityScopedBookmarks()
        bookmarks.unresolvablePaths = [library.path]
        let access = installSandboxedFolderAccess(defaults: defaults, bookmarks: bookmarks)
        let preferences = LibraryPreferenceStore(defaults: makeTestUserDefaults())
        preferences.libraryFolderURL = library
        preferences.libraryGrantID = "library-grant"
        let controller = LibraryController(
            preferenceStore: preferences,
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) },
            chooseLibraryFolder: { _, _, _ in XCTFail("asked although the library has its grant") }
        )
        controller.reopenPersistedLibraryIfAvailable()
        flushMainQueue()
        waitForLibraryIdle(controller)
        XCTAssertFalse(preferences.hasAskedForLibraryAccess, "the one-time prompt is not used up")
        XCTAssertEqual(controller.rootURL, FileIdentity.normalized(library), "the library stays selected")
        XCTAssertEqual(preferences.libraryGrantID, "library-grant")
        XCTAssertNotNil(controller.scanFailure, "the drive is not connected")
        controller.retryIfUnavailable()
        XCTAssertNotNil(controller.scanFailure, "nothing to retry before the grant resolves")

        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("# Guide".utf8).write(to: library.appendingPathComponent("Guide.md"))
        bookmarks.unresolvablePaths = []
        XCTAssertTrue(access.store.resolveUnavailableGrants().didResolve)
        controller.retryIfUnavailable()
        waitForLibraryIdle(controller)

        XCTAssertNil(controller.scanFailure)
        XCTAssertEqual(controller.files.map(\.displayTitle), ["Guide"])
        controller.closeLibrary()
    }

    func testRemovingTheLibrarysFolderInFolderAccessClosesTheLibrary() throws {
        let library = try TemporaryTestDirectory()
        defer { library.remove() }
        let notes = try TemporaryTestDirectory()
        defer { notes.remove() }
        let access = installSandboxedFolderAccess()
        access.store.grantAccess(to: notes.url)
        let preferences = LibraryPreferenceStore(defaults: makeTestUserDefaults())
        let controller = LibraryController(
            preferenceStore: preferences,
            scanner: { _ in LibraryScanner.Result(files: [], truncated: false) },
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) }
        )
        try controller.openLibrary(at: library.url)
        waitForLibraryIdle(controller)
        let window = FolderAccessWindowController(library: { controller })
        defer { window.windowForTesting?.close() }
        window.showFolderAccess(nil)
        func select(_ folder: URL) throws {
            window.selectRowForTesting(try XCTUnwrap(window.rowsForTesting.firstIndex { $0[0] == folder.path }))
        }
        XCTAssertTrue(window.rowsForTesting.contains([library.url.path, "Read and write", "Your library"]))
        XCTAssertTrue(window.summaryForTesting.contains("Removing your library's folder also closes the library."))

        try select(notes.url)
        window.removeSelectedForTesting()
        XCTAssertTrue(controller.hasLibrary, "removing another folder keeps the library")

        try select(library.url)
        window.removeSelectedForTesting()

        XCTAssertFalse(controller.hasLibrary, "the library closes with its grant")
        XCTAssertNil(preferences.libraryFolderURL)
        XCTAssertNil(preferences.libraryGrantID, "no dangling grant identity is left for the next launch")
        XCTAssertTrue(access.store.folderGrants.isEmpty)
        XCTAssertTrue(window.rowsForTesting.isEmpty)
        XCTAssertFalse(access.store.covers(library.url.appendingPathComponent("Guide.md")))
    }

    func testALibraryCoveredOnlyByAReadOnlyGrantAsksOnceForAccessThatAllowsSaving() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let library = tempDirectory.url.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let access = installSandboxedFolderAccess()
        access.store.grantAccess(to: tempDirectory.url)
        let preferences = LibraryPreferenceStore(defaults: makeTestUserDefaults())
        preferences.libraryFolderURL = library
        let asked = expectation(description: "asked to choose the library folder again")
        let controller = LibraryController(
            preferenceStore: preferences,
            scanner: { _ in LibraryScanner.Result(files: [], truncated: false) },
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) },
            chooseLibraryFolder: { folder, _, completion in
                asked.fulfill()
                completion(folder)
            }
        )

        controller.reopenPersistedLibraryIfAvailable()
        wait(for: [asked], timeout: 5)

        XCTAssertTrue(access.store.allowsWriting(library.appendingPathComponent("Guide.md")))
        XCTAssertEqual(access.store.folderGrants.first(where: \.isLibrary)?.folderURL.path, library.path)
        controller.closeLibrary()
    }

    func testRetryingALibraryWithoutAccessOffersTheFolderPanel() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        _ = installSandboxedFolderAccess()
        let store = LibraryPreferenceStore(defaults: makeTestUserDefaults())
        store.libraryFolderURL = tempDirectory.url
        store.hasAskedForLibraryAccess = true
        var requests: [(folder: String, explainFirst: Bool)] = []
        let controller = LibraryController(
            preferenceStore: store,
            scanner: { _ in LibraryScanner.Result(files: [], truncated: false) },
            monitorFactory: { rootURL, onChange in FakeDirectoryMonitor(rootURL: rootURL, onChange: onChange) },
            chooseLibraryFolder: { folder, explainFirst, completion in
                requests.append((folder.path, explainFirst))
                completion(nil)
            }
        )
        controller.reopenPersistedLibraryIfAvailable()
        waitForLibraryIdle(controller)
        XCTAssertTrue(requests.isEmpty)

        controller.refreshLibrary()

        XCTAssertEqual(requests.map(\.folder), [tempDirectory.url.path])
        XCTAssertEqual(requests.map(\.explainFirst), [false])
        XCTAssertTrue(controller.hasLibrary, "a cancelled panel keeps the saved library")
        controller.closeLibrary()
    }

    func testChoosingAnotherLibraryClearsTheOneTimePrompt() {
        let store = LibraryPreferenceStore(defaults: makeTestUserDefaults())
        store.libraryFolderURL = URL(fileURLWithPath: "/tmp/WaferLibraryA", isDirectory: true)
        store.hasAskedForLibraryAccess = true
        store.libraryFolderURL = URL(fileURLWithPath: "/tmp/WaferLibraryA", isDirectory: true)
        XCTAssertTrue(store.hasAskedForLibraryAccess)
        store.libraryFolderURL = URL(fileURLWithPath: "/tmp/WaferLibraryB", isDirectory: true)
        XCTAssertFalse(store.hasAskedForLibraryAccess)
    }

    /// Runs the work already queued on the main queue, such as the prompt
    /// `reopenPersistedLibraryIfAvailable()` defers until launch finishes.
    private func flushMainQueue() {
        let flushed = expectation(description: "queued main-queue work ran")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)
    }

    private func waitForLibraryIdle(_ controller: LibraryController, timeout: TimeInterval = 2) {
        waitUntil(timeout: timeout) {
            !controller.isScanning
        }
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition())
    }

    private func libraryFile(url: URL, title: String) -> LibraryFile {
        LibraryFile(
            fileURL: url,
            relativePathComponents: [url.lastPathComponent],
            displayTitle: title,
            outlineItems: [],
            plainText: "",
            searchableText: "",
            contentFingerprint: LibraryFileFingerprint(
                modificationDate: Date(timeIntervalSince1970: 0),
                fileSize: 0
            )
        )
    }
}

@MainActor
private final class FakeDirectoryMonitor: DirectoryMonitoring {
    let rootURL: URL
    let onChange: () -> Void
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var changedPaths: Set<String>?

    init(rootURL: URL, onChange: @escaping () -> Void) {
        self.rootURL = rootURL
        self.onChange = onChange
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func fire(paths: Set<String>? = nil) {
        changedPaths = paths
        onChange()
    }
}

private final class RecordingLibraryScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var scanCount = 0

    var count: Int {
        lock.withLock { scanCount }
    }

    func scan(rootURL: URL) -> LibraryScanner.Result {
        lock.withLock {
            scanCount += 1
        }
        return LibraryScanner.scan(rootURL: rootURL)
    }
}

private final class ThreadRecordingLibraryScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var scanCount = 0
    private var mainThreadResults: [Bool] = []

    var count: Int {
        lock.withLock { scanCount }
    }

    var ranOnMainThread: Bool {
        lock.withLock { mainThreadResults.contains(true) }
    }

    func scan(rootURL: URL) -> LibraryScanner.Result {
        lock.withLock {
            scanCount += 1
            mainThreadResults.append(Thread.isMainThread)
        }
        return LibraryScanner.Result(files: [], truncated: false)
    }
}

private final class StaticLibraryScanner: @unchecked Sendable {
    private let result: LibraryScanner.Result

    init(result: LibraryScanner.Result) {
        self.result = result
    }

    func scan(rootURL: URL) -> LibraryScanner.Result {
        result
    }
}

private final class BlockingLibraryScanner: @unchecked Sendable {
    private let result: LibraryScanner.Result
    private let started = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    init(result: LibraryScanner.Result) {
        self.result = result
    }

    func scan(rootURL: URL) -> LibraryScanner.Result {
        started.signal()
        releaseSemaphore.wait()
        return result
    }

    func waitUntilStarted(timeout: TimeInterval) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class SupersedingLibraryScanner: @unchecked Sendable {
    private let lock = NSLock()
    private let firstResult: LibraryScanner.Result
    private let secondResult: LibraryScanner.Result
    private let firstStarted = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private var count = 0

    init(firstResult: LibraryScanner.Result, secondResult: LibraryScanner.Result) {
        self.firstResult = firstResult
        self.secondResult = secondResult
    }

    func scan(rootURL: URL) -> LibraryScanner.Result {
        let scanNumber = lock.withLock {
            count += 1
            return count
        }

        if scanNumber == 1 {
            firstStarted.signal()
            releaseFirst.wait()
            return firstResult
        }

        return secondResult
    }

    func waitUntilFirstScanStarted(timeout: TimeInterval) -> Bool {
        firstStarted.wait(timeout: .now() + timeout) == .success
    }

    func releaseFirstScan() {
        releaseFirst.signal()
    }
}

private final class GatedLibraryScanner: @unchecked Sendable {
    private let lock = NSLock()
    private let files: [LibraryFile]
    private let started: [XCTestExpectation]
    private let gates: [DispatchSemaphore]
    private var scanCount = 0

    init(files: [LibraryFile], started: [XCTestExpectation]) {
        self.files = files
        self.started = started
        self.gates = files.map { _ in DispatchSemaphore(value: 0) }
    }

    var count: Int { lock.withLock { scanCount } }

    func scan(rootURL: URL) -> LibraryScanner.Result {
        let index = lock.withLock { let index = scanCount; scanCount += 1; return index }
        guard files.indices.contains(index) else {
            XCTFail("unexpected extra scan")
            return LibraryScanner.Result(files: [], truncated: false)
        }
        started[index].fulfill()
        gates[index].wait()
        return LibraryScanner.Result(files: [files[index]], truncated: false)
    }

    func release(_ index: Int) { gates[index].signal() }
    func releaseAll() { gates.forEach { $0.signal() } }
}

@MainActor
private final class ManualLibraryRescanClock {
    private var now: TimeInterval = 0
    private var scheduled: [(deadline: TimeInterval, work: DispatchWorkItem)] = []

    var scheduler: LibraryRescanScheduler {
        LibraryRescanScheduler(now: { self.now }, schedule: { delay, action in
            let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
            self.scheduled.append((self.now + delay, work))
            return work
        })
    }

    func advance(by interval: TimeInterval) {
        now += interval
        let due = scheduled.filter { $0.deadline <= now }
        scheduled.removeAll { $0.deadline <= now }
        for item in due where !item.work.isCancelled { item.work.perform() }
    }
}
