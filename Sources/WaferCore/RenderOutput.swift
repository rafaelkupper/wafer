import Foundation

public struct WebKitRenderOutput: Equatable, Sendable {
    public let html: String
    public let baseURL: URL?
    public let statistics: DocumentStatistics
    public let sidebarEntries: [DocumentSidebarEntry]
    public let outlineItems: [DocumentOutlineItem]
    public let waitsForContentReady: Bool
    public let previewAttachments: [String: URL]
    public let hasWikiLinks: Bool
    /// Inner HTML of `#write` for reader renders. The app diffs it against the
    /// next render to patch the page in place (edit mode).
    public let bodyHTML: String?
    public let hasMermaidDiagrams: Bool
    public let hasMathDisplays: Bool

    public init(
        html: String,
        baseURL: URL?,
        statistics: DocumentStatistics = .zero,
        sidebarEntries: [DocumentSidebarEntry] = [],
        outlineItems: [DocumentOutlineItem] = [],
        waitsForContentReady: Bool = false,
        previewAttachments: [String: URL] = [:],
        hasWikiLinks: Bool = false,
        bodyHTML: String? = nil,
        hasMermaidDiagrams: Bool = false,
        hasMathDisplays: Bool = false
    ) {
        self.html = html
        self.baseURL = baseURL
        self.statistics = statistics
        self.sidebarEntries = sidebarEntries
        self.outlineItems = outlineItems
        self.waitsForContentReady = waitsForContentReady
        self.previewAttachments = previewAttachments
        self.hasWikiLinks = hasWikiLinks
        self.bodyHTML = bodyHTML
        self.hasMermaidDiagrams = hasMermaidDiagrams
        self.hasMathDisplays = hasMathDisplays
    }
}

/// Source-derived metadata can be reused when link resolution changes.
public struct DocumentRenderMetadata: Sendable {
    public let statistics: DocumentStatistics
    public let sidebarEntries: [DocumentSidebarEntry]
    public let outlineItems: [DocumentOutlineItem]
}
