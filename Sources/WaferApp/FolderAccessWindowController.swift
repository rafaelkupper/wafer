import AppKit
import WaferCore

/// Wafer > Folder Access…: the folders Wafer remembers, whether it may
/// change them, and Remove, which stops access and deletes the bookmark.
/// The window is built the first time it is shown.
@MainActor
final class FolderAccessWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column {
        static let folder = NSUserInterfaceItemIdentifier("folder")
        static let access = NSUserInterfaceItemIdentifier("access")
        static let notes = NSUserInterfaceItemIdentifier("notes")
    }

    private let store: @MainActor () -> FolderAccessStore
    private var window: NSWindow?
    private let tableView = NSTableView()
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private var grants: [FolderGrantInfo] = []

    init(store: @escaping @MainActor () -> FolderAccessStore = { FolderAccessStore.shared }) {
        self.store = store
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(folderAccessDidChange(_:)), name: .folderAccessDidChange, object: nil
        )
    }

    @objc func showFolderAccess(_ sender: Any?) {
        let window = ensureWindow()
        reload()
        window.appearance = ReaderTheme.windowAppearance
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(sender)
    }

    static func summary(isSandboxed: Bool, isEmpty: Bool) -> String {
        guard isSandboxed else {
            return "This copy of Wafer is not sandboxed, so it can read every file your account can. No folders need to be granted."
        }
        let summary = "Wafer remembers these folders so that documents can show their images and linked files. It only reads folders marked Read only; it can also save in your library and in folders granted while editing. Removing a folder stops Wafer from using it, and a document that needs it asks again."
        return isEmpty ? summary + "\n\nNo folders are granted." : summary
    }

    static func text(for grant: FolderGrantInfo, column: NSUserInterfaceItemIdentifier) -> String {
        switch column {
        case Column.folder:
            grant.folderURL.path
        case Column.access:
            grant.mode == .readOnly ? "Read only" : "Read and write"
        default:
            [grant.isLibrary ? "Library" : nil, grant.isAvailable ? nil : "Not available"].compactMap { $0 }.joined(separator: ", ")
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        grants.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, grants.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? Self.makeCell(identifier)
        let text = Self.text(for: grants[row], column: identifier)
        cell.textField?.stringValue = text
        cell.textField?.toolTip = identifier == Column.folder ? text : nil
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    #if DEBUG
    var windowForTesting: NSWindow? { window }
    var summaryForTesting: String { summaryLabel.stringValue }
    var rowsForTesting: [[String]] {
        grants.map { grant in [Column.folder, Column.access, Column.notes].map { Self.text(for: grant, column: $0) } }
    }
    var isRemoveEnabledForTesting: Bool { removeButton.isEnabled }

    func selectRowForTesting(_ row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func removeSelectedForTesting() {
        removeSelected(nil)
    }
    #endif

    // MARK: Private

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true
        )
        window.title = "Folder Access"
        window.minSize = NSSize(width: 460, height: 260)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FolderAccess")

        for (identifier, title, width) in [
            (Column.folder, "Folder", 360.0), (Column.access, "Access", 110.0), (Column.notes, "", 100.0),
        ] {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = 60
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.setAccessibilityLabel("Granted folders")
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        removeButton.bezelStyle = .rounded
        removeButton.setAccessibilityHelp("Stops Wafer from using the selected folder and forgets it.")
        summaryLabel.textColor = .secondaryLabelColor

        let content = NSView()
        for view in [summaryLabel, scrollView, removeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            summaryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            summaryLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            removeButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            removeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            removeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
        self.window = window
        return window
    }

    private static func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = identifier == Column.folder ? .byTruncatingMiddle : .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func reload() {
        let store = store()
        let selectedID = grants.indices.contains(tableView.selectedRow) ? grants[tableView.selectedRow].id : nil
        grants = store.folderGrants
        summaryLabel.stringValue = Self.summary(isSandboxed: store.isSandboxed, isEmpty: grants.isEmpty)
        tableView.reloadData()
        if let selectedID, let row = grants.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateRemoveButton()
    }

    private func updateRemoveButton() {
        removeButton.isEnabled = grants.indices.contains(tableView.selectedRow)
    }

    @objc private func removeSelected(_ sender: Any?) {
        let row = tableView.selectedRow
        guard grants.indices.contains(row) else { return }
        store().revoke(grantID: grants[row].id)
        reload()
    }

    @objc private func folderAccessDidChange(_ notification: Notification) {
        guard window?.isVisible == true else { return }
        reload()
    }
}
