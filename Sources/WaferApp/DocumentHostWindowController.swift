import AppKit

/// The window controller documents actually use: hosts an ordered list of
/// `DocumentTab`s in one window, with a themed tab strip that appears from
/// the second tab onward.
///
/// NSDocument ownership rule: `addWindowController` allows one owning
/// document at a time, so the host's NSDocument association always tracks
/// the ACTIVE tab's document (selection transfers ownership). Inactive tab
/// documents stay alive through their tabs and `OpenDocumentRegistry`, and
/// are closed explicitly when their tab closes or the window closes.
@MainActor
final class DocumentHostWindowController: DocumentWindowController {
    private(set) var tabs: [DocumentTab]
    private(set) var activeTabIndex = 0

    private let tabStripView = DocumentTabStripView()
    // NotificationCenter observer removal is thread-safe; unsafe-nonisolated so
    // the nonisolated deinit can clean up.
    nonisolated(unsafe) private var windowWillCloseObserver: NSObjectProtocol?

    #if DEBUG
    /// Test seam for command-click routing; nil uses NSApp.currentEvent.
    var commandClickProviderForTesting: (() -> Bool)?
    /// Test seam for secondary-tab document creation; nil uses the normal loader.
    var tabDocumentFactoryForTesting: ((URL) -> MarkdownReaderDocument?)?
    #endif

    var activeTab: DocumentTab {
        tabs[activeTabIndex]
    }

    #if DEBUG
    var tabStripViewForTesting: DocumentTabStripView {
        tabStripView
    }
    #endif

    init(
        tab: DocumentTab,
        cascadeFrom sourceWindow: NSWindow? = nil,
        statisticPreferenceStore: DocumentStatisticPreferenceStore = .shared,
        appearancePreferenceStore: AppearancePreferenceStore = .shared,
        exportController: DocumentExportControlling = DocumentExportController()
    ) {
        self.tabs = [tab]
        super.init(
            contentViewController: tab.readerController,
            cascadeFrom: sourceWindow,
            statisticPreferenceStore: statisticPreferenceStore,
            appearancePreferenceStore: appearancePreferenceStore,
            exportController: exportController
        )

        installTabStrip(tabStripView, height: DocumentTabStripView.stripHeight)
        setTabStripVisible(false)
        tabStripView.onSelectTab = { [weak self] index in
            self?.selectTab(at: index)
        }
        tabStripView.onCloseTab = { [weak self] index in
            self?.closeTab(at: index)
        }
        tabStripView.onMoveTab = { [weak self] fromIndex, toIndex in
            self?.moveTab(from: fromIndex, to: toIndex)
        }
        tabStripView.onCloseOtherTabs = { [weak self] index in
            self?.closeOtherTabs(around: index)
        }

        wireSidebarRouting()
        observeWindowClose()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let windowWillCloseObserver {
            NotificationCenter.default.removeObserver(windowWillCloseObserver)
        }
    }

    // MARK: - Tab operations

    func openTab(for url: URL, anchorID: String? = nil) {
        let normalizedURL = MarkdownDocumentOpener.normalizedFileURL(for: url)
        guard MarkdownDocumentOpener.supports(url: normalizedURL) else {
            return
        }

        if let existingIndex = tabIndex(for: normalizedURL) {
            selectTab(at: existingIndex)
            if let anchorID, !anchorID.isEmpty {
                tabs[existingIndex].document.navigateToAnchor(id: anchorID)
            }
            return
        }

        guard let document = makeTabDocument(for: normalizedURL) else {
            return
        }

        NSDocumentController.shared.addDocument(document)
        OpenDocumentRegistry.shared.retain(document)

        let tab = document.attachAsTab(to: self)
        tabs.append(tab)
        selectTab(at: tabs.count - 1)
        if let anchorID, !anchorID.isEmpty {
            document.navigateToAnchor(id: anchorID)
        }
        document.loadInitialSource { [weak self, weak document] in
            guard let self, let document,
                  let index = self.tabs.firstIndex(where: { $0.document === document }) else { return }
            self.closeTab(at: index)
        }
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else {
            return
        }

        activeTabIndex = index
        let tab = tabs[index]
        if tab.document !== document {
            tab.document.addWindowController(self)
        }
        setHostedContent(tab.readerController)
        // Tabs switch at once: the window takes the width this tab needs.
        setEditorPane(tab.document.editorPaneController, animated: false)
        tab.document.applyThemeIfNeeded()
        tab.document.pushWindowLevelStateToHost()
        refreshTabStrip()
    }

    func selectTab(containing document: MarkdownReaderDocument) {
        guard let index = tabs.firstIndex(where: { $0.document === document }) else {
            return
        }

        selectTab(at: index)
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else {
            return
        }

        guard tabs.count > 1 else {
            window?.performClose(nil)
            return
        }
        // Save editor text first; a cancelled save keeps the tab open.
        guard tabs[index].document.flushEdits(interactive: true) else {
            return
        }

        let closingActive = index == activeTabIndex
        let tab = tabs.remove(at: index)
        if closingActive {
            // Prefer the neighbor to the LEFT unless closing the first tab.
            selectTab(at: index == 0 ? 0 : index - 1)
        } else {
            if index < activeTabIndex {
                activeTabIndex -= 1
            }
            refreshTabStrip()
        }
        tab.document.close()
    }

    func moveTab(from fromIndex: Int, to toIndex: Int) {
        guard
            tabs.indices.contains(fromIndex),
            tabs.indices.contains(toIndex),
            fromIndex != toIndex
        else {
            return
        }

        let activeTab = self.activeTab
        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: toIndex)
        activeTabIndex = tabs.firstIndex(where: { $0 === activeTab }) ?? 0
        refreshTabStrip()
    }

    func closeOtherTabs(around index: Int) {
        guard tabs.indices.contains(index) else {
            return
        }

        let keptTab = tabs[index]
        selectTab(at: index)
        var offset = tabs.count - 1
        while tabs.count > 1, offset >= 0 {
            if offset < tabs.count, tabs[offset] !== keptTab {
                closeTab(at: offset)
            }
            offset -= 1
        }
    }

    func refreshTabTitles() {
        refreshTabStrip()
    }

    override func setEditorPane(_ controller: NSViewController?, for document: MarkdownReaderDocument, animated: Bool) {
        guard activeTab.document === document else {
            return
        }

        setEditorPane(controller, animated: animated)
    }

    override func prepareToCloseWindow() -> Bool {
        tabs.allSatisfy { $0.document.flushEdits(interactive: true) }
    }

    static func host(containing document: MarkdownReaderDocument) -> DocumentHostWindowController? {
        NSApp.windows
            .compactMap { $0.windowController as? DocumentHostWindowController }
            .first { host in
                host.tabs.contains { $0.document === document }
            }
    }

    // MARK: - Keyboard / menu actions

    @objc func closeActiveTab(_ sender: Any?) {
        closeTab(at: activeTabIndex)
    }

    @objc func showNextTab(_ sender: Any?) {
        guard tabs.count > 1 else {
            return
        }
        selectTab(at: (activeTabIndex + 1) % tabs.count)
    }

    @objc func showPreviousTab(_ sender: Any?) {
        guard tabs.count > 1 else {
            return
        }
        selectTab(at: (activeTabIndex - 1 + tabs.count) % tabs.count)
    }

    @objc func moveActiveTabLeft(_ sender: Any?) {
        guard activeTabIndex > 0 else {
            return
        }
        moveTab(from: activeTabIndex, to: activeTabIndex - 1)
    }

    @objc func moveActiveTabRight(_ sender: Any?) {
        guard activeTabIndex < tabs.count - 1 else {
            return
        }
        moveTab(from: activeTabIndex, to: activeTabIndex + 1)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(closeActiveTab(_:)):
            return true
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)):
            return tabs.count > 1
        case #selector(moveActiveTabLeft(_:)):
            return activeTabIndex > 0
        case #selector(moveActiveTabRight(_:)):
            return activeTabIndex < tabs.count - 1
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func applyCurrentTheme() {
        super.applyCurrentTheme()
        tabStripView.applyCurrentTheme()
    }

    // MARK: - Private

    private func tabIndex(for normalizedURL: URL) -> Int? {
        tabs.firstIndex { tab in
            guard let tabURL = tab.document.fileURL else {
                return false
            }
            return MarkdownDocumentOpener.normalizedFileURL(for: tabURL) == normalizedURL
        }
    }

    private func makeTabDocument(for url: URL) -> MarkdownReaderDocument? {
        #if DEBUG
        if let tabDocumentFactoryForTesting {
            return tabDocumentFactoryForTesting(url)
        }
        #endif

        let document = MarkdownReaderDocument(scrollStateStore: .init())
        document.fileURL = url
        return document
    }

    private var isTabOpeningClick: Bool {
        #if DEBUG
        if let commandClickProviderForTesting {
            return commandClickProviderForTesting()
        }
        #endif

        guard let event = NSApp.currentEvent else {
            return false
        }

        if event.modifierFlags.contains(.command) {
            return true
        }

        // Middle-click (button 2) opens in a new tab, browser-style.
        switch event.type {
        case .otherMouseDown, .otherMouseUp:
            return event.buttonNumber == 2
        default:
            return false
        }
    }

    private func wireSidebarRouting() {
        onSelectSidebarDocument = { [weak self] url in
            self?.routeSidebarSelection(url: url, anchorID: nil)
        }
        onSelectSidebarDocumentWithAnchor = { [weak self] url, anchorID in
            self?.routeSidebarSelection(url: url, anchorID: anchorID)
        }
        onSelectOutlineItem = { [weak self] anchorID in
            self?.activeTab.document.scrollReaderToHeading(id: anchorID)
        }
    }

    private func routeSidebarSelection(url: URL, anchorID: String?) {
        if isTabOpeningClick {
            openTab(for: url, anchorID: anchorID)
        } else {
            activeTab.document.navigateInCurrentWindow(to: url, anchorID: anchorID)
        }
    }

    private func refreshTabStrip() {
        tabStripView.reload(
            items: tabs.map { tab in
                DocumentTabStripView.TabItem(
                    title: tab.document.fileURL?.lastPathComponent ?? "Markdown"
                )
            },
            selectedIndex: activeTabIndex
        )
        setTabStripVisible(tabs.count > 1)
    }

    private func observeWindowClose() {
        guard let window else {
            return
        }

        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeInactiveTabDocuments()
            }
        }
    }

    private func closeInactiveTabDocuments() {
        for tab in tabs where tab.document !== document {
            tab.document.close()
        }
    }
}
