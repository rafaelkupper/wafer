import AppKit
import WaferCore

@MainActor
final class QuickOpenPanelController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, ThemeApplying {
    typealias FileProvider = () -> [LibraryFile]
    typealias LibraryAvailabilityProvider = () -> Bool
    typealias CurrentWindowOpenHandler = @MainActor (URL, NSWindow?) -> Void
    typealias NewWindowOpenHandler = @MainActor (URL, NSWindow?) -> Void

    private enum Metrics {
        static let panelSize = NSSize(width: 620, height: 420)
        static let contentInset: CGFloat = 16
        static let rowHeight: CGFloat = 52
    }

    private let fileProvider: FileProvider
    private let isLibraryAvailable: LibraryAvailabilityProvider
    private let openInCurrentWindow: CurrentWindowOpenHandler
    private let openInNewWindow: NewWindowOpenHandler

    private var panel: QuickOpenPanel?
    private var searchField: NSTextField?
    private var tableView: NSTableView?
    private var results: [LibraryFile] = []
    private let searchWork = LatestWorkQueue<LibrarySearchInput, [LibraryFile]>()
    private var isSearching = false
    #if DEBUG
    var isSearchingForTesting: Bool { isSearching }
    #endif
    private var pendingSubmission: Bool?
    private var selectedIndex: Int?
    private weak var presentingWindow: NSWindow?
    private var isDismissing = false

    init(
        fileProvider: @escaping FileProvider = { LibraryController.shared.files },
        isLibraryAvailable: @escaping LibraryAvailabilityProvider = { LibraryController.shared.hasLibrary },
        openInCurrentWindow: @escaping CurrentWindowOpenHandler = QuickOpenPanelController.openInCurrentMarkdownWindow(url:presentingWindow:),
        openInNewWindow: @escaping NewWindowOpenHandler = QuickOpenPanelController.openInNewMarkdownTab(url:presentingWindow:)
    ) {
        self.fileProvider = fileProvider
        self.isLibraryAvailable = isLibraryAvailable
        self.openInCurrentWindow = openInCurrentWindow
        self.openInNewWindow = openInNewWindow
        super.init()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showQuickOpen(_:)):
            return isLibraryAvailable()
        default:
            return true
        }
    }

    @objc
    func showQuickOpen(_ sender: Any?) {
        guard isLibraryAvailable() else {
            return
        }

        let application = NSApplication.shared
        let anchorWindow = application.keyWindow ?? application.mainWindow
        presentingWindow = anchorWindow
        let panel = ensurePanel()
        panel.setFrame(centeredFrame(over: anchorWindow), display: false)

        searchField?.stringValue = ""
        updateResults()
        applyCurrentTheme()
        panel.makeKeyAndOrderFront(sender)
        panel.makeFirstResponder(searchField)
    }

    @objc
    func cancelOperation(_ sender: Any?) {
        dismissPanel()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === searchField else {
            return
        }

        updateResults()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else {
            return false
        }

        switch commandSelector {
        case #selector(cancelOperation(_:)):
            dismissPanel()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let event = NSApplication.shared.currentEvent
            openSelectedResult(opensNewWindow: event?.modifierFlags.contains(.command) == true)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        default:
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        QuickOpenTableRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("QuickOpenResultCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? QuickOpenResultCellView
            ?? QuickOpenResultCellView()
        cell.identifier = identifier
        cell.configure(file: results[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView?.selectedRow ?? -1 >= 0 else {
            selectedIndex = nil
            return
        }

        selectedIndex = tableView?.selectedRow
    }

    @objc
    private func openSelectedFromTable(_ sender: Any?) {
        openSelectedResult(opensNewWindow: false)
    }

    func applyCurrentTheme() {
        panel?.backgroundColor = ReaderTheme.sidebarBackgroundColor
        panel?.contentView?.layer?.backgroundColor = ReaderTheme.sidebarBackgroundColor.cgColor
        searchField?.textColor = ReaderTheme.sidebarPrimaryTextColor
        searchField?.backgroundColor = ReaderTheme.sidebarChromeFillColor
        tableView?.backgroundColor = ReaderTheme.sidebarBackgroundColor
        tableView?.enclosingScrollView?.backgroundColor = ReaderTheme.sidebarBackgroundColor
        tableView?.enclosingScrollView?.contentView.backgroundColor = ReaderTheme.sidebarBackgroundColor
        tableView?.reloadData()
    }

    #if DEBUG
    var resultTitlesForTesting: [String] {
        results.map(\.displayTitle)
    }

    var resultCountForTesting: Int {
        results.count
    }

    var selectedResultIndexForTesting: Int? {
        selectedIndex
    }

    var isPanelVisibleForTesting: Bool {
        panel?.isVisible == true
    }

    func setQueryForTesting(_ query: String) {
        _ = ensurePanel()
        searchField?.stringValue = query
        updateResults()
    }

    func showForTesting(presentingWindow: NSWindow? = nil) {
        presentingWindow.map { self.presentingWindow = $0 }
        showQuickOpen(nil)
    }

    func moveSelectionForTesting(by offset: Int) {
        moveSelection(by: offset)
    }

    func submitSelectionForTesting(opensNewWindow: Bool = false) {
        openSelectedResult(opensNewWindow: opensNewWindow)
    }
    #endif

    private func ensurePanel() -> QuickOpenPanel {
        if let panel {
            return panel
        }

        let panel = QuickOpenPanel(
            contentRect: NSRect(origin: .zero, size: Metrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.onResignKey = { [weak self] in
            self?.dismissPanel()
        }

        let rootView = NSView(frame: NSRect(origin: .zero, size: Metrics.panelSize))
        rootView.wantsLayer = true

        let searchField = NSTextField(string: "")
        searchField.placeholderString = "Quick Open"
        searchField.font = .systemFont(ofSize: 15, weight: .regular)
        searchField.focusRingType = .none
        searchField.bezelStyle = .roundedBezel
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let tableView = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Metrics.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(openSelectedFromTable(_:))
        scrollView.documentView = tableView

        rootView.addSubview(searchField)
        rootView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: Metrics.contentInset),
            searchField.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -Metrics.contentInset),
            searchField.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Metrics.contentInset),

            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: Metrics.contentInset),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -Metrics.contentInset),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -Metrics.contentInset),
        ])

        panel.contentView = rootView
        self.panel = panel
        self.searchField = searchField
        self.tableView = tableView
        applyCurrentTheme()
        return panel
    }

    private func updateResults() {
        searchWork.cancel()
        pendingSubmission = nil
        let query = searchField?.stringValue ?? ""
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isSearching = false
            applyResults([])
            return
        }
        isSearching = true
        searchWork.submit(LibrarySearchInput(query: query, files: fileProvider())) { input, cancellation in
            LibrarySearch.quickOpenMatches(query: input.query, in: input.files, cancellation: cancellation)
        } completion: { [weak self] results in
            self?.isSearching = false
            guard let self else { return }
            self.applyResults(results)
            if let opensNewWindow = self.pendingSubmission {
                self.pendingSubmission = nil
                self.openSelectedResult(opensNewWindow: opensNewWindow)
            }
        }
    }

    private func applyResults(_ results: [LibraryFile]) {
        self.results = results
        selectedIndex = results.isEmpty ? nil : min(selectedIndex ?? 0, results.count - 1)
        tableView?.reloadData()
        applySelection()
    }

    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else {
            return
        }

        let currentIndex = selectedIndex ?? 0
        selectedIndex = (currentIndex + offset + results.count) % results.count
        applySelection()
    }

    private func applySelection() {
        guard let tableView else {
            return
        }

        guard let selectedIndex else {
            tableView.deselectAll(nil)
            return
        }

        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
    }

    private func openSelectedResult(opensNewWindow: Bool) {
        if isSearching {
            pendingSubmission = opensNewWindow
            return
        }
        guard let selectedIndex, results.indices.contains(selectedIndex) else {
            return
        }

        let url = results[selectedIndex].fileURL
        dismissPanel()
        if opensNewWindow {
            openInNewWindow(url, presentingWindow)
        } else {
            openInCurrentWindow(url, presentingWindow)
        }
    }

    private func dismissPanel() {
        pendingSubmission = nil
        searchWork.cancel()
        isSearching = false
        guard !isDismissing else {
            return
        }

        isDismissing = true
        panel?.orderOut(nil)
        isDismissing = false
    }

    private func centeredFrame(over window: NSWindow?) -> NSRect {
        let containerFrame = window?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: Metrics.panelSize)
        return NSRect(
            x: containerFrame.midX - Metrics.panelSize.width / 2,
            y: containerFrame.midY - Metrics.panelSize.height / 2,
            width: Metrics.panelSize.width,
            height: Metrics.panelSize.height
        )
    }

    private static func openInCurrentMarkdownWindow(url: URL, presentingWindow: NSWindow?) {
        guard let document = presentingWindow?.windowController?.document as? MarkdownReaderDocument else {
            openInNewMarkdownTab(url: url, presentingWindow: presentingWindow)
            return
        }

        document.navigateInCurrentWindow(to: url)
        presentingWindow?.makeKeyAndOrderFront(nil)
    }

    private static func openInNewMarkdownTab(url: URL, presentingWindow: NSWindow?) {
        if let host = presentingWindow?.windowController as? DocumentHostWindowController {
            host.openTab(for: url)
            presentingWindow?.makeKeyAndOrderFront(nil)
            return
        }

        do {
            try MarkdownDocumentOpener.open(url: url)
        } catch {
            NSApplication.shared.presentError(error)
        }
    }
}

@MainActor
private final class QuickOpenPanel: NSPanel {
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

@MainActor
private final class QuickOpenResultCellView: NSTableCellView, ThemeApplying {
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.font = .systemFont(ofSize: 11, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, pathLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(file: LibraryFile) {
        titleLabel.stringValue = file.displayTitle
        pathLabel.stringValue = file.relativePathComponents.joined(separator: "/")
        applyCurrentTheme()
    }

    func applyCurrentTheme() {
        titleLabel.textColor = ReaderTheme.sidebarPrimaryTextColor
        pathLabel.textColor = ReaderTheme.sidebarSecondaryTextColor
    }
}

@MainActor
private final class QuickOpenTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else {
            return
        }

        ReaderTheme.sidebarSelectionColor.setFill()
        dirtyRect.fill()
    }
}
