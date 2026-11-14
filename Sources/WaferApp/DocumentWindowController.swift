import AppKit
import QuartzCore
import WaferCore
import WebKit

@MainActor
private final class DocumentWindow: NSWindow {
    weak var findResponder: WebKitReaderViewController?
    weak var librarySearchResponder: DocumentWindowController?
    weak var exportResponder: DocumentWindowController?

    @objc func showFindInterface(_ sender: Any?) {
        guard let findResponder else {
            return
        }

        findResponder.showFindInterface(sender)
    }

    @objc func findNextMatch(_ sender: Any?) {
        findResponder?.findNextMatch(sender)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        findResponder?.findPreviousMatch(sender)
    }

    @objc func focusLibrarySearch(_ sender: Any?) {
        librarySearchResponder?.focusLibrarySearch(sender)
    }

    @objc func printDocument(_ sender: Any?) {
        exportResponder?.printDocument(sender)
    }

    @objc func exportPDF(_ sender: Any?) {
        exportResponder?.exportPDF(sender)
    }

    @objc func exportHTML(_ sender: Any?) {
        exportResponder?.exportHTML(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48 { // Tab
            if flags == .control,
               NSApp.sendAction(#selector(DocumentHostWindowController.showNextTab(_:)), to: nil, from: self) {
                return true
            }
            if flags == [.control, .shift],
               NSApp.sendAction(#selector(DocumentHostWindowController.showPreviousTab(_:)), to: nil, from: self) {
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    /// Close button and Cmd-W on the last tab: save editor text first; a
    /// cancelled save keeps the window open.
    override func performClose(_ sender: Any?) {
        if let controller = windowController as? DocumentWindowController, !controller.prepareToCloseWindow() {
            return
        }
        super.performClose(sender)
    }

    override func otherMouseUp(with event: NSEvent) {
        switch event.buttonNumber {
        case 3:
            if NSApp.sendAction(#selector(MarkdownReaderDocument.goBackInHistory(_:)), to: nil, from: self) {
                return
            }
        case 4:
            if NSApp.sendAction(#selector(MarkdownReaderDocument.goForwardInHistory(_:)), to: nil, from: self) {
                return
            }
        default:
            break
        }

        super.otherMouseUp(with: event)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(showFindInterface(_:)),
             #selector(findNextMatch(_:)),
             #selector(findPreviousMatch(_:)):
            guard let findResponder else {
                return false
            }
            return findResponder.validateUserInterfaceItem(item)
        case #selector(focusLibrarySearch(_:)):
            return librarySearchResponder?.canFocusLibrarySearch == true
        case #selector(printDocument(_:)),
             #selector(exportPDF(_:)),
             #selector(exportHTML(_:)):
            guard let exportResponder else {
                return false
            }
            return exportResponder.validateUserInterfaceItem(item)
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

@MainActor
class DocumentWindowController: NSWindowController, ThemeApplying, NSUserInterfaceValidations {
    static let initialContentSize = NSSize(width: 1150, height: 760)
    static let minimumWindowSize = NSSize(width: 520, height: 360)
    static let cascadeOffset: CGFloat = 28

    let libraryController: LibraryController
    private let chromeViewController: DocumentChromeViewController
    private let statisticsAccessoryController: DocumentStatisticsAccessoryViewController
    private let navigationAccessoryController = NavigationHistoryAccessoryViewController()
    private let appearancePreferenceStore: AppearancePreferenceStore
    private let exportController: DocumentExportControlling
    /// Created the first time a document here needs a folder grant.
    private var folderAccessNotice: FolderAccessNoticeViewController?
    /// Documents whose notice was dismissed in this window.
    private var dismissedFolderAccessNotices: Set<String> = []

    var onSelectSidebarDocument: ((URL) -> Void)? {
        get { chromeViewController.onSelectSidebarDocument }
        set { chromeViewController.onSelectSidebarDocument = newValue }
    }

    var onSelectSidebarDocumentWithAnchor: ((URL, String?) -> Void)? {
        get { chromeViewController.onSelectSidebarDocumentWithAnchor }
        set { chromeViewController.onSelectSidebarDocumentWithAnchor = newValue }
    }

    var onSelectOutlineItem: ((String) -> Void)? {
        get { chromeViewController.onSelectOutlineItem }
        set { chromeViewController.onSelectOutlineItem = newValue }
    }

    init(
        contentViewController: NSViewController,
        libraryController: LibraryController = LibraryController(),
        cascadeFrom sourceWindow: NSWindow? = nil,
        statisticPreferenceStore: DocumentStatisticPreferenceStore = .shared,
        appearancePreferenceStore: AppearancePreferenceStore = .shared,
        exportController: DocumentExportControlling = DocumentExportController()
    ) {
        let visibleFrame = sourceWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        let initialContentSize = Self.initialContentSize(for: visibleFrame)
        let appearancePreferenceStore = appearancePreferenceStore
        self.appearancePreferenceStore = appearancePreferenceStore
        self.libraryController = libraryController
        self.exportController = exportController
        self.chromeViewController = DocumentChromeViewController(
            contentViewController: contentViewController,
            libraryController: libraryController,
            onEffectiveAppearanceChange: {
                appearancePreferenceStore.applySystemAppearanceIfNeeded()
            }
        )
        self.statisticsAccessoryController = DocumentStatisticsAccessoryViewController(
            preferenceStore: statisticPreferenceStore
        )
        contentViewController.loadViewIfNeeded()
        contentViewController.view.frame = NSRect(origin: .zero, size: initialContentSize)
        let window = DocumentWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.findResponder = Self.findNativeFindResponder(in: contentViewController)
        window.contentViewController = chromeViewController
        window.setContentSize(initialContentSize)
        window.minSize = Self.minimumWindowSize
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.backgroundColor = ReaderTheme.backgroundColor
        window.appearance = ReaderTheme.windowAppearance
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        if let visibleFrame {
            window.setFrame(
                Self.initialFrame(
                    contentSize: initialContentSize,
                    visibleFrame: visibleFrame,
                    cascadeFrom: sourceWindow?.frame
                ),
                display: false
            )
        } else {
            window.center()
        }

        super.init(window: window)
        window.librarySearchResponder = self
        window.exportResponder = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReaderThemeDidChangeNotification(_:)),
            name: .readerThemeDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFolderAccessDidChange(_:)),
            name: .folderAccessDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLocalAssetAccessDenied(_:)),
            name: .localAssetAccessDenied,
            object: nil
        )
        statisticsAccessoryController.onToggleSidebar = { [weak self] in
            self?.toggleSidebar()
        }
        statisticsAccessoryController.onToggleEditing = { [weak self] in
            (self?.document as? MarkdownReaderDocument)?.toggleEditing(nil)
        }
        statisticsAccessoryController.onCopyDocument = { [weak self] in
            (self?.document as? MarkdownReaderDocument)?.copySourceToPasteboard() ?? false
        }
        statisticsAccessoryController.onCopyFile = { [weak self] in
            (self?.document as? MarkdownReaderDocument)?.copyFileToPasteboard() ?? false
        }
        navigationAccessoryController.onGoBack = { [weak self] in
            guard let document = self?.document as? MarkdownReaderDocument else {
                return
            }
            document.goBackInHistory(nil)
        }
        navigationAccessoryController.onGoForward = { [weak self] in
            guard let document = self?.document as? MarkdownReaderDocument else {
                return
            }
            document.goForwardInHistory(nil)
        }
        window.addTitlebarAccessoryViewController(navigationAccessoryController)
        window.addTitlebarAccessoryViewController(statisticsAccessoryController)
        chromeViewController.installCenteredTitleIfNeeded(in: window)
        suppressSystemTitlebarBackground(in: window)
        shouldCascadeWindows = true
        setDisplayedTitle("")
        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .readerThemeDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .folderAccessDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .localAssetAccessDenied, object: nil)
    }

    var hostedContentViewController: NSViewController {
        chromeViewController.contentViewController
    }

    func setHostedContent(_ controller: NSViewController) {
        chromeViewController.setContentViewController(controller)
        (window as? DocumentWindow)?.findResponder = Self.findNativeFindResponder(in: controller)
        refreshFolderAccessNotice()
    }

    /// Shows the editor pane left of the reader, or hides it (nil). Opening
    /// widens the window to the left so the reader keeps its size and place;
    /// closing takes that width back.
    func setEditorPane(_ controller: NSViewController?, animated: Bool) {
        chromeViewController.setEditorPane(controller, animated: animated)
    }

    /// The same for one document's editor. The tab host applies it only to
    /// the selected tab.
    func setEditorPane(_ controller: NSViewController?, for document: MarkdownReaderDocument, animated: Bool) {
        setEditorPane(controller, animated: animated)
    }

    #if DEBUG
    var editorVisibleFrameForTesting: NSRect? {
        get { chromeViewController.editorVisibleFrameOverride }
        set { chromeViewController.editorVisibleFrameOverride = newValue }
    }

    var editorPaneControllerForTesting: NSViewController? {
        chromeViewController.editorPaneController
    }

    var editorPaneWidthForTesting: CGFloat {
        chromeViewController.editorPaneWidthForTesting
    }

    var hostedContentWidthForTesting: CGFloat {
        chromeViewController.hostedContentWidthForTesting
    }

    var isEditorPaneAnimatingForTesting: Bool {
        chromeViewController.isEditorPaneAnimating
    }

    /// Frames and slowest step of the last finished pane animation.
    var lastEditorPaneAnimationStatsForTesting: (frames: Int, slowestStep: TimeInterval)? {
        chromeViewController.lastEditorPaneAnimationStats
    }
    #endif

    func setEditingActive(_ isActive: Bool) {
        statisticsAccessoryController.setEditingActive(isActive)
    }

    #if DEBUG
    var editButtonIsActiveForTesting: Bool {
        statisticsAccessoryController.editButtonIsActiveForTesting
    }
    #endif

    /// Saves unsaved editor text before the window closes.
    func prepareToCloseWindow() -> Bool {
        (document as? MarkdownReaderDocument)?.flushEdits(interactive: true) ?? true
    }

    func installTabStrip(_ stripView: NSView, height: CGFloat) {
        chromeViewController.installTabStrip(stripView, height: height)
    }

    func setTabStripVisible(_ visible: Bool) {
        chromeViewController.setTabStripVisible(visible)
    }

    var isTabStripVisible: Bool {
        chromeViewController.isTabStripVisible
    }

    #if DEBUG
    var displayedStatisticTextForTesting: String? {
        statisticsAccessoryController.displayedTextForTesting
    }

    var displayedWindowTitleForTesting: String {
        chromeViewController.displayedTitleForTesting
    }

    var titleViewHostClassNameForTesting: String? {
        chromeViewController.titleViewHostClassNameForTesting
    }

    var isSidebarVisibleForTesting: Bool {
        chromeViewController.isSidebarVisible
    }

    var librarySearchFieldIsFocusedForTesting: Bool {
        chromeViewController.librarySearchFieldIsFocusedForTesting
    }

    var sidebarModeForTesting: DocumentSidebarMode {
        chromeViewController.sidebarMode
    }

    var sidebarDocumentTitlesForTesting: [String] {
        chromeViewController.sidebarDocumentTitlesForTesting
    }

    var outlineTitlesForTesting: [String] {
        chromeViewController.outlineTitlesForTesting
    }

    var sidebarButtonIsActiveForTesting: Bool {
        statisticsAccessoryController.sidebarButtonIsActiveForTesting
    }

    var isSidebarAttachedForTesting: Bool {
        chromeViewController.isSidebarAttachedForTesting
    }

    var activeOutlineAnchorIDForTesting: String? {
        chromeViewController.activeOutlineAnchorIDForTesting
    }

    var sidebarWidthForTesting: CGFloat {
        chromeViewController.sidebarWidthForTesting
    }

    var sidebarAlphaForTesting: CGFloat {
        chromeViewController.sidebarAlphaForTesting
    }

    var isContentAlignedWithSidebarForTesting: Bool {
        chromeViewController.isContentAlignedWithSidebarForTesting
    }

    static var sidebarAnimationDurationForTesting: TimeInterval {
        DocumentChromeViewController.sidebarAnimationDuration
    }

    func triggerSidebarToggleForTesting() {
        statisticsAccessoryController.triggerSidebarToggleForTesting()
    }

    func handleReaderThemeDidChangeForTesting() {
        handleReaderThemeDidChange()
    }

    func handleEffectiveAppearanceChangeForTesting() {
        appearancePreferenceStore.applySystemAppearanceIfNeeded()
    }
    #endif

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let window else {
            return
        }

        applyCurrentTheme()
        suppressSystemTitlebarBackground(in: window)
        chromeViewController.installCenteredTitleIfNeeded(in: window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else {
                return
            }

            self.chromeViewController.installCenteredTitleIfNeeded(in: window)
            self.suppressSystemTitlebarBackground(in: window)
        }
    }

    #if DEBUG
    func prepareSidebarForAnimatedOpenForTesting() {
        chromeViewController.prepareSidebarForAnimatedOpen()
    }

    func setReducedMotionForTesting(_ value: Bool?) {
        chromeViewController.reducedMotionOverride = value
    }

    func setSidebarModeForTesting(_ mode: DocumentSidebarMode) {
        chromeViewController.setSidebarMode(mode)
    }

    func triggerSidebarDocumentSelectionForTesting(_ url: URL) {
        chromeViewController.triggerSidebarDocumentSelectionForTesting(url)
    }

    func triggerOutlineSelectionForTesting(_ anchorID: String) {
        chromeViewController.triggerOutlineSelectionForTesting(anchorID)
    }
    #endif

    func updateNavigationControls(canGoBack: Bool, canGoForward: Bool) {
        navigationAccessoryController.setNavigationState(canGoBack: canGoBack, canGoForward: canGoForward)
    }

    #if DEBUG
    var navigationBackEnabledForTesting: Bool {
        navigationAccessoryController.backButtonIsEnabledForTesting
    }

    var navigationForwardEnabledForTesting: Bool {
        navigationAccessoryController.forwardButtonIsEnabledForTesting
    }

    func triggerNavigationBackForTesting() {
        navigationAccessoryController.triggerBackForTesting()
    }

    var navigationAccessoryForTesting: NavigationHistoryAccessoryViewController {
        navigationAccessoryController
    }
    #endif

    func apply(documentStatistics: DocumentStatistics?) {
        statisticsAccessoryController.apply(statistics: documentStatistics)
    }

    var canFocusLibrarySearch: Bool {
        libraryController.hasLibrary
    }

    @objc
    func focusLibrarySearch(_ sender: Any?) {
        guard canFocusLibrarySearch else {
            return
        }

        chromeViewController.focusLibrarySearch()
    }

    func setDisplayedTitle(_ title: String) {
        window?.title = title
        chromeViewController.setDisplayedTitle(title)
        refreshFolderAccessNotice()
    }

    func apply(sidebarEntries: [DocumentSidebarEntry], outlineItems: [DocumentOutlineItem]) {
        chromeViewController.apply(sidebarEntries: sidebarEntries, outlineItems: outlineItems)
        // Linked documents outside the granted folders cannot be summarized or opened.
        if let current = sidebarEntries.first(where: \.isCurrent) {
            FolderAccessStore.shared.recordLinkedFiles(
                sidebarEntries.filter { !$0.isCurrent }.map(\.fileURL), forDocumentAt: current.fileURL
            )
        }
        refreshFolderAccessNotice()
    }

    // MARK: - Folder access notice

    #if DEBUG
    var folderAccessNoticeForTesting: FolderAccessNoticeViewController? {
        folderAccessNotice
    }

    var isFolderAccessNoticeVisibleForTesting: Bool {
        folderAccessNotice.map { !$0.isHidden } ?? false
    }
    #endif

    private var activeDocumentURL: URL? {
        (document as? NSDocument)?.fileURL
    }

    /// Shows the notice while the active document needs files the App Sandbox
    /// does not let Wafer read, and hides it otherwise.
    func refreshFolderAccessNotice() {
        let store = FolderAccessStore.shared
        guard store.isSandboxed else { return }
        guard let documentURL = activeDocumentURL,
              !dismissedFolderAccessNotices.contains(FileIdentity.identity(for: documentURL)),
              !store.unreadableFiles(neededByDocumentAt: documentURL).isEmpty else {
            if let folderAccessNotice, !folderAccessNotice.isHidden {
                folderAccessNotice.isHidden = true
                FolderAccessStore.log.info("Hid the folder access notice")
            }
            return
        }

        let notice = installFolderAccessNoticeIfNeeded()
        if notice.isHidden || notice.message.isEmpty {
            FolderAccessStore.log.info("Showing the folder access notice for \(documentURL.lastPathComponent, privacy: .private)")
        }
        let suggestion = store.suggestion(forDocumentAt: documentURL)
            ?? .outOfRange(file: documentURL, folder: documentURL.deletingLastPathComponent())
        let folderPath: String? = if case .folder(let folder, _) = suggestion { folder.path } else { nil }
        notice.show(message: FolderAccessFlow.noticeMessage(for: suggestion, documentName: documentURL.lastPathComponent),
                    folderPath: folderPath)
    }

    private func installFolderAccessNoticeIfNeeded() -> FolderAccessNoticeViewController {
        if let folderAccessNotice { return folderAccessNotice }
        let notice = FolderAccessNoticeViewController()
        notice.onGrantAccess = { [weak self] in
            guard let self, let documentURL = self.activeDocumentURL else { return }
            FolderAccessFlow.requestAccess(forDocumentAt: documentURL, window: self.window) { [weak self] _ in
                self?.refreshFolderAccessNotice()
            }
        }
        notice.onDismiss = { [weak self] in
            guard let self, let documentURL = self.activeDocumentURL else { return }
            self.dismissedFolderAccessNotices.insert(FileIdentity.identity(for: documentURL))
            self.refreshFolderAccessNotice()
        }
        folderAccessNotice = notice
        window?.addTitlebarAccessoryViewController(notice)
        return notice
    }

    @objc private func handleFolderAccessDidChange(_ notification: Notification) {
        refreshFolderAccessNotice()
    }

    /// The scheme handler refused an image: record it for the tab whose
    /// reader requested it.
    @objc private func handleLocalAssetAccessDenied(_ notification: Notification) {
        guard let webView = notification.object as? WKWebView,
              let fileURL = notification.userInfo?["fileURL"] as? URL,
              let documentURL = documentURL(owning: webView) else { return }
        FolderAccessStore.shared.recordUnreadableFile(fileURL, forDocumentAt: documentURL)
    }

    private func documentURL(owning webView: WKWebView) -> URL? {
        if let host = self as? DocumentHostWindowController {
            return host.tabs.first { webView.isDescendant(of: $0.readerController.view) }?.document.fileURL
        }
        return webView.isDescendant(of: hostedContentViewController.view) ? activeDocumentURL : nil
    }

    func setActiveOutlineAnchorID(_ anchorID: String?) {
        chromeViewController.setActiveOutlineAnchorID(anchorID)
    }

    func toggleSidebar() {
        chromeViewController.toggleSidebar()
        statisticsAccessoryController.setSidebarActive(chromeViewController.isSidebarVisible)
    }

    func applyCurrentTheme() {
        window?.backgroundColor = ReaderTheme.backgroundColor
        window?.appearance = ReaderTheme.windowAppearance
        chromeViewController.applyCurrentTheme()
        statisticsAccessoryController.applyCurrentTheme()
        navigationAccessoryController.applyCurrentTheme()
        folderAccessNotice?.applyCurrentTheme()
        if let window {
            suppressSystemTitlebarBackground(in: window)
            chromeViewController.installCenteredTitleIfNeeded(in: window)
        }
    }

    func currentExportContext() -> DocumentExportContext? {
        guard
            let window,
            let readerController = Self.findNativeFindResponder(in: chromeViewController.contentViewController),
            let webView = readerController.webViewForExport
        else {
            return nil
        }

        return DocumentExportContext(
            webView: webView,
            window: window,
            documentURL: (document as? NSDocument)?.fileURL,
            readerController: readerController
        )
    }

    @objc func printDocument(_ sender: Any?) {
        guard let context = currentExportContext() else {
            return
        }

        exportController.printDocument(context.webView, window: context.window)
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let context = currentExportContext() else {
            return
        }

        exportController.exportPDF(from: context)
    }

    @objc func exportHTML(_ sender: Any?) {
        guard let context = currentExportContext() else {
            return
        }

        exportController.exportHTML(from: context)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(printDocument(_:)),
             #selector(exportPDF(_:)):
            return currentExportContext() != nil
        case #selector(exportHTML(_:)):
            guard let context = currentExportContext() else {
                return false
            }
            return exportController.canExportHTML(from: context)
        default:
            return true
        }
    }

    private func suppressSystemTitlebarBackground(in window: NSWindow) {
        WindowChromeSuppression.suppress(in: window)
    }

    private func handleReaderThemeDidChange() {
        applyCurrentTheme()
        (document as? MarkdownReaderDocument)?.applyThemeIfNeeded()
    }

    @objc
    private func handleReaderThemeDidChangeNotification(_ notification: Notification) {
        handleReaderThemeDidChange()
    }

    static func initialContentSize(for visibleFrame: NSRect?) -> NSSize {
        guard let visibleFrame else {
            return initialContentSize
        }

        return NSSize(
            width: min(initialContentSize.width, max(minimumWindowSize.width, visibleFrame.width)),
            height: max(minimumWindowSize.height, visibleFrame.height)
        )
    }

    static func initialFrame(
        contentSize: NSSize,
        visibleFrame: NSRect,
        cascadeFrom sourceFrame: NSRect?
    ) -> NSRect {
        let unclampedOrigin: NSPoint
        if let sourceFrame {
            unclampedOrigin = NSPoint(
                x: sourceFrame.minX + cascadeOffset,
                y: sourceFrame.minY - cascadeOffset
            )
        } else {
            unclampedOrigin = NSPoint(
                x: visibleFrame.midX - (contentSize.width / 2),
                y: visibleFrame.midY - (contentSize.height / 2)
            )
        }

        let clampedOrigin = clampedOrigin(
            unclampedOrigin,
            contentSize: contentSize,
            visibleFrame: visibleFrame
        )

        return NSRect(origin: clampedOrigin, size: contentSize)
    }

    private static func clampedOrigin(
        _ origin: NSPoint,
        contentSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - contentSize.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - contentSize.height)

        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
    }

    private static func findNativeFindResponder(in controller: NSViewController) -> WebKitReaderViewController? {
        if let reader = controller as? WebKitReaderViewController {
            return reader
        }

        for child in controller.children {
            if let reader = findNativeFindResponder(in: child) {
                return reader
            }
        }

        return nil
    }
}
