import AppKit
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
    /// Keep the edits in memory without saving and cancel the pending action.
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
    private let diskState: MarkdownDiskState
    private var saving = false
    private var saveWaiters: [@MainActor () -> Void] = []

    init(
        fileURL: URL,
        text: String,
        fingerprint: String,
        format: MarkdownTextFormat,
        resolveConflict: @escaping EditConflictResolver,
        worker: MarkdownSaveWorker = MarkdownSaveWorker(),
        diskState: MarkdownDiskState = MarkdownDiskState()
    ) {
        self.fileURL = fileURL
        self.savedText = text
        self.savedFingerprint = fingerprint
        self.format = format
        self.baselineText = text
        self.resolveConflict = resolveConflict
        self.worker = worker
        self.diskState = diskState
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

    /// Includes conflict resolution and copy writes.
    var isSaving: Bool { saving }

    // MARK: Saving

    /// Saves in order after any earlier write. Completion and conflict UI
    /// run on the main actor; encoding, hashing and writes run on the worker.
    func save(
        _ snapshot: EditSnapshot, interactive: Bool,
        completion: @escaping @MainActor (Outcome) -> Void
    ) {
        finishPendingSave {
            if let revision = snapshot.revision, revision == self.savedRevision {
                completion(.unchanged)
                return
            }
            self.saving = true
            self.attemptSave(snapshot, overwrite: false, interactive: interactive) { outcome in
                self.completeSave { completion(outcome) }
            }
        }
    }

    func save(_ text: String, interactive: Bool, completion: @escaping @MainActor (Outcome) -> Void) {
        save(EditSnapshot(text: text, revision: nil), interactive: interactive, completion: completion)
    }

    @discardableResult
    func saveInBackground(
        _ snapshot: EditSnapshot,
        completion: @escaping @MainActor (BackgroundOutcome) -> Void
    ) -> Bool {
        guard !saving else { return false }
        saving = true
        worker.performInBackground(request(for: snapshot, overwrite: false)) { attempt in
            DispatchQueue.main.async {
                let outcome: BackgroundOutcome
                switch attempt {
                case .unchanged:
                    self.markSaved(snapshot, fingerprint: self.savedFingerprint)
                    outcome = .saved
                case .written(let fingerprint):
                    self.diskState.didSave()
                    self.markSaved(snapshot, fingerprint: fingerprint)
                    outcome = .saved
                case .conflict(let kind, _):
                    outcome = .conflict(kind)
                }
                self.completeSave { completion(outcome) }
            }
        }
        return true
    }

    /// Continues after all earlier saves have delivered their bookkeeping.
    /// Never waits for the worker on the calling thread.
    func finishPendingSave(completion: @escaping @MainActor () -> Void) {
        guard saving else { completion(); return }
        saveWaiters.append { self.finishPendingSave(completion: completion) }
    }

    private func completeSave(_ completion: () -> Void) {
        saving = false
        let waiters = saveWaiters
        saveWaiters.removeAll()
        completion()
        for waiter in waiters { waiter() }
    }

    private func attemptSave(
        _ snapshot: EditSnapshot, overwrite: Bool, interactive: Bool,
        restorableDiskData: Data? = nil,
        completion: @escaping @MainActor (Outcome) -> Void
    ) {
        worker.performInBackground(request(for: snapshot, overwrite: overwrite)) { attempt in
            DispatchQueue.main.async {
                switch attempt {
                case .unchanged:
                    self.markSaved(snapshot, fingerprint: self.savedFingerprint)
                    completion(.unchanged)
                case .written(let fingerprint):
                    self.diskState.didSave()
                    self.markSaved(snapshot, fingerprint: fingerprint)
                    completion(.saved)
                case .conflict(let kind, let diskData):
                    guard interactive else { completion(.keptInMemory); return }
                    self.resolve(kind, diskData: restorableDiskData ?? (kind == .changedOnDisk ? diskData : nil),
                                 snapshot: snapshot, completion: completion)
                }
            }
        }
    }

    private func resolve(
        _ conflict: EditConflictKind, diskData: Data?, snapshot: EditSnapshot,
        completion: @escaping @MainActor (Outcome) -> Void
    ) {
        let restorableDiskData = diskData
        switch resolveConflict(conflict, fileURL) {
        case .overwrite:
            attemptSave(snapshot, overwrite: true, interactive: true,
                        restorableDiskData: restorableDiskData, completion: completion)
        case .discardMine:
            completion(discardEdits(diskData: restorableDiskData))
        case .saveCopy(let copyURL):
            worker.saveCopy(snapshot.text, format: format, to: copyURL) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        if restorableDiskData != nil {
                            completion(self.discardEdits(diskData: restorableDiskData))
                        } else {
                            self.savedText = snapshot.text
                            self.savedRevision = snapshot.revision
                            completion(.saved)
                        }
                    case .failure(let error):
                        self.resolve(.writeFailed(error.localizedDescription), diskData: restorableDiskData,
                                     snapshot: snapshot, completion: completion)
                    }
                }
            }
        case .cancel:
            completion(.keptInMemory)
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
                do {
                    try fileManager.removeItem(at: replacementDirectory)
                } catch {
                    WaferLog.editing.error("Could not remove save staging directory \(replacementDirectory.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            } else {
                WaferLog.editing.fault("Save left \(url.path, privacy: .private) missing; staging directory kept at \(replacementDirectory.path, privacy: .private)")
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
                do {
                    try fileManager.moveItem(at: original, to: url)
                } catch {
                    WaferLog.editing.fault("Could not restore \(url.path, privacy: .private) from \(original.path, privacy: .private) after a failed save: \(error.localizedDescription, privacy: .public)")
                }
            }
            throw error
        }
    }

    // MARK: Conflict UI

    @MainActor
    struct ConflictAlert {
        let alert = NSAlert()
        private let resolutions: [EditConflictResolution?]

        init(_ kind: EditConflictKind, fileURL: URL) {
            let name = fileURL.lastPathComponent
            alert.alertStyle = .warning
            let choices: [(String, EditConflictResolution?)]
            switch kind {
            case .changedOnDisk:
                alert.messageText = "\(name) changed on disk while you were editing it."
                alert.informativeText = "Keep your version and overwrite the file, use the version on disk, or save your version as a separate file. Cancel keeps your unsaved edits open without changing the file."
                choices = [("Keep My Edits", .overwrite), ("Use Disk Version", .discardMine), ("Save a Copy…", nil), ("Cancel", .cancel)]
            case .missingOnDisk:
                alert.messageText = "\(name) was moved or deleted while you were editing it."
                alert.informativeText = "Save it again at its original location, save your version somewhere else, or discard your unsaved edits. Cancel keeps your unsaved edits open without recreating the file."
                choices = [("Save", .overwrite), ("Save a Copy…", nil), ("Discard My Edits", .discardMine), ("Cancel", .cancel)]
            case .writeFailed(let message):
                alert.messageText = "Wafer couldn't save \(name)."
                alert.informativeText = message
                choices = [("Save a Copy…", nil), ("Discard My Edits", .discardMine), ("Cancel", .cancel)]
            }
            for choice in choices {
                let button = alert.addButton(withTitle: choice.0)
                if choice.1 == .cancel {
                    button.keyEquivalent = "\u{1b}"
                }
            }
            resolutions = choices.map(\.1)
        }

        /// Nil opens the copy panel; an unrecognized response cancels the save.
        func resolution(for response: NSApplication.ModalResponse) -> EditConflictResolution? {
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard resolutions.indices.contains(index) else { return .cancel }
            return resolutions[index]
        }
    }

    /// Default conflict UI: an app-modal alert, plus a save panel for copies.
    static func presentConflict(_ kind: EditConflictKind, fileURL: URL) -> EditConflictResolution {
        let prompt = ConflictAlert(kind, fileURL: fileURL)
        while true {
            if let resolution = prompt.resolution(for: prompt.alert.runModal()) {
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
/// stay off the main thread, including interactive saves and copies.
final class MarkdownSaveWorker: Sendable {
    private let queue = DispatchQueue(label: "dev.wafer.edit-save", qos: .userInitiated)
    private let writer: MarkdownEditSession.FileWriter

    init(writer: @escaping MarkdownEditSession.FileWriter = MarkdownEditSession.replaceContents) {
        self.writer = writer
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

    func saveCopy(
        _ text: String, format: MarkdownTextFormat, to url: URL,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async {
            completion(Result { try Self.encodedData(for: text, format: format).write(to: url, options: .atomic) })
        }
    }

    static func attempt(_ request: MarkdownSaveRequest, writer: MarkdownEditSession.FileWriter) -> MarkdownSaveAttempt {
        if !request.overwrite, request.snapshot.text == request.savedText {
            return .unchanged
        }

        let target = request.fileURL.resolvingSymlinksInPath()
        do {
            let data = try encodedData(for: request.snapshot.text, format: request.format)
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

    static func encodedData(for text: String, format: MarkdownTextFormat) throws -> Data {
        let data = format.encode(text)
        let limit = MarkdownSourceLoader.maximumSourceByteCount
        guard data.count <= limit else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Wafer saves Markdown files up to \(size) after encoding and line-ending conversion. Shorten the document before saving. Your unsaved edits remain in the editor.",
            ])
        }
        return data
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
                data = try BoundedFileReader.read(from: url, maximumByteCount: MarkdownReaderDocument.maximumSourceByteCount)
            } catch BoundedFileReader.ReadError.tooLarge {
                throw DiskConflict(kind: .changedOnDisk, diskData: nil)
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
