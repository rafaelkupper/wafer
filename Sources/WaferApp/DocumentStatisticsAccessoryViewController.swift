import AppKit
import WaferCore

@MainActor
final class DocumentStatisticsAccessoryViewController: NSTitlebarAccessoryViewController, ThemeApplying {
    private static let trailingInset: CGFloat = 14
    private static let minimumContainerHeight: CGFloat = 28
    private static let controlSpacing: CGFloat = 6

    private let preferenceStore: DocumentStatisticPreferenceStore
    private let notificationCenter: NotificationCenter
    private let containerView = NSView()
    private let stackView = NSStackView()
    private let pillView = DocumentStatisticsPillView()
    private static let copyConfirmationDuration: TimeInterval = 1.4

    private let sidebarButton = TitlebarAccessoryIconButtonView(symbolName: "sidebar.left")
    private static let editSymbol = "square.and.pencil"
    private let editButton = TitlebarAccessoryIconButtonView(symbolName: editSymbol)
    private static let copyTextSymbol = "doc.on.doc"
    private static let copyFileSymbol = "doc"

    private let copyButton = TitlebarAccessoryIconButtonView(symbolName: copyTextSymbol)
    private let copyFileButton = TitlebarAccessoryIconButtonView(symbolName: copyFileSymbol)
    private var statistics: DocumentStatistics?
    private var copyConfirmationWorkItems: [ObjectIdentifier: DispatchWorkItem] = [:]

    var onToggleSidebar: (() -> Void)? {
        get { sidebarButton.onActivate }
        set { sidebarButton.onActivate = newValue }
    }

    var onToggleEditing: (() -> Void)? {
        get { editButton.onActivate }
        set { editButton.onActivate = newValue }
    }

    /// Each copy callback returns true on success, which shows a brief checkmark.
    var onCopyDocument: (() -> Bool)?
    var onCopyFile: (() -> Bool)?

    init(
        preferenceStore: DocumentStatisticPreferenceStore = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.preferenceStore = preferenceStore
        self.notificationCenter = notificationCenter
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right
        fullScreenMinHeight = DocumentStatisticsPillView.defaultHeight
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    override func loadView() {
        // AppKit sizes titlebar accessories from the root frame. Only the
        // contents use Auto Layout; do not constrain the root as well.
        containerView.translatesAutoresizingMaskIntoConstraints = true

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = Self.controlSpacing
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false

        pillView.onActivate = { [weak self] in
            self?.showMetricMenu()
        }
        pillView.translatesAutoresizingMaskIntoConstraints = false
        pillView.setContentHuggingPriority(.required, for: .horizontal)
        pillView.setContentCompressionResistancePriority(.required, for: .horizontal)

        editButton.accessibilityLabelText = "Edit Markdown"
        editButton.toolTip = "Edit Markdown (⌘E)"
        copyButton.accessibilityLabelText = "Copy Markdown Text"
        copyButton.toolTip = "Copy Markdown Text"
        copyButton.onActivate = { [weak self] in
            guard let self else { return }
            self.performCopy(self.onCopyDocument, button: self.copyButton, restingSymbol: Self.copyTextSymbol)
        }
        copyFileButton.accessibilityLabelText = "Copy File"
        copyFileButton.toolTip = "Copy File"
        copyFileButton.onActivate = { [weak self] in
            guard let self else { return }
            self.performCopy(self.onCopyFile, button: self.copyFileButton, restingSymbol: Self.copyFileSymbol)
        }

        for button in [editButton, copyButton, copyFileButton, sidebarButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        stackView.addArrangedSubview(pillView)
        stackView.addArrangedSubview(editButton)
        stackView.addArrangedSubview(copyButton)
        stackView.addArrangedSubview(copyFileButton)
        stackView.addArrangedSubview(sidebarButton)
        containerView.addSubview(stackView)

        let trailing = stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -Self.trailingInset)
        trailing.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            // AppKit can temporarily constrain the accessory narrower while
            // recomputing titlebar placement. Let its intrinsic width win next pass.
            trailing,
            stackView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
        ])

        view = containerView

        notificationCenter.addObserver(
            self,
            selector: #selector(handleStatisticKindChange),
            name: .documentStatisticKindDidChange,
            object: nil
        )

        updateDisplay()
        applyCurrentTheme()
    }

    func apply(statistics: DocumentStatistics?) {
        self.statistics = statistics
        updateDisplay()
    }

    func setSidebarActive(_ isActive: Bool) {
        sidebarButton.isActive = isActive
    }

    func setEditingActive(_ isActive: Bool) {
        editButton.isActive = isActive
    }

    #if DEBUG
    var editButtonIsActiveForTesting: Bool {
        editButton.isActive
    }

    func triggerEditToggleForTesting() {
        editButton.onActivate?()
    }
    #endif

    func applyCurrentTheme() {
        pillView.applyCurrentTheme()
        editButton.applyCurrentTheme()
        copyButton.applyCurrentTheme()
        copyFileButton.applyCurrentTheme()
        sidebarButton.applyCurrentTheme()
    }

    private func performCopy(
        _ copy: (() -> Bool)?,
        button: TitlebarAccessoryIconButtonView,
        restingSymbol: String
    ) {
        guard copy?() == true else {
            NSSound.beep()
            return
        }

        let key = ObjectIdentifier(button)
        copyConfirmationWorkItems[key]?.cancel()
        button.setSymbol("checkmark")
        let workItem = DispatchWorkItem { [weak button] in
            button?.setSymbol(restingSymbol)
        }
        copyConfirmationWorkItems[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copyConfirmationDuration, execute: workItem)
    }

    #if DEBUG
    var copyButtonSymbolForTesting: String {
        copyButton.symbolName
    }

    var copyFileButtonSymbolForTesting: String {
        copyFileButton.symbolName
    }

    func triggerCopyDocumentForTesting() {
        copyButton.onActivate?()
    }

    func triggerCopyFileForTesting() {
        copyFileButton.onActivate?()
    }

    var displayedTextForTesting: String? {
        guard !pillView.isHidden else {
            return nil
        }

        return pillView.displayText
    }

    var sidebarButtonIsActiveForTesting: Bool {
        sidebarButton.isActive
    }

    var preferredWidthForTesting: CGFloat {
        preferredContentSize.width
    }

    func triggerSidebarToggleForTesting() {
        sidebarButton.onActivate?()
    }
    #endif

    @objc
    func selectKind(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let kind = DocumentStatisticKind(rawValue: rawValue)
        else {
            return
        }

        preferenceStore.selectedKind = kind
    }

    @objc
    private func handleStatisticKindChange() {
        updateDisplay()
    }

    private func updateDisplay() {
        if let statistics {
            pillView.displayText = statistics.displayText(for: preferenceStore.selectedKind)
            pillView.isHidden = false
        } else {
            pillView.isHidden = true
        }

        let containerSize = NSSize(
            width: clusterWidth() + Self.trailingInset,
            height: Self.minimumContainerHeight
        )
        preferredContentSize = containerSize
        containerView.setFrameSize(containerSize)
    }

    private func clusterWidth() -> CGFloat {
        let visibleViews = stackView.arrangedSubviews.filter { !$0.isHidden }
        guard !visibleViews.isEmpty else {
            return 0
        }

        let widths = visibleViews.map { view in
            let intrinsic = view.intrinsicContentSize.width
            if intrinsic > 0 {
                return intrinsic
            }
            return view.fittingSize.width
        }

        return widths.reduce(0, +) + (Self.controlSpacing * CGFloat(max(visibleViews.count - 1, 0)))
    }

    private func showMetricMenu() {
        let menu = NSMenu()
        let selectedKind = preferenceStore.selectedKind

        for kind in DocumentStatisticKind.allCases {
            let item = NSMenuItem(
                title: statistics?.displayText(for: kind) ?? kind.title,
                action: #selector(selectKind(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.state = kind == selectedKind ? .on : .off
            item.representedObject = kind.rawValue
            menu.addItem(item)
        }

        let anchor = NSPoint(x: pillView.bounds.maxX - 8, y: pillView.bounds.minY - 6)
        menu.popUp(positioning: nil, at: anchor, in: pillView)
    }
}

@MainActor
private final class DocumentStatisticsPillView: NSView, ThemeApplying {
    static let defaultHeight: CGFloat = 20
    private static let minimumWidth: CGFloat = 84

    private let label = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else {
                return
            }

            updateAppearance()
        }
    }

    var onActivate: (() -> Void)?

    var displayText: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1

        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [label, imageView])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.defaultHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth),
        ])

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        let imageSize = imageView.intrinsicContentSize
        return NSSize(
            width: max(Self.minimumWidth, labelSize.width + imageSize.width + 19),
            height: Self.defaultHeight
        )
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

    func applyCurrentTheme() {
        label.textColor = ReaderTheme.statisticsLabelColor
        imageView.contentTintColor = ReaderTheme.statisticsIconColor
        layer?.backgroundColor = (
            isHovering
                ? ReaderTheme.statisticsPillHoverBackgroundColor
                : ReaderTheme.statisticsPillRestingBackgroundColor
        ).cgColor
        layer?.borderColor = isHovering
            ? ReaderTheme.statisticsPillHoverBorderColor.cgColor
            : NSColor.clear.cgColor
    }

    private func updateAppearance() {
        applyCurrentTheme()
    }
}

@MainActor
final class TitlebarAccessoryIconButtonView: NSView, ThemeApplying {
    static let defaultSize = NSSize(width: 20, height: 20)

    private let imageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else {
                return
            }

            updateAppearance()
        }
    }

    var isActive = false {
        didSet {
            guard oldValue != isActive else {
                return
            }

            updateAppearance()
        }
    }

    var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else {
                return
            }

            if !isEnabled {
                isHovering = false
            }
            setAccessibilityEnabled(isEnabled)
            updateAppearance()
        }
    }

    var accessibilityLabelText: String? {
        didSet {
            setAccessibilityLabel(accessibilityLabelText)
        }
    }

    var onActivate: (() -> Void)?

    #if DEBUG
    var imageTintForTesting: NSColor? {
        imageView.contentTintColor
    }

    var imageAlphaForTesting: CGFloat {
        imageView.alphaValue
    }
    #endif

    private(set) var symbolName: String

    init(symbolName: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityEnabled(true)

        setSymbol(symbolName)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: Self.defaultSize.width),
            heightAnchor.constraint(equalToConstant: Self.defaultSize.height),
        ])

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        Self.defaultSize
    }

    func setSymbol(_ name: String) {
        symbolName = name
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
    }

    // Titlebar accessory buttons must not participate in the titlebar's
    // drag machinery - otherwise rapid clicks register as a titlebar
    // double-click and zoom (maximize) the window.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func mouseUp(with event: NSEvent) {
        // Consume; never let the titlebar interpret the click sequence.
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
        guard isEnabled else {
            return
        }
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            return
        }
        onActivate?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else {
            return false
        }

        onActivate?()
        return true
    }

    func applyCurrentTheme() {
        let backgroundColor: NSColor
        if isActive {
            backgroundColor = ReaderTheme.statisticsIconButtonActiveBackgroundColor
        } else if isHovering {
            backgroundColor = ReaderTheme.statisticsIconButtonHoverBackgroundColor
        } else {
            backgroundColor = ReaderTheme.statisticsIconButtonRestingBackgroundColor
        }

        imageView.contentTintColor = ReaderTheme.statisticsIconButtonColor
        imageView.alphaValue = isEnabled ? 1 : 0.35
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = (isHovering || isActive)
            ? ReaderTheme.statisticsIconButtonHoverBorderColor.cgColor
            : NSColor.clear.cgColor
    }

    private func updateAppearance() {
        applyCurrentTheme()
    }
}
