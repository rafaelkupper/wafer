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

    func fire() {
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
