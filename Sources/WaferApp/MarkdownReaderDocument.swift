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
    typealias MarkdownLinkOpener = @MainActor (_ url: URL, _ anchorID: String?) -> Void
    typealias LinkTargetHandler = @MainActor (LinkTarget) -> Void
    typealias ReaderControllerFactory = () -> WebKitReaderViewController
    typealias SourceLoader = @Sendable (_ fileURL: URL) throws -> LoadedMarkdownSource
    typealias FileMonitorFactory =
        @MainActor (_ fileURL: URL, _ onChange: @escaping () -> Void) -> FileChangeMonitoring

    private let assetResolver: AssetResolver
    private let scrollStateStore: ScrollStateStore
    private let renderWorker: MarkdownRenderWorker
    private let renderScheduler: RenderScheduler
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
    private let editConflictResolver: EditConflictResolver
    private let autosaveDelay: TimeInterval
    private let liveRenderInterval: TimeInterval

    private var sourceText = ""
    private var fileFingerprint = ""
    private weak var readerController: WebKitReaderViewController?
    private weak var documentWindowController: DocumentWindowController?
    private var fileMonitor: FileChangeMonitoring?
    private var renderWorkItem: DispatchWorkItem?
    private var renderToken = UUID()
    private var sourceLoadToken = UUID()
    private var loadingSourceURL: URL?
    private var initialSourceFailureHandler: (@MainActor () -> Void)?
    private var isNavigating = false
    private var deferredReload: Bool?
    private var currentStatistics: DocumentStatistics?
    private var currentSidebarEntries: [DocumentSidebarEntry] = []
    private var currentOutlineItems: [DocumentOutlineItem] = []
    private var currentActiveHeadingID: String?
    private var pendingNavigationAnchorID: String?
    private var consumePendingAnchorOnNextNavigationFinish = false
    private var pendingScrollFraction: Double?
    private var scrollPersistenceWorkItem: DispatchWorkItem?
    private var scrollPersistenceGeneration = 0
    private(set) var navigationHistory = WindowNavigationHistory()
    private var lastRenderedWikiLinkIndex: WikiLinkIndex?
    private var lastOutputHadWikiLinks = false
    private var renderedPalette: ReaderThemePalette?
    private var currentFormat = MarkdownTextFormat.default
    // Edit mode
    private(set) var isEditing = false
    private var editSession: MarkdownEditSession?
    private var editorController: MarkdownSourceEditorViewController?
    private var autosaveWorkItem: DispatchWorkItem?
    private var liveRenderWorkItem: DispatchWorkItem?
    /// The editor has not been aligned with the reader's position yet (edit
    /// mode just started, or another file was loaded). Until it is, neither
    /// pane follows the other, so the reader stays where the user left it.
    private var awaitsEditorAlignment = false
    private var isAligningEditor = false
    private var resignActiveObserver: NSObjectProtocol?
    var initialCascadeSourceWindow: NSWindow?
    var hasLoadedSource: Bool { !fileFingerprint.isEmpty }

    /// Copies the displayed document's Markdown source as plain text (the
    /// editor's current text in edit mode). Returns false while loading.
    @discardableResult
    func copySourceToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard hasLoadedSource else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(editorController?.text ?? sourceText, forType: .string)
    }

    /// Copies the displayed file itself, like Finder's Copy, so pasting into
    /// Finder, Mail, or a chat app attaches the file.
    @discardableResult
    func copyFileToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard hasLoadedSource, let fileURL else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([fileURL as NSURL])
    }

    override init() {
        self.assetResolver = AssetResolver()
        self.scrollStateStore = ScrollStateStore()
        let worker = MarkdownRenderWorker()
        self.renderWorker = worker
        self.renderScheduler = worker.schedule
        self.markdownLinkOpener = MarkdownReaderDocument.defaultOpenMarkdownLink
        self.linkTargetHandler = MarkdownReaderDocument.defaultHandle
        self.readerControllerFactory = { WebKitReaderViewController() }
        self.statisticPreferenceStore = .shared
        self.appearancePreferenceStore = .shared
        self.readerBehaviorPreferenceStore = .shared
        self.sourceLoader = MarkdownReaderDocument.loadSource
        self.fileMonitorFactory = { url, onChange in FileChangeMonitor(fileURL: url, onChange: onChange) }
        self.scrollPersistenceDebounceInterval = 1.0
        self.wikiLinkIndexProvider = MarkdownReaderDocument.defaultWikiLinkIndexProvider
        self.sourceLoadErrorHandler = { NSApp.presentError($0) }
        self.editConflictResolver = MarkdownEditSession.presentConflict
        self.autosaveDelay = 1.0
        self.liveRenderInterval = 0.1
        super.init()
        observeLibraryChanges()
    }

    init(
        assetResolver: AssetResolver = AssetResolver(),
        scrollStateStore: ScrollStateStore = ScrollStateStore(),
        renderScheduler: RenderScheduler? = nil,
        markdownLinkOpener: @escaping MarkdownLinkOpener = MarkdownReaderDocument.defaultOpenMarkdownLink,
        linkTargetHandler: @escaping LinkTargetHandler = MarkdownReaderDocument.defaultHandle,
        readerControllerFactory: @escaping ReaderControllerFactory = { WebKitReaderViewController() },
        statisticPreferenceStore: DocumentStatisticPreferenceStore = .shared,
        appearancePreferenceStore: AppearancePreferenceStore = .shared,
        readerBehaviorPreferenceStore: ReaderBehaviorPreferenceStore = .shared,
        sourceLoader: @escaping SourceLoader = MarkdownReaderDocument.loadSource,
        fileMonitorFactory: @escaping FileMonitorFactory = { url, onChange in
            FileChangeMonitor(fileURL: url, onChange: onChange)
        },
        scrollPersistenceDebounceInterval: TimeInterval = 1.0,
        wikiLinkIndexProvider: @escaping WikiLinkIndexProvider = MarkdownReaderDocument.defaultWikiLinkIndexProvider,
        sourceLoadErrorHandler: @escaping @MainActor (Error) -> Void = { NSApp.presentError($0) },
        editConflictResolver: @escaping EditConflictResolver = MarkdownEditSession.presentConflict,
        autosaveDelay: TimeInterval = 1.0,
        liveRenderInterval: TimeInterval = 0.1
    ) {
        self.assetResolver = assetResolver
        self.scrollStateStore = scrollStateStore
        let worker = MarkdownRenderWorker()
        self.renderWorker = worker
        self.renderScheduler = renderScheduler ?? worker.schedule
        self.markdownLinkOpener = markdownLinkOpener
        self.linkTargetHandler = linkTargetHandler
        self.readerControllerFactory = readerControllerFactory
        self.statisticPreferenceStore = statisticPreferenceStore
        self.appearancePreferenceStore = appearancePreferenceStore
        self.readerBehaviorPreferenceStore = readerBehaviorPreferenceStore
        self.sourceLoader = sourceLoader
        self.fileMonitorFactory = fileMonitorFactory
        self.scrollPersistenceDebounceInterval = scrollPersistenceDebounceInterval
        self.wikiLinkIndexProvider = wikiLinkIndexProvider
        self.sourceLoadErrorHandler = sourceLoadErrorHandler
        self.editConflictResolver = editConflictResolver
        self.autosaveDelay = autosaveDelay
        self.liveRenderInterval = liveRenderInterval
        super.init()
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

        if let fileURL {
            readerController.displayLoading(for: fileURL.lastPathComponent)
            startFileMonitor(for: fileURL)
        } else {
            readerController.displayLoading(for: "Markdown")
        }

        scheduleRenderIfPossible()
    }

    /// Creates this document's reading surface inside an existing host window
    /// (a secondary tab). Mirrors makeWindowControllers minus window creation;
    /// the host selects the tab and pulls window-level state afterwards.
    func attachAsTab(to host: DocumentHostWindowController) -> DocumentTab {
        let readerController = makeReaderController()
        self.readerController = readerController
        self.documentWindowController = host
        let tab = DocumentTab(document: self, readerController: readerController)

        if let fileURL {
            readerController.displayLoading(for: fileURL.lastPathComponent)
            startFileMonitor(for: fileURL)
        } else {
            readerController.displayLoading(for: "Markdown")
        }

        scheduleRenderIfPossible()
        return tab
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
        guard let decoded = MarkdownTextFormat.decode(data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let fingerprint = FileFingerprint.sha256Hex(for: data)

        MainActor.assumeIsolated {
            sourceText = decoded.text
            currentFormat = decoded.format
            fileFingerprint = fingerprint
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
        stopEditingTimers()
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        renderToken = UUID()
        sourceLoadToken = UUID()
        loadingSourceURL = nil
        initialSourceFailureHandler = nil
        isNavigating = false
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
            guard isEditing, let editSession, let editorController else { return false }
            return editorController.text != editSession.baselineText
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

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

    private var canGoBack: Bool { !isNavigating && navigationHistory.canGoBack }
    private var canGoForward: Bool { !isNavigating && navigationHistory.canGoForward }

    private func updateWindowNavigationControls() {
        guard isActiveInHost else {
            return
        }

        documentWindowController?.updateNavigationControls(
            canGoBack: canGoBack,
            canGoForward: canGoForward
        )
    }

    private func scheduleRenderIfPossible() {
        scheduleRenderIfPossible(initialScrollFractionOverride: nil)
    }

    private func scheduleRenderIfPossible(
        initialScrollFractionOverride: Double?,
        showsLoadingPlaceholder: Bool = true,
        live: Bool = false
    ) {
        guard !fileFingerprint.isEmpty, let readerController else {
            return
        }

        renderWorker.annotatesSourceLines = isEditing
        let sourceText = sourceText
        let fileURL = fileURL
        let restoreFraction: Double?
        if live {
            restoreFraction = nil
        } else if pendingNavigationAnchorID == nil {
            restoreFraction = initialScrollFractionOverride ?? fileURL.flatMap {
                scrollStateStore.load(for: $0, fingerprint: fileFingerprint)?.fraction
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
        renderWorkItem = renderScheduler(sourceText, fileURL, palette, wikiLinkIndex) { [weak self] output in
            guard let self, self.renderToken == token else {
                return
            }

            self.lastOutputHadWikiLinks = output.hasWikiLinks
            if live {
                // Typing must stay cheap: only push chrome state that changed.
                let statisticsChanged = self.currentStatistics != output.statistics
                let sidebarChanged = self.currentSidebarEntries != output.sidebarEntries
                    || self.currentOutlineItems != output.outlineItems
                self.currentStatistics = output.statistics
                self.currentSidebarEntries = output.sidebarEntries
                self.currentOutlineItems = output.outlineItems
                if self.isActiveInHost {
                    if statisticsChanged {
                        self.documentWindowController?.apply(documentStatistics: output.statistics)
                    }
                    if sidebarChanged {
                        self.documentWindowController?.apply(sidebarEntries: output.sidebarEntries, outlineItems: output.outlineItems)
                    }
                }
                let editorPosition = self.isEditing && !self.awaitsEditorAlignment
                    ? self.editorController?.currentScrollPosition
                    : nil
                self.readerController?.applyLiveUpdate(renderOutput: output, editorPosition: editorPosition) { [weak self] patched in
                    // After a full load the navigation callback aligns instead.
                    guard let self, patched, self.awaitsEditorAlignment else { return }
                    self.alignEditorToPreview()
                }
                return
            }
            self.currentStatistics = output.statistics
            self.currentSidebarEntries = output.sidebarEntries
            self.currentOutlineItems = output.outlineItems
            if self.isActiveInHost {
                self.documentWindowController?.apply(documentStatistics: output.statistics)
                self.documentWindowController?.apply(sidebarEntries: output.sidebarEntries, outlineItems: output.outlineItems)
            }
            self.consumePendingAnchorOnNextNavigationFinish = self.pendingNavigationAnchorID != nil
            self.readerController?.apply(renderOutput: output, initialScrollFraction: restoreFraction)
        }
    }

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

    static func defaultWikiLinkIndexProvider() -> WikiLinkIndex? {
        let snapshot = LibraryController.shared.snapshot
        return snapshot.files.isEmpty ? nil : snapshot.wikiLinkIndex
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

    private func performReloadFromDisk(forceRender: Bool = false) {
        guard loadingSourceURL == nil else {
            deferredReload = (deferredReload ?? false) || forceRender
            return
        }
        guard let fileURL else {
            return
        }

        loadSource(at: fileURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let source):
                self.applyReloadedSourceIfNeeded(source, forceRender: forceRender)
            case .failure(let error):
                if forceRender { self.sourceLoadErrorHandler(error) }
            }
            self.runDeferredReload()
        }
    }

    /// All app-driven source reads, decoding, and hashing run off the main thread.
    /// A superseding request or close discards both successful and failed results.
    private func loadSource(
        at url: URL,
        completion: @escaping @MainActor (Result<LoadedMarkdownSource, Error>) -> Void
    ) {
        let token = UUID()
        sourceLoadToken = token
        loadingSourceURL = url
        let loader = sourceLoader
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try loader(url) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sourceLoadToken == token else { return }
                self.loadingSourceURL = nil
                completion(result)
            }
        }
    }

    func loadInitialSource(onFailure: @escaping @MainActor () -> Void) {
        guard fileFingerprint.isEmpty, let fileURL else { return }
        initialSourceFailureHandler = onFailure
        isNavigating = true
        updateWindowNavigationControls()
        loadSource(at: fileURL) { [weak self] result in
            guard let self else { return }
            self.isNavigating = false
            self.updateWindowNavigationControls()
            switch result {
            case .success(let source):
                self.initialSourceFailureHandler = nil
                self.sourceText = source.sourceText
                self.currentFormat = source.format
                self.fileFingerprint = source.fingerprint
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
    }

    private func runDeferredReload() {
        guard let forceRender = deferredReload else { return }
        deferredReload = nil
        performReloadFromDisk(forceRender: forceRender)
    }

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
            markdownLinkOpener(
                MarkdownDocumentOpener.normalizedFileURL(for: markdownURL),
                markdownURL.fragment
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
                anchorID: markdownURL.fragment
            )
            return
        }

        openResolvedLink(url)
    }

    private func persistScrollFractionImmediately(_ fraction: Double) {
        guard let fileURL, !fileFingerprint.isEmpty else {
            return
        }

        scrollStateStore.save(fraction: fraction, for: fileURL, fingerprint: fileFingerprint)
    }

    private func scheduleScrollFractionPersistence(_ fraction: Double) {
        guard fileURL != nil, !fileFingerprint.isEmpty else {
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
            self?.previewDidScroll(toSourceLine: line)
        }
        readerController.onNavigationFinished = { [weak self, weak readerController] in
            self?.consumePendingNavigationAnchorIfNeeded(using: readerController)
            self?.applyThemeIfNeeded()
            self?.alignEditingPanesAfterPageLoad()
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

    func navigateToAnchor(id: String) {
        guard !id.isEmpty else {
            return
        }

        pendingNavigationAnchorID = id
        consumePendingAnchorOnNextNavigationFinish = false

        if let readerController, readerController.isContentReadyForExport {
            scrollReaderToHeading(id: id)
            pendingNavigationAnchorID = nil
        } else {
            consumePendingAnchorOnNextNavigationFinish = true
        }
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
            if fileFingerprint.isEmpty {
                if loadingSourceURL != normalizedURL, let initialSourceFailureHandler {
                    loadInitialSource(onFailure: initialSourceFailureHandler)
                }
                if let anchorID { navigateToAnchor(id: anchorID) }
                return
            }
            if isNavigating {
                sourceLoadToken = UUID()
                loadingSourceURL = nil
                isNavigating = false
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
        isNavigating = true
        updateWindowNavigationControls()
        loadSource(at: normalizedURL) { [weak self] result in
            guard let self else { return }
            self.isNavigating = false
            switch result {
            case .success(let source):
                self.replaceCurrentFile(with: source, fileURL: normalizedURL,
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
        sourceText = loadedSource.sourceText
        currentFormat = loadedSource.format
        fileFingerprint = loadedSource.fingerprint
        currentActiveHeadingID = nil
        pendingNavigationAnchorID = anchorID?.isEmpty == false ? anchorID : nil
        consumePendingAnchorOnNextNavigationFinish = false
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

    private func applyReloadedSourceIfNeeded(_ loadedSource: LoadedMarkdownSource, forceRender: Bool) {
        guard forceRender || loadedSource.fingerprint != fileFingerprint else {
            return
        }

        if isEditing {
            applyReloadedSourceWhileEditing(loadedSource)
            return
        }

        sourceText = loadedSource.sourceText
        currentFormat = loadedSource.format
        fileFingerprint = loadedSource.fingerprint
        let fraction = readerController?.currentScrollFraction ?? 0
        let restoreFraction = fraction >= 0.98 ? 1.0 : fraction
        scheduleRenderIfPossible(
            initialScrollFractionOverride: restoreFraction,
            showsLoadingPlaceholder: false
        )
    }

    // MARK: - Edit mode

    var editorControllerForTesting: MarkdownSourceEditorViewController? { editorController }

    /// The editor to show beside this document's reader while editing.
    var editorPaneController: NSViewController? {
        isEditing ? editorController : nil
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
        guard isEditing, let editSession, let editorController else { return }
        editorController.replaceAllUndoably(with: editSession.baselineText)
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

        let editor = MarkdownSourceEditorViewController()
        editor.onTextChange = { [weak self] in
            self?.editorTextDidChange()
        }
        editor.onScroll = { [weak self] position in
            self?.editorDidScroll(to: position)
        }
        editorController = editor
        isEditing = true
        loadCurrentFileIntoEditor()
        guard isEditing else { return }

        // The pane starts closed with the editor already at its final width,
        // so it can be near the reader's position before any of it shows; the
        // exact line follows once the page reports it.
        documentWindowController?.setEditorPane(editor, for: self, animated: true)
        editor.scroll(toFraction: readerController.currentScrollFraction)
        observeResignActive()
        pushEditingStateToHost()
        performLiveRender()
        editor.focus()
    }

    /// Saves and closes the editor. Returns false when unsaved edits could
    /// not be saved and the user kept them.
    @discardableResult
    func endEditing() -> Bool {
        guard isEditing else { return true }
        guard flushEdits(interactive: true) else { return false }

        if let editorController {
            sourceText = editorController.text
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
        guard isEditing, let editSession, let editorController else { return true }
        editorController.commitComposition()
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil

        let outcome = editSession.save(editorController.text, interactive: interactive)
        fileFingerprint = editSession.savedFingerprint
        currentFormat = editSession.format
        switch outcome {
        case .unchanged, .saved:
            return true
        case .reverted(let text):
            editorController.replaceTextPreservingPosition(text)
            sourceText = text
            performLiveRender()
            return true
        case .keptInMemory:
            return false
        }
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

    /// Scrolls the reader to a heading (outline, anchor links). In edit mode
    /// the page reports the scroll like any other and the editor follows.
    func scrollReaderToHeading(id: String) {
        readerController?.scrollToHeading(id: id)
    }

    private func loadCurrentFileIntoEditor() {
        guard let fileURL, let editorController else { return }
        guard Self.isWritable(fileURL) else {
            // Navigated to a read-only file: the previous file was already saved.
            tearDownEditing()
            sourceLoadErrorHandler(CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: fileURL]))
            return
        }

        let text = MarkdownTextFormat.normalizingLineEndings(sourceText)
        sourceText = text
        editSession = MarkdownEditSession(
            fileURL: fileURL,
            text: text,
            fingerprint: fileFingerprint,
            format: currentFormat,
            resolveConflict: editConflictResolver
        )
        editorController.load(text: text)
        awaitsEditorAlignment = true
    }

    private func tearDownEditing() {
        stopEditingTimers()
        isEditing = false
        // The editor stays on screen, inert, while its pane closes.
        editorController?.endSession()
        readerController?.endLivePreview()
        documentWindowController?.setEditorPane(nil, for: self, animated: true)
        if isActiveInHost {
            readerController?.focusContent()
        }
        editorController = nil
        editSession = nil
        awaitsEditorAlignment = false
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        pushEditingStateToHost()
    }

    private func editorTextDidChange() {
        scheduleAutosave()
        scheduleLiveRender()
    }

    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autosaveWorkItem = nil
            self.flushEdits(interactive: true)
        }
        autosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: workItem)
    }

    /// Throttled rather than debounced so the preview keeps up during
    /// continuous typing: at most one render per `liveRenderInterval`.
    private func scheduleLiveRender() {
        guard liveRenderWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.liveRenderWorkItem = nil
            self.performLiveRender()
        }
        liveRenderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + liveRenderInterval, execute: workItem)
    }

    private func performLiveRender() {
        guard isEditing, let editorController else { return }
        sourceText = editorController.text
        scheduleRenderIfPossible(initialScrollFractionOverride: nil, showsLoadingPlaceholder: false, live: true)
    }

    private func stopEditingTimers() {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        liveRenderWorkItem?.cancel()
        liveRenderWorkItem = nil
    }

    private func applyReloadedSourceWhileEditing(_ loadedSource: LoadedMarkdownSource) {
        guard let editSession, let editorController else { return }
        guard loadedSource.fingerprint != editSession.savedFingerprint else {
            // Same bytes (explicit reload): refresh the page, keeping its place.
            rerenderPreservingScroll()
            return
        }

        guard !editSession.hasUnsavedChanges(editorController.text) else {
            // Both sides changed: the save path detects the conflict and asks.
            flushEdits(interactive: true)
            return
        }

        let text = MarkdownTextFormat.normalizingLineEndings(loadedSource.sourceText)
        editSession.rebase(text: text, fingerprint: loadedSource.fingerprint, format: loadedSource.format)
        fileFingerprint = loadedSource.fingerprint
        currentFormat = loadedSource.format
        sourceText = text
        editorController.replaceTextPreservingPosition(text)
        performLiveRender()
    }

    /// After a full page load while editing: align the editor with the
    /// preview once (entering edit mode, navigating), otherwise keep the
    /// preview following the editor.
    private func alignEditingPanesAfterPageLoad() {
        guard isEditing, let editorController, let readerController else { return }
        if awaitsEditorAlignment {
            alignEditorToPreview()
        } else {
            readerController.syncScroll(to: editorController.currentScrollPosition)
        }
    }

    /// Puts the editor at the source line the reader is showing. The page
    /// takes its own position as the synced one, so the reader does not move.
    /// The panes start following each other only once the answer is in:
    /// until then the editor sits at an approximate position that must not
    /// be pushed to the reader.
    private func alignEditorToPreview() {
        guard isEditing, !isAligningEditor, let editorController, let readerController else { return }
        isAligningEditor = true
        readerController.sourceLineAtTop(for: editorController.currentScrollPosition) { [weak self, weak editorController] line in
            guard let self else { return }
            self.isAligningEditor = false
            guard self.isEditing, let editorController, editorController === self.editorController else { return }
            self.awaitsEditorAlignment = false
            if let line {
                editorController.scroll(toSourceLine: line)
            }
        }
    }

    private func editorDidScroll(to position: EditorScrollPosition) {
        guard isEditing, !awaitsEditorAlignment else { return }
        readerController?.syncScroll(to: position)
    }

    private func previewDidScroll(toSourceLine line: Double) {
        guard isEditing, !awaitsEditorAlignment, let editorController else { return }
        editorController.scroll(toSourceLine: line)
        // Scrolling can finish laying out text and change the editor's range.
        readerController?.updateScrollSyncMetrics(editorController.currentScrollPosition)
    }

    private func observeResignActive() {
        guard resignActiveObserver == nil else { return }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Never prompt while the app is in the background.
                _ = self?.flushEdits(interactive: false)
            }
        }
    }

    private func pushEditingStateToHost() {
        guard isActiveInHost else { return }
        documentWindowController?.setEditingActive(isEditing)
    }

    private static func defaultHandle(_ linkTarget: LinkTarget) {
        switch linkTarget {
        case .external(let externalURL):
            NSWorkspace.shared.open(externalURL)
        case .markdownFile(let markdownURL):
            MarkdownDocumentOpener.open(urls: [markdownURL])
        case .otherFile(let fileURL):
            NSWorkspace.shared.open(fileURL)
        case .unresolved:
            break
        }
    }

    private static func defaultOpenMarkdownLink(_ url: URL, _ anchorID: String?) {
        do {
            try MarkdownDocumentOpener.open(url: url, anchorID: anchorID)
        } catch {
            NSApp.presentError(error)
        }
    }

    nonisolated private static func loadSource(from fileURL: URL) throws -> LoadedMarkdownSource {
        let data = try Data(contentsOf: fileURL)
        guard let decoded = MarkdownTextFormat.decode(data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }

        return LoadedMarkdownSource(
            sourceText: decoded.text,
            fingerprint: FileFingerprint.sha256Hex(for: data),
            format: decoded.format
        )
    }

    private func sameDocumentAnchorID(for url: URL) -> String? {
        guard
            let currentFileURL = fileURL,
            url.isFileURL,
            let fragment = url.fragment,
            !fragment.isEmpty,
            MarkdownDocumentOpener.normalizedFileURL(for: currentFileURL) == MarkdownDocumentOpener.normalizedFileURL(for: url)
        else {
            return nil
        }

        return fragment
    }

    private func consumePendingNavigationAnchorIfNeeded(using readerController: WebKitReaderViewController?) {
        guard
            consumePendingAnchorOnNextNavigationFinish,
            let anchorID = pendingNavigationAnchorID,
            let readerController, readerController.isContentReadyForExport
        else {
            return
        }

        consumePendingAnchorOnNextNavigationFinish = false
        pendingNavigationAnchorID = nil
        scrollReaderToHeading(id: anchorID)
    }
}

/// Parsed Markdown is confined to this serial queue and retained only for the last source.
private final class MarkdownRenderWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.wafer.document-render", qos: .userInitiated)
    /// Set on the main thread before scheduling; captured per request.
    var annotatesSourceLines = false
    private let lock = NSLock()
    private var cancellation: WorkCancellation?
    private var parsed: MarkdownDocument?
    private var metadata: DocumentRenderMetadata?

    func cancel() {
        lock.withLock { cancellation?.cancel() }
        queue.async { [weak self] in
            self?.parsed = nil
            self?.metadata = nil
        }
    }

    func schedule(
        source: String, baseURL: URL?, palette: ReaderThemePalette, wikiLinkIndex: WikiLinkIndex?,
        completion: @escaping (WebKitRenderOutput) -> Void
    ) -> DispatchWorkItem {
        let token = WorkCancellation()
        lock.withLock { cancellation?.cancel(); cancellation = token }
        let completionBox = RenderCompletionBox(completion: completion)
        let annotatesSourceLines = annotatesSourceLines
        let workItem = DispatchWorkItem { @Sendable [self] in
            guard !token.isCancelled else { return }
            let renderer = WebKitHTMLRenderer(
                palette: palette,
                wikiLinkIndex: wikiLinkIndex,
                annotatesSourceLines: annotatesSourceLines
            )
            if parsed?.source != source || parsed?.baseURL != baseURL {
                parsed = MarkdownParser().parse(source: source, baseURL: baseURL)
                metadata = nil
            }
            guard !token.isCancelled, let parsed else { return }
            if metadata == nil { metadata = renderer.metadata(for: parsed) }
            guard !token.isCancelled, let metadata else { return }
            let output = renderer.render(document: parsed, metadata: metadata)
            guard !token.isCancelled else { return }
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                completionBox.completion(output)
            }
        }
        queue.async(execute: workItem)
        return workItem
    }
}

private final class RenderCompletionBox: @unchecked Sendable {
    let completion: (WebKitRenderOutput) -> Void

    init(completion: @escaping (WebKitRenderOutput) -> Void) {
        self.completion = completion
    }
}

struct LoadedMarkdownSource: Sendable {
    let sourceText: String
    let fingerprint: String
    var format: MarkdownTextFormat = .default
}
