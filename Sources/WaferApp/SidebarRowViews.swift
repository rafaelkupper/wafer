import AppKit
import WaferCore

enum SidebarRow: Equatable {
    case document(DocumentSidebarEntry)
    case outline(DocumentOutlineItem)
    case folder(title: String, path: String, level: Int, expanded: Bool)
    case file(LibraryFile, level: Int, current: Bool)
    case search(LibrarySearch.FileMatch, String)
    case backlink(Backlink)
    case backlinkHeader
    case footer(String)
    case message(String)

    var identity: String {
        switch self {
        case .document(let entry): "document:" + entry.fileURL.path
        case .outline(let item): "outline:" + item.anchorID
        case .folder(_, let path, _, _): "folder:" + path
        case .file(let file, _, _): "file:" + file.identity
        case .search(let match, _): "search:" + match.file.identity
        case .backlink(let backlink): "backlink:" + backlink.sourceFileURL.path
        case .backlinkHeader: "backlink-header"
        case .footer: "footer"
        case .message(let text): "message:\(text)"
        }
    }

    var height: CGFloat {
        switch self {
        case .document: 68
        case .outline: 26
        case .folder, .footer, .message: 32
        case .file: 48
        case .search: 80
        case .backlink: 60
        case .backlinkHeader: 36
        }
    }
}

@MainActor
final class SidebarTableCell: NSTableCellView {
    private var model: SidebarRow?
    private(set) var content: NSView?

    func configure(row: SidebarRow, makeView: () -> NSView) {
        guard model != row else { return }
        content?.removeFromSuperview()
        model = row
        let content = makeView()
        self.content = content
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

@MainActor
class SidebarSelectableRowView: NSView, ThemeApplying {
    static let cornerRadius: CGFloat = 7

    var onActivate: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    fileprivate var isHovering = false {
        didSet {
            guard oldValue != isHovering else {
                return
            }
            updateAppearance()
        }
    }

    var isSelected = false {
        didSet {
            guard oldValue != isSelected else {
                return
            }
            updateAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle-click activates too; the host routes it to a new tab.
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        onActivate?()
    }

    func updateAppearance() {
        let backgroundColor: NSColor
        if isSelected {
            backgroundColor = ReaderTheme.sidebarSelectionColor
        } else if isHovering {
            backgroundColor = ReaderTheme.sidebarHoverColor
        } else {
            backgroundColor = .clear
        }
        layer?.backgroundColor = backgroundColor.cgColor
    }

    func applyCurrentTheme() {
        updateAppearance()
    }
}

@MainActor
final class SidebarDocumentRowView: SidebarSelectableRowView {
    private let entry: DocumentSidebarEntry
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")

    init(entry: DocumentSidebarEntry) {
        self.entry = entry
        super.init(frame: .zero)

        isSelected = entry.isCurrent

        titleLabel.stringValue = entry.displayTitle
        titleLabel.font = .systemFont(ofSize: 13, weight: entry.isCurrent ? .semibold : .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        previewLabel.stringValue = entry.previewText
        previewLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        previewLabel.maximumNumberOfLines = 2
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, previewLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func applyCurrentTheme() {
        super.applyCurrentTheme()
        titleLabel.textColor = entry.isAvailable ? ReaderTheme.sidebarPrimaryTextColor : ReaderTheme.sidebarSecondaryTextColor
        previewLabel.textColor = entry.isAvailable
            ? ReaderTheme.sidebarSecondaryTextColor
            : ReaderTheme.sidebarSecondaryTextColor.withAlphaComponent(0.6)
    }
}

@MainActor
final class SidebarOutlineRowView: SidebarSelectableRowView {
    let anchorID: String

    private let titleLabel = NSTextField(labelWithString: "")
    private let itemLevel: Int
    private let rowLeadingInset: CGFloat

    init(item: DocumentOutlineItem, isActive: Bool) {
        self.anchorID = item.anchorID
        self.itemLevel = item.level
        self.rowLeadingInset = OutlineSidebarMetrics.leadingInset(for: item.level)
        super.init(frame: .zero)

        self.isSelected = isActive
        titleLabel.stringValue = item.title
        titleLabel.alignment = .left
        titleLabel.font = .systemFont(
            ofSize: OutlineSidebarMetrics.fontSize,
            weight: OutlineSidebarMetrics.fontWeight(for: item.level, isSelected: isActive)
        )
        titleLabel.textColor = OutlineSidebarMetrics.textColor(for: item.level, isSelected: isActive, isHovering: false)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.wraps = false
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: rowLeadingInset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: OutlineSidebarMetrics.rowVerticalInset),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -OutlineSidebarMetrics.rowVerticalInset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isSelected: Bool {
        didSet {
            updateAppearance()
        }
    }

    #if DEBUG
    var leadingInsetForTesting: CGFloat {
        rowLeadingInset
    }

    var labelMinXForTesting: CGFloat {
        titleLabel.frame.minX
    }
    #endif

    override func updateAppearance() {
        layer?.backgroundColor = NSColor.clear.cgColor
        titleLabel.font = .systemFont(
            ofSize: OutlineSidebarMetrics.fontSize,
            weight: OutlineSidebarMetrics.fontWeight(for: itemLevel, isSelected: isSelected)
        )
        titleLabel.textColor = OutlineSidebarMetrics.textColor(
            for: itemLevel,
            isSelected: isSelected,
            isHovering: isHovering
        )
    }
}

enum LibraryTreeNodeKind {
    case folder
    case file(LibraryFile)
}

struct LibraryTreeNode {
    let title: String
    let pathKey: String
    let kind: LibraryTreeNodeKind
    let children: [LibraryTreeNode]
}

enum LibraryTreeBuilder {
    private final class Folder {
        var folders: [String: Folder] = [:]
        var files: [LibraryFile] = []
    }

    static func build(files: [LibraryFile]) -> LibraryTreeNode {
        let root = Folder()
        for file in files {
            guard file.relativePathComponents.last != nil else {
                continue
            }

            var folder = root
            for component in file.relativePathComponents.dropLast() {
                if folder.folders[component] == nil {
                    folder.folders[component] = Folder()
                }
                folder = folder.folders[component]!
            }
            folder.files.append(file)
        }

        return LibraryTreeNode(title: "", pathKey: "", kind: .folder, children: childNodes(in: root, path: []))
    }

    private static func childNodes(in folder: Folder, path: [String]) -> [LibraryTreeNode] {
        let folderNodes = folder.folders.keys.sorted(by: localizedPathOrder).map { name in
            let childPath = path + [name]
            return LibraryTreeNode(
                title: name,
                pathKey: childPath.joined(separator: "/"),
                kind: .folder,
                children: childNodes(in: folder.folders[name]!, path: childPath)
            )
        }
        let fileNodes = folder.files.sorted { lhs, rhs in
            lhs.relativePathComponents.joined(separator: "/").localizedStandardCompare(
                rhs.relativePathComponents.joined(separator: "/")
            ) == .orderedAscending
        }.map { file in
            LibraryTreeNode(
                title: file.displayTitle,
                pathKey: file.relativePathComponents.joined(separator: "/"),
                kind: .file(file),
                children: []
            )
        }
        return folderNodes + fileNodes
    }

    private static func localizedPathOrder(lhs: String, rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

@MainActor
protocol SidebarLibraryRowTesting {
    #if DEBUG
    var libraryTitleForTesting: String { get }
    var primaryTextColorForTesting: NSColor? { get }
    #endif
}

@MainActor
final class SidebarLibraryFolderRowView: SidebarSelectableRowView, SidebarLibraryRowTesting {
    private let disclosureLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let level: Int
    private let isExpanded: Bool

    init(title: String, level: Int, isExpanded: Bool) {
        self.level = level
        self.isExpanded = isExpanded
        super.init(frame: .zero)

        disclosureLabel.stringValue = isExpanded ? "v" : ">"
        disclosureLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        disclosureLabel.alignment = .center
        disclosureLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(disclosureLabel)
        addSubview(titleLabel)
        let leading = CGFloat(12 + (level * 14))
        NSLayoutConstraint.activate([
            disclosureLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            disclosureLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureLabel.widthAnchor.constraint(equalToConstant: 12),

            titleLabel.leadingAnchor.constraint(equalTo: disclosureLabel.trailingAnchor, constant: 5),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    #if DEBUG
    var libraryTitleForTesting: String {
        titleLabel.stringValue
    }

    var primaryTextColorForTesting: NSColor? {
        titleLabel.textColor
    }
    #endif

    override func applyCurrentTheme() {
        super.applyCurrentTheme()
        disclosureLabel.textColor = ReaderTheme.sidebarSecondaryTextColor
        titleLabel.textColor = ReaderTheme.sidebarPrimaryTextColor.withAlphaComponent(isExpanded ? 0.94 : 0.82)
    }
}

@MainActor
final class SidebarLibraryFileRowView: SidebarSelectableRowView, SidebarLibraryRowTesting {
    private let file: LibraryFile
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    init(file: LibraryFile, level: Int, isCurrent: Bool) {
        self.file = file
        super.init(frame: .zero)

        isSelected = isCurrent

        titleLabel.stringValue = file.displayTitle
        titleLabel.font = .systemFont(ofSize: 12.5, weight: isCurrent ? .semibold : .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.stringValue = file.relativePathComponents.joined(separator: "/")
        pathLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, pathLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        let leading = CGFloat(28 + (level * 14))
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    #if DEBUG
    var relativePathForTesting: String {
        file.relativePathComponents.joined(separator: "/")
    }

    var libraryTitleForTesting: String {
        titleLabel.stringValue
    }

    var primaryTextColorForTesting: NSColor? {
        titleLabel.textColor
    }
    #endif

    override func applyCurrentTheme() {
        super.applyCurrentTheme()
        titleLabel.textColor = ReaderTheme.sidebarPrimaryTextColor
        pathLabel.textColor = ReaderTheme.sidebarSecondaryTextColor
    }
}

@MainActor
final class SidebarLibrarySearchResultRowView: SidebarSelectableRowView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    init(match: LibrarySearch.FileMatch) {
        super.init(frame: .zero)

        titleLabel.stringValue = match.file.displayTitle
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        snippetLabel.stringValue = match.snippet
        snippetLabel.font = .systemFont(ofSize: 11, weight: .regular)
        snippetLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.maximumNumberOfLines = 2
        snippetLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.stringValue = match.file.relativePathComponents.joined(separator: "/")
        pathLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, snippetLabel, pathLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    #if DEBUG
    var titleForTesting: String {
        titleLabel.stringValue
    }
    #endif

    override func applyCurrentTheme() {
        super.applyCurrentTheme()
        titleLabel.textColor = ReaderTheme.sidebarPrimaryTextColor
        snippetLabel.textColor = ReaderTheme.sidebarSecondaryTextColor.withAlphaComponent(0.9)
        pathLabel.textColor = ReaderTheme.sidebarSecondaryTextColor.withAlphaComponent(0.78)
    }
}

@MainActor
final class SidebarLibraryMessageRowView: NSView, ThemeApplying {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)

        label.stringValue = text
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    #if DEBUG
    var textForTesting: String {
        label.stringValue
    }
    #endif

    func applyCurrentTheme() {
        label.textColor = ReaderTheme.sidebarSecondaryTextColor.withAlphaComponent(0.72)
    }
}

@MainActor
final class SidebarLibraryFooterView: NSView, ThemeApplying {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)

        label.stringValue = text
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    #if DEBUG
    var textForTesting: String {
        label.stringValue
    }
    #endif

    func applyCurrentTheme() {
        label.textColor = ReaderTheme.sidebarSecondaryTextColor.withAlphaComponent(0.72)
    }
}

@MainActor
final class SidebarModeToggleView: NSView, ThemeApplying {
    private let containerStackView = NSStackView()
    private let libraryButton = SidebarModeButton(title: "Library")
    private let documentsButton = SidebarModeButton(title: "Docs")
    private let outlineButton = SidebarModeButton(title: "Outline")

    var onSelectMode: ((DocumentSidebarMode) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        containerStackView.orientation = .horizontal
        containerStackView.alignment = .centerY
        containerStackView.spacing = 4
        containerStackView.translatesAutoresizingMaskIntoConstraints = false

        libraryButton.onActivate = { [weak self] in
            self?.onSelectMode?(.library)
        }
        documentsButton.onActivate = { [weak self] in
            self?.onSelectMode?(.documents)
        }
        outlineButton.onActivate = { [weak self] in
            self?.onSelectMode?(.outline)
        }

        containerStackView.addArrangedSubview(libraryButton)
        containerStackView.addArrangedSubview(documentsButton)
        containerStackView.addArrangedSubview(outlineButton)
        addSubview(containerStackView)

        NSLayoutConstraint.activate([
            containerStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            containerStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            containerStackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            containerStackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setMode(_ mode: DocumentSidebarMode) {
        libraryButton.isSelected = mode == .library
        documentsButton.isSelected = mode == .documents
        outlineButton.isSelected = mode == .outline
    }

    func setLibraryAvailable(_ isAvailable: Bool) {
        libraryButton.isHidden = !isAvailable
    }

    func applyCurrentTheme() {
        layer?.backgroundColor = ReaderTheme.sidebarChromeFillColor.cgColor
        layer?.borderColor = ReaderTheme.sidebarChromeBorderColor.cgColor
        libraryButton.applyCurrentTheme()
        documentsButton.applyCurrentTheme()
        outlineButton.applyCurrentTheme()
    }

    #if DEBUG
    var availableTitlesForTesting: [String] {
        [libraryButton, documentsButton, outlineButton].compactMap { button in
            button.isHidden ? nil : button.titleForTesting
        }
    }
    #endif
}

@MainActor
final class SidebarModeButton: NSView, ThemeApplying {
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else {
                return
            }
            updateAppearance()
        }
    }

    var isSelected = false {
        didSet {
            guard oldValue != isSelected else {
                return
            }
            updateAppearance()
        }
    }

    var onActivate: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6

        label.stringValue = title
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        updateAppearance()
    }

    #if DEBUG
    var titleForTesting: String {
        label.stringValue
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    private func updateAppearance() {
        if isSelected {
            layer?.backgroundColor = ReaderTheme.sidebarChromeSelectedFillColor.cgColor
            label.textColor = ReaderTheme.sidebarPrimaryTextColor
        } else if isHovering {
            layer?.backgroundColor = ReaderTheme.sidebarChromeHoverFillColor.cgColor
            label.textColor = ReaderTheme.sidebarPrimaryTextColor.withAlphaComponent(0.92)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = ReaderTheme.sidebarSecondaryTextColor
        }
    }

    func applyCurrentTheme() {
        updateAppearance()
    }
}
