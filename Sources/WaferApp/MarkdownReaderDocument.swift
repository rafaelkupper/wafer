import AppKit
import Foundation
import WaferCore

final class MarkdownReaderDocument: NSDocument {
    typealias RenderScheduler = (
        _ source: String,
        _ baseURL: URL?,
        _ palette: ReaderThemePalette,
        _ wikiLinkIndex: WikiLinkIndex?,
        _ completion: @escaping (WebKitRenderOutput) -> Void
    ) -> DispatchWorkItem
    typealias WikiLinkIndexProvider = @MainActor () -> WikiLinkIndex?
    typealias LibrarySnapshotProvider = @MainActor () -> LibrarySnapshot
    typealias MarkdownLinkOpener = @MainActor (_ url: URL, _ anchorID: String?) -> Void
    typealias LinkTargetHandler = @MainActor (LinkTarget) -> Void
    typealias ReaderControllerFactory = () -> WebKitReaderViewController
    typealias SourceLoader = @Sendable (_ fileURL: URL) throws -> LoadedMarkdownSource
    typealias FileMonitorFactory =
        @MainActor (_ fileURL: URL, _ onChange: @escaping () -> Void) -> FileChangeMonitoring

    /// The source read in progress, if any. A read that is superseded or
    /// abandoned bumps `loadGeneration`, and its completion is discarded.
    private enum LoadState: Equatable {
        case idle
        /// Reading the file the document was opened with.
        case opening(URL)
        /// Reading another file to show in place of the current one.
        case navigating(URL)
        /// Re-reading the current file (file monitor or Cmd-R).
        case reloading(URL)

        var url: URL? {
            switch self {
            case .idle:
                nil
            case .opening(let url), .navigating(let url), .reloading(let url):
                url
            }
        }

        /// Back and Forward wait until an open or navigation read finishes.
        var isNavigating: Bool {
            switch self {
            case .opening, .navigating:
                true
            case .idle, .reloading:
                false
            }
        }
    }

    /// A heading to scroll to once the page that contains it is ready.
    private enum PendingAnchor: Equatable {
        case none
        /// Waits for the render of a newly loaded file.
        case beforeRender(String)
        /// Scrolls when the reader next finishes loading ready content.
        case afterPageLoad(String)

        var id: String? {
            switch self {
            case .none:
                nil
            case .beforeRender(let id), .afterPageLoad(let id):
                id
            }
        }
    }

    private let assetResolver: AssetResolver
    private let scrollStateStore: ScrollStateStore
    private let renderWorker = MarkdownRenderWorker()
    /// Replaces the render worker in tests.
    private let injectedRenderScheduler: RenderScheduler?
    private let markdownLinkOpener: MarkdownLinkOpener
    private let linkTargetHandler: LinkTargetHandler
    private let readerControllerFactory: ReaderControllerFactory
    private let statisticPreferenceStore: DocumentStatisticPreferenceStore
    private let appearancePreferenceStore: AppearancePreferenceStore
    private let readerBehaviorPreferenceStore: ReaderBehaviorPreferenceStore
    private let sourceLoader: SourceLoader
    private let fileMonitorFactory: FileMonitorFactory
    private let scrollPersistenceDebounceInterval: TimeInterval
    private let wikiLinkIndexProvider: WikiLinkIndexProvider
    private let sourceLoadErrorHandler: @MainActor (Error) -> Void
    private let editMode: MarkdownEditCoordinator

    /// The file as shown: its text (the editor's text while editing), its
    /// format, and the fingerprint of the bytes last loaded or saved. Nil
    /// until the first read succeeds.
    private var source: LoadedMarkdownSource?
    private weak var readerController: WebKitReaderViewController?
    private weak var documentWindowController: DocumentWindowController?
    private var fileMonitor: FileChangeMonitoring?
    private var renderWorkItem: DispatchWorkItem?
    private var renderToken = UUID()
    private var loadState = LoadState.idle
    private var loadGeneration = 0
    /// A reload requested while a read was running; true when it was
    /// explicit (Cmd-R). It runs against whatever file that read leaves.
    private var deferredReload: Bool?
    private var initialSourceFailureHandler: (@MainActor () -> Void)?
    private var currentStatistics: DocumentStatistics?
    private var currentSidebarEntries: [DocumentSidebarEntry] = []
    private var currentOutlineItems: [DocumentOutlineItem] = []
    private var currentActiveHeadingID: String?
    private var pendingAnchor = PendingAnchor.none
    private var pendingScrollFraction: Double?
    private var scrollPersistenceWorkItem: DispatchWorkItem?
    private var scrollPersistenceGeneration = 0
    private(set) var navigationHistory = WindowNavigationHistory()
    private var lastRenderedWikiLinkIndex: WikiLinkIndex?
    private var lastOutputHadWikiLinks = false
    private var renderedPalette: ReaderThemePalette?
    var initialCascadeSourceWindow: NSWindow?
    var hasLoadedSource: Bool { source != nil }

    /// Copies the displayed document's Markdown source as plain text (the
    /// editor's current text in edit mode). Returns false while loading.
    @discardableResult
    func copySourceToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard let source else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(editMode.editor?.text ?? source.sourceText, forType: .string)
    }

    /// Copies the displayed file itself, like Finder's Copy, so pasting into
    /// Finder, Mail, or a chat app attaches the file.
    @discardableResult
    func copyFileToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard hasLoadedSource, let fileURL else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([fileURL as NSURL])
    }

    override convenience init() {
        // Every dependency takes its production default.
        self.init(assetResolver: AssetResolver())
    }

    init(
        assetResolver: AssetResolver = AssetResolver(),
        scrollStateStore: ScrollStateStore = ScrollStateStore(),
        renderScheduler: RenderScheduler? = nil,
        markdownLinkOpener: @escaping MarkdownLinkOpener = MarkdownReaderDocument.defaultOpenMarkdownLink,
        linkTargetHandler: @escaping LinkTargetHandler = { LinkTargetOpener().handle($0) },
        readerControllerFactory: @escaping ReaderControllerFactory = { WebKitReaderViewController() },
        statisticPreferenceStore: DocumentStatisticPreferenceStore = .shared,
        appearancePreferenceStore: AppearancePreferenceStore = .shared,
        readerBehaviorPreferenceStore: ReaderBehaviorPreferenceStore = .shared,
        sourceLoader: @escaping SourceLoader = MarkdownReaderDocument.loadSource,
        fileMonitorFactory: @escaping FileMonitorFactory = { url, onChange in
            FileChangeMonitor(fileURL: url, onChange: onChange)
        },
        scrollPersistenceDebounceInterval: TimeInterval = 1.0,
        wikiLinkIndexProvider: WikiLinkIndexProvider? = nil,
        librarySnapshotProvider: @escaping LibrarySnapshotProvider = { LibraryController.shared.snapshot },
        sourceLoadErrorHandler: @escaping @MainActor (Error) -> Void = { NSApp.presentError($0) },
        editConflictResolver: @escaping EditConflictResolver = MarkdownEditSession.presentConflict,
        editFileWriter: @escaping MarkdownEditSession.FileWriter = MarkdownEditSession.replaceContents,
        autosaveDelay: TimeInterval = 1.0,
        liveRenderInterval: TimeInterval = 0.1
    ) {
        self.assetResolver = assetResolver
        self.scrollStateStore = scrollStateStore
        self.injectedRenderScheduler = renderScheduler
        self.markdownLinkOpener = markdownLinkOpener
        self.linkTargetHandler = linkTargetHandler
        self.readerControllerFactory = readerControllerFactory
        self.statisticPreferenceStore = statisticPreferenceStore
        self.appearancePreferenceStore = appearancePreferenceStore
        self.readerBehaviorPreferenceStore = readerBehaviorPreferenceStore
        self.sourceLoader = sourceLoader
        self.fileMonitorFactory = fileMonitorFactory
        self.scrollPersistenceDebounceInterval = scrollPersistenceDebounceInterval
        self.wikiLinkIndexProvider = wikiLinkIndexProvider ?? {
            MarkdownReaderDocument.wikiLinkIndex(in: librarySnapshotProvider())
        }
        self.sourceLoadErrorHandler = sourceLoadErrorHandler
        self.editMode = MarkdownEditCoordinator(configuration: .init(
            resolveConflict: editConflictResolver,
            autosaveDelay: autosaveDelay,
            liveRenderInterval: liveRenderInterval,
            fileWriter: editFileWriter
        ))
        super.init()
        editMode.delegate = self
        observeLibraryChanges()
    }

    override class var autosavesInPlace: Bool {
        false
    }

    override class var readableTypes: [String] {
        ["dev.wafer.markdown", "net.daringfireball.markdown"]
    }

    override class var writableTypes: [String] {
        []
    }

    override func makeWindowControllers() {
        let readerController = makeReaderController()
        let windowController = DocumentHostWindowController(
            tab: DocumentTab(document: self, readerController: readerController),
            cascadeFrom: initialCascadeSourceWindow,
            statisticPreferenceStore: statisticPreferenceStore,
            appearancePreferenceStore: appearancePreferenceStore
        )
        addWindowController(windowController)
        self.readerController = readerController
        self.documentWindowController = windowController
        initialCascadeSourceWindow = nil
        pushWindowLevelStateToHost()
        startShowingFile(in: readerController)
    }

    /// Creates this document's reading surface inside an existing host window
    /// (a secondary tab). Mirrors makeWindowControllers minus window creation;
    /// the host selects the tab and pulls window-level state afterwards.
    func attachAsTab(to host: DocumentHostWindowController) -> DocumentTab {
        let readerController = makeReaderController()
        self.readerController = readerController
        self.documentWindowController = host
        let tab = DocumentTab(document: self, readerController: readerController)
        startShowingFile(in: readerController)
        return tab
    }

    /// Shows the loading placeholder, watches the file, and renders the
    /// source if it is already loaded.
    private func startShowingFile(in readerController: WebKitReaderViewController) {
        readerController.displayLoading(for: fileURL?.lastPathComponent ?? "Markdown")
        if let fileURL {
            startFileMonitor(for: fileURL)
        }
        scheduleRenderIfPossible()
    }

    /// True when this document is the visible tab of its host (or has no
    /// tabbed host at all). Inactive tabs keep rendering into their own
    /// readers but must never touch window-level chrome.
    var isActiveInHost: Bool {
        guard let host = documentWindowController as? DocumentHostWindowController else {
            return true
        }

        return host.tabs.indices.contains(host.activeTabIndex) && host.activeTab.document === self
    }

    /// Pushes every piece of window-level state this document owns (title,
    /// statistics, sidebar content, outline highlight, history controls).
    /// Called on activation by the host and after local changes.
    func pushWindowLevelStateToHost() {
        guard let documentWindowController, isActiveInHost else {
            return
        }

        documentWindowController.setDisplayedTitle(fileURL?.lastPathComponent ?? "Markdown")
        documentWindowController.apply(documentStatistics: currentStatistics)
        documentWindowController.apply(sidebarEntries: currentSidebarEntries, outlineItems: currentOutlineItems)
        documentWindowController.setActiveOutlineAnchorID(currentActiveHeadingID)
        documentWindowController.updateNavigationControls(
            canGoBack: canGoBack,
            canGoForward: canGoForward
        )
        documentWindowController.setEditingActive(isEditing)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard data.count <= Self.maximumSourceByteCount else {
            throw Self.tooLargeError(for: fileURL)
        }
        let loaded = try Self.decodeSource(data)

        MainActor.assumeIsolated {
            source = loaded
            scheduleRenderIfPossible()
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        throw CocoaError(.featureUnsupported)
    }

    override func close() {
        // Last chance for edits that reached here without an interactive
        // flush (for example an inactive tab in a closing window).
        if isEditing {
            _ = flushEdits(interactive: false)
        }
        editMode.stop()
        renderToken = UUID()
        abandonSourceRead()
        initialSourceFailureHandler = nil
        deferredReload = nil
        NotificationCenter.default.removeObserver(self, name: .libraryDidChange, object: nil)
        stopFileMonitor()
        persistCurrentScrollFraction()
        scrollPersistenceWorkItem?.cancel()
        renderWorkItem?.cancel()
        renderWorker.cancel()
        readerController?.shutdown()
        MarkdownDocumentOpener.release(document: self)
        super.close()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(reloadDocument(_:)):
            return fileURL != nil
        case #selector(goBackInHistory(_:)):
            return canGoBack
        case #selector(goForwardInHistory(_:)):
            return canGoForward
        case #selector(toggleEditing(_:)):
            (item as? NSMenuItem)?.state = isEditing ? .on : .off
            return isEditing || (hasLoadedSource && fileURL != nil)
        case #selector(saveEdits(_:)):
            return isEditing
        case #selector(revertEdits(_:)):
            return editMode.canRevert
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: - History

    @objc func goBackInHistory(_ sender: Any?) {
        guard canGoBack, let currentFileURL = fileURL else { return }
        var history = navigationHistory
        guard
            let target = history.goBack(from: WindowNavigationHistoryEntry(fileURL: currentFileURL))
        else {
            return
        }

        navigate(to: target.fileURL, anchorID: target.anchorID, historyAfterNavigation: history)
    }

    @objc func goForwardInHistory(_ sender: Any?) {
        guard canGoForward, let currentFileURL = fileURL else { return }
        var history = navigationHistory
        guard
            let target = history.goForward(from: WindowNavigationHistoryEntry(fileURL: currentFileURL))
        else {
            return
        }

        navigate(to: target.fileURL, anchorID: target.anchorID, historyAfterNavigation: history)
    }

    private var canGoBack: Bool { !loadState.isNavigating && navigationHistory.canGoBack }
    private var canGoForward: Bool { !loadState.isNavigating && navigationHistory.canGoForward }

    private func updateWindowNavigationControls() {
        guard isActiveInHost else {
            return
        }

        documentWindowController?.updateNavigationControls(
            canGoBack: canGoBack,
            canGoForward: canGoForward
        )
    }

    // MARK: - Rendering

    private func scheduleRenderIfPossible() {
        scheduleRenderIfPossible(initialScrollFractionOverride: nil)
    }

    private func scheduleRenderIfPossible(
        initialScrollFractionOverride: Double?,
        showsLoadingPlaceholder: Bool = true,
        live: Bool = false
    ) {
        guard let source, let readerController else {
            return
        }

        let fileURL = fileURL
        let restoreFraction: Double?
        if live {
            restoreFraction = nil
        } else if pendingAnchor.id == nil {
            restoreFraction = initialScrollFractionOverride ?? fileURL.flatMap {
                scrollStateStore.load(for: $0, fingerprint: source.fingerprint)?.fraction
            }
        } else {
            restoreFraction = nil
        }
        let token = UUID()
        renderToken = token

        renderWorkItem?.cancel()
        if showsLoadingPlaceholder {
            currentStatistics = nil
            currentActiveHeadingID = nil
            readerController.displayLoading(for: fileURL?.lastPathComponent ?? "Markdown")
            if isActiveInHost {
                documentWindowController?.apply(documentStatistics: nil)
                documentWindowController?.setActiveOutlineAnchorID(nil)
            }
        }
        let palette = ReaderTheme.current
        let wikiLinkIndex = wikiLinkIndexProvider()
        lastRenderedWikiLinkIndex = wikiLinkIndex
        renderedPalette = palette
        renderWorkItem = scheduleRender(source.sourceText, fileURL, palette, wikiLinkIndex) { [weak self] output in
            guard let self, self.renderToken == token else {
                return
            }

            self.lastOutputHadWikiLinks = output.hasWikiLinks
            if live {
                self.applyLiveRender(output)
                return
            }
            self.currentStatistics = output.statistics
            self.currentSidebarEntries = output.sidebarEntries
            self.currentOutlineItems = output.outlineItems
            if self.isActiveInHost {
                self.documentWindowController?.apply(documentStatistics: output.statistics)
                self.documentWindowController?.apply(sidebarEntries: output.sidebarEntries, outlineItems: output.outlineItems)
            }
            if let anchorID = self.pendingAnchor.id {
                self.pendingAnchor = .afterPageLoad(anchorID)
            }
            self.readerController?.apply(renderOutput: output, initialScrollFraction: restoreFraction)
        }
    }

    /// Edit-mode renders carry source-line annotations; each request says so
    /// itself, so the worker keeps no flag between requests.
    private func scheduleRender(
        _ source: String,
        _ baseURL: URL?,
        _ palette: ReaderThemePalette,
        _ wikiLinkIndex: WikiLinkIndex?,
        completion: @escaping (WebKitRenderOutput) -> Void
    ) -> DispatchWorkItem {
        if let injectedRenderScheduler {
            return injectedRenderScheduler(source, baseURL, palette, wikiLinkIndex, completion)
        }

        return renderWorker.schedule(
            source: source,
            baseURL: baseURL,
            palette: palette,
            wikiLinkIndex: wikiLinkIndex,
            annotatesSourceLines: isEditing,
            completion: completion
        )
    }

    /// Typing must stay cheap: only chrome state that changed is pushed,
    /// and the page is patched in place.
    private func applyLiveRender(_ output: WebKitRenderOutput) {
        let statisticsChanged = currentStatistics != output.statistics
        let sidebarChanged = currentSidebarEntries != output.sidebarEntries
            || currentOutlineItems != output.outlineItems
        currentStatistics = output.statistics
        currentSidebarEntries = output.sidebarEntries
        currentOutlineItems = output.outlineItems
        if isActiveInHost {
            if statisticsChanged {
                documentWindowController?.apply(documentStatistics: output.statistics)
            }
            if sidebarChanged {
                documentWindowController?.apply(sidebarEntries: output.sidebarEntries, outlineItems: output.outlineItems)
            }
        }
        readerController?.applyLiveUpdate(renderOutput: output, editorPosition: editMode.editorPositionForPreview) { [weak self] patched in
            // After a full load the navigation callback aligns instead.
            guard let self, patched else { return }
            self.editMode.previewDidPatch()
        }
    }

    /// The library's wiki-link index, or nil while no library is open.
    static func wikiLinkIndex(in snapshot: LibrarySnapshot) -> WikiLinkIndex? {
        snapshot.files.isEmpty ? nil : snapshot.wikiLinkIndex
    }

    private func observeLibraryChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLibraryDidChangeForWikiLinks(_:)),
            name: .libraryDidChange,
            object: nil
        )
    }

    @objc private func handleLibraryDidChangeForWikiLinks(_ notification: Notification) {
        guard notification.userInfo?["contentChanged"] as? Bool != false, lastOutputHadWikiLinks else {
            return
        }

        let newIndex = wikiLinkIndexProvider()
        guard newIndex != lastRenderedWikiLinkIndex else {
            return
        }

        rerenderPreservingScroll()
    }

    func applyThemeIfNeeded() {
        let palette = ReaderTheme.current
        guard palette != renderedPalette, let readerController, readerController.isContentReadyForExport else { return }
        renderedPalette = palette
        readerController.updateTheme(palette)
    }

    private func rerenderPreservingScroll() {
        let fraction = readerController?.currentScrollFraction ?? 0
        let restoreFraction = fraction >= 0.98 ? 1.0 : fraction
        scheduleRenderIfPossible(
            initialScrollFractionOverride: restoreFraction,
            showsLoadingPlaceholder: false
        )
    }

    // MARK: - Loading

    func reloadFromDiskIfNeeded() {
        guard readerBehaviorPreferenceStore.automaticallyReloadsDocuments else {
            return
        }

        performReloadFromDisk()
    }

    @objc func reloadDocument(_ sender: Any?) {
        if isEditing, !flushEdits(interactive: true) {
            return
        }
        performReloadFromDisk(forceRender: true)
    }

    private func performReloadFromDisk(forceRender: Bool = false) {
        guard loadState == .idle else {
            deferredReload = (deferredReload ?? false) || forceRender
            return
        }
        guard let fileURL else {
            return
        }

        readSource(.reloading(fileURL)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let loaded):
                self.applyReloadedSourceIfNeeded(loaded, forceRender: forceRender)
            case .failure(let error):
                if forceRender { self.sourceLoadErrorHandler(error) }
            }
            self.runDeferredReload()
        }
    }

    /// All app-driven source reads, decoding, and hashing run off the main
    /// thread. `state` names the read; a superseding read or close discards
    /// both successful and failed results.
    private func readSource(
        _ state: LoadState,
        completion: @escaping @MainActor (Result<LoadedMarkdownSource, Error>) -> Void
    ) {
        guard let url = state.url else { return }
        loadGeneration += 1
        let generation = loadGeneration
        loadState = state
        let loader = sourceLoader
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try loader(url) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.loadState = .idle
                completion(result)
            }
        }
    }

    /// Discards the read in progress, if any.
    private func abandonSourceRead() {
        loadGeneration += 1
        loadState = .idle
    }

    func loadInitialSource(onFailure: @escaping @MainActor () -> Void) {
        guard source == nil, let fileURL else { return }
        initialSourceFailureHandler = onFailure
        readSource(.opening(fileURL)) { [weak self] result in
            guard let self else { return }
            self.updateWindowNavigationControls()
            switch result {
            case .success(let loaded):
                self.initialSourceFailureHandler = nil
                self.source = loaded
                self.scheduleRenderIfPossible()
                NSDocumentController.shared.noteNewRecentDocumentURL(fileURL)
                self.runDeferredReload()
            case .failure(let error):
                self.initialSourceFailureHandler = nil
                self.deferredReload = nil
                onFailure()
                self.sourceLoadErrorHandler(error)
            }
        }
        updateWindowNavigationControls()
    }

    private func runDeferredReload() {
        guard let forceRender = deferredReload else { return }
        deferredReload = nil
        performReloadFromDisk(forceRender: forceRender)
    }

    private func applyReloadedSourceIfNeeded(_ loadedSource: LoadedMarkdownSource, forceRender: Bool) {
        guard forceRender || loadedSource.fingerprint != source?.fingerprint else {
            return
        }

        if isEditing {
            if !editMode.adoptDiskVersion(loadedSource) {
                // Same bytes (explicit reload): refresh the page, keeping its place.
                rerenderPreservingScroll()
            }
            return
        }

        source = loadedSource
        rerenderPreservingScroll()
    }

    // MARK: - Links

    private func openResolvedLink(_ url: URL) {
        if let wikiDestination = WikiLinkURL.destination(from: url) {
            navigateInCurrentWindow(to: wikiDestination.fileURL, anchorID: wikiDestination.anchorID)
            return
        }

        if let sameDocumentAnchorID = sameDocumentAnchorID(for: url) {
            scrollReaderToHeading(id: sameDocumentAnchorID)
            return
        }

        let target = assetResolver.classify(url)
        switch target {
        case .markdownFile(let markdownURL):
            // The anchor comes from the clicked URL: classify rebuilds the
            // fragment, which can add a layer of percent-encoding.
            markdownLinkOpener(
                MarkdownDocumentOpener.normalizedFileURL(for: markdownURL),
                MarkdownDocumentOpener.anchorID(in: url)
            )
        default:
            linkTargetHandler(target)
        }
    }

    /// Cmd-click / middle-click on an in-content link. Wiki links and local
    /// markdown links open as a new tab in the hosting window; same-document
    /// anchors and external links keep their plain-click behavior.
    private func openResolvedLinkInNewTab(_ url: URL) {
        let host = documentWindowController as? DocumentHostWindowController

        if let wikiDestination = WikiLinkURL.destination(from: url) {
            if let host {
                host.openTab(for: wikiDestination.fileURL, anchorID: wikiDestination.anchorID)
            } else {
                navigateInCurrentWindow(to: wikiDestination.fileURL, anchorID: wikiDestination.anchorID)
            }
            return
        }

        if sameDocumentAnchorID(for: url) == nil,
           let host,
           case .markdownFile(let markdownURL) = assetResolver.classify(url) {
            host.openTab(
                for: MarkdownDocumentOpener.normalizedFileURL(for: markdownURL),
                anchorID: MarkdownDocumentOpener.anchorID(in: url)
            )
            return
        }

        openResolvedLink(url)
    }

    private func sameDocumentAnchorID(for url: URL) -> String? {
        guard
            let currentFileURL = fileURL,
            url.isFileURL,
            let anchorID = MarkdownDocumentOpener.anchorID(in: url),
            MarkdownDocumentOpener.normalizedFileURL(for: currentFileURL) == MarkdownDocumentOpener.normalizedFileURL(for: url)
        else {
            return nil
        }

        return anchorID
    }

    private static func defaultOpenMarkdownLink(_ url: URL, _ anchorID: String?) {
        do {
            try MarkdownDocumentOpener.open(url: url, anchorID: anchorID)
        } catch {
            NSApp.presentError(error)
        }
    }

    // MARK: - Scroll persistence

    private func persistScrollFractionImmediately(_ fraction: Double) {
        guard let fileURL, let source else {
            return
        }

        scrollStateStore.save(fraction: fraction, for: fileURL, fingerprint: source.fingerprint)
    }

    private func scheduleScrollFractionPersistence(_ fraction: Double) {
        guard fileURL != nil, hasLoadedSource else {
            return
        }

        pendingScrollFraction = fraction
        scrollPersistenceGeneration += 1
        let generation = scrollPersistenceGeneration

        scrollPersistenceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.scrollPersistenceGeneration == generation else {
                return
            }

            self.scrollPersistenceWorkItem = nil
            guard let pendingScrollFraction = self.pendingScrollFraction else {
                return
            }

            self.pendingScrollFraction = nil
            self.persistScrollFractionImmediately(pendingScrollFraction)
        }
        scrollPersistenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + scrollPersistenceDebounceInterval, execute: workItem)
    }

    private func persistCurrentScrollFraction() {
        scrollPersistenceGeneration += 1
        scrollPersistenceWorkItem?.cancel()
        scrollPersistenceWorkItem = nil
        pendingScrollFraction = nil

        guard let fraction = readerController?.currentScrollFraction else {
            return
        }

        persistScrollFractionImmediately(fraction)
    }

    // MARK: - Reader and file monitor

    private func makeReaderController() -> WebKitReaderViewController {
        let readerController = readerControllerFactory()
        readerController.onOpenLink = { [weak self] url in
            self?.openResolvedLink(url)
        }
        readerController.onOpenLinkInNewTab = { [weak self] url in
            self?.openResolvedLinkInNewTab(url)
        }
        readerController.onScrollPositionChange = { [weak self] fraction in
            self?.scheduleScrollFractionPersistence(fraction)
        }
        readerController.onActiveHeadingChange = { [weak self] anchorID in
            self?.currentActiveHeadingID = anchorID
            if self?.isActiveInHost == true {
                self?.documentWindowController?.setActiveOutlineAnchorID(anchorID)
            }
        }
        readerController.onLiveScroll = { [weak self] line in
            self?.editMode.previewDidScroll(toSourceLine: line)
        }
        readerController.onNavigationFinished = { [weak self, weak readerController] in
            self?.consumePendingAnchorIfNeeded(using: readerController)
            self?.applyThemeIfNeeded()
            self?.editMode.previewDidLoadPage()
        }
        return readerController
    }

    private func startFileMonitor(for fileURL: URL) {
        stopFileMonitor()

        let monitor = fileMonitorFactory(fileURL) { [weak self] in
            self?.reloadFromDiskIfNeeded()
        }
        fileMonitor = monitor
        monitor.start()
    }

    private func stopFileMonitor() {
        fileMonitor?.stop()
        fileMonitor = nil
    }

    // MARK: - Navigation

    func navigateToAnchor(id: String) {
        guard !id.isEmpty else {
            return
        }

        if let readerController, readerController.isContentReadyForExport {
            pendingAnchor = .none
            scrollReaderToHeading(id: id)
        } else {
            pendingAnchor = .afterPageLoad(id)
        }
    }

    /// Scrolls the reader to a heading (outline, anchor links). In edit mode
    /// the page reports the scroll like any other and the editor follows.
    func scrollReaderToHeading(id: String) {
        readerController?.scrollToHeading(id: id)
    }

    private func consumePendingAnchorIfNeeded(using readerController: WebKitReaderViewController?) {
        guard
            case .afterPageLoad(let anchorID) = pendingAnchor,
            let readerController, readerController.isContentReadyForExport
        else {
            return
        }

        pendingAnchor = .none
        scrollReaderToHeading(id: anchorID)
    }

    func navigateInCurrentWindow(to url: URL, anchorID: String? = nil) {
        navigate(to: url, anchorID: anchorID, historyAfterNavigation: nil)
    }

    private func navigate(to url: URL, anchorID: String?, historyAfterNavigation: WindowNavigationHistory?) {
        let normalizedURL = MarkdownDocumentOpener.normalizedFileURL(for: url)
        guard MarkdownDocumentOpener.supports(url: normalizedURL) else {
            return
        }

        guard fileURL != normalizedURL else {
            // Selecting the opening document again must keep its initial read.
            if source == nil {
                if loadState.url != normalizedURL, let initialSourceFailureHandler {
                    loadInitialSource(onFailure: initialSourceFailureHandler)
                }
                if let anchorID { navigateToAnchor(id: anchorID) }
                return
            }
            if loadState.isNavigating {
                // Coming back to the shown file drops the pending navigation.
                abandonSourceRead()
            }
            if let historyAfterNavigation { navigationHistory = historyAfterNavigation }
            updateWindowNavigationControls()
            if let anchorID, !anchorID.isEmpty {
                navigateToAnchor(id: anchorID)
            }
            runDeferredReload()
            return
        }

        // Unsaved edits are saved before leaving; a cancelled conflict stays put.
        guard flushEdits(interactive: true) else {
            return
        }

        persistCurrentScrollFraction()
        readSource(.navigating(normalizedURL)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let loaded):
                // The editor stayed editable during the read: save what was
                // typed meanwhile before it shows the new file, and stay on
                // this file if that save fails or is cancelled.
                guard self.flushEdits(interactive: true) else {
                    self.updateWindowNavigationControls()
                    break
                }
                // A conflict prompt runs the run loop; a reload of this file
                // that began meanwhile must not land on the next one.
                self.abandonSourceRead()
                self.replaceCurrentFile(with: loaded, fileURL: normalizedURL,
                    anchorID: anchorID, historyAfterNavigation: historyAfterNavigation)
            case .failure(let error):
                self.updateWindowNavigationControls()
                if !self.hasLoadedSource {
                    let cleanup = self.initialSourceFailureHandler
                    self.initialSourceFailureHandler = nil
                    cleanup?()
                }
                self.sourceLoadErrorHandler(error)
            }
            self.runDeferredReload()
        }
        updateWindowNavigationControls()
    }

    private func replaceCurrentFile(
        with loadedSource: LoadedMarkdownSource,
        fileURL: URL,
        anchorID: String? = nil,
        historyAfterNavigation: WindowNavigationHistory?
    ) {
        // Publish history only after the source has loaded successfully.
        if let historyAfterNavigation {
            navigationHistory = historyAfterNavigation
        } else if hasLoadedSource, let departingFileURL = self.fileURL {
            navigationHistory.push(departing: WindowNavigationHistoryEntry(fileURL: departingFileURL))
        }
        updateWindowNavigationControls()
        initialSourceFailureHandler = nil

        stopFileMonitor()
        self.fileURL = fileURL
        source = loadedSource
        currentActiveHeadingID = nil
        if let anchorID, !anchorID.isEmpty {
            pendingAnchor = .beforeRender(anchorID)
        } else {
            pendingAnchor = .none
        }
        OpenDocumentRegistry.shared.reindex(self)
        NSDocumentController.shared.noteNewRecentDocumentURL(fileURL)

        startFileMonitor(for: fileURL)
        if isActiveInHost {
            documentWindowController?.setDisplayedTitle(fileURL.lastPathComponent)
        }
        (documentWindowController as? DocumentHostWindowController)?.refreshTabTitles()
        if isEditing {
            loadCurrentFileIntoEditor()
        }
        scheduleRenderIfPossible()
    }

    // MARK: - Edit mode

    var isEditing: Bool {
        editMode.isEditing
    }

    var editorControllerForTesting: MarkdownSourceEditorViewController? { editMode.editor }

    /// The editor to show beside this document's reader while editing.
    var editorPaneController: NSViewController? {
        isEditing ? editMode.editor : nil
    }

    @objc func toggleEditing(_ sender: Any?) {
        if isEditing {
            endEditing()
        } else {
            beginEditing()
        }
    }

    @objc func saveEdits(_ sender: Any?) {
        flushEdits(interactive: true)
    }

    /// Restores the text from when the editor last loaded the file, as one
    /// undoable edit that autosave then writes.
    @objc func revertEdits(_ sender: Any?) {
        editMode.revertToBaseline()
    }

    /// Opens the source editor to the left of the reader, which becomes a
    /// live preview. The page is not reloaded: one render adds source-line
    /// annotations to the blocks already on screen. Read-only files are
    /// refused with an explanation.
    func beginEditing() {
        guard !isEditing, hasLoadedSource, let fileURL, let readerController else { return }
        guard Self.isWritable(fileURL) else {
            sourceLoadErrorHandler(CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: fileURL]))
            return
        }

        let editor = editMode.start()
        loadCurrentFileIntoEditor()
        guard isEditing else { return }

        // The pane starts closed with the editor already at its final width,
        // so it can be near the reader's position before any of it shows; the
        // exact line follows once the page reports it.
        documentWindowController?.setEditorPane(editor, for: self, animated: true)
        editor.scroll(toFraction: readerController.currentScrollFraction)
        editMode.observeDeactivation()
        pushEditingStateToHost()
        editMode.renderLive()
        editor.focus()
    }

    /// Saves and closes the editor. Returns false when unsaved edits could
    /// not be saved and the user kept them.
    @discardableResult
    func endEditing() -> Bool {
        guard isEditing else { return true }
        guard flushEdits(interactive: true) else { return false }

        if let text = editMode.editor?.text {
            source?.sourceText = text
        }
        tearDownEditing()
        // The final text without annotations, patched into the same page.
        scheduleRenderIfPossible(initialScrollFractionOverride: nil, showsLoadingPlaceholder: false, live: true)
        return true
    }

    /// Saves unsaved editor text. Returns true when nothing unsaved remains:
    /// the text was saved or unchanged, or the user discarded the edits.
    @discardableResult
    func flushEdits(interactive: Bool) -> Bool {
        editMode.flush(interactive: interactive)
    }

    /// Saves every open document's editor text, prompting on conflicts.
    /// Returns false if any document kept unsaved edits (quit is cancelled).
    static func flushAllEdits() -> Bool {
        for case let document as MarkdownReaderDocument in NSDocumentController.shared.documents {
            guard document.flushEdits(interactive: true) else { return false }
        }
        return true
    }

    static func isWritable(_ url: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: url.resolvingSymlinksInPath().path)
    }

    /// Opens the current file in the editor, after entering edit mode or
    /// navigating while editing. A read-only file ends edit mode instead.
    private func loadCurrentFileIntoEditor() {
        guard isEditing, let fileURL, var source else { return }
        guard Self.isWritable(fileURL) else {
            // Navigated to a read-only file: the previous file was already saved.
            tearDownEditing()
            sourceLoadErrorHandler(CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: fileURL]))
            return
        }

        source.sourceText = MarkdownTextFormat.normalizingLineEndings(source.sourceText)
        self.source = source
        editMode.load(source, fileURL: fileURL)
    }

    private func tearDownEditing() {
        editMode.end()
        readerController?.endLivePreview()
        documentWindowController?.setEditorPane(nil, for: self, animated: true)
        if isActiveInHost {
            readerController?.focusContent()
        }
        pushEditingStateToHost()
    }

    private func pushEditingStateToHost() {
        guard isActiveInHost else { return }
        documentWindowController?.setEditingActive(isEditing)
    }

    /// The largest Markdown file Wafer opens, 32 MB as Finder counts it: far
    /// above real notes and generated references, and small enough that
    /// parsing, rendering, and the editor stay usable. Larger files are
    /// refused as a whole, never read, shown, or edited in part.
    nonisolated static let maximumSourceByteCount = 32_000_000

    /// The production source loader: reads, decodes, and fingerprints a file.
    nonisolated static func loadSource(from fileURL: URL) throws -> LoadedMarkdownSource {
        let data: Data
        do {
            data = try BoundedFileReader.read(from: fileURL, maximumByteCount: maximumSourceByteCount)
        } catch BoundedFileReader.ReadError.tooLarge {
            throw tooLargeError(for: fileURL)
        }
        return try decodeSource(data)
    }

    nonisolated private static func decodeSource(_ data: Data) throws -> LoadedMarkdownSource {
        guard let decoded = MarkdownTextFormat.decode(data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }

        return LoadedMarkdownSource(
            sourceText: decoded.text,
            fingerprint: FileFingerprint.sha256Hex(for: data),
            format: decoded.format
        )
    }

    /// "The item X couldn't be opened because it is too large", with the limit.
    nonisolated static func tooLargeError(for fileURL: URL?) -> CocoaError {
        let limit = ByteCountFormatter.string(fromByteCount: Int64(maximumSourceByteCount), countStyle: .file)
        var userInfo: [String: Any] = [
            NSLocalizedRecoverySuggestionErrorKey: "Wafer opens Markdown files up to \(limit).",
        ]
        if let fileURL {
            userInfo[NSURLErrorKey] = fileURL
            userInfo[NSFilePathErrorKey] = fileURL.path
        }
        return CocoaError(.fileReadTooLarge, userInfo: userInfo)
    }
}

extension MarkdownReaderDocument: MarkdownEditCoordinatorDelegate {
    var livePreviewReader: WebKitReaderViewController? {
        readerController
    }

    func editCoordinator(_ coordinator: MarkdownEditCoordinator, renderLive text: String) {
        source?.sourceText = text
        scheduleRenderIfPossible(initialScrollFractionOverride: nil, showsLoadingPlaceholder: false, live: true)
    }

    func editCoordinator(
        _ coordinator: MarkdownEditCoordinator,
        didUpdateDiskFingerprint fingerprint: String,
        format: MarkdownTextFormat
    ) {
        source?.fingerprint = fingerprint
        source?.format = format
    }
}

/// A file's decoded text, its on-disk format, and the fingerprint of its bytes.
struct LoadedMarkdownSource: Sendable {
    var sourceText: String
    var fingerprint: String
    var format: MarkdownTextFormat = .default
}
