import AppKit
import QuartzCore
import WaferCore

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

    private let chromeViewController: DocumentChromeViewController
    private let statisticsAccessoryController: DocumentStatisticsAccessoryViewController
    private let navigationAccessoryController = NavigationHistoryAccessoryViewController()
    private let appearancePreferenceStore: AppearancePreferenceStore
    private let exportController: DocumentExportControlling

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
        cascadeFrom sourceWindow: NSWindow? = nil,
        statisticPreferenceStore: DocumentStatisticPreferenceStore = .shared,
        appearancePreferenceStore: AppearancePreferenceStore = .shared,
        exportController: DocumentExportControlling = DocumentExportController()
    ) {
        let visibleFrame = sourceWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        let initialContentSize = Self.initialContentSize(for: visibleFrame)
        let appearancePreferenceStore = appearancePreferenceStore
        self.appearancePreferenceStore = appearancePreferenceStore
        self.exportController = exportController
        self.chromeViewController = DocumentChromeViewController(
            contentViewController: contentViewController,
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
    }

    var hostedContentViewController: NSViewController {
        chromeViewController.contentViewController
    }

    func setHostedContent(_ controller: NSViewController) {
        chromeViewController.setContentViewController(controller)
        (window as? DocumentWindow)?.findResponder = Self.findNativeFindResponder(in: controller)
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
        LibraryController.shared.hasLibrary
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
    }

    func apply(sidebarEntries: [DocumentSidebarEntry], outlineItems: [DocumentOutlineItem]) {
        chromeViewController.apply(sidebarEntries: sidebarEntries, outlineItems: outlineItems)
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

@MainActor
private final class DocumentChromeViewController: NSViewController, ThemeApplying {
    fileprivate static let sidebarAnimationDuration: TimeInterval = 0.26
    private static let titlebarLeadingInset: CGFloat = 88
    private static let titlebarTrailingInset: CGFloat = 154

    private struct WindowSizeLock {
        let frame: NSRect
        let minimumSize: NSSize
        let maximumSize: NSSize
        let minimumContentSize: NSSize
        let maximumContentSize: NSSize
    }

    private(set) var contentViewController: NSViewController
    private let onEffectiveAppearanceChange: () -> Void
    private let contentContainerView = DocumentContentSplitView()
    private let tabStripContainerView = NSView()
    private var tabStripHeightConstraint: NSLayoutConstraint?
    private var installedTabStripHeight: CGFloat = 0
    private let sidebarViewController = DocumentSidebarViewController()
    private let sidebarContainerView = NSView()
    private let sidebarRevealView = NSView()
    private let titlebarBackgroundView = PassthroughTitlebarView()
    private let centeredTitleView = CenteredWindowTitleView()
    private var centeredTitleConstraints: [NSLayoutConstraint] = []
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarRevealWidthConstraint: NSLayoutConstraint?
    private var sidebarAttachmentConstraints: [NSLayoutConstraint] = []
    private var hostedLeadingWithoutSidebarConstraint: NSLayoutConstraint?
    private var hostedLeadingWithSidebarConstraint: NSLayoutConstraint?
    private var hostedTransitionLeadingConstraint: NSLayoutConstraint?
    private var transitionWindowSizeLock: WindowSizeLock?
    fileprivate var reducedMotionOverride: Bool?
    fileprivate static let editorPaneAnimationDuration: TimeInterval = 0.35
    private(set) var editorPaneController: NSViewController?
    /// How much wider the window is for the editor pane, and how far its
    /// right edge moved to make room; closing the pane undoes both.
    private var editorPaneGrowth: CGFloat = 0
    private var editorPaneRightShift: CGFloat = 0
    private var editorPaneAnimation: DisplayLinkedAnimation?
    private(set) var lastEditorPaneAnimationStats: (frames: Int, slowestStep: TimeInterval)?

    var onSelectSidebarDocument: ((URL) -> Void)? {
        get { sidebarViewController.onSelectDocument }
        set { sidebarViewController.onSelectDocument = newValue }
    }

    var onSelectSidebarDocumentWithAnchor: ((URL, String?) -> Void)? {
        get { sidebarViewController.onSelectDocumentWithAnchor }
        set { sidebarViewController.onSelectDocumentWithAnchor = newValue }
    }

    var onSelectOutlineItem: ((String) -> Void)? {
        get { sidebarViewController.onSelectOutlineItem }
        set { sidebarViewController.onSelectOutlineItem = newValue }
    }

    init(contentViewController: NSViewController, onEffectiveAppearanceChange: @escaping () -> Void = {}) {
        self.contentViewController = contentViewController
        self.onEffectiveAppearanceChange = onEffectiveAppearanceChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var isSidebarVisible: Bool {
        !(sidebarContainerView.isHidden)
    }

    var sidebarMode: DocumentSidebarMode {
        sidebarViewController.mode
    }

    #if DEBUG
    var sidebarDocumentTitlesForTesting: [String] {
        sidebarViewController.documentTitlesForTesting
    }

    var outlineTitlesForTesting: [String] {
        sidebarViewController.outlineTitlesForTesting
    }

    var activeOutlineAnchorIDForTesting: String? {
        sidebarViewController.activeOutlineAnchorIDForTesting
    }

    var displayedTitleForTesting: String {
        centeredTitleView.title
    }

    var titleViewHostClassNameForTesting: String? {
        centeredTitleView.superview.map { NSStringFromClass(type(of: $0)) }
    }

    var sidebarWidthForTesting: CGFloat {
        sidebarRevealWidthConstraint?.constant ?? 0
    }

    var sidebarAlphaForTesting: CGFloat {
        sidebarContainerView.alphaValue
    }

    var isSidebarAttachedForTesting: Bool {
        sidebarContainerView.superview === view
    }

    var isContentAlignedWithSidebarForTesting: Bool {
        hostedLeadingWithSidebarConstraint?.isActive == true
    }

    var librarySearchFieldIsFocusedForTesting: Bool {
        sidebarViewController.librarySearchFieldIsFocusedForTesting
    }
    #endif

    override func loadView() {
        let rootView = ThemeObservingView(frame: NSRect(origin: .zero, size: DocumentWindowController.initialContentSize))
        rootView.onEffectiveAppearanceChange = onEffectiveAppearanceChange
        view = rootView
        view.wantsLayer = true

        sidebarContainerView.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainerView.wantsLayer = true
        sidebarContainerView.layer?.backgroundColor = NSColor.clear.cgColor
        sidebarContainerView.layer?.masksToBounds = true
        sidebarContainerView.isHidden = true

        addChild(sidebarViewController)
        let sidebarView = sidebarViewController.view
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarRevealView.translatesAutoresizingMaskIntoConstraints = false
        sidebarRevealView.wantsLayer = true
        sidebarRevealView.layer?.masksToBounds = true
        sidebarContainerView.addSubview(sidebarRevealView)
        sidebarRevealView.addSubview(sidebarView)

        contentContainerView.translatesAutoresizingMaskIntoConstraints = false
        tabStripContainerView.translatesAutoresizingMaskIntoConstraints = false

        titlebarBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        titlebarBackgroundView.wantsLayer = true

        view.addSubview(tabStripContainerView)
        view.addSubview(contentContainerView)
        view.addSubview(titlebarBackgroundView)
        embedContentViewController(contentViewController)
        if let editorPaneController {
            contentContainerView.installEditor(editorPaneController.view)
        }

        sidebarWidthConstraint = sidebarContainerView.widthAnchor.constraint(equalToConstant: DocumentSidebarViewController.sidebarWidth)
        sidebarRevealWidthConstraint = sidebarRevealView.widthAnchor.constraint(equalToConstant: 0)
        hostedLeadingWithoutSidebarConstraint = contentContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        hostedLeadingWithSidebarConstraint = contentContainerView.leadingAnchor.constraint(equalTo: sidebarContainerView.trailingAnchor)
        tabStripHeightConstraint = tabStripContainerView.heightAnchor.constraint(equalToConstant: 0)
        sidebarAttachmentConstraints = [
            sidebarContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarContainerView.topAnchor.constraint(equalTo: tabStripContainerView.bottomAnchor),
            sidebarContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarWidthConstraint!,
        ]

        NSLayoutConstraint.activate([
            sidebarRevealView.leadingAnchor.constraint(equalTo: sidebarContainerView.leadingAnchor),
            sidebarRevealView.topAnchor.constraint(equalTo: sidebarContainerView.topAnchor),
            sidebarRevealView.bottomAnchor.constraint(equalTo: sidebarContainerView.bottomAnchor),
            sidebarRevealWidthConstraint!,

            sidebarView.leadingAnchor.constraint(equalTo: sidebarRevealView.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: sidebarRevealView.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: sidebarRevealView.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalTo: sidebarContainerView.widthAnchor),

            hostedLeadingWithoutSidebarConstraint!,
            contentContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainerView.topAnchor.constraint(equalTo: tabStripContainerView.bottomAnchor),
            contentContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            tabStripContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabStripContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabStripContainerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabStripHeightConstraint!,

            titlebarBackgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titlebarBackgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titlebarBackgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            titlebarBackgroundView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
        applyCurrentTheme()
    }

    func toggleSidebar() {
        setSidebarVisible(!isSidebarVisible)
    }

    func apply(sidebarEntries: [DocumentSidebarEntry], outlineItems: [DocumentOutlineItem]) {
        sidebarViewController.apply(sidebarEntries: sidebarEntries, outlineItems: outlineItems)
    }

    func setActiveOutlineAnchorID(_ anchorID: String?) {
        sidebarViewController.setActiveOutlineAnchorID(anchorID)
    }

    func setSidebarMode(_ mode: DocumentSidebarMode) {
        sidebarViewController.setMode(mode)
    }

    func focusLibrarySearch() {
        if !isSidebarVisible {
            applySidebarVisibility(true)
        }
        sidebarViewController.focusLibrarySearch()
    }

    #if DEBUG
    func triggerSidebarDocumentSelectionForTesting(_ url: URL) {
        sidebarViewController.triggerDocumentSelectionForTesting(url)
    }

    func triggerOutlineSelectionForTesting(_ anchorID: String) {
        sidebarViewController.triggerOutlineSelectionForTesting(anchorID)
    }
    #endif

    func setDisplayedTitle(_ title: String) {
        centeredTitleView.title = title
    }

    func applyCurrentTheme() {
        view.layer?.backgroundColor = ReaderTheme.backgroundColor.cgColor
        sidebarContainerView.layer?.backgroundColor = NSColor.clear.cgColor
        sidebarRevealView.layer?.backgroundColor = ReaderTheme.sidebarBackgroundColor.cgColor
        titlebarBackgroundView.layer?.backgroundColor = ReaderTheme.backgroundColor.cgColor
        centeredTitleView.applyCurrentTheme()
        sidebarViewController.applyCurrentTheme()
        (contentViewController as? ThemeApplying)?.applyCurrentTheme()
        (editorPaneController as? ThemeApplying)?.applyCurrentTheme()
        contentContainerView.applyCurrentThemeRecursively()
        tabStripContainerView.applyCurrentThemeRecursively()
    }

    private func embedContentViewController(_ controller: NSViewController) {
        addChild(controller)
        contentContainerView.embedMainView(controller.view)
    }

    // MARK: Editor pane

    #if DEBUG
    var editorPaneWidthForTesting: CGFloat {
        contentContainerView.editorWidth
    }

    var hostedContentWidthForTesting: CGFloat {
        contentContainerView.mainWidth
    }
    #endif

    var isEditorPaneAnimating: Bool {
        editorPaneAnimation != nil
    }

    func setEditorPane(_ controller: NSViewController?, animated: Bool) {
        // A toggle during the animation completes it first.
        editorPaneAnimation?.finish()
        guard controller !== editorPaneController else {
            return
        }

        switch (editorPaneController, controller) {
        case (nil, let incoming?):
            showEditorPane(incoming, animated: animated)
        case (let outgoing?, nil):
            hideEditorPane(outgoing, animated: animated)
        case (let outgoing?, let incoming?):
            // Another tab's editor: same pane, same window size.
            outgoing.removeFromParent()
            addChild(incoming)
            editorPaneController = incoming
            if isViewLoaded {
                contentContainerView.installEditor(incoming.view)
            }
            (incoming as? ThemeApplying)?.applyCurrentTheme()
        case (nil, nil):
            break
        }
    }

    private func showEditorPane(_ controller: NSViewController, animated: Bool) {
        editorPaneController = controller
        addChild(controller)
        (controller as? ThemeApplying)?.applyCurrentTheme()
        guard isViewLoaded else {
            return
        }
        guard let window = view.window else {
            contentContainerView.installEditor(controller.view)
            return
        }

        endWindowSizeLockIfNeeded()
        view.layoutSubtreeIfNeeded()
        let split = contentContainerView
        let start = window.frame
        let plan = EditorPaneExpansion.plan(
            windowFrame: start,
            contentWidth: split.bounds.width,
            visibleFrame: (window.screen ?? NSScreen.main)?.visibleFrame,
            canResize: !window.styleMask.contains(.fullScreen)
        )
        editorPaneGrowth = plan.growth
        editorPaneRightShift = plan.rightShift
        split.installEditor(controller.view)
        split.beginTransition(revealed: 0, layoutWidth: plan.editorWidth)
        runEditorPaneTransition(animated: animated, in: window) { [weak self, weak window] progress in
            split.setRevealed((plan.editorWidth * progress).rounded())
            window?.setFrame(EditorPaneExpansion.frame(from: start, to: plan.frame, progress: progress), display: true)
            self?.view.layoutSubtreeIfNeeded()
        } completion: {
            split.endTransition()
        }
    }

    private func hideEditorPane(_ controller: NSViewController, animated: Bool) {
        editorPaneController = nil
        let growth = editorPaneGrowth
        let rightShift = editorPaneRightShift
        editorPaneGrowth = 0
        editorPaneRightShift = 0
        guard isViewLoaded, let window = view.window else {
            controller.removeFromParent()
            if isViewLoaded {
                contentContainerView.removeEditor()
            }
            return
        }

        endWindowSizeLockIfNeeded()
        view.layoutSubtreeIfNeeded()
        let split = contentContainerView
        let start = window.frame
        let editorWidth = split.editorWidth
        var end = start
        if !window.styleMask.contains(.fullScreen) {
            end.size.width -= min(growth, max(start.width - window.minSize.width, 0))
            end.origin.x = start.maxX - rightShift - end.width
        }
        split.beginTransition(revealed: editorWidth, layoutWidth: editorWidth)
        runEditorPaneTransition(animated: animated, in: window) { [weak self, weak window] progress in
            split.setRevealed(editorWidth - (editorWidth * progress).rounded())
            window?.setFrame(EditorPaneExpansion.frame(from: start, to: end, progress: progress), display: true)
            self?.view.layoutSubtreeIfNeeded()
        } completion: {
            controller.removeFromParent()
            split.removeEditor()
        }
    }

    private func runEditorPaneTransition(
        animated: Bool,
        in window: NSWindow,
        step: @escaping (CGFloat) -> Void,
        completion: @escaping () -> Void
    ) {
        let reducesMotion = reducedMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reducesMotion, window.isVisible, !window.isMiniaturized else {
            step(1)
            completion()
            view.layoutSubtreeIfNeeded()
            return
        }

        let animation = DisplayLinkedAnimation(duration: Self.editorPaneAnimationDuration, step: step) { [weak self] in
            if let finished = self?.editorPaneAnimation {
                self?.lastEditorPaneAnimationStats = (finished.frameCount, finished.slowestStep)
            }
            self?.editorPaneAnimation = nil
            completion()
            self?.view.layoutSubtreeIfNeeded()
        }
        editorPaneAnimation = animation
        animation.start(in: view)
    }

    func setContentViewController(_ controller: NSViewController) {
        guard controller !== contentViewController else {
            return
        }

        let previousController = contentViewController
        previousController.view.removeFromSuperview()
        previousController.removeFromParent()
        contentViewController = controller
        if isViewLoaded {
            embedContentViewController(controller)
        }
        (controller as? ThemeApplying)?.applyCurrentTheme()
    }

    func installTabStrip(_ stripView: NSView, height: CGFloat) {
        installedTabStripHeight = height
        stripView.translatesAutoresizingMaskIntoConstraints = false
        tabStripContainerView.addSubview(stripView)
        NSLayoutConstraint.activate([
            stripView.leadingAnchor.constraint(equalTo: tabStripContainerView.leadingAnchor),
            stripView.trailingAnchor.constraint(equalTo: tabStripContainerView.trailingAnchor),
            stripView.topAnchor.constraint(equalTo: tabStripContainerView.topAnchor),
            stripView.bottomAnchor.constraint(equalTo: tabStripContainerView.bottomAnchor),
        ])
    }

    func setTabStripVisible(_ visible: Bool) {
        tabStripHeightConstraint?.constant = visible ? installedTabStripHeight : 0
        tabStripContainerView.isHidden = !visible
    }

    var isTabStripVisible: Bool {
        !tabStripContainerView.isHidden
    }

    func installCenteredTitleIfNeeded(in window: NSWindow) {
        let hostView = titlebarHostView(in: window) ?? view
        guard centeredTitleView.superview !== hostView else {
            return
        }

        NSLayoutConstraint.deactivate(centeredTitleConstraints)
        centeredTitleConstraints.removeAll()
        centeredTitleView.removeFromSuperview()
        centeredTitleView.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(centeredTitleView)

        if hostView === view {
            centeredTitleConstraints = [
                centeredTitleView.topAnchor.constraint(equalTo: view.topAnchor),
                centeredTitleView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                centeredTitleView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                centeredTitleView.leadingAnchor.constraint(
                    greaterThanOrEqualTo: view.leadingAnchor,
                    constant: Self.titlebarLeadingInset
                ),
                centeredTitleView.trailingAnchor.constraint(
                    lessThanOrEqualTo: view.trailingAnchor,
                    constant: -Self.titlebarTrailingInset
                ),
            ]
        } else {
            centeredTitleConstraints = [
                centeredTitleView.centerXAnchor.constraint(equalTo: hostView.centerXAnchor),
                centeredTitleView.centerYAnchor.constraint(equalTo: hostView.centerYAnchor),
                centeredTitleView.leadingAnchor.constraint(
                    greaterThanOrEqualTo: hostView.leadingAnchor,
                    constant: Self.titlebarLeadingInset
                ),
                centeredTitleView.trailingAnchor.constraint(
                    lessThanOrEqualTo: hostView.trailingAnchor,
                    constant: -Self.titlebarTrailingInset
                ),
            ]
        }

        NSLayoutConstraint.activate(centeredTitleConstraints)
    }

    private func setSidebarVisible(_ isVisible: Bool) {
        // The sidebar animation locks the window size; let the pane finish.
        editorPaneAnimation?.finish()
        let shouldReduceMotion = reducedMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if shouldReduceMotion {
            applySidebarVisibility(isVisible)
            sidebarContainerView.alphaValue = isVisible ? 1 : 0
            view.layoutSubtreeIfNeeded()
            if isVisible { sidebarViewController.refreshVisibleDocumentSummaries() }
            return
        }

        let startLeading = isSidebarVisible ? DocumentSidebarViewController.sidebarWidth : 0

        if isVisible {
            prepareSidebarForAnimatedOpen()
        } else {
            prepareSidebarForAnimatedClose()
        }

        let endLeading = isVisible ? DocumentSidebarViewController.sidebarWidth : 0
        beginContentTransition(startLeading: startLeading, endLeading: endLeading)
        beginWindowSizeLockIfNeeded()
        view.layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.sidebarAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            hostedTransitionLeadingConstraint?.animator().constant = isVisible ? DocumentSidebarViewController.sidebarWidth : 0
            sidebarRevealWidthConstraint?.animator().constant = isVisible ? DocumentSidebarViewController.sidebarWidth : 0
            sidebarContainerView.animator().alphaValue = isVisible ? 1 : 0
            view.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.finalizeAnimatedSidebarTransition(isVisible: isVisible)
                self.endWindowSizeLockIfNeeded()
                self.view.layoutSubtreeIfNeeded()
                if isVisible { self.sidebarViewController.refreshVisibleDocumentSummaries() }
            }
        }
    }

    fileprivate func prepareSidebarForAnimatedOpen() {
        attachSidebarIfNeeded()
        alignContentWithoutSidebar()
        sidebarContainerView.isHidden = false
        sidebarWidthConstraint?.constant = DocumentSidebarViewController.sidebarWidth
        sidebarRevealWidthConstraint?.constant = 0
        sidebarContainerView.alphaValue = 0
    }

    private func prepareSidebarForAnimatedClose() {
        attachSidebarIfNeeded()
        alignContentWithSidebar()
        sidebarContainerView.isHidden = false
        sidebarWidthConstraint?.constant = DocumentSidebarViewController.sidebarWidth
        sidebarRevealWidthConstraint?.constant = DocumentSidebarViewController.sidebarWidth
        sidebarContainerView.alphaValue = 1
    }

    private func finalizeAnimatedSidebarTransition(isVisible: Bool) {
        if isVisible {
            finishContentTransition(activateSidebarAlignedConstraint: true)
            alignContentWithSidebar()
            sidebarContainerView.isHidden = false
            sidebarWidthConstraint?.constant = DocumentSidebarViewController.sidebarWidth
            sidebarRevealWidthConstraint?.constant = DocumentSidebarViewController.sidebarWidth
            sidebarContainerView.alphaValue = 1
        } else {
            finishContentTransition(activateSidebarAlignedConstraint: false)
            applySidebarVisibility(false)
            sidebarContainerView.alphaValue = 1
        }
    }

    private func applySidebarVisibility(_ isVisible: Bool) {
        if isVisible {
            attachSidebarIfNeeded()
            alignContentWithSidebar()
            sidebarContainerView.isHidden = false
            sidebarWidthConstraint?.constant = DocumentSidebarViewController.sidebarWidth
            sidebarRevealWidthConstraint?.constant = DocumentSidebarViewController.sidebarWidth
            sidebarContainerView.alphaValue = 1
        } else {
            alignContentWithoutSidebar()
            sidebarWidthConstraint?.constant = DocumentSidebarViewController.sidebarWidth
            sidebarRevealWidthConstraint?.constant = 0
            sidebarContainerView.isHidden = true
            detachSidebarIfNeeded()
        }
    }

    private func beginContentTransition(startLeading: CGFloat, endLeading: CGFloat) {
        hostedLeadingWithoutSidebarConstraint?.isActive = false
        hostedLeadingWithSidebarConstraint?.isActive = false

        if hostedTransitionLeadingConstraint == nil {
            hostedTransitionLeadingConstraint = contentContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        }
        hostedTransitionLeadingConstraint?.constant = startLeading
        hostedTransitionLeadingConstraint?.isActive = true

        view.layoutSubtreeIfNeeded()
    }

    private func finishContentTransition(activateSidebarAlignedConstraint: Bool) {
        hostedTransitionLeadingConstraint?.isActive = false
        hostedTransitionLeadingConstraint = nil

        if activateSidebarAlignedConstraint {
            alignContentWithSidebar()
        } else {
            alignContentWithoutSidebar()
        }
    }

    private func attachSidebarIfNeeded() {
        guard sidebarContainerView.superview !== view else {
            return
        }

        view.addSubview(sidebarContainerView, positioned: .above, relativeTo: contentContainerView)
        NSLayoutConstraint.activate(sidebarAttachmentConstraints)
    }

    private func alignContentWithSidebar() {
        hostedLeadingWithoutSidebarConstraint?.isActive = false
        hostedLeadingWithSidebarConstraint?.isActive = true
    }

    private func alignContentWithoutSidebar() {
        hostedLeadingWithSidebarConstraint?.isActive = false
        hostedLeadingWithoutSidebarConstraint?.isActive = true
    }

    private func detachSidebarIfNeeded() {
        guard sidebarContainerView.superview === view else {
            return
        }

        NSLayoutConstraint.deactivate(sidebarAttachmentConstraints)
        sidebarContainerView.removeFromSuperview()
    }

    private func titlebarHostView(in window: NSWindow) -> NSView? {
        guard WindowChromeSuppression.supportsPrivateDecoration(
            on: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        ) else { return nil }
        guard let frameView = window.contentView?.superview else {
            return nil
        }

        return ([frameView] + recursiveSubviews(in: frameView)).first {
            NSStringFromClass(type(of: $0)) == "NSTitlebarView"
        }
    }

    private func recursiveSubviews(in rootView: NSView) -> [NSView] {
        rootView.subviews + rootView.subviews.flatMap(recursiveSubviews(in:))
    }

    private func beginWindowSizeLockIfNeeded() {
        guard transitionWindowSizeLock == nil, let window = view.window else {
            return
        }

        let contentSize = window.contentRect(forFrameRect: window.frame).size
        transitionWindowSizeLock = WindowSizeLock(
            frame: window.frame,
            minimumSize: window.minSize,
            maximumSize: window.maxSize,
            minimumContentSize: window.contentMinSize,
            maximumContentSize: window.contentMaxSize
        )
        let lockedSize = window.frame.size
        window.minSize = lockedSize
        window.maxSize = lockedSize
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
    }

    private func endWindowSizeLockIfNeeded() {
        guard let lock = transitionWindowSizeLock, let window = view.window else {
            return
        }

        transitionWindowSizeLock = nil
        window.minSize = lock.minimumSize
        window.maxSize = lock.maximumSize
        window.contentMinSize = lock.minimumContentSize
        window.contentMaxSize = lock.maximumContentSize
        if window.frame.size != lock.frame.size {
            window.setFrame(lock.frame, display: false)
        }
    }
}

@MainActor
private final class CenteredWindowTitleView: PassthroughTitlebarView, ThemeApplying {
    private let label = NSTextField(labelWithString: "")

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13, weight: .semibold)

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func applyCurrentTheme() {
        label.textColor = ReaderTheme.titlebarPrimaryTextColor
    }
}

@MainActor
private final class ThemeObservingView: NSView {
    var onEffectiveAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }
}

@MainActor
private class PassthroughTitlebarView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
