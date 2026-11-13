import AppKit
import WaferCore

/// Where the editor is scrolled, in fractional 1-based source lines.
struct EditorScrollPosition: Equatable {
    /// The line at the top of the visible area.
    let line: Double
    /// The lines at the top when scrolled all the way up and all the way
    /// down: the editor's scroll range. `topLine` is below 1 by the top inset.
    let topLine: Double
    let bottomLine: Double
    /// How many source lines fit in the visible area.
    let visibleLines: Double
    let totalLines: Int

    static let zero = EditorScrollPosition(line: 1, topLine: 1, bottomLine: 1, visibleLines: 0, totalLines: 0)

    /// True when only `line` differs: the scroll range is the same.
    func hasSameMetrics(as other: EditorScrollPosition?) -> Bool {
        guard let other else { return false }
        return topLine == other.topLine && bottomLine == other.bottomLine
            && visibleLines == other.visibleLines && totalLines == other.totalLines
    }
}

/// Plain-text view for Markdown source. Owns its undo stack so edits never
/// mark the NSDocument as edited, and routes Wafer's find commands to the
/// system find bar while it has focus.
final class MarkdownSourceTextView: NSTextView {
    @objc func showFindInterface(_ sender: Any?) {
        performFinderAction(.showFindInterface)
    }

    @objc func findNextMatch(_ sender: Any?) {
        performFinderAction(.nextMatch)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        performFinderAction(.previousMatch)
    }

    @objc func undo(_ sender: Any?) {
        undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        undoManager?.redo()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(showFindInterface(_:)), #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)):
            return true
        case #selector(undo(_:)):
            return undoManager?.canUndo == true
        case #selector(redo(_:)):
            return undoManager?.canRedo == true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    private func performFinderAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }
}

@MainActor
final class MarkdownSourceEditorViewController: NSViewController, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate, ThemeApplying {
    static let fontSize: CGFloat = 13
    /// Up to this many UTF-16 units the whole text is laid out before scroll
    /// positions are read (about 0.4 ms per 1,000 units), so the scroll range
    /// is exact. Longer texts use TextKit's estimate until its background
    /// layout catches up.
    static let fullLayoutLimit = 80_000

    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private let textView: MarkdownSourceTextView
    private let scrollView = NSScrollView()
    private let editorUndoManager = UndoManager()
    private let highlighter = MarkdownSourceHighlighter()
    private var structure: MarkdownSourceStructure
    private var colors = MarkdownEditorColors(palette: ReaderTheme.current)
    private var pendingEditedRange: NSRange?
    private var pendingChangeInLength = 0
    private var isApplyingProgrammaticScroll = false
    private var scrollReportScheduled = false
    /// The last position reported or set, so bounds notifications that change
    /// nothing (layout passes) are not reported as scrolls.
    private var lastKnownScrollPosition: EditorScrollPosition?

    private let regularFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    private let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        let spaceWidth = ("    " as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
        ]).width
        style.defaultTabInterval = spaceWidth
        style.tabStops = []
        return style
    }()

    /// Called after each user edit (not for programmatic loads).
    var onTextChange: (() -> Void)?
    /// Called when the user scrolls the editor (coalesced per run loop turn).
    var onScroll: ((EditorScrollPosition) -> Void)?

    init() {
        textView = MarkdownSourceTextView(frame: .zero, textContainer: textContainer)
        structure = highlighter.structure(of: "")
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var text: String {
        textStorage.string
    }

    /// Increases with every change to the text, typed or programmatic, so
    /// saving can tell whether the text moved on without comparing it.
    private(set) var revision = 0

    /// An immutable copy of the text and the revision it belongs to.
    var snapshot: EditSnapshot {
        EditSnapshot(text: text, revision: revision)
    }

    var textViewForTesting: NSTextView {
        textView
    }

    var undoManagerForTesting: UndoManager {
        editorUndoManager
    }

    override func loadView() {
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        textStorage.delegate = self

        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.setAccessibilityLabel("Markdown source")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        scrollView.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        view = scrollView
        applyCurrentTheme()
    }

    // MARK: Text loading

    /// Replaces the text without undo, for opening a file in the editor.
    func load(text: String) {
        loadViewIfNeeded()
        replaceAllProgrammatically(with: text)
        editorUndoManager.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scrollToTop()
    }

    /// Adopts text that changed on disk: keeps the selection and scroll
    /// position as close as possible and clears undo (the old steps no longer
    /// apply to the new text).
    func replaceTextPreservingPosition(_ text: String) {
        loadViewIfNeeded()
        let selection = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        replaceAllProgrammatically(with: text)
        editorUndoManager.removeAllActions()
        let length = textStorage.length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        isApplyingProgrammaticScroll = true
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isApplyingProgrammaticScroll = false
    }

    /// Replaces all text as one undoable edit (Revert Edits).
    func replaceAllUndoably(with text: String) {
        loadViewIfNeeded()
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard textView.shouldChangeText(in: fullRange, replacementString: text) else {
            return
        }
        textStorage.replaceCharacters(in: fullRange, with: text)
        textView.didChangeText()
        editorUndoManager.setActionName("Revert Edits")
    }

    func focus() {
        view.window?.makeFirstResponder(textView)
    }

    /// Edit mode ended: the view may stay on screen while its pane closes,
    /// but it no longer accepts or reports anything.
    func endSession() {
        loadViewIfNeeded()
        textView.isEditable = false
        onTextChange = nil
        onScroll = nil
    }

    /// Commits any in-progress input-method composition before saving.
    func commitComposition() {
        if textView.hasMarkedText() {
            textView.unmarkText()
        }
    }

    private func replaceAllProgrammatically(with text: String) {
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
        textStorage.endEditing()
        pendingEditedRange = nil
        pendingChangeInLength = 0
        rehighlightAll()
    }

    // MARK: Editing callbacks

    func undoManager(for view: NSTextView) -> UndoManager? {
        editorUndoManager
    }

    /// Keeps the text LF-only, as saving expects. Text with CR or CRLF line
    /// endings (pasted, dropped, or inserted by a service) goes in normalized
    /// instead, as its own undo step, with the insertion point after it.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString, replacementString.utf16.contains(0x0D) else {
            return true
        }

        let normalized = MarkdownTextFormat.normalizingLineEndings(replacementString)
        textView.breakUndoCoalescing()
        // Asks again with LF-only text, which this method lets through.
        guard textView.shouldChangeText(in: affectedCharRange, replacementString: normalized) else {
            return false
        }
        textStorage.replaceCharacters(in: affectedCharRange, with: normalized)
        textView.didChangeText()
        let insertionPoint = NSRange(location: affectedCharRange.location + (normalized as NSString).length, length: 0)
        textView.setSelectedRange(insertionPoint)
        textView.scrollRangeToVisible(insertionPoint)
        return false
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else {
            return
        }

        revision += 1
        if let pending = pendingEditedRange {
            // Shift the earlier range by this edit and merge.
            let shifted = pending.location >= editedRange.location
                ? NSRange(location: max(pending.location + delta, editedRange.location), length: pending.length)
                : NSRange(location: pending.location, length: max(pending.length + delta, 0))
            pendingEditedRange = NSUnionRange(shifted, editedRange)
        } else {
            pendingEditedRange = editedRange
        }
        pendingChangeInLength += delta
    }

    func textDidChange(_ notification: Notification) {
        guard !textView.hasMarkedText() else {
            return
        }

        if let editedRange = pendingEditedRange {
            let delta = pendingChangeInLength
            pendingEditedRange = nil
            pendingChangeInLength = 0
            rehighlight(afterEditIn: editedRange, changeInLength: delta)
        }
        onTextChange?()
    }

    // MARK: Highlighting

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: regularFont,
            .foregroundColor: colors.text,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private func rehighlightAll() {
        structure = highlighter.structure(of: textStorage.string as NSString)
        applyHighlighting(lines: 0..<structure.lineCount)
    }

    private func rehighlight(afterEditIn editedRange: NSRange, changeInLength delta: Int) {
        let snapshot = textStorage.string as NSString
        let previous = structure
        let current = highlighter.structure(of: snapshot)
        structure = current

        var start = min(editedRange.location, current.length)
        var end = min(NSMaxRange(editedRange), current.length)
        if let changedFrom = Self.firstStructuralChange(previous: previous, current: current, editedRange: editedRange, delta: delta) {
            start = min(start, changedFrom)
            end = current.length
        }

        // Widen to whole fenced blocks so multi-line code tokens stay right.
        if let block = current.block(containing: start) {
            start = min(start, block.range.location)
        }
        if let block = current.block(containing: end) {
            end = max(end, NSMaxRange(block.range))
        }

        let firstLine = current.lineIndex(containing: start)
        let lastLine = current.lineIndex(containing: end)
        applyHighlighting(lines: firstLine..<(lastLine + 1), text: snapshot)
    }

    /// The first location where block structure differs from what the edit
    /// alone predicts (blocks after the edit shift, the block containing it
    /// grows or shrinks), or nil when only the edited lines need recoloring.
    static func firstStructuralChange(
        previous: MarkdownSourceStructure,
        current: MarkdownSourceStructure,
        editedRange: NSRange,
        delta: Int
    ) -> Int? {
        let editStart = editedRange.location
        let oldEditEnd = NSMaxRange(editedRange) - delta
        let predicted = previous.blocks.map { block -> (MarkdownSourceStructure.Block.Kind, NSRange) in
            if block.range.location >= oldEditEnd {
                return (block.kind, NSRange(location: block.range.location + delta, length: block.range.length))
            }
            if NSMaxRange(block.range) < editStart {
                return (block.kind, block.range)
            }
            return (block.kind, NSRange(location: block.range.location, length: max(block.range.length + delta, 0)))
        }

        let count = max(predicted.count, current.blocks.count)
        for index in 0..<count {
            guard index < predicted.count, index < current.blocks.count else {
                let candidates = [predicted[safe: index]?.1.location, current.blocks[safe: index]?.range.location]
                return candidates.compactMap { $0 }.min() ?? editStart
            }
            let block = current.blocks[index]
            if predicted[index].0 != block.kind || predicted[index].1 != block.range {
                return min(predicted[index].1.location, block.range.location, editStart)
            }
        }
        return nil
    }

    private func applyHighlighting(lines: Range<Int>, text: NSString? = nil) {
        guard !lines.isEmpty, textStorage.length > 0 else {
            textView.typingAttributes = baseAttributes()
            return
        }

        let snapshot = text ?? (textStorage.string as NSString)
        let lastLine = min(lines.upperBound, structure.lineCount) - 1
        let start = structure.lineStarts[lines.lowerBound]
        let end = lastLine + 1 < structure.lineCount ? structure.lineStarts[lastLine + 1] : structure.length
        let range = NSRange(location: start, length: end - start)
        let tokens = highlighter.tokens(in: snapshot, structure: structure, lines: lines.lowerBound..<(lastLine + 1))

        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes(), range: range)
        for token in tokens {
            apply(token)
        }
        textStorage.endEditing()
        textView.typingAttributes = baseAttributes()
    }

    private func apply(_ token: MarkdownSourceToken) {
        let range = token.range
        switch token.kind {
        case .headingMarker, .headingText:
            textStorage.addAttributes([.foregroundColor: colors.heading, .font: boldFont], range: range)
        case .quoteMarker, .listMarker, .taskMarker:
            textStorage.addAttribute(.foregroundColor, value: colors.link, range: range)
        case .quoteText:
            textStorage.addAttribute(.foregroundColor, value: colors.secondaryText, range: range)
        case .thematicBreak, .tableDelimiter, .escape, .fenceDelimiter, .frontMatterDelimiter, .frontMatterValue, .linkDestination:
            textStorage.addAttribute(.foregroundColor, value: colors.secondaryText, range: range)
        case .strong:
            addTrait(.boldFontMask, range: range)
        case .emphasis:
            addTrait(.italicFontMask, range: range)
        case .strikethrough:
            textStorage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: colors.secondaryText,
            ], range: range)
        case .highlight:
            textStorage.addAttribute(.foregroundColor, value: colors.syntaxAtom, range: range)
        case .inlineCode:
            textStorage.addAttributes([
                .foregroundColor: colors.syntaxString,
                .backgroundColor: colors.inlineCodeBackground,
                .font: regularFont,
            ], range: range)
        case .linkText, .wikiLink, .footnote:
            textStorage.addAttribute(.foregroundColor, value: colors.link, range: range)
        case .html:
            textStorage.addAttribute(.foregroundColor, value: colors.syntaxKeyword, range: range)
        case .codeText:
            textStorage.addAttribute(.foregroundColor, value: colors.syntaxVariable, range: range)
        case .code(let kind):
            textStorage.addAttribute(.foregroundColor, value: colors.color(for: kind), range: range)
        case .frontMatterKey:
            textStorage.addAttribute(.foregroundColor, value: colors.syntaxDefinition, range: range)
        }
    }

    private func addTrait(_ trait: NSFontTraitMask, range: NSRange) {
        textStorage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? regularFont
            let converted = NSFontManager.shared.convert(font, toHaveTrait: trait)
            textStorage.addAttribute(.font, value: converted, range: subrange)
        }
    }

    func applyCurrentTheme() {
        colors = MarkdownEditorColors(palette: ReaderTheme.current)
        scrollView.backgroundColor = colors.background
        textView.backgroundColor = colors.background
        textView.drawsBackground = true
        textView.insertionPointColor = colors.text
        textView.selectedTextAttributes = [
            .backgroundColor: colors.selection,
            .foregroundColor: colors.selectionText,
        ]
        scrollView.appearance = ReaderTheme.windowAppearance
        if isViewLoaded {
            rehighlightAll()
        }
    }

    // MARK: Scrolling

    private var defaultLineHeight: CGFloat {
        layoutManager.defaultLineHeight(for: regularFont) + paragraphStyle.lineSpacing
    }

    private var maximumScrollOffset: CGFloat {
        max(textView.frame.height - scrollView.contentView.bounds.height, 0)
    }

    private func completeLayoutIfAffordable() {
        if textStorage.length <= Self.fullLayoutLimit {
            layoutManager.ensureLayout(for: textContainer)
        }
    }

    /// The fractional source line at a document offset. Above the first line
    /// (the top inset) it keeps counting down, so the value is continuous
    /// over the whole scroll range.
    private func sourceLine(atOffset offset: CGFloat) -> Double {
        let containerY = offset - textView.textContainerOrigin.y
        guard containerY > 0, textStorage.length > 0 else {
            return 1 + Double(containerY / defaultLineHeight)
        }

        let glyphIndex = layoutManager.glyphIndex(for: NSPoint(x: 0, y: containerY), in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let lineIndex = structure.lineIndex(containing: characterIndex)
        let rect = boundingRect(ofLine: lineIndex)
        let fraction = rect.height > 0 ? min(max((containerY - rect.minY) / rect.height, 0), 1) : 0
        return Double(lineIndex + 1) + Double(fraction)
    }

    /// Inverse of `sourceLine(atOffset:)`.
    private func offset(forSourceLine line: Double) -> CGFloat {
        let originY = textView.textContainerOrigin.y
        guard line >= 1, structure.lineCount > 0, textStorage.length > 0 else {
            return max(originY + CGFloat(line - 1) * defaultLineHeight, 0)
        }

        let clamped = min(line, Double(structure.lineCount) + 1)
        let index = min(Int(clamped.rounded(.down)) - 1, structure.lineCount - 1)
        let fraction = min(max(clamped - Double(index + 1), 0), 1)
        let rect = boundingRect(ofLine: index)
        return max(rect.minY + rect.height * CGFloat(fraction) + originY, 0)
    }

    var currentScrollPosition: EditorScrollPosition {
        completeLayoutIfAffordable()
        let visible = scrollView.contentView.bounds
        let line = sourceLine(atOffset: visible.minY)
        return EditorScrollPosition(
            line: line,
            topLine: sourceLine(atOffset: 0),
            bottomLine: sourceLine(atOffset: maximumScrollOffset),
            visibleLines: max(sourceLine(atOffset: visible.maxY) - line, 1),
            totalLines: structure.lineCount
        )
    }

    /// Scrolls so the given fractional 1-based source line is at the top.
    /// Does not report the scroll back through `onScroll`.
    func scroll(toSourceLine line: Double) {
        loadViewIfNeeded()
        completeLayoutIfAffordable()
        scrollProgrammatically(to: offset(forSourceLine: line))
    }

    /// Scrolls to a fraction of the scroll range, as a first approximation
    /// of the reader's position before the exact line is known.
    func scroll(toFraction fraction: Double) {
        loadViewIfNeeded()
        completeLayoutIfAffordable()
        scrollProgrammatically(to: maximumScrollOffset * CGFloat(min(max(fraction, 0), 1)))
    }

    private func scrollToTop() {
        scrollProgrammatically(to: 0)
    }

    private func scrollProgrammatically(to offset: CGFloat) {
        let target = NSPoint(x: 0, y: min(max(offset, 0), maximumScrollOffset))
        guard scrollView.contentView.bounds.origin != target else {
            return
        }

        isApplyingProgrammaticScroll = true
        scrollView.contentView.scroll(to: target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isApplyingProgrammaticScroll = false
        lastKnownScrollPosition = currentScrollPosition
    }

    private func boundingRect(ofLine index: Int) -> NSRect {
        let lineRange = structure.lineRange(at: index)
        let characterRange = NSRange(location: lineRange.location, length: max(lineRange.length, 1))
        let clamped = NSIntersectionRange(characterRange, NSRange(location: 0, length: textStorage.length))
        guard clamped.length > 0 else {
            return layoutManager.extraLineFragmentRect
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard !isApplyingProgrammaticScroll, !scrollReportScheduled else {
            return
        }

        scrollReportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollReportScheduled = false
            let position = self.currentScrollPosition
            guard position != self.lastKnownScrollPosition else { return }
            self.lastKnownScrollPosition = position
            self.onScroll?(position)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
