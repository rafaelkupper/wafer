import Foundation

public enum LibraryIndexDiff {
    public struct Result: Equatable, Sendable {
        public let files: [LibraryFile]
        public let added: [LibraryFile]
        public let changed: [LibraryFile]
        public let removed: [LibraryFile]
        public let truncated: Bool

        public init(
            files: [LibraryFile],
            added: [LibraryFile],
            changed: [LibraryFile],
            removed: [LibraryFile],
            truncated: Bool
        ) {
            self.files = files
            self.added = added
            self.changed = changed
            self.removed = removed
            self.truncated = truncated
        }
    }

    public static func apply(scan: LibraryScanner.Result, to existingFiles: [LibraryFile]) -> Result {
        let existingByIdentity = Dictionary(
            existingFiles.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let scannedIdentities = Set(scan.files.map { $0.identity })

        var added: [LibraryFile] = []
        var changed: [LibraryFile] = []
        let files = scan.files.map { scannedFile in
            let identity = scannedFile.identity
            guard let existingFile = existingByIdentity[identity] else {
                added.append(scannedFile)
                return scannedFile
            }

            guard existingFile.contentFingerprint.describesSameContent(as: scannedFile.contentFingerprint) else {
                changed.append(scannedFile)
                return scannedFile
            }

            // Same text. When only metadata moved, keep the fresher metadata
            // so the next recovery scan can reuse the entry.
            return existingFile.contentFingerprint == scannedFile.contentFingerprint ? existingFile : scannedFile
        }

        let removed = existingFiles.filter {
            !scannedIdentities.contains($0.identity)
        }

        return Result(
            files: files,
            added: added,
            changed: changed,
            removed: removed,
            truncated: scan.truncated
        )
    }
}
