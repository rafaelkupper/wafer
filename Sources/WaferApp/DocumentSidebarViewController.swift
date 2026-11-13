import AppKit
import WaferCore

enum OutlineSidebarMetrics {
    static let fontSize: CGFloat = 12.5
    static let rowVerticalInset: CGFloat = 4
    static let levelOneLeadingInset: CGFloat = 16
    static let indentationStep: CGFloat = 16

    static func leadingInset(for level: Int) -> CGFloat {
        levelOneLeadingInset + CGFloat(max(level - 1, 0)) * indentationStep
    }

    static func fontWeight(for level: Int, isSelected: Bool) -> NSFont.Weight {
        if isSelected || level == 1 {
            return .semibold
        }

        return .regular
    }

    @MainActor static func textColor(for level: Int, isSelected: Bool, isHovering: Bool) -> NSColor {
        if isSelected {
            return ReaderTheme.sidebarPrimaryTextColor
        }

        if isHovering {
            return ReaderTheme.sidebarPrimaryTextColor.withAlphaComponent(level == 1 ? 0.92 : 0.82)
        }

        if level == 1 {
            return ReaderTheme.sidebarPrimaryTextColor.withAlphaComponent(0.88)
        }

        return ReaderTheme.sidebarSecondaryTextColor.withAlphaComponent(level <= 3 ? 0.9 : 0.82)
    }
}

@MainActor
enum DocumentSidebarMode: Int {
    case library
    case documents
    case outline

    var title: String {
        switch self {
        case .library:
            "LIBRARY"
        case .documents:
            "DOCUMENTS"
        case .outline:
            "OUTLINE"
        }
    }
}

struct SidebarLibrarySearchRunResult: Sendable {
    let matches: [LibrarySearch.FileMatch]
    let ranOnMainThread: Bool
}

@MainActor
final class DocumentSidebarViewController: NSViewController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, ThemeApplying {
    typealias LibrarySearchRunner = @Sendable (_ query: String, _ files: [LibraryFile]) -> SidebarLibrarySearchRunResult

    static let sidebarWidth: CGFloat = 270

    private let libraryController: LibraryController
    private let notificationCenter: NotificationCenter
    private let librarySearchRunner: LibrarySearchRunner?
    private let summaryWork = LatestWorkQueue<[DocumentSidebarEntry], [DocumentSidebarEntry]>()
    private var summaryRequestScheduled = false
    private let searchWork = LatestWorkQueue<LibrarySearchInput, SidebarLibrarySearchRunResult>()
    private let modeToggleView = SidebarModeToggleView()
    private let titleLabel = NSTextField(labelWithString: DocumentSidebarMode.documents.title)
    private let librarySearchContainerView = NSView()
    private let librarySearchField = NSTextField(string: "")
    private let scrollView = NSScrollView()
    private let rowTable = NSTableView()
    private var rows: [SidebarRow] = []
    private var libraryTree: LibraryTreeNode?
    private var librarySearchContainerHeightConstraint: NSLayoutConstraint?

    private var sidebarEntries: [DocumentSidebarEntry] = []
    private var outlineItems: [DocumentOutlineItem] = []
    private var activeOutlineAnchorID: String?
    private var collapsedLibraryFolderPaths: Set<String> = []
    private var librarySearchResults: [LibrarySearch.FileMatch] = []
    private var librarySearchGeneration = 0
    private var isLibrarySearchRunning = false
    private var lastLibrarySearchRanOnMainThread: Bool?

    var onSelectDocument: ((URL) -> Void)?
    var onSelectDocumentWithAnchor: ((URL, String?) -> Void)?
    var onSelectOutlineItem: ((String) -> Void)?

    private(set) var mode: DocumentSidebarMode = .documents

    init(
        libraryController: LibraryController = .shared,
        notificationCenter: NotificationCenter = .default,
        librarySearchRunner: LibrarySearchRunner? = nil
    ) {
        self.libraryController = libraryController
        self.notificationCenter = notificationCenter
        self.librarySearchRunner = librarySearchRunner
        super.init(nibName: nil, bundle: nil)
        notificationCenter.addObserver(
            self,
            selector: #selector(handleLibraryDidChangeNotification(_:)),
            name: .libraryDidChange,
            object: libraryController
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        notificationCenter.removeObserver(self, name: .libraryDidChange, object: libraryController)
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: 760))
        view.wantsLayer = true

        let headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false

        modeToggleView.translatesAutoresizingMaskIntoConstraints = false
        modeToggleView.onSelectMode = { [weak self] mode in
            self?.setMode(mode)
        }
        modeToggleView.setLibraryAvailable(libraryController.hasLibrary)
        modeToggleView.setMode(.documents)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        headerView.addSubview(modeToggleView)
        headerView.addSubview(titleLabel)

        librarySearchContainerView.translatesAutoresizingMaskIntoConstraints = false
        librarySearchContainerView.wantsLayer = true
        librarySearchContainerView.isHidden = true

        librarySearchField.placeholderString = "Search Library"
        librarySearchField.font = .systemFont(ofSize: 13, weight: .regular)
        librarySearchField.focusRingType = .none
        librarySearchField.bezelStyle = .roundedBezel
        librarySearchField.delegate = self
        librarySearchField.translatesAutoresizingMaskIntoConstraints = false
        librarySearchContainerView.addSubview(librarySearchField)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.horizontalScroller = nil
        scrollView.autohidesScrollers = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        rowTable.addTableColumn(column)
        rowTable.headerView = nil
        rowTable.intercellSpacing = NSSize(width: 0, height: 0)
        rowTable.backgroundColor = .clear
        rowTable.selectionHighlightStyle = .none
        rowTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        rowTable.dataSource = self
        rowTable.delegate = self
        rowTable.target = self
        rowTable.action = #selector(activateSelectedRow(_:))
        scrollView.documentView = rowTable

        view.addSubview(headerView)
        view.addSubview(librarySearchContainerView)
        view.addSubview(scrollView)

        let librarySearchContainerHeightConstraint = librarySearchContainerView.heightAnchor.constraint(equalToConstant: 0)
        self.librarySearchContainerHeightConstraint = librarySearchContainerHeightConstraint
        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 76),

            modeToggleView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            modeToggleView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 12),

            titleLabel.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -12),

            librarySearchContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            librarySearchContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            librarySearchContainerView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            librarySearchContainerHeightConstraint,

            librarySearchField.leadingAnchor.constraint(equalTo: librarySearchContainerView.leadingAnchor, constant: 14),
            librarySearchField.trailingAnchor.constraint(equalTo: librarySearchContainerView.trailingAnchor, constant: -14),
            librarySearchField.centerYAnchor.constraint(equalTo: librarySearchContainerView.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: librarySearchContainerView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        updateLibrarySearchVisibility()
        rebuildRows()
        applyCurrentTheme()
    }

    func apply(sidebarEntries: [DocumentSidebarEntry], outlineItems: [DocumentOutlineItem]) {
        summaryWork.cancel()
        self.sidebarEntries = sidebarEntries
        self.outlineItems = outlineItems
        rebuildRows()
    }

    func applyCurrentTheme() {
        view.layer?.backgroundColor = ReaderTheme.sidebarBackgroundColor.cgColor
        librarySearchContainerView.layer?.backgroundColor = ReaderTheme.sidebarBackgroundColor.cgColor
        librarySearchField.textColor = ReaderTheme.sidebarPrimaryTextColor
        librarySearchField.backgroundColor = ReaderTheme.sidebarChromeFillColor
        titleLabel.textColor = ReaderTheme.sidebarSecondaryTextColor
        modeToggleView.applyCurrentTheme()
        visibleRowViews.forEach { $0.applyCurrentThemeRecursively() }
    }

    func setMode(_ mode: DocumentSidebarMode) {
        let mode = mode == .library && !libraryController.hasLibrary ? .documents : mode
        guard self.mode != mode else {
            return
        }

        self.mode = mode
        modeToggleView.setMode(mode)
        titleLabel.stringValue = mode.title
        updateLibrarySearchVisibility()
        rebuildRows()
    }

    func focusLibrarySearch() {
        loadViewIfNeeded()
        setMode(.library)
        view.window?.makeFirstResponder(librarySearchField)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === librarySearchField else {
            return
        }

        runLibrarySearchForCurrentQuery()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === librarySearchField else {
            return false
        }

        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            librarySearchField.stringValue = ""
            runLibrarySearchForCurrentQuery()
            return true
        default:
            return false
        }
    }

    func setActiveOutlineAnchorID(_ anchorID: String?) {
        guard activeOutlineAnchorID != anchorID else {
            return
        }

        activeOutlineAnchorID = anchorID
        guard mode == .outline else {
            return
        }

        updateActiveOutlineSelection()
    }

    var documentTitlesForTesting: [String] {
        sidebarEntries.map(\.displayTitle)
    }

    var backlinkTitlesForTesting: [String] {
        rowViewsForTesting.compactMap { ($0 as? SidebarBacklinkRowView)?.titleForTesting }
    }

    var hasBacklinkSectionForTesting: Bool {
        rowViewsForTesting.contains { $0 is SidebarBacklinkHeaderView }
    }

    func triggerBacklinkActivationForTesting(at index: Int) {
        let rows = rowViewsForTesting.compactMap { $0 as? SidebarBacklinkRowView }
        guard rows.indices.contains(index) else {
            return
        }
        rows[index].onActivate?()
    }

    var outlineTitlesForTesting: [String] {
        outlineItems.map(\.title)
    }

    var activeOutlineAnchorIDForTesting: String? {
        activeOutlineAnchorID
    }

    var arrangedRowFramesForTesting: [NSRect] {
        view.layoutSubtreeIfNeeded()
        return rows.indices.map { rowTable.rect(ofRow: $0) }
    }

    var arrangedRowHeightsForTesting: [CGFloat] {
        arrangedRowFramesForTesting.map(\.height)
    }

    var scrollDocumentHeightForTesting: CGFloat {
        view.layoutSubtreeIfNeeded()
        return rowTable.frame.height
    }

    var scrollViewportHeightForTesting: CGFloat {
        view.layoutSubtreeIfNeeded()
        return scrollView.contentView.bounds.height
    }

    var outlineLabelMinXPositionsForTesting: [CGFloat] {
        view.layoutSubtreeIfNeeded()
        return rowViewsForTesting.compactMap { row in
            (row as? SidebarOutlineRowView)?.labelMinXForTesting
        }
    }

    var outlineLeadingInsetsForTesting: [CGFloat] {
        rowViewsForTesting.compactMap { row in
            (row as? SidebarOutlineRowView)?.leadingInsetForTesting
        }
    }

    var arrangedRowObjectIdentifiersForTesting: [ObjectIdentifier] {
        rowViewsForTesting.map { ObjectIdentifier($0) }
    }

    var selectedOutlineAnchorIDsForTesting: [String] {
        rowViewsForTesting.compactMap { row in
            guard let outlineRow = row as? SidebarOutlineRowView, outlineRow.isSelected else {
                return nil
            }

            return outlineRow.anchorID
        }
    }

    var availableModeTitlesForTesting: [String] {
        modeToggleView.availableTitlesForTesting
    }

    var libraryRowTitlesForTesting: [String] {
        rows.compactMap {
            switch $0 {
            case .folder(let title, _, _, _): title
            case .file(let file, _, _): file.displayTitle
            default: nil
            }
        }
    }

    var realizedRowCountForTesting: Int { visibleRowViews.count }

    var selectedLibraryFilePathsForTesting: [String] {
        rowViewsForTesting.compactMap {
            guard
                let row = $0 as? SidebarLibraryFileRowView,
                row.isSelected
            else {
                return nil
            }

            return row.relativePathForTesting
        }
    }

    var libraryFooterTextsForTesting: [String] {
        rowViewsForTesting.compactMap {
            ($0 as? SidebarLibraryFooterView)?.textForTesting
        }
    }

    var libraryPrimaryTextColorsForTesting: [NSColor] {
        rowViewsForTesting.compactMap {
            ($0 as? SidebarLibraryRowTesting)?.primaryTextColorForTesting
        }
    }

    var librarySearchQueryForTesting: String {
        librarySearchField.stringValue
    }

    var librarySearchResultTitlesForTesting: [String] {
        rows.compactMap { if case .search(let match, _) = $0 { match.file.displayTitle } else { nil } }
    }

    var librarySearchNoResultTextsForTesting: [String] {
        rowViewsForTesting.compactMap {
            ($0 as? SidebarLibraryMessageRowView)?.textForTesting
        }
    }

    var librarySearchFieldIsFocusedForTesting: Bool {
        view.window?.firstResponder === librarySearchField.currentEditor()
    }

    var lastLibrarySearchRanOnMainThreadForTesting: Bool? {
        lastLibrarySearchRanOnMainThread
    }

    func setLibrarySearchQueryForTesting(_ query: String) {
        loadViewIfNeeded()
        librarySearchField.stringValue = query
        runLibrarySearchForCurrentQuery()
    }

    func triggerDocumentSelectionForTesting(_ url: URL) {
        onSelectDocument?(url)
    }

    func triggerOutlineSelectionForTesting(_ anchorID: String) {
        onSelectOutlineItem?(anchorID)
    }

    func triggerLibrarySelectionForTesting(relativePath: String) {
        guard
            let file = libraryController.files.first(where: {
                $0.relativePathComponents.joined(separator: "/") == relativePath
            })
        else {
            return
        }

        onSelectDocument?(file.fileURL)
    }

    func triggerLibrarySearchResultSelectionForTesting(relativePath: String) {
        guard
            let match = librarySearchResults.first(where: {
                $0.file.relativePathComponents.joined(separator: "/") == relativePath
            })
        else {
            return
        }

        openLibrarySearchResult(match)
    }

    func toggleLibraryFolderForTesting(_ pathKey: String) {
        toggleLibraryFolder(pathKey: pathKey)
    }

    private func rebuildRows() {
        var updated: [SidebarRow] = []
        switch mode {
        case .documents:
            updated = sidebarEntries.map(SidebarRow.document)
        case .outline:
            updated = outlineItems.map(SidebarRow.outline)
            if let url = currentDocumentFileURL {
                let backlinks = libraryController.backlinks(for: url)
                if !backlinks.isEmpty {
                    updated.append(.backlinkHeader)
                    updated += backlinks.map(SidebarRow.backlink)
                }
            }
        case .library:
            if libraryController.scanFailure != nil {
                updated.append(.message("Library unavailable. Results may be stale."))
            }
            if hasLibrarySearchQuery {
                updated += librarySearchResults.map { .search($0, normalizedLibrarySearchQuery) }
                if librarySearchResults.isEmpty, !isLibrarySearchRunning { updated.append(.message("No results")) }
            } else {
                if libraryTree == nil { libraryTree = LibraryTreeBuilder.build(files: libraryController.files) }
                appendLibraryRows(libraryTree?.children ?? [], level: 0, to: &updated)
                if libraryController.truncated { updated.append(.footer("Showing first 2,000 files")) }
                if libraryController.skippedItemCount > 0 {
                    let count = libraryController.skippedItemCount
                    updated.append(.footer("\(count) \(count == 1 ? "file" : "files") skipped (unreadable or too large)"))
                }
            }
        }
        guard rows != updated else { return }
        let previous = rows
        rows = updated
        if previous.map(\.identity) == updated.map(\.identity) {
            let changed = IndexSet(updated.indices.filter { previous[$0] != updated[$0] })
            rowTable.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        } else {
            rowTable.reloadData()
        }
    }

    private var currentDocumentFileURL: URL? { sidebarEntries.first(where: \.isCurrent)?.fileURL }

    private func appendLibraryRows(_ nodes: [LibraryTreeNode], level: Int, to result: inout [SidebarRow]) {
        for node in nodes {
            switch node.kind {
            case .folder:
                let expanded = !collapsedLibraryFolderPaths.contains(node.pathKey)
                result.append(.folder(title: node.title, path: node.pathKey, level: level, expanded: expanded))
                if expanded { appendLibraryRows(node.children, level: level + 1, to: &result) }
            case .file(let file):
                result.append(.file(file, level: level, current: isCurrentLibraryFile(file.fileURL)))
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SidebarTableCell ?? SidebarTableCell()
        cell.identifier = identifier
        cell.configure(row: rows[row]) { makeRowView(rows[row]) }
        if let outline = cell.content as? SidebarOutlineRowView {
            outline.isSelected = outline.anchorID == activeOutlineAnchorID
        }
        cell.content?.applyCurrentThemeRecursively()
        scheduleVisibleSummaries()
        return cell
    }

    func refreshVisibleDocumentSummaries() { scheduleVisibleSummaries() }

    private func scheduleVisibleSummaries() {
        guard mode == .documents, !summaryRequestScheduled else { return }
        summaryRequestScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.summaryRequestScheduled = false
            guard self.mode == .documents, self.view.window != nil, !self.view.isHiddenOrHasHiddenAncestor else { return }
            let visible = self.rowTable.rows(in: self.rowTable.visibleRect)
            guard visible.location != NSNotFound else { return }
            let pending = self.rows.indices.filter { NSLocationInRange($0, visible) }.compactMap { index -> DocumentSidebarEntry? in
                guard case .document(let entry) = self.rows[index], entry.needsSummary else { return nil }
                return entry
            }
            guard !pending.isEmpty else { return }
            let library = self.libraryController.snapshot.filesByIdentity
            self.summaryWork.submit(pending, work: { entries, cancellation in
                var summaries: [DocumentSidebarEntry] = []
                for entry in entries {
                    guard !cancellation.isCancelled else { break }
                    if let file = library[FileIdentity.identity(for: entry.fileURL)] {
                        summaries.append(DocumentSidebarEntry(fileURL: entry.fileURL,
                            displayTitle: file.displayTitle, previewText: String(file.plainText.prefix(140)),
                            isCurrent: false, isAvailable: true))
                    } else {
                        summaries.append(DocumentSummaryCache.shared.summary(for: entry.fileURL))
                    }
                }
                return summaries
            }, completion: { [weak self] summaries in
                guard let self else { return }
                let byURL = Dictionary(uniqueKeysWithValues: summaries.map { ($0.fileURL, $0) })
                self.sidebarEntries = self.sidebarEntries.map { entry in
                    entry.needsSummary ? byURL[entry.fileURL] ?? entry : entry
                }
                self.rebuildRows()
            })
        }
    }

    @objc private func activateSelectedRow(_ sender: Any?) {
        guard rows.indices.contains(rowTable.selectedRow) else { return }
        activate(rows[rowTable.selectedRow])
    }

    private func activate(_ row: SidebarRow) {
        switch row {
        case .document(let entry):
            if entry.isAvailable { onSelectDocument?(entry.fileURL) }
        case .outline(let item):
            setActiveOutlineAnchorID(item.anchorID)
            onSelectOutlineItem?(item.anchorID)
        case .file(let file, _, _): onSelectDocument?(file.fileURL)
        case .folder(_, let path, _, _): toggleLibraryFolder(pathKey: path)
        case .search(let match, _): openLibrarySearchResult(match)
        case .backlink(let backlink): onSelectDocumentWithAnchor?(backlink.sourceFileURL, nil)
        default: break
        }
    }

    private func makeRowView(_ model: SidebarRow) -> NSView {
        let row: NSView
        switch model {
        case .document(let entry): row = SidebarDocumentRowView(entry: entry)
        case .outline(let item): row = SidebarOutlineRowView(item: item, isActive: item.anchorID == activeOutlineAnchorID)
        case .file(let file, let level, let current): row = SidebarLibraryFileRowView(file: file, level: level, isCurrent: current)
        case .folder(let title, _, let level, let expanded): row = SidebarLibraryFolderRowView(title: title, level: level, isExpanded: expanded)
        case .search(let match, let query):
            let displayMatch = LibrarySearch.FileMatch(file: match.file, matchedAnchorID: match.matchedAnchorID,
                snippet: match.snippet.isEmpty ? LibrarySearch.snippet(query: query, in: match.file) : match.snippet, score: match.score)
            row = SidebarLibrarySearchResultRowView(match: displayMatch)
        case .backlink(let backlink): row = SidebarBacklinkRowView(backlink: backlink)
        case .backlinkHeader: row = SidebarBacklinkHeaderView(title: "Linked From")
        case .footer(let text): row = SidebarLibraryFooterView(text: text)
        case .message(let text): row = SidebarLibraryMessageRowView(text: text)
        }
        if case .message = model, libraryController.scanFailure != nil {
            row.toolTip = "Library unavailable. Results may be stale. Choose File > Retry Library after the folder is available."
        }
        (row as? SidebarSelectableRowView)?.onActivate = { [weak self] in self?.activate(model) }
        (row as? SidebarBacklinkRowView)?.onActivate = { [weak self] in self?.activate(model) }
        return row
    }

    private var visibleRowViews: [NSView] {
        let range = rowTable.rows(in: rowTable.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        return (range.location..<NSMaxRange(range)).compactMap {
            (rowTable.view(atColumn: 0, row: $0, makeIfNecessary: false) as? SidebarTableCell)?.content
        }
    }

    private var rowViewsForTesting: [NSView] {
        view.layoutSubtreeIfNeeded()
        return rows.indices.compactMap {
            let cell = rowTable.view(atColumn: 0, row: $0, makeIfNecessary: true) as? SidebarTableCell
            cell?.layoutSubtreeIfNeeded()
            return cell?.content
        }
    }

    private func toggleLibraryFolder(pathKey: String) {
        if collapsedLibraryFolderPaths.contains(pathKey) {
            collapsedLibraryFolderPaths.remove(pathKey)
        } else {
            collapsedLibraryFolderPaths.insert(pathKey)
        }
        guard mode == .library else {
            return
        }
        rebuildRows()
    }

    private func isCurrentLibraryFile(_ fileURL: URL) -> Bool {
        guard let currentURL = sidebarEntries.first(where: \.isCurrent)?.fileURL else {
            return false
        }
        return FileIdentity.normalized(currentURL) == FileIdentity.normalized(fileURL)
    }

    private var hasLibrarySearchQuery: Bool {
        !normalizedLibrarySearchQuery.isEmpty
    }

    private var normalizedLibrarySearchQuery: String {
        librarySearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateLibrarySearchVisibility() {
        let isVisible = mode == .library && libraryController.hasLibrary
        librarySearchContainerView.isHidden = !isVisible
        librarySearchContainerHeightConstraint?.constant = isVisible ? 46 : 0
    }

    private func runLibrarySearchForCurrentQuery() {
        searchWork.cancel()
        librarySearchGeneration += 1
        let generation = librarySearchGeneration
        let query = normalizedLibrarySearchQuery

        guard !query.isEmpty else {
            librarySearchResults = []
            isLibrarySearchRunning = false
            lastLibrarySearchRanOnMainThread = nil
            if mode == .library {
                rebuildRows()
            }
            return
        }

        let files = libraryController.files
        let runner = librarySearchRunner
        isLibrarySearchRunning = true
        librarySearchResults = []
        if mode == .library {
            rebuildRows()
        }

        searchWork.submit(LibrarySearchInput(query: query, files: files)) { input, cancellation in
            if let runner { return runner(input.query, input.files) }
            return SidebarLibrarySearchRunResult(
                matches: LibrarySearch.fullTextMatches(query: input.query, in: input.files, includesSnippets: false, cancellation: cancellation),
                ranOnMainThread: Thread.isMainThread
            )
        } completion: { [weak self] result in
            guard let self, self.librarySearchGeneration == generation,
                  self.normalizedLibrarySearchQuery == query else { return }
            self.librarySearchResults = result.matches
            self.isLibrarySearchRunning = false
            self.lastLibrarySearchRanOnMainThread = result.ranOnMainThread
            if self.mode == .library { self.rebuildRows() }
        }
    }

    private func openLibrarySearchResult(_ match: LibrarySearch.FileMatch) {
        guard !isLibrarySearchRunning else { return }
        if let onSelectDocumentWithAnchor {
            onSelectDocumentWithAnchor(match.file.fileURL, match.matchedAnchorID)
        } else {
            onSelectDocument?(match.file.fileURL)
        }
    }

    private func updateActiveOutlineSelection() {
        for row in visibleRowViews.compactMap({ $0 as? SidebarOutlineRowView }) {
            row.isSelected = row.anchorID == activeOutlineAnchorID
        }
    }

    @objc
    private func handleLibraryDidChangeNotification(_ notification: Notification) {
        modeToggleView.setLibraryAvailable(libraryController.hasLibrary)
        if !libraryController.hasLibrary, mode == .library {
            setMode(.documents)
            return
        }
        guard notification.userInfo?["contentChanged"] as? Bool != false else {
            if notification.userInfo?["availabilityChanged"] as? Bool == true,
               isViewLoaded, mode == .library { rebuildRows() }
            return
        }
        libraryTree = nil
        if isViewLoaded, mode == .outline {
            rebuildRows()
        }
        guard isViewLoaded, mode == .library else {
            return
        }
        updateLibrarySearchVisibility()
        if hasLibrarySearchQuery {
            runLibrarySearchForCurrentQuery()
            return
        }
        rebuildRows()
    }
}
