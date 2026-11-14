import AppKit
import QuartzCore
import WaferCore

@MainActor
final class DocumentChromeViewController: NSViewController, ThemeApplying {
    static let sidebarAnimationDuration: TimeInterval = 0.26
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
    private var sidebarTransition: (id: UUID, isVisible: Bool)?
    private var hostedTransitionLeadingConstraint: NSLayoutConstraint?
    private var transitionWindowSizeLock: WindowSizeLock?
    #if DEBUG
    var editorVisibleFrameOverride: NSRect?
    #endif
    var reducedMotionOverride: Bool?
    static let editorPaneAnimationDuration: TimeInterval = 0.35
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
        sidebarTransition?.isVisible ?? !(sidebarContainerView.isHidden)
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

    var isSidebarTransitioningForTesting: Bool { sidebarTransition != nil }
    var contentFrameForTesting: NSRect { contentContainerView.frame }
    var sidebarFrameForTesting: NSRect { sidebarContainerView.frame }
    var activeContentLeadingConstraintCountForTesting: Int {
        [hostedLeadingWithoutSidebarConstraint, hostedLeadingWithSidebarConstraint, hostedTransitionLeadingConstraint]
            .compactMap { $0 }.filter(\.isActive).count
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
        var visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
        #if DEBUG
        visibleFrame = editorVisibleFrameOverride ?? visibleFrame
        #endif
        let plan = EditorPaneExpansion.plan(
            windowFrame: start,
            contentWidth: split.bounds.width,
            visibleFrame: visibleFrame,
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
        if let transition = sidebarTransition {
            sidebarTransition = nil
            finalizeAnimatedSidebarTransition(isVisible: transition.isVisible)
            endWindowSizeLockIfNeeded()
        }
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

        let transitionID = UUID()
        sidebarTransition = (transitionID, isVisible)
        beginContentTransition(startLeading: startLeading)
        beginWindowSizeLockIfNeeded()
        view.layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.sidebarAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            hostedTransitionLeadingConstraint?.constant = isVisible ? DocumentSidebarViewController.sidebarWidth : 0
            sidebarRevealWidthConstraint?.constant = isVisible ? DocumentSidebarViewController.sidebarWidth : 0
            sidebarContainerView.animator().alphaValue = isVisible ? 1 : 0
            view.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sidebarTransition?.id == transitionID else { return }
                self.sidebarTransition = nil
                self.finalizeAnimatedSidebarTransition(isVisible: isVisible)
                self.endWindowSizeLockIfNeeded()
                self.view.layoutSubtreeIfNeeded()
                if isVisible { self.sidebarViewController.refreshVisibleDocumentSummaries() }
            }
        }
    }

    func prepareSidebarForAnimatedOpen() {
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

    private func beginContentTransition(startLeading: CGFloat) {
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
        hostedTransitionLeadingConstraint?.isActive = false
        hostedLeadingWithoutSidebarConstraint?.isActive = false
        hostedLeadingWithSidebarConstraint?.isActive = true
    }

    private func alignContentWithoutSidebar() {
        hostedTransitionLeadingConstraint?.isActive = false
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
final class CenteredWindowTitleView: PassthroughTitlebarView, ThemeApplying {
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
final class ThemeObservingView: NSView {
    var onEffectiveAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }
}

@MainActor
class PassthroughTitlebarView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
