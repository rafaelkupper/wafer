import AppKit
import QuartzCore
import WaferCore

/// A window's content area: the hosted reader and, in edit mode, the editor
/// pane on its left.
///
/// Frames are set by hand rather than by constraints so that opening and
/// closing the pane can hold both layout widths fixed while the window
/// changes width: the editor is laid out at its final width and uncovered,
/// and the reader keeps its width, so neither the text view nor the web view
/// reflows during the animation.
@MainActor
final class DocumentContentSplitView: NSView, ThemeApplying {
    static let minimumPaneWidth: CGFloat = 240
    private static let handleWidth: CGFloat = 7

    /// Holds the hosted content view (the reader).
    private let mainSlot = NSView()
    /// Clips the editor while its pane is partly open.
    private let editorSlot = NSView()
    private let dividerLine = NSView()
    private let dividerHandle = SplitDividerHandleView()
    private weak var editorView: NSView?
    /// The editor's share of the width outside transitions.
    private(set) var editorFraction: CGFloat = 0.5
    private var transition: (revealed: CGFloat, layoutWidth: CGFloat)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        editorSlot.clipsToBounds = true
        editorSlot.isHidden = true
        dividerLine.wantsLayer = true
        dividerLine.isHidden = true
        dividerHandle.isHidden = true
        dividerHandle.onDrag = { [weak self] position in
            self?.setEditorWidth(position)
        }
        dividerHandle.onReset = { [weak self] in
            guard let self else { return }
            self.setEditorWidth(self.bounds.width / 2)
        }
        addSubview(mainSlot)
        addSubview(editorSlot)
        addSubview(dividerLine)
        addSubview(dividerHandle)
        layoutPanes()
        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var hasEditor: Bool {
        editorView != nil
    }

    /// Width of the visible part of the editor pane.
    var editorWidth: CGFloat {
        editorView == nil ? 0 : editorSlot.frame.width
    }

    var mainWidth: CGFloat {
        mainSlot.frame.width
    }

    var isInTransition: Bool {
        transition != nil
    }

    func embedMainView(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = mainSlot.bounds
        mainSlot.addSubview(view)
    }

    func installEditor(_ view: NSView) {
        editorView?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        editorSlot.addSubview(view)
        editorView = view
        layoutPanes()
    }

    func removeEditor() {
        editorView?.removeFromSuperview()
        editorView = nil
        transition = nil
        layoutPanes()
    }

    /// Starts a transition: `revealed` points of the editor show, and its
    /// content is laid out `layoutWidth` wide throughout.
    func beginTransition(revealed: CGFloat, layoutWidth: CGFloat) {
        transition = (revealed, layoutWidth)
        layoutPanes()
    }

    /// Changes how much of the editor shows. Takes effect at the next layout,
    /// so a window frame change in the same step lays the panes out once.
    func setRevealed(_ revealed: CGFloat) {
        guard let transition else { return }
        self.transition = (revealed, transition.layoutWidth)
        needsLayout = true
    }

    /// Ends a transition, keeping the editor at its current width.
    func endTransition() {
        guard transition != nil else { return }
        if hasEditor, bounds.width > 0 {
            editorFraction = editorSlot.frame.width / bounds.width
        }
        transition = nil
        layoutPanes()
    }

    func applyCurrentTheme() {
        dividerLine.layer?.backgroundColor = MarkdownEditorColors(palette: ReaderTheme.current).divider.cgColor
    }

    override func layout() {
        super.layout()
        layoutPanes()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutPanes()
    }

    private func setEditorWidth(_ width: CGFloat) {
        guard hasEditor, transition == nil, bounds.width > 0 else { return }
        editorFraction = Self.editorWidth(forFraction: width / bounds.width, totalWidth: bounds.width) / bounds.width
        layoutPanes()
    }

    static func editorWidth(forFraction fraction: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let minimum = min(minimumPaneWidth, (totalWidth / 2).rounded(.down))
        return min(max((totalWidth * fraction).rounded(), minimum), totalWidth - minimum)
    }

    private func layoutPanes() {
        let size = bounds.size
        guard let editorView else {
            editorSlot.isHidden = true
            dividerLine.isHidden = true
            dividerHandle.isHidden = true
            setFrame(NSRect(origin: .zero, size: size), of: mainSlot)
            return
        }

        let revealed: CGFloat
        let layoutWidth: CGFloat
        if let transition {
            revealed = min(max(transition.revealed, 0), size.width)
            layoutWidth = transition.layoutWidth
        } else {
            revealed = Self.editorWidth(forFraction: editorFraction, totalWidth: size.width)
            layoutWidth = revealed
        }

        editorSlot.isHidden = false
        setFrame(NSRect(x: 0, y: 0, width: revealed, height: size.height), of: editorSlot)
        setFrame(NSRect(x: 0, y: 0, width: layoutWidth, height: size.height), of: editorView)
        setFrame(NSRect(x: revealed, y: 0, width: size.width - revealed, height: size.height), of: mainSlot)
        dividerLine.isHidden = revealed < 1
        setFrame(NSRect(x: revealed - 1, y: 0, width: 1, height: size.height), of: dividerLine)
        dividerHandle.isHidden = transition != nil
        setFrame(
            NSRect(x: revealed - (Self.handleWidth - 1) / 2, y: 0, width: Self.handleWidth, height: size.height),
            of: dividerHandle
        )
    }

    private func setFrame(_ frame: NSRect, of view: NSView) {
        if view.frame != frame {
            view.frame = frame
        }
    }
}

/// Invisible strip over the divider: drag to resize the panes, double-click
/// to make them equal.
private final class SplitDividerHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onReset: (() -> Void)?
    private var grabOffset: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        grabOffset = convert(event.locationInWindow, from: nil).x - bounds.midX
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x - grabOffset)
    }
}

/// Where the window goes when the editor pane opens.
struct EditorPaneExpansion: Equatable {
    /// The window frame with the pane open.
    let frame: NSRect
    /// How much wider that is than before.
    let growth: CGFloat
    /// How far the window's right edge moved, when the left had no room.
    let rightShift: CGFloat
    /// The editor pane's width.
    let editorWidth: CGFloat

    /// The pane opens to the left and doubles the content width, so the
    /// reader keeps its size and place. With less room on screen the window
    /// takes what there is, moving right only if the left runs out, and the
    /// two panes share the result equally. A window that cannot resize (full
    /// screen) splits in place.
    static func plan(windowFrame: NSRect, contentWidth: CGFloat, visibleFrame: NSRect?, canResize: Bool) -> EditorPaneExpansion {
        var growth: CGFloat = 0
        if canResize {
            let room = visibleFrame.map { max($0.width - windowFrame.width, 0) } ?? .greatestFiniteMagnitude
            growth = min(contentWidth, room).rounded(.down)
        }
        var frame = windowFrame
        frame.size.width += growth
        frame.origin.x = max(windowFrame.minX - growth, min(windowFrame.minX, visibleFrame?.minX ?? -.greatestFiniteMagnitude))
        return EditorPaneExpansion(
            frame: frame,
            growth: growth,
            rightShift: frame.maxX - windowFrame.maxX,
            editorWidth: ((contentWidth + growth) / 2).rounded()
        )
    }

    /// The frame `progress` of the way between two frames that differ in
    /// width and horizontal position. Edges land on whole points.
    static func frame(from start: NSRect, to end: NSRect, progress: CGFloat) -> NSRect {
        let width = start.width + ((end.width - start.width) * progress).rounded()
        let maxX = start.maxX + ((end.maxX - start.maxX) * progress).rounded()
        return NSRect(x: maxX - width, y: end.minY, width: width, height: end.height)
    }
}

/// Drives a short animation from the display's refresh, calling `step` with
/// eased progress once per frame. Unlike an animator proxy it can be finished
/// early, and each step sets final values, so layout happens once per frame.
@MainActor
final class DisplayLinkedAnimation: NSObject {
    private let duration: TimeInterval
    private let step: (CGFloat) -> Void
    private var completion: (() -> Void)?
    private var link: CADisplayLink?
    private var startTimestamp: CFTimeInterval?
    private var watchdog: DispatchWorkItem?
    /// Frames drawn and the longest time one step took, for measurements.
    private(set) var frameCount = 0
    private(set) var slowestStep: TimeInterval = 0

    init(duration: TimeInterval, step: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        self.duration = duration
        self.step = step
        self.completion = completion
    }

    func start(in view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // The display link stops when the window is hidden or occluded.
        let watchdog = DispatchWorkItem { [weak self] in
            self?.finish()
        }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.5, execute: watchdog)
    }

    /// Jumps to the end state and completes. Safe to call more than once.
    func finish() {
        guard let completion else { return }
        self.completion = nil
        link?.invalidate()
        link = nil
        watchdog?.cancel()
        watchdog = nil
        step(1)
        completion()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let start = startTimestamp ?? link.timestamp
        startTimestamp = start
        let progress = (link.targetTimestamp - start) / duration
        if progress >= 1 {
            finish()
        } else if completion != nil {
            let began = CACurrentMediaTime()
            step(Self.eased(CGFloat(max(progress, 0))))
            frameCount += 1
            slowestStep = max(slowestStep, CACurrentMediaTime() - began)
        }
    }

    /// Ease in and out along a half cosine: starts and ends at rest, and the
    /// peak speed is only about 1.6 times the average, which keeps the steps
    /// between frames small over a long travel.
    static func eased(_ progress: CGFloat) -> CGFloat {
        (1 - cos(.pi * min(max(progress, 0), 1))) / 2
    }
}
