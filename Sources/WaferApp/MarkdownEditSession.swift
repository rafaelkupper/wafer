import AppKit
import os
import WaferCore

enum EditConflictKind: Equatable, Sendable {
    /// The file's bytes differ from what Wafer last loaded or saved.
    case changedOnDisk
    /// The file no longer exists at its path.
    case missingOnDisk
    /// Reading or writing the file failed.
    case writeFailed(String)
}

enum EditConflictResolution: Equatable {
    /// Write the editor text to the file anyway.
    case overwrite
    /// Drop unsaved edits: take the disk version, or the last saved text when
    /// there is nothing usable on disk.
    case discardMine
    /// Write the editor text to another file; the original keeps its disk state.
    case saveCopy(URL)
    /// Keep the edits in memory without saving (only offered for write failures).
    case cancel
}

typealias EditConflictResolver = @MainActor (_ kind: EditConflictKind, _ fileURL: URL) -> EditConflictResolution

/// The editor text at one moment and the editor revision it was taken at.
/// Saves work on these immutable copies, never on live editor state.
struct EditSnapshot: Sendable {
    let text: String
    /// Nil when the text did not come from an editor.
    let revision: Int?
}

/// Save bookkeeping for one file open in the editor. Text is LF-normalized;
/// `format` converts it back to the file's encoding, byte-order mark, and
/// dominant line ending. State changes and conflict prompts happen on the
/// main actor; the file I/O runs on a `MarkdownSaveWorker`.
@MainActor
final class MarkdownEditSession {
    /// Replaces the file at `url` with `data` without ever leaving a partial
    /// file. `beforeReplacing` runs once the new bytes are staged, right
    /// before they replace the file; when it throws, the file is left as it
    /// was and the error propagates.
    typealias FileWriter = @Sendable (_ url: URL, _ data: Data, _ beforeReplacing: () throws -> Void) throws -> Void

    enum Outcome: Equatable {
        /// The text matches the last loaded or saved text; nothing was written.
        case unchanged
        /// The file now holds the text (or the text was saved as a copy and
        /// the original has nothing to restore).
        case saved
        /// Edits were dropped; the editor must show this text.
        case reverted(String)
        /// Edits remain unsaved (cancelled, or a conflict outside an
        /// interactive save).
        case keptInMemory
    }

    /// The result of a background save, delivered on the main actor.
    enum BackgroundOutcome: Equatable {
        /// The file holds the snapshot's text (written, or already there).
        case saved
        /// Nothing was written. An interactive save resolves the conflict.
        case conflict(EditConflictKind)
    }

    let fileURL: URL
    private(set) var savedText: String
    private(set) var savedFingerprint: String
    private(set) var format: MarkdownTextFormat
    /// Text when the editor last loaded the file; Revert Edits restores it.
    private(set) var baselineText: String
    /// The editor revision whose text is `savedText`, when known. It lets
    /// callers skip comparing the whole text after every keystroke.
    private(set) var savedRevision: Int?
    private let resolveConflict: EditConflictResolver
    private let worker: MarkdownSaveWorker
    private var isResolvingConflict = false
    private var pendingSave: PendingSave?

    init(
        fileURL: URL,
        text: String,
        fingerprint: String,
        format: MarkdownTextFormat,
        resolveConflict: @escaping EditConflictResolver,
        worker: MarkdownSaveWorker = MarkdownSaveWorker()
    ) {
        self.fileURL = fileURL
        self.savedText = text
        self.savedFingerprint = fingerprint
        self.format = format
        self.baselineText = text
        self.resolveConflict = resolveConflict
        self.worker = worker
    }

    /// Adopts a new disk version (external change while clean).
    func rebase(text: String, fingerprint: String, format: MarkdownTextFormat) {
        savedText = text
        savedFingerprint = fingerprint
        self.format = format
        baselineText = text
        savedRevision = nil
    }

    /// The editor now shows `savedText` at `revision` (after loading the file
    /// or adopting a disk version).
    func editorShowsSavedText(revision: Int) {
        savedRevision = revision
    }

    func hasUnsavedChanges(_ text: String) -> Bool {
        text != savedText
    }

    /// True while a background save runs.
    var isSaving: Bool {
        pendingSave != nil
    }

    // MARK: Saving

    /// Saves `snapshot` if it differs from the saved text, after any
    /// background save has finished. The disk is compared with the last
    /// loaded or saved bytes immediately before the file is replaced; any
    /// difference is a conflict. Non-interactive saves never prompt and
    /// leave conflicting edits in memory.
    func save(_ snapshot: EditSnapshot, interactive: Bool) -> Outcome {
        finishPendingSave()
        if let revision = snapshot.revision, revision == savedRevision {
            return .unchanged
        }
        guard !isResolvingConflict else {
            return snapshot.text == savedText ? .unchanged : .keptInMemory
        }

        switch worker.perform(request(for: snapshot, overwrite: false)) {
        case .unchanged:
            markSaved(snapshot, fingerprint: savedFingerprint)
            return .unchanged
        case .written(let fingerprint):
            markSaved(snapshot, fingerprint: fingerprint)
            return .saved
        case .conflict(let kind, let diskData):
            guard interactive else {
                return .keptInMemory
            }
            return resolve(kind, diskData: diskData, snapshot: snapshot)
        }
    }

    func save(_ text: String, interactive: Bool) -> Outcome {
        save(EditSnapshot(text: text, revision: nil), interactive: interactive)
    }

    /// Starts saving `snapshot` on the worker and returns at once; the caller
    /// never waits for file I/O. `completion` runs on the main actor unless a
    /// synchronous save takes the result first. Returns false, starting
    /// nothing, while another save or a conflict prompt is running.
    @discardableResult
    func saveInBackground(
        _ snapshot: EditSnapshot,
        completion: @escaping @MainActor (BackgroundOutcome) -> Void
    ) -> Bool {
        guard pendingSave == nil, !isResolvingConflict else {
            return false
        }

        let request = request(for: snapshot, overwrite: false)
        let slot = SaveResultSlot()
        pendingSave = PendingSave(request: request, slot: slot, completion: completion)
        // The session stays alive until its save is delivered.
        worker.performInBackground(request) { attempt in
            slot.store(attempt)
            DispatchQueue.main.async {
                self.deliverPendingSave(from: slot, callingCompletion: true)
            }
        }
        return true
    }

    /// Waits for a background save in flight and applies its result. Its
    /// completion is not called: the caller saves next and handles conflicts.
    func finishPendingSave() {
        guard let pendingSave else { return }
        worker.waitUntilIdle()
        deliverPendingSave(from: pendingSave.slot, callingCompletion: false)
    }

    private func deliverPendingSave(from slot: SaveResultSlot, callingCompletion: Bool) {
        guard let pending = pendingSave, pending.slot === slot, let attempt = slot.take() else {
            return
        }

        pendingSave = nil
        let outcome: BackgroundOutcome
        switch attempt {
        case .unchanged:
            markSaved(pending.request.snapshot, fingerprint: savedFingerprint)
            outcome = .saved
        case .written(let fingerprint):
            markSaved(pending.request.snapshot, fingerprint: fingerprint)
            outcome = .saved
        case .conflict(let kind, _):
            outcome = .conflict(kind)
        }
        if callingCompletion {
            pending.completion(outcome)
        }
    }

    private func resolve(_ firstConflict: EditConflictKind, diskData: Data?, snapshot: EditSnapshot) -> Outcome {
        var conflict = firstConflict
        let restorableDiskData = conflict == .changedOnDisk ? diskData : nil
        isResolvingConflict = true
        defer { isResolvingConflict = false }
        while true {
            switch resolveConflict(conflict, fileURL) {
            case .overwrite:
                switch worker.perform(request(for: snapshot, overwrite: true)) {
                case .written(let fingerprint):
                    markSaved(snapshot, fingerprint: fingerprint)
                    return .saved
                case .unchanged:
                    markSaved(snapshot, fingerprint: savedFingerprint)
                    return .saved
                case .conflict(let kind, _):
                    conflict = kind
                }
            case .discardMine:
                return discardEdits(diskData: restorableDiskData)
            case .saveCopy(let copyURL):
                do {
                    try format.encode(snapshot.text).write(to: copyURL, options: .atomic)
                } catch {
                    conflict = .writeFailed(error.localizedDescription)
                    continue
                }
                if restorableDiskData != nil {
                    return discardEdits(diskData: restorableDiskData)
                }
                // Nothing usable on disk: the edits now live in the copy.
                savedText = snapshot.text
                savedRevision = snapshot.revision
                return .saved
            case .cancel:
                return .keptInMemory
            }
        }
    }

    private func discardEdits(diskData: Data?) -> Outcome {
        if let diskData, let decoded = MarkdownTextFormat.decode(diskData) {
            rebase(
                text: MarkdownTextFormat.normalizingLineEndings(decoded.text),
                fingerprint: FileFingerprint.sha256Hex(for: diskData),
                format: decoded.format
            )
        }
        savedRevision = nil
        return .reverted(savedText)
    }

    private func markSaved(_ snapshot: EditSnapshot, fingerprint: String) {
        savedText = snapshot.text
        savedFingerprint = fingerprint
        savedRevision = snapshot.revision
    }

    private func request(for snapshot: EditSnapshot, overwrite: Bool) -> MarkdownSaveRequest {
        MarkdownSaveRequest(
            fileURL: fileURL,
            snapshot: snapshot,
            savedText: savedText,
            expectedFingerprint: savedFingerprint,
            format: format,
            overwrite: overwrite
        )
    }

    // MARK: Writing

    /// Writes beside the file and swaps it in, so readers never see a partial
    /// file and the original keeps its permissions and creation date. There
    /// is no in-place fallback: when the swap fails, the original stays as it
    /// was and the error is thrown.
    nonisolated static func replaceContents(
        of url: URL,
        with data: Data,
        beforeReplacing: () throws -> Void = {}
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            try beforeReplacing()
            // Nothing to preserve; an atomic write never leaves a partial file either.
            try data.write(to: url, options: .atomic)
            return
        }

        let replacementDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: url,
            create: true
        )
        defer {
            // A failed swap can leave the original in the replacement
            // directory; keep the directory unless the file is back in place.
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: replacementDirectory)
            }
        }

        let temporaryURL = replacementDirectory.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temporaryURL)
        try beforeReplacing()
        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } catch {
            if !fileManager.fileExists(atPath: url.path),
               let original = (error as NSError).userInfo["NSFileOriginalItemLocationKey"] as? URL {
                try? fileManager.moveItem(at: original, to: url)
            }
            throw error
        }
    }

    // MARK: Conflict UI

    /// Default conflict UI: an app-modal alert, plus a save panel for copies.
    static func presentConflict(_ kind: EditConflictKind, fileURL: URL) -> EditConflictResolution {
        let name = fileURL.lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .warning
        let choices: [(String, EditConflictResolution?)]
        switch kind {
        case .changedOnDisk:
            alert.messageText = "\(name) changed on disk while you were editing it."
            alert.informativeText = "Keep your version and overwrite the file, use the version on disk, or save your version as a separate file."
            choices = [("Keep My Edits", .overwrite), ("Use Disk Version", .discardMine), ("Save a Copy…", nil)]
        case .missingOnDisk:
            alert.messageText = "\(name) was moved or deleted while you were editing it."
            alert.informativeText = "Save it again at its original location, save your version somewhere else, or discard your unsaved edits."
            choices = [("Save", .overwrite), ("Save a Copy…", nil), ("Discard My Edits", .discardMine)]
        case .writeFailed(let message):
            alert.messageText = "Wafer couldn't save \(name)."
            alert.informativeText = message
            choices = [("Save a Copy…", nil), ("Discard My Edits", .discardMine), ("Cancel", .cancel)]
        }
        for choice in choices {
            alert.addButton(withTitle: choice.0)
        }

        while true {
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard choices.indices.contains(index) else {
                return .cancel
            }
            if let resolution = choices[index].1 {
                return resolution
            }

            let panel = NSSavePanel()
            panel.directoryURL = fileURL.deletingLastPathComponent()
            panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + " copy." + fileURL.pathExtension
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
                return .saveCopy(url)
            }
            // Panel cancelled: ask again rather than losing the edits.
        }
    }
}

/// A background save in flight: what it writes, where its result lands, and
/// what runs when it is delivered.
@MainActor
private final class PendingSave {
    let request: MarkdownSaveRequest
    let slot: SaveResultSlot
    let completion: @MainActor (MarkdownEditSession.BackgroundOutcome) -> Void

    init(
        request: MarkdownSaveRequest,
        slot: SaveResultSlot,
        completion: @escaping @MainActor (MarkdownEditSession.BackgroundOutcome) -> Void
    ) {
        self.request = request
        self.slot = slot
        self.completion = completion
    }
}

/// Hands a background save's result to the main actor, taken once: by the
/// main-queue callback, or by a synchronous save that waited for it.
private final class SaveResultSlot: Sendable {
    private let attempt = OSAllocatedUnfairLock<MarkdownSaveAttempt?>(initialState: nil)

    func store(_ value: MarkdownSaveAttempt) {
        attempt.withLock { $0 = value }
    }

    func take() -> MarkdownSaveAttempt? {
        attempt.withLock { value in
            defer { value = nil }
            return value
        }
    }
}

// MARK: - Save worker

/// One save's inputs, copied on the main actor.
struct MarkdownSaveRequest: Sendable {
    let fileURL: URL
    let snapshot: EditSnapshot
    /// The text the file held when the request was made.
    let savedText: String
    let expectedFingerprint: String
    let format: MarkdownTextFormat
    /// Write without comparing the disk (Keep My Edits, or Save after the
    /// file was deleted).
    let overwrite: Bool
}

enum MarkdownSaveAttempt: Sendable, Equatable {
    /// The text equals the saved text; nothing was written.
    case unchanged
    /// The file was replaced with bytes that have this fingerprint.
    case written(fingerprint: String)
    /// Nothing was written. `diskData` holds the file's bytes when it changed.
    case conflict(EditConflictKind, diskData: Data?)
}

/// Runs saves one at a time on a background queue, so file I/O and hashing
/// stay off the main thread. Synchronous saves queue behind background ones.
final class MarkdownSaveWorker: Sendable {
    private let queue = DispatchQueue(label: "dev.wafer.edit-save", qos: .userInitiated)
    private let writer: MarkdownEditSession.FileWriter

    init(writer: @escaping MarkdownEditSession.FileWriter = MarkdownEditSession.replaceContents) {
        self.writer = writer
    }

    /// Runs `request` after any queued save and returns its result.
    func perform(_ request: MarkdownSaveRequest) -> MarkdownSaveAttempt {
        let writer = writer
        return queue.sync { Self.attempt(request, writer: writer) }
    }

    /// Runs `request` after any queued save; `completion` runs on the queue.
    func performInBackground(
        _ request: MarkdownSaveRequest,
        completion: @escaping @Sendable (MarkdownSaveAttempt) -> Void
    ) {
        let writer = writer
        queue.async {
            completion(Self.attempt(request, writer: writer))
        }
    }

    /// Returns once every queued save has finished.
    func waitUntilIdle() {
        queue.sync {}
    }

    static func attempt(_ request: MarkdownSaveRequest, writer: MarkdownEditSession.FileWriter) -> MarkdownSaveAttempt {
        if !request.overwrite, request.snapshot.text == request.savedText {
            return .unchanged
        }

        let target = request.fileURL.resolvingSymlinksInPath()
        let data = request.format.encode(request.snapshot.text)
        do {
            try writer(target, data) {
                if !request.overwrite {
                    try verifyUnchanged(target, fingerprint: request.expectedFingerprint)
                }
            }
            return .written(fingerprint: FileFingerprint.sha256Hex(for: data))
        } catch let conflict as DiskConflict {
            return .conflict(conflict.kind, diskData: conflict.diskData)
        } catch {
            return .conflict(.writeFailed(error.localizedDescription), diskData: nil)
        }
    }

    /// Throws a `DiskConflict` unless the file still holds the bytes with
    /// `fingerprint`. It runs right before the replace. The file's identity,
    /// size, and modification time are compared before and after its bytes
    /// are read and hashed, so a write that lands meanwhile is seen rather
    /// than overwritten; only the moment between that last check and the
    /// swap remains.
    static func verifyUnchanged(_ url: URL, fingerprint: String) throws {
        var lastData: Data?
        for _ in 0..<3 {
            let before = FileState(url)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                throw DiskConflict(kind: .missingOnDisk, diskData: nil)
            } catch {
                throw DiskConflict(kind: .writeFailed(error.localizedDescription), diskData: nil)
            }
            let matches = FileFingerprint.sha256Hex(for: data) == fingerprint
            guard before != nil, FileState(url) == before else {
                // Written while it was read: look again.
                lastData = data
                continue
            }
            guard matches else {
                throw DiskConflict(kind: .changedOnDisk, diskData: data)
            }
            return
        }
        throw DiskConflict(kind: .changedOnDisk, diskData: lastData)
    }
}

/// The disk no longer holds what the session last loaded or saved.
struct DiskConflict: Error {
    let kind: EditConflictKind
    let diskData: Data?
}

/// A file's identity and last content change, as `stat` reports them.
private struct FileState: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    init?(_ url: URL) {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &info) } ?? -1
        }
        guard status == 0 else {
            return nil
        }

        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }
}
