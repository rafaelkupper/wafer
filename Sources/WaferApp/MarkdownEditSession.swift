import AppKit
import WaferCore

enum EditConflictKind: Equatable {
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

/// Save bookkeeping for one file open in the editor. Text is LF-normalized;
/// `format` converts it back to the file's encoding, byte-order mark, and
/// dominant line ending.
@MainActor
final class MarkdownEditSession {
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

    let fileURL: URL
    private(set) var savedText: String
    private(set) var savedFingerprint: String
    private(set) var format: MarkdownTextFormat
    /// Text when the editor last loaded the file; Revert Edits restores it.
    private(set) var baselineText: String
    private let resolveConflict: EditConflictResolver
    private var isResolvingConflict = false

    init(
        fileURL: URL,
        text: String,
        fingerprint: String,
        format: MarkdownTextFormat,
        resolveConflict: @escaping EditConflictResolver
    ) {
        self.fileURL = fileURL
        self.savedText = text
        self.savedFingerprint = fingerprint
        self.format = format
        self.baselineText = text
        self.resolveConflict = resolveConflict
    }

    /// Adopts a new disk version (external change while clean).
    func rebase(text: String, fingerprint: String, format: MarkdownTextFormat) {
        savedText = text
        savedFingerprint = fingerprint
        self.format = format
        baselineText = text
    }

    func hasUnsavedChanges(_ text: String) -> Bool {
        text != savedText
    }

    /// Saves `text` if it differs from the saved text. Before writing, the
    /// file on disk is compared with the last loaded or saved bytes; any
    /// difference is a conflict. Non-interactive saves never prompt and
    /// leave conflicting edits in memory.
    func save(_ text: String, interactive: Bool) -> Outcome {
        guard text != savedText else {
            return .unchanged
        }
        guard !isResolvingConflict else {
            return .keptInMemory
        }

        let target = fileURL.resolvingSymlinksInPath()
        var diskData: Data?
        var conflict: EditConflictKind?
        do {
            let data = try Data(contentsOf: target)
            diskData = data
            if FileFingerprint.sha256Hex(for: data) != savedFingerprint {
                conflict = .changedOnDisk
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            conflict = .missingOnDisk
        } catch {
            conflict = .writeFailed(error.localizedDescription)
        }

        if conflict == nil {
            do {
                try write(text, to: target)
                return .saved
            } catch {
                conflict = .writeFailed(error.localizedDescription)
            }
        }

        guard var conflict, interactive else {
            return .keptInMemory
        }

        let restorableDiskData = conflict == .changedOnDisk ? diskData : nil
        isResolvingConflict = true
        defer { isResolvingConflict = false }
        while true {
            switch resolveConflict(conflict, fileURL) {
            case .overwrite:
                do {
                    try write(text, to: target)
                    return .saved
                } catch {
                    conflict = .writeFailed(error.localizedDescription)
                }
            case .discardMine:
                return discardEdits(diskData: restorableDiskData)
            case .saveCopy(let copyURL):
                do {
                    try format.encode(text).write(to: copyURL, options: .atomic)
                } catch {
                    conflict = .writeFailed(error.localizedDescription)
                    continue
                }
                if restorableDiskData != nil {
                    return discardEdits(diskData: restorableDiskData)
                }
                // Nothing usable on disk: the edits now live in the copy.
                savedText = text
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
        return .reverted(savedText)
    }

    private func write(_ text: String, to target: URL) throws {
        let data = format.encode(text)
        try Self.replaceContents(of: target, with: data)
        savedText = text
        savedFingerprint = FileFingerprint.sha256Hex(for: data)
    }

    /// Writes beside the file and swaps it in so readers never see a partial
    /// file, keeping the original's permissions and creation date. Falls back
    /// to an in-place write where a replacement directory is unavailable.
    static func replaceContents(of url: URL, with data: Data) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }

        let replacementDirectory: URL
        do {
            replacementDirectory = try fileManager.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: url,
                create: true
            )
        } catch {
            try data.write(to: url)
            return
        }
        defer { try? fileManager.removeItem(at: replacementDirectory) }

        let temporaryURL = replacementDirectory.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temporaryURL)
        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } catch {
            try data.write(to: url)
        }
    }

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
