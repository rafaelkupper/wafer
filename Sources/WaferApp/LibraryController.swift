import AppKit
import Foundation
import WaferCore

extension Notification.Name {
    static let libraryDidChange = Notification.Name("LibraryController.libraryDidChange")
}

@MainActor
final class LibraryController {
    typealias Scanner = @Sendable (_ rootURL: URL) -> LibraryScanner.Result
    typealias MonitorFactory = @MainActor (_ rootURL: URL, _ onChange: @escaping () -> Void) -> DirectoryMonitoring
    typealias FirstScanCompletion = @MainActor (_ files: [LibraryFile]) -> Void
    /// Asks the user to choose `folder` (or another) as the library, after an
    /// explanation when `explainFirst`; nil when cancelled.
    typealias FolderChooser = @MainActor (
        _ folder: URL, _ explainFirst: Bool, _ completion: @escaping @MainActor (URL?) -> Void
    ) -> Void

    static let shared = LibraryController()

    private let preferenceStore: LibraryPreferenceStore
    private let notificationCenter: NotificationCenter
    private let scanner: Scanner?
    private let monitorFactory: MonitorFactory
    private let monitorDebounceInterval: TimeInterval
    private let monitorMaximumWait: TimeInterval
    private var firstPendingMonitorChange: TimeInterval?
    private let rescanScheduler: LibraryRescanScheduler
    private let chooseLibraryFolder: FolderChooser

    private var monitor: DirectoryMonitoring?
    private var pendingMonitorWorkItem: DispatchWorkItem?
    private var pendingFirstScanCompletion: FirstScanCompletion?
    private var scanCancellation: WorkCancellation?
    private var pendingScan = false
    private var changedPaths: Set<String>? = []
    private var scanGeneration = 0

    private(set) var rootURL: URL?
    private(set) var snapshot = LibrarySnapshot()
    var files: [LibraryFile] { snapshot.files }
    var backlinksByIdentity: [String: [Backlink]] { snapshot.backlinksByIdentity }
    var truncated: Bool { snapshot.truncated }
    /// Items the last successful scan could not index because they were
    /// unreadable or over the size budget.
    private(set) var skippedItemCount = 0
    private(set) var isScanning = false
    private(set) var scanFailure: LibraryScanner.Failure?

    init(
        preferenceStore: LibraryPreferenceStore = .shared,
        notificationCenter: NotificationCenter = .default,
        scanner: Scanner? = nil,
        monitorFactory: @escaping MonitorFactory = { rootURL, onChange in
            DirectoryChangeMonitor(rootURL: rootURL, onChange: onChange)
        },
        monitorDebounceInterval: TimeInterval = 0.5,
        monitorMaximumWait: TimeInterval = 2,
        rescanScheduler: LibraryRescanScheduler = .main,
        chooseLibraryFolder: @escaping FolderChooser = LibraryController.askToChooseLibraryFolder
    ) {
        self.preferenceStore = preferenceStore
        self.notificationCenter = notificationCenter
        self.scanner = scanner
        self.monitorFactory = monitorFactory
        self.monitorDebounceInterval = monitorDebounceInterval
        self.monitorMaximumWait = monitorMaximumWait
        self.rescanScheduler = rescanScheduler
        self.chooseLibraryFolder = chooseLibraryFolder
    }

    var hasLibrary: Bool {
        rootURL != nil
    }

    func openLibrary(
        at url: URL,
        onFirstScanCompletion: FirstScanCompletion? = nil
    ) throws {
        let normalizedURL = FileIdentity.normalized(url)
        guard Self.isDirectory(normalizedURL) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        // Under the App Sandbox the folder chosen in the open panel or dropped
        // on the app stays readable in later launches as a folder grant.
        FolderAccessFlow.refreshDocuments(FolderAccessStore.shared.grantAccess(to: url))
        selectLibrary(at: normalizedURL, onFirstScanCompletion: onFirstScanCompletion)
    }

    private func selectLibrary(at normalizedURL: URL, onFirstScanCompletion: FirstScanCompletion? = nil) {
        pendingMonitorWorkItem?.cancel()
        pendingMonitorWorkItem = nil
        firstPendingMonitorChange = nil
        scanCancellation?.cancel()
        snapshot = LibrarySnapshot()
        skippedItemCount = 0
        scanFailure = nil
        changedPaths = nil
        pendingFirstScanCompletion = onFirstScanCompletion
        rootURL = normalizedURL
        preferenceStore.libraryFolderURL = normalizedURL
        startMonitoring(rootURL: normalizedURL)
        postLibraryDidChange(diff: nil, contentChanged: true)
        performScan()
    }

    func closeLibrary() {
        scanGeneration += 1
        pendingFirstScanCompletion = nil
        scanCancellation?.cancel()
        pendingScan = false
        changedPaths = []
        pendingMonitorWorkItem?.cancel()
        pendingMonitorWorkItem = nil
        firstPendingMonitorChange = nil
        monitor?.stop()
        monitor = nil
        rootURL = nil
        snapshot = LibrarySnapshot()
        skippedItemCount = 0
        scanFailure = nil
        isScanning = false
        preferenceStore.libraryFolderURL = nil
        postLibraryDidChange(diff: nil, contentChanged: true)
    }

    func refreshLibrary() {
        // A rescan cannot read a folder the App Sandbox has no grant for; ask for it.
        if let rootURL, needsFolderAccess(rootURL) {
            requestLibraryAccess(for: rootURL, explainFirst: false)
            return
        }
        // A manual retry also recovers changes missed while the folder was offline.
        changedPaths = nil
        if let rootURL { startMonitoring(rootURL: rootURL) }
        performScan()
    }

    func reopenPersistedLibraryIfAvailable() {
        guard let persistedURL = preferenceStore.libraryFolderURL else {
            return
        }

        // An unavailable mount is still the user's selected library. Let the
        // background scan report availability without forgetting its path.
        selectLibrary(at: persistedURL)

        // Before the App Sandbox, Wafer saved only the library's path. Unless a
        // folder grant covers it, ask once (after launch) to choose it again.
        guard needsFolderAccess(persistedURL), !preferenceStore.hasAskedForLibraryAccess else { return }
        preferenceStore.hasAskedForLibraryAccess = true
        DispatchQueue.main.async { [weak self] in
            self?.requestLibraryAccess(for: persistedURL, explainFirst: true)
        }
    }

    private func needsFolderAccess(_ folderURL: URL) -> Bool {
        let store = FolderAccessStore.shared
        return store.isSandboxed && !store.covers(folderURL)
    }

    private func requestLibraryAccess(for folderURL: URL, explainFirst: Bool) {
        chooseLibraryFolder(folderURL, explainFirst) { [weak self] chosen in
            guard let self, let chosen else { return }
            do {
                try self.openLibrary(at: chosen)
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    /// The default chooser: an optional explanation, then an open panel that
    /// starts inside the saved folder, so Choose picks it.
    static func askToChooseLibraryFolder(
        _ folderURL: URL, explainFirst: Bool, completion: @escaping @MainActor (URL?) -> Void
    ) {
        let name = folderURL.lastPathComponent
        if explainFirst {
            let alert = NSAlert()
            alert.messageText = "Choose your library folder again"
            alert.informativeText = "Wafer now runs in the macOS App Sandbox, which lets it read only the folders you choose. Choose “\(name)” once to keep it as your library."
            alert.addButton(withTitle: "Choose Folder…")
            alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
        }
        FolderAccessFlow.chooseFolder(FolderAccessRequest(
            suggestedFolder: folderURL,
            message: "Choose “\(name)” to keep reading it as your library. Wafer can read only the folders you choose.",
            prompt: "Choose"
        ), nil, completion)
    }

    func backlinks(for fileURL: URL) -> [Backlink] {
        backlinksByIdentity[FileIdentity.identity(for: fileURL)] ?? []
    }

    private func startMonitoring(rootURL: URL) {
        monitor?.stop()
        let monitor = monitorFactory(rootURL) { [weak self] in
            guard let self, self.rootURL == rootURL else { return }
            if let paths = self.monitor?.changedPaths, self.changedPaths != nil {
                self.changedPaths?.formUnion(paths)
            } else {
                self.changedPaths = nil
            }
            // Preserve dirty paths if the active scan finishes during the debounce window.
            self.scanCancellation?.cancel()
            self.scheduleMonitorRescan()
        }
        self.monitor = monitor
        monitor.start()
    }

    private func scheduleMonitorRescan() {
        pendingMonitorWorkItem?.cancel()

        let now = rescanScheduler.now()
        let firstChange = firstPendingMonitorChange ?? now
        firstPendingMonitorChange = firstChange
        let delay = min(monitorDebounceInterval, max(0, firstChange + monitorMaximumWait - now))
        pendingMonitorWorkItem = rescanScheduler.schedule(delay) { [weak self] in
            guard let self else { return }
            self.pendingMonitorWorkItem = nil
            self.firstPendingMonitorChange = nil
            self.performScan()
        }
    }

    private func performScan() {
        guard rootURL != nil else { return }
        scanGeneration += 1
        pendingScan = true
        isScanning = true
        postLibraryDidChange(diff: nil, contentChanged: false)
        if let scanCancellation {
            scanCancellation.cancel()
            return
        }
        startPendingScan()
    }

    private func startPendingScan() {
        guard pendingScan, let rootURL else { return }
        pendingScan = false
        let generation = scanGeneration
        let cancellation = WorkCancellation()
        scanCancellation = cancellation
        let previous = snapshot
        let previousSkippedItemCount = skippedItemCount
        let paths = changedPaths
        let scanner = self.scanner

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = scanner?(rootURL) ?? LibraryScanner.scan(
                rootURL: rootURL, existingFiles: previous.files,
                changedPaths: paths, cancellation: cancellation
            )
            if let failure = result.failure {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.scanCancellation = nil
                    if self.scanGeneration == generation, !cancellation.isCancelled {
                        let availabilityChanged = self.scanFailure != failure
                        self.scanFailure = failure
                        self.isScanning = false
                        self.postLibraryDidChange(diff: nil, contentChanged: false,
                            availabilityChanged: availabilityChanged)
                    }
                    self.startPendingScan()
                }
                return
            }
            let diff = LibraryIndexDiff.apply(scan: result, to: previous.files)
            let contentChanged = !diff.added.isEmpty || !diff.changed.isEmpty || !diff.removed.isEmpty
                || result.truncated != previous.truncated
                || result.skippedItemCount != previousSkippedItemCount
                || diff.files.map(\.identity) != previous.files.map(\.identity)
            let snapshot = contentChanged && !cancellation.isCancelled
                ? LibrarySnapshot(files: diff.files, truncated: diff.truncated) : previous
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanCancellation = nil
                if self.scanGeneration == generation, !cancellation.isCancelled {
                    let availabilityChanged = self.scanFailure != nil
                    self.snapshot = snapshot
                    self.skippedItemCount = result.skippedItemCount
                    self.scanFailure = nil
                    self.changedPaths = []
                    self.isScanning = false
                    let completion = self.pendingFirstScanCompletion
                    self.pendingFirstScanCompletion = nil
                    self.postLibraryDidChange(diff: diff, contentChanged: contentChanged,
                        availabilityChanged: availabilityChanged)
                    completion?(self.files)
                }
                self.startPendingScan()
            }
        }
    }

    private func postLibraryDidChange(
        diff: LibraryIndexDiff.Result?, contentChanged: Bool, availabilityChanged: Bool = false
    ) {
        notificationCenter.post(
            name: .libraryDidChange,
            object: self,
            userInfo: LibraryChange(
                rootURL: rootURL, files: files, truncated: truncated, isScanning: isScanning,
                contentChanged: contentChanged, availabilityChanged: availabilityChanged, diff: diff
            ).userInfo
        )
    }

    static func isDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else {
            return false
        }

        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
