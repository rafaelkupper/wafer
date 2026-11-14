import AppKit
import UniformTypeIdentifiers
import WaferCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    typealias URLOpenHandler = @MainActor ([URL]) -> Void
    typealias LibraryOpenHandler = @MainActor (URL, LibraryController.FirstScanCompletion?) throws -> Void
    typealias InitialLibraryDocumentOpenHandler = @MainActor ([LibraryFile]) -> Void
    typealias PersistedLibraryReopenHandler = @MainActor () -> Void

    static let sharedScrollStateStore = ScrollStateStore()

    private static let scrollStateRetentionInterval: TimeInterval = 180 * 24 * 60 * 60

    private let openURLs: URLOpenHandler
    private let openLibrary: LibraryOpenHandler
    private let openInitialLibraryDocument: InitialLibraryDocumentOpenHandler
    private let reopenPersistedLibrary: PersistedLibraryReopenHandler
    private let scrollStateStore: ScrollStateStore
    private let appearancePreferenceStore: AppearancePreferenceStore
    private let workspaceNotificationCenter: NotificationCenter
    private let retryUnavailableAccess: @MainActor () -> Void
    private var volumeMountObserver: NSObjectProtocol?
    private var terminationSaveInFlight = false
    var flushForTermination: @MainActor (@escaping @MainActor (Bool) -> Void) -> Void = MarkdownReaderDocument.flushAllEdits
    var replyToTermination: @MainActor (NSApplication, Bool) -> Void = { $0.reply(toApplicationShouldTerminate: $1) }

    init(
        openURLs: @escaping URLOpenHandler = MarkdownDocumentOpener.open(urls:),
        openLibrary: @escaping LibraryOpenHandler = {
            try LibraryController.shared.openLibrary(at: $0, onFirstScanCompletion: $1)
        },
        openInitialLibraryDocument: @escaping InitialLibraryDocumentOpenHandler = {
            LibraryInitialDocumentOpener.openFirstDocumentIfNoMarkdownWindow(files: $0)
        },
        reopenPersistedLibrary: @escaping PersistedLibraryReopenHandler = {
            LibraryController.shared.reopenPersistedLibraryIfAvailable()
        },
        scrollStateStore: ScrollStateStore = AppDelegate.sharedScrollStateStore,
        appearancePreferenceStore: AppearancePreferenceStore = .shared,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        retryUnavailableAccess: @escaping @MainActor () -> Void = AppDelegate.retryUnavailableAccess
    ) {
        self.openURLs = openURLs
        self.openLibrary = openLibrary
        self.openInitialLibraryDocument = openInitialLibraryDocument
        self.reopenPersistedLibrary = reopenPersistedLibrary
        self.scrollStateStore = scrollStateStore
        self.appearancePreferenceStore = appearancePreferenceStore
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.retryUnavailableAccess = retryUnavailableAccess
    }

    /// Documents opened at launch arrive before `applicationDidFinishLaunching`,
    /// so stored folder grants are restored first. Grants on a drive that is
    /// not connected are retried whenever a volume mounts.
    func applicationWillFinishLaunching(_ notification: Notification) {
        FolderAccessStore.shared.restoreGrants()
        let retry = retryUnavailableAccess
        volumeMountObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { retry() }
        }
    }

    /// After a volume mounts: resolves the grants that were unavailable,
    /// reloads documents whose files became readable, and rescans a library
    /// that could not be read.
    static func retryUnavailableAccess() {
        let result = FolderAccessStore.shared.resolveUnavailableGrants()
        guard result.didResolve else { return }
        FolderAccessFlow.refreshDocuments(result.documents)
        LibraryController.shared.retryIfUnavailable()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearancePreferenceStore.reloadThemes()
        appearancePreferenceStore.applyResolvedPalette()
        scrollStateStore.pruneEntries(
            olderThan: Date(timeIntervalSinceNow: -Self.scrollStateRetentionInterval)
        )
        reopenPersistedLibrary()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UpdateController.shared.postponesQuitAfterLastWindowClosed()
    }

    /// Edit mode autosaves; flush anything typed in the last second and let a
    /// cancelled save-conflict prompt cancel the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationSaveInFlight else { return .terminateLater }
        terminationSaveInFlight = true
        // Reply on a later turn even when all documents are already saved.
        DispatchQueue.main.async {
            self.flushForTermination { success in
                self.terminationSaveInFlight = false
                self.replyToTermination(sender, success)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        volumeMountObserver.map(workspaceNotificationCenter.removeObserver)
        volumeMountObserver = nil
        FolderAccessStore.shared.stopAccessingAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Edit mode on a file covered only by a read-only folder grant is
    /// refused as a write-permission error; it is presented with Grant
    /// Access…, which asks for a read-write grant and then starts editing.
    func application(_ application: NSApplication, willPresentError error: Error) -> Error {
        FolderAccessDeniedError.explainingWriteRefusal(error) ?? error
    }

    @objc
    func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = AssetResolver.markdownExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }

        guard panel.runModal() == .OK else {
            return
        }

        FolderAccessStore.shared.noteUserSelected(panel.urls)
        openURLs(panel.urls)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Finder, the Dock, and `open` hand Wafer access to exactly these items.
        FolderAccessStore.shared.noteUserSelected(urls)
        var documentURLs: [URL] = []
        for url in urls {
            if LibraryController.isDirectory(url) {
                do {
                    try openLibrary(url) { [openInitialLibraryDocument] files in
                        openInitialLibraryDocument(files)
                    }
                } catch {
                    NSApp.presentError(error)
                }
            } else {
                documentURLs.append(url)
            }
        }

        if !documentURLs.isEmpty {
            openURLs(documentURLs)
        }
    }
}
