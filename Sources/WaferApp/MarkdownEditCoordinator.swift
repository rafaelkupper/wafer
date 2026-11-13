import AppKit
import WaferCore

/// What edit mode needs from the document it edits.
@MainActor
protocol MarkdownEditCoordinatorDelegate: AnyObject {
    /// The reader that shows the live preview.
    var livePreviewReader: WebKitReaderViewController? { get }
    /// Renders `text`, the editor's current text, as a live preview update.
    func editCoordinator(_ coordinator: MarkdownEditCoordinator, renderLive text: String)
    /// The file now holds the bytes with this fingerprint and format: after a
    /// save, or after the editor adopted a version from disk.
    func editCoordinator(
        _ coordinator: MarkdownEditCoordinator,
        didUpdateDiskFingerprint fingerprint: String,
        format: MarkdownTextFormat
    )
}

/// Edit mode for one document: the source editor, its save session and
/// autosave, the throttled live preview, and scroll sync between the panes.
/// The document keeps the file, the reader, and the window.
@MainActor
final class MarkdownEditCoordinator {
    struct Configuration {
        var resolveConflict: EditConflictResolver
        var autosaveDelay: TimeInterval
        var liveRenderInterval: TimeInterval
        var fileWriter: MarkdownEditSession.FileWriter = MarkdownEditSession.replaceContents
    }

    /// Whether the editor shows the reader's line yet. Until it does, neither
    /// pane follows the other, so the reader stays where the user left it.
    private enum Alignment {
        case aligned
        /// Edit mode just started or another file was loaded.
        case awaiting
        /// The page is reporting the line at its top.
        case measuring
    }

    weak var delegate: MarkdownEditCoordinatorDelegate?
    private let configuration: Configuration
    /// One queue per document, so its saves never overlap, across files too.
    private let saveWorker: MarkdownSaveWorker
    private(set) var isEditing = false
    private(set) var editor: MarkdownSourceEditorViewController?
    private(set) var session: MarkdownEditSession?
    private var autosaveWorkItem: DispatchWorkItem?
    /// A background save requested while one was running: whether it may
    /// prompt. It starts when the running save finishes.
    private var queuedBackgroundSave: Bool?
    private var liveRenderWorkItem: DispatchWorkItem?
    private var alignment = Alignment.aligned
    /// Bumped by each load and by the end of edit mode, so a line reported
    /// for an earlier text is ignored.
    private var alignmentGeneration = 0
    private var resignActiveObserver: NSObjectProtocol?

    init(configuration: Configuration) {
        self.configuration = configuration
        self.saveWorker = MarkdownSaveWorker(writer: configuration.fileWriter)
    }

    // MARK: Lifecycle

    /// Creates the editor and enters edit mode. The caller loads a file
    /// with `load(_:fileURL:)` and shows the editor.
    func start() -> MarkdownSourceEditorViewController {
        let editor = MarkdownSourceEditorViewController()
        editor.onTextChange = { [weak self] in
            self?.editorTextDidChange()
        }
        editor.onScroll = { [weak self] position in
            self?.editorDidScroll(to: position)
        }
        self.editor = editor
        isEditing = true
        return editor
    }

    /// Opens `source` (LF-normalized text) in the editor with a new save
    /// session. Undo is cleared, and the editor waits to be aligned with
    /// the reader.
    func load(_ source: LoadedMarkdownSource, fileURL: URL) {
        guard isEditing, let editor else { return }
        session?.finishPendingSave()
        let session = MarkdownEditSession(
            fileURL: fileURL,
            text: source.sourceText,
            fingerprint: source.fingerprint,
            format: source.format,
            resolveConflict: configuration.resolveConflict,
            worker: saveWorker
        )
        self.session = session
        editor.load(text: source.sourceText)
        session.editorShowsSavedText(revision: editor.revision)
        alignment = .awaiting
        alignmentGeneration += 1
    }

    /// Leaves edit mode without saving. The editor stays on screen, inert,
    /// while its pane closes.
    func end() {
        stopTimers()
        session?.finishPendingSave()
        isEditing = false
        editor?.endSession()
        editor = nil
        session = nil
        alignment = .aligned
        alignmentGeneration += 1
        stopObservingDeactivation()
    }

    /// Stops the timers and the deactivation observer (document close).
    func stop() {
        stopTimers()
        stopObservingDeactivation()
    }

    /// Unsaved text is saved when the app deactivates, without prompting.
    func observeDeactivation() {
        guard resignActiveObserver == nil else { return }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Never prompt while the app is in the background.
                self?.saveInBackground(promptsOnConflict: false)
            }
        }
    }

    private func stopObservingDeactivation() {
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
    }

    // MARK: Saving

    /// True when Revert Edits would change the text.
    var canRevert: Bool {
        guard isEditing, let session, let editor else { return false }
        return editor.text != session.baselineText
    }

    /// Restores the text from when the editor last loaded the file, as one
    /// undoable edit that autosave then writes.
    func revertToBaseline() {
        guard isEditing, let session, let editor else { return }
        editor.replaceAllUndoably(with: session.baselineText)
    }

    /// Saves unsaved editor text and waits for the result (explicit saves,
    /// navigation, closing, quitting). A background save in flight finishes
    /// first. Returns true when nothing unsaved remains: the text was saved
    /// or unchanged, or the user discarded the edits.
    @discardableResult
    func flush(interactive: Bool) -> Bool {
        guard isEditing, let session, let editor else { return true }
        editor.commitComposition()
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        queuedBackgroundSave = nil

        session.finishPendingSave()
        let outcome = editor.revision == session.savedRevision
            ? .unchanged
            : session.save(editor.snapshot, interactive: interactive)
        delegate?.editCoordinator(self, didUpdateDiskFingerprint: session.savedFingerprint, format: session.format)
        switch outcome {
        case .unchanged, .saved:
            return true
        case .reverted(let text):
            editor.replaceTextPreservingPosition(text)
            session.editorShowsSavedText(revision: editor.revision)
            renderLive()
            return true
        case .keptInMemory:
            return false
        }
    }

    /// The file changed on disk while editing. Without unsaved edits the
    /// editor adopts the new text; with them, an interactive save reports the
    /// conflict. Returns false when the bytes are the ones last loaded or
    /// saved, so there is nothing to adopt.
    func adoptDiskVersion(_ loadedSource: LoadedMarkdownSource) -> Bool {
        guard let session, let editor else { return true }
        // A save that just finished may be what changed the file.
        finishPendingSave(of: session)
        guard loadedSource.fingerprint != session.savedFingerprint else {
            return false
        }

        guard editor.revision == session.savedRevision || !session.hasUnsavedChanges(editor.text) else {
            // Both sides changed: the save path detects the conflict and asks.
            flush(interactive: true)
            return true
        }

        let text = MarkdownTextFormat.normalizingLineEndings(loadedSource.sourceText)
        session.rebase(text: text, fingerprint: loadedSource.fingerprint, format: loadedSource.format)
        delegate?.editCoordinator(self, didUpdateDiskFingerprint: loadedSource.fingerprint, format: loadedSource.format)
        editor.replaceTextPreservingPosition(text)
        session.editorShowsSavedText(revision: editor.revision)
        renderLive()
        return true
    }

    private func editorTextDidChange() {
        scheduleAutosave()
        scheduleLiveRender()
    }

    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autosaveWorkItem = nil
            self.saveInBackground(promptsOnConflict: true)
        }
        autosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.autosaveDelay, execute: workItem)
    }

    /// Saves a snapshot of the editor text on the save worker, so typing
    /// never waits for file I/O. One save runs at a time; a request made
    /// meanwhile starts when it finishes. After a conflict, an interactive
    /// save on the main thread asks the user when `promptsOnConflict`;
    /// otherwise the edits stay in memory for the next save.
    private func saveInBackground(promptsOnConflict: Bool) {
        guard isEditing, let session, let editor else { return }
        guard !session.isSaving else {
            queuedBackgroundSave = (queuedBackgroundSave ?? false) || promptsOnConflict
            return
        }

        editor.commitComposition()
        guard editor.revision != session.savedRevision else { return }
        // Refused only while a conflict prompt is open; its save covers this text.
        session.saveInBackground(editor.snapshot) { [weak self, weak session] outcome in
            guard let self, let session, session === self.session else { return }
            self.backgroundSaveDidFinish(outcome, in: session, promptsOnConflict: promptsOnConflict)
        }
    }

    /// Lets a background save in flight finish now and passes its result to
    /// the document. A save requested meanwhile goes back on the autosave
    /// schedule, since the finished save's completion does not run.
    private func finishPendingSave(of session: MarkdownEditSession) {
        guard session.isSaving else { return }
        session.finishPendingSave()
        delegate?.editCoordinator(self, didUpdateDiskFingerprint: session.savedFingerprint, format: session.format)
        if queuedBackgroundSave != nil {
            queuedBackgroundSave = nil
            scheduleAutosave()
        }
    }

    private func backgroundSaveDidFinish(
        _ outcome: MarkdownEditSession.BackgroundOutcome,
        in session: MarkdownEditSession,
        promptsOnConflict: Bool
    ) {
        delegate?.editCoordinator(self, didUpdateDiskFingerprint: session.savedFingerprint, format: session.format)
        let queued = queuedBackgroundSave
        queuedBackgroundSave = nil
        switch outcome {
        case .saved:
            if let queued {
                saveInBackground(promptsOnConflict: queued)
            }
        case .conflict:
            if promptsOnConflict || queued == true {
                flush(interactive: true)
            }
        }
    }

    private func stopTimers() {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        queuedBackgroundSave = nil
        liveRenderWorkItem?.cancel()
        liveRenderWorkItem = nil
    }

    // MARK: Live preview

    /// Throttled rather than debounced so the preview keeps up during
    /// continuous typing: at most one render per `liveRenderInterval`.
    private func scheduleLiveRender() {
        guard liveRenderWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.liveRenderWorkItem = nil
            self.renderLive()
        }
        liveRenderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.liveRenderInterval, execute: workItem)
    }

    /// Renders the editor's current text into the preview.
    func renderLive() {
        guard isEditing, let editor else { return }
        delegate?.editCoordinator(self, renderLive: editor.text)
    }

    // MARK: Scroll sync

    /// The editor position a live patch aligns the preview with, or nil
    /// while the editor is not aligned with the reader yet.
    var editorPositionForPreview: EditorScrollPosition? {
        isEditing && alignment == .aligned ? editor?.currentScrollPosition : nil
    }

    /// A live update was patched into the page (not a full load).
    func previewDidPatch() {
        guard alignment != .aligned else { return }
        alignEditorToPreview()
    }

    /// After a full page load while editing: align the editor with the
    /// preview once (entering edit mode, navigating), otherwise keep the
    /// preview following the editor.
    func previewDidLoadPage() {
        guard isEditing, let editor, let reader = delegate?.livePreviewReader else { return }
        if alignment != .aligned {
            alignEditorToPreview()
        } else {
            reader.syncScroll(to: editor.currentScrollPosition)
        }
    }

    /// The user scrolled the preview: the editor follows without reporting back.
    func previewDidScroll(toSourceLine line: Double) {
        guard isEditing, alignment == .aligned, let editor else { return }
        editor.scroll(toSourceLine: line)
        // Scrolling can finish laying out text and change the editor's range.
        delegate?.livePreviewReader?.updateScrollSyncMetrics(editor.currentScrollPosition)
    }

    private func editorDidScroll(to position: EditorScrollPosition) {
        guard isEditing, alignment == .aligned else { return }
        delegate?.livePreviewReader?.syncScroll(to: position)
    }

    /// Puts the editor at the source line the reader is showing. The page
    /// takes its own position as the synced one, so the reader does not move.
    /// The panes start following each other only once the answer is in:
    /// until then the editor sits at an approximate position that must not
    /// be pushed to the reader.
    private func alignEditorToPreview() {
        guard isEditing, alignment == .awaiting, let editor, let reader = delegate?.livePreviewReader else { return }
        alignment = .measuring
        let generation = alignmentGeneration
        reader.sourceLineAtTop(for: editor.currentScrollPosition) { [weak self] line in
            guard let self, self.alignmentGeneration == generation, self.isEditing, let editor = self.editor else { return }
            self.alignment = .aligned
            if let line {
                editor.scroll(toSourceLine: line)
            }
        }
    }
}
