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
        appearancePreferenceStore: AppearancePreferenceStore = .shared
    ) {
        self.openURLs = openURLs
        self.openLibrary = openLibrary
        self.openInitialLibraryDocument = openInitialLibraryDocument
        self.reopenPersistedLibrary = reopenPersistedLibrary
        self.scrollStateStore = scrollStateStore
        self.appearancePreferenceStore = appearancePreferenceStore
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
        MarkdownReaderDocument.flushAllEdits() ? .terminateNow : .terminateCancel
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
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

        openURLs(panel.urls)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
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
