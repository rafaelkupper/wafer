import AppKit
import WaferCore

/// The custom, palette-exact tab strip (v1.2-W6). The view API frozen in W4
/// is unchanged (`reload`, select/close/move callbacks); `onCloseOtherTabs`
/// is an additive context-menu hook.
@MainActor
final class DocumentTabStripView: NSView, ThemeApplying {
    static let stripHeight: CGFloat = 30
    private static let dragThreshold: CGFloat = 4

    struct TabItem: Equatable {
        let title: String
    }

    var onSelectTab: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onMoveTab: ((_ fromIndex: Int, _ toIndex: Int) -> Void)?
    var onCloseOtherTabs: ((Int) -> Void)?

    private(set) var items: [TabItem] = []
    private(set) var selectedIndex = 0

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let bottomBorderView = NSView()
    private var tabViews: [TabItemView] = []

    // Drag-reorder state (spacer-based reflow).
    private var draggedTabView: TabItemView?
    private var dragSpacerView: NSView?
    private var dragOriginIndex = 0
    private var dragProjectedIndex = 0
    private var dragInitialMouseX: CGFloat = 0
    private var dragInitialTabMinX: CGFloat = 0
    private var isDragging = false
    private var dragCancelled = false
    private var escapeKeyMonitor: Any?

    var tabViewsForTesting: [NSView] {
        tabViews
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Document Tabs")

        stackView.orientation = .horizontal
        stackView.spacing = 4
        stackView.alignment = .centerY
        stackView.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = documentView

        bottomBorderView.translatesAutoresizingMaskIntoConstraints = false
        bottomBorderView.wantsLayer = true

        addSubview(scrollView)
        addSubview(bottomBorderView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.heightAnchor.constraint(equalToConstant: Self.stripHeight),

            bottomBorderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorderView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorderView.heightAnchor.constraint(equalToConstant: 1),
        ])

        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func reload(items: [TabItem], selectedIndex: Int) {
        cancelDragIfNeeded()
        self.items = items
        self.selectedIndex = items.indices.contains(selectedIndex) ? selectedIndex : 0
        rebuildTabViews()
    }

    func applyCurrentTheme() {
        layer?.backgroundColor = ReaderTheme.tabBarBackgroundColor.cgColor
        bottomBorderView.layer?.backgroundColor = ReaderTheme.tabBarBorderColor.cgColor
        for tabView in tabViews {
            tabView.applyCurrentTheme()
        }
    }

    // MARK: - Item construction

    private func rebuildTabViews() {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        tabViews.removeAll()

        for (index, item) in items.enumerated() {
            let tabView = TabItemView(
                title: item.title,
                isSelected: index == selectedIndex
            )
            tabView.onSelect = { [weak self] in
                self?.onSelectTab?(index)
            }
            tabView.onClose = { [weak self] in
                self?.onCloseTab?(index)
            }
            tabView.onCloseOthers = { [weak self] in
                self?.onCloseOtherTabs?(index)
            }
            tabView.onDragEvent = { [weak self, weak tabView] phase, event in
                guard let self, let tabView else {
                    return
                }
                self.handleDrag(phase: phase, event: event, tabView: tabView)
            }
            tabViews.append(tabView)
            stackView.addArrangedSubview(tabView)
        }
        applyCurrentTheme()
    }

    // MARK: - Drag-reorder (local tracking, spacer reflow)

    enum DragPhase {
        case began
        case moved
        case ended
    }

    private func handleDrag(phase: DragPhase, event: NSEvent, tabView: TabItemView) {
        switch phase {
        case .began:
            guard let index = tabViews.firstIndex(where: { $0 === tabView }) else {
                return
            }
            dragOriginIndex = index
            dragProjectedIndex = index
            dragInitialMouseX = stackView.convert(event.locationInWindow, from: nil).x
            dragInitialTabMinX = tabView.frame.minX
            isDragging = false
            dragCancelled = false
        case .moved:
            let mouseX = stackView.convert(event.locationInWindow, from: nil).x
            if !isDragging {
                guard abs(mouseX - dragInitialMouseX) > Self.dragThreshold else {
                    return
                }
                beginDrag(of: tabView)
            }
            guard isDragging, !dragCancelled else {
                return
            }
            continueDrag(of: tabView, mouseX: mouseX)
        case .ended:
            finishDrag(of: tabView)
        }
    }

    private func beginDrag(of tabView: TabItemView) {
        isDragging = true
        draggedTabView = tabView

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: tabView.frame.width).isActive = true
        spacer.heightAnchor.constraint(equalToConstant: tabView.frame.height).isActive = true
        dragSpacerView = spacer

        let frameInStack = tabView.frame
        stackView.removeArrangedSubview(tabView)
        stackView.insertArrangedSubview(spacer, at: dragOriginIndex)
        // Float the dragged tab above its siblings at its current position.
        tabView.translatesAutoresizingMaskIntoConstraints = true
        tabView.frame = frameInStack
        tabView.setFloating(true)

        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                MainActor.assumeIsolated {
                    self?.cancelDragIfNeeded()
                }
                return nil
            }
            return event
        }
    }

    private func continueDrag(of tabView: TabItemView, mouseX: CGFloat) {
        let deltaX = mouseX - dragInitialMouseX
        let proposedMidX = dragInitialTabMinX + deltaX + tabView.frame.width / 2
        let clampedMidX = TabStripReorderMath.clampedDragMidX(
            proposed: proposedMidX,
            tabWidth: tabView.frame.width,
            stripWidth: stackView.bounds.width
        )
        tabView.frame.origin.x = clampedMidX - tabView.frame.width / 2

        var midXs: [CGFloat] = []
        for (index, view) in stackView.arrangedSubviews.enumerated() {
            if index == dragProjectedIndex {
                midXs.append(clampedMidX)
            } else {
                midXs.append(view.frame.midX)
            }
        }
        let projected = TabStripReorderMath.projectedInsertionIndex(
            draggedIndex: dragProjectedIndex,
            draggedMidX: clampedMidX,
            tabMidXs: midXs
        )
        guard projected != dragProjectedIndex, let dragSpacerView else {
            return
        }

        dragProjectedIndex = projected
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            stackView.removeArrangedSubview(dragSpacerView)
            stackView.insertArrangedSubview(dragSpacerView, at: projected)
            stackView.layoutSubtreeIfNeeded()
        }
    }

    private func finishDrag(of tabView: TabItemView) {
        removeEscapeMonitor()
        guard isDragging, !dragCancelled else {
            // A plain click: selection already happened on mouse-down.
            cleanUpDragViews(restoreAt: dragOriginIndex)
            return
        }

        let targetIndex = dragProjectedIndex
        cleanUpDragViews(restoreAt: targetIndex)
        if targetIndex != dragOriginIndex {
            onMoveTab?(dragOriginIndex, targetIndex)
        }
    }

    private func cancelDragIfNeeded() {
        removeEscapeMonitor()
        guard isDragging else {
            return
        }

        dragCancelled = true
        cleanUpDragViews(restoreAt: dragOriginIndex)
    }

    private func cleanUpDragViews(restoreAt index: Int) {
        guard let draggedTabView else {
            isDragging = false
            return
        }

        if let dragSpacerView {
            stackView.removeArrangedSubview(dragSpacerView)
            dragSpacerView.removeFromSuperview()
        }
        draggedTabView.setFloating(false)
        draggedTabView.translatesAutoresizingMaskIntoConstraints = false
        if stackView.arrangedSubviews.count >= index {
            stackView.insertArrangedSubview(draggedTabView, at: index)
        } else {
            stackView.addArrangedSubview(draggedTabView)
        }

        self.draggedTabView = nil
        dragSpacerView = nil
        isDragging = false
    }

    private func removeEscapeMonitor() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
    }
}

/// One themed tab segment: title, hover state, hover/selected close button,
/// context menu, and accessibility as a radio-button tab.
@MainActor
final class TabItemView: NSView, ThemeApplying {
    private let titleLabel: NSTextField
    private let closeButton = NSButton()
    private let isSelected: Bool
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else {
                return
            }
            updateCloseButtonVisibility()
            applyCurrentTheme()
        }
    }

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onCloseOthers: (() -> Void)?
    var onDragEvent: ((DocumentTabStripView.DragPhase, NSEvent) -> Void)?

    var titleForTesting: String {
        titleLabel.stringValue
    }

    var isSelectedForTesting: Bool {
        isSelected
    }

    var closeButtonForTesting: NSButton {
        closeButton
    }

    init(title: String, isSelected: Bool) {
        self.titleLabel = NSTextField(labelWithString: title)
        self.isSelected = isSelected
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        setAccessibilityValue(isSelected ? 1 : 0)

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close \(title)")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed(_:))
        closeButton.setAccessibilityLabel("Close \(title)")

        addSubview(closeButton)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 3),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])

        let menu = NSMenu()
        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(contextCloseTab(_:)), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)
        let closeOthersItem = NSMenuItem(title: "Close Other Tabs", action: #selector(contextCloseOtherTabs(_:)), keyEquivalent: "")
        closeOthersItem.target = self
        menu.addItem(closeOthersItem)
        self.menu = menu

        updateCloseButtonVisibility()
        applyCurrentTheme()
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
        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        onDragEvent?(.began, event)
    }

    override func mouseDragged(with event: NSEvent) {
        onDragEvent?(.moved, event)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEvent?(.ended, event)
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    @objc private func closeButtonPressed(_ sender: Any?) {
        onClose?()
    }

    @objc private func contextCloseTab(_ sender: Any?) {
        onClose?()
    }

    @objc private func contextCloseOtherTabs(_ sender: Any?) {
        onCloseOthers?()
    }

    func setFloating(_ floating: Bool) {
        layer?.zPosition = floating ? 10 : 0
        if floating {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.28
            layer?.shadowRadius = 5
            layer?.shadowOffset = CGSize(width: 0, height: -1)
            layer?.setAffineTransform(CGAffineTransform(scaleX: 1.03, y: 1.03))
        } else {
            layer?.shadowOpacity = 0
            layer?.setAffineTransform(.identity)
        }
    }

    private func updateCloseButtonVisibility() {
        // Always present for accessibility; visually revealed on hover or
        // selection.
        closeButton.alphaValue = (isHovering || isSelected) ? 1 : 0
    }

    func applyCurrentTheme() {
        let fill: NSColor
        if isSelected {
            fill = ReaderTheme.tabSelectedFillColor
        } else if isHovering {
            fill = ReaderTheme.tabHoverFillColor
        } else {
            fill = ReaderTheme.tabRestingFillColor
        }
        layer?.backgroundColor = fill.cgColor
        titleLabel.textColor = isSelected
            ? ReaderTheme.tabSelectedTextColor
            : ReaderTheme.tabUnselectedTextColor
        closeButton.contentTintColor = ReaderTheme.tabCloseIconColor
    }
}
