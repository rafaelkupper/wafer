import Foundation

/// Constructed off-main; readers share one consistent index revision.
public struct LibrarySnapshot: Sendable {
    public let files: [LibraryFile]
    public let filesByIdentity: [String: LibraryFile]
    public let backlinksByIdentity: [String: [Backlink]]
    public let wikiLinkIndex: WikiLinkIndex
    public let truncated: Bool

    public init(files: [LibraryFile] = [], truncated: Bool = false) {
        self.files = files
        self.filesByIdentity = Dictionary(files.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        self.wikiLinkIndex = WikiLinkIndex(files: files)
        self.backlinksByIdentity = BacklinkIndex.build(files: files, wikiIndex: wikiLinkIndex)
        self.truncated = truncated
    }
}
