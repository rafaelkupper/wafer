import Darwin
import Foundation

public struct LibraryFileFingerprint: Equatable, Hashable, Sendable {
    public let modificationDate: Date
    public let fileSize: UInt64
    public let contentDigest: String?
    public let fileIdentifier: String?
    public let statusChangeDate: Date?

    public init(modificationDate: Date, fileSize: UInt64, contentDigest: String? = nil,
                fileIdentifier: String? = nil, statusChangeDate: Date? = nil) {
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.contentDigest = contentDigest
        self.fileIdentifier = fileIdentifier
        self.statusChangeDate = statusChangeDate
    }
}

public struct LibraryFile: Equatable, Sendable {
    public let identity: String
    public let relativePath: String
    let searchFields: LibrarySearchFields
    public let fileURL: URL
    public let relativePathComponents: [String]
    public let displayTitle: String
    public let outlineItems: [DocumentOutlineItem]
    public let plainText: String
    public var searchableText: String { searchFields.body }
    public let contentFingerprint: LibraryFileFingerprint
    public let outgoingReferences: [OutgoingReference]

    public init(
        fileURL: URL,
        relativePathComponents: [String],
        displayTitle: String,
        outlineItems: [DocumentOutlineItem],
        plainText: String,
        searchableText: String,
        contentFingerprint: LibraryFileFingerprint,
        outgoingReferences: [OutgoingReference] = []
    ) {
        self.identity = FileIdentity.identity(for: fileURL)
        self.relativePath = relativePathComponents.joined(separator: "/")
        self.searchFields = LibrarySearchFields(
            fileURL: fileURL, relativePath: relativePathComponents.joined(separator: "/"),
            title: displayTitle, headings: outlineItems, body: searchableText
        )
        self.fileURL = fileURL
        self.relativePathComponents = relativePathComponents
        self.displayTitle = displayTitle
        self.outlineItems = outlineItems
        self.plainText = plainText.collapsingWhitespace
        self.contentFingerprint = contentFingerprint
        self.outgoingReferences = outgoingReferences
    }
}

public enum LibraryScanner {
    public struct Failure: Equatable, Sendable {
        public let url: URL
        public let message: String

        public init(url: URL, message: String) {
            self.url = url
            self.message = message
        }
    }

    public struct Result: Sendable {
        public let files: [LibraryFile]
        public let truncated: Bool
        public let failure: Failure?
        public let skippedItemCount: Int
        public let parsedFileCount: Int

        public init(files: [LibraryFile], truncated: Bool, failure: Failure? = nil, skippedItemCount: Int = 0, parsedFileCount: Int = 0) {
            self.files = files
            self.truncated = truncated
            self.failure = failure
            self.skippedItemCount = skippedItemCount
            self.parsedFileCount = parsedFileCount
        }
    }

    public static let skippedDirectoryNames: Set<String> = [
        ".build",
        ".git",
        "build",
        "dist",
        "node_modules",
    ]

    public static func scan(
        rootURL: URL, fileLimit: Int = WaferLimits.libraryFileCount, existingFiles: [LibraryFile] = [],
        changedPaths: Set<String>? = [], cancellation: WorkCancellation? = nil,
        maximumFileByteCount: Int = WaferLimits.libraryFileByteCount, maximumLibraryByteCount: Int = WaferLimits.libraryByteCount
    ) -> Result {
        guard fileLimit > 0 else {
            var traversal = LibraryTraversal(rootURL: FileIdentity.normalized(rootURL), fileLimit: 1)
            let files = traversal.markdownFileURLs()
            return Result(files: [], truncated: !files.isEmpty, failure: traversal.failure)
        }

        let normalizedRootURL = FileIdentity.normalized(rootURL)
        var traversal = LibraryTraversal(rootURL: normalizedRootURL, fileLimit: fileLimit, cancellation: cancellation)
        let fileURLs = traversal.markdownFileURLs()
        if let failure = traversal.failure {
            return Result(files: [], truncated: traversal.truncated, failure: failure)
        }
        let parser = MarkdownParser()
        let existing = Dictionary(existingFiles.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        var files: [LibraryFile] = existingFiles.filter { previous in
            traversal.skippedURLs.contains { skipped in
                FileContainment.isContained(previous.fileURL, in: skipped)
            }
        }
        var skippedItemCount = traversal.skippedURLs.count
        var parsedFileCount = 0
        var remainingBytes = max(0, maximumLibraryByteCount) - files.reduce(0) { $0 + Int(clamping: $1.contentFingerprint.fileSize) }
        for url in fileURLs {
            if cancellation?.isCancelled == true { break }
            do {
                let metadata = try fingerprint(for: url)
                let identity = FileIdentity.identity(for: url)
                guard FileManager.default.isReadableFile(atPath: url.path) else { throw CocoaError(.fileReadNoPermission) }
                if let previous = existing[identity],
                   changedPaths?.contains(identity) != true,
                   previous.contentFingerprint.modificationDate == metadata.modificationDate,
                   previous.contentFingerprint.fileSize == metadata.fileSize,
                   previous.contentFingerprint.fileIdentifier == metadata.fileIdentifier,
                   previous.contentFingerprint.statusChangeDate == metadata.statusChangeDate {
                    if previous.contentFingerprint.fileSize > UInt64(max(0, min(maximumFileByteCount, remainingBytes))) { skippedItemCount += 1 }
                    remainingBytes -= Int(clamping: previous.contentFingerprint.fileSize)
                    files.append(previous)
                    continue
                }
                let data = try BoundedFileReader.read(from: url, maximumByteCount: max(0, min(maximumFileByteCount, remainingBytes)))
                remainingBytes -= data.count
                guard let source = MarkdownSourceDecoding.decode(data) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                let file = try autoreleasepool {
                    try makeLibraryFile(for: url, rootURL: normalizedRootURL, parser: parser, data: data, source: source, before: metadata)
                }
                files.append(file)
                parsedFileCount += 1
            } catch {
                skippedItemCount += 1
                WaferLog.library.info("Skipped library item \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                if let previous = existing[FileIdentity.identity(for: url)] {
                    remainingBytes -= Int(clamping: previous.contentFingerprint.fileSize)
                    files.append(previous)
                }
            }
        }
        files.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return Result(files: files, truncated: traversal.truncated, skippedItemCount: skippedItemCount, parsedFileCount: parsedFileCount)
    }

    private static func makeLibraryFile(for fileURL: URL, rootURL: URL, parser: MarkdownParser, data: Data, source: String, before: LibraryFileFingerprint) throws -> LibraryFile {
        let normalizedURL = FileIdentity.normalized(fileURL)
        let document = parser.parse(source: source, baseURL: normalizedURL)
        let plainText = RenderedTextDocumentStatistics.renderedText(from: document).collapsingWhitespace
        let after = try fingerprint(for: fileURL)
        let date = before == after ? after.modificationDate : .distantPast

        return LibraryFile(
            fileURL: normalizedURL,
            relativePathComponents: relativePathComponents(for: normalizedURL, rootURL: rootURL),
            displayTitle: DocumentSidebarDataBuilder.documentDisplayTitle(for: document, fallbackURL: normalizedURL),
            outlineItems: DocumentSidebarDataBuilder.outlineItems(from: document),
            plainText: plainText,
            searchableText: plainText.libraryFoldedSearchText,
            contentFingerprint: LibraryFileFingerprint(
                modificationDate: date, fileSize: UInt64(data.count), contentDigest: document.fingerprint,
                fileIdentifier: after.fileIdentifier, statusChangeDate: after.statusChangeDate
            ),
            outgoingReferences: OutgoingReferenceCollector.collect(from: document, assetResolver: AssetResolver())
        )
    }

    private static func relativePathComponents(for fileURL: URL, rootURL: URL) -> [String] {
        let rootPath = rootURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let filePath = fileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = rootPath.isEmpty ? "" : rootPath + "/"
        let relativePath = filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : fileURL.lastPathComponent
        return relativePath.split(separator: "/").map(String.init)
    }

    private static func fingerprint(for fileURL: URL) throws -> LibraryFileFingerprint {
        var metadata = stat()
        guard stat(fileURL.path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return LibraryFileFingerprint(
            modificationDate: Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000),
            fileSize: UInt64(max(metadata.st_size, 0)),
            fileIdentifier: "\(metadata.st_dev):\(metadata.st_ino)",
            statusChangeDate: Date(timeIntervalSince1970: Double(metadata.st_ctimespec.tv_sec) + Double(metadata.st_ctimespec.tv_nsec) / 1_000_000_000)
        )
    }

    private struct LibraryTraversal {
        let rootURL: URL
        let fileLimit: Int
        let cancellation: WorkCancellation?
        private(set) var truncated = false
        private(set) var failure: Failure?
        private(set) var skippedURLs: [URL] = []
        private var files: [URL] = []

        init(rootURL: URL, fileLimit: Int, cancellation: WorkCancellation? = nil) {
            self.rootURL = rootURL
            self.fileLimit = fileLimit
            self.cancellation = cancellation
        }

        mutating func markdownFileURLs() -> [URL] {
            visitDirectory(rootURL)
            return files
        }

        private mutating func visitDirectory(_ directoryURL: URL) {
            guard cancellation?.isCancelled != true, failure == nil else { return }
            guard files.count < fileLimit else {
                truncated = true
                return
            }

            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directoryURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            } catch {
                if directoryURL == rootURL {
                    failure = Failure(url: directoryURL, message: error.localizedDescription)
                } else { skippedURLs.append(directoryURL) }
                return
            }

            for childURL in children.sorted(by: relativePathOrder) {
                guard cancellation?.isCancelled != true, failure == nil else { return }
                if files.count >= fileLimit {
                    truncated = true
                    return
                }

                let values: URLResourceValues
                do {
                    values = try childURL.resourceValues(forKeys: keys)
                } catch {
                    skippedURLs.append(childURL)
                    continue
                }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    guard !LibraryScanner.skippedDirectoryNames.contains(childURL.lastPathComponent) else {
                        continue
                    }
                    visitDirectory(childURL)
                    continue
                }

                guard
                    values.isRegularFile == true,
                    AssetResolver.markdownExtensions.contains(childURL.pathExtension.lowercased())
                else {
                    continue
                }

                files.append(FileIdentity.normalized(childURL))
            }
        }

        private func relativePathOrder(lhs: URL, rhs: URL) -> Bool {
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }
}

extension String {
    var libraryFoldedSearchText: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .collapsingWhitespace
    }
}
