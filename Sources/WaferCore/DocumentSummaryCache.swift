import Foundation

/// A small shared cache for summaries requested by visible document rows.
public final class DocumentSummaryCache: @unchecked Sendable {
    public static let shared = DocumentSummaryCache()
    private let lock = NSLock()
    private var entries: [String: CachedSummary] = [:]
    private var order: [String] = []
    private let capacity: Int

    public init(capacity: Int = 256) { self.capacity = max(1, capacity) }

    public func summary(for url: URL) -> DocumentSidebarEntry {
        lock.withLock {
            let identity = FileIdentity.identity(for: url)
            let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let cached = entries[identity], cached.modified == values?.contentModificationDate,
               cached.size == values?.fileSize {
                return cached.entry
            }
            let summary = DocumentSidebarDataBuilder.summary(for: url)
            if entries[identity] == nil { order.append(identity) }
            entries[identity] = CachedSummary(modified: values?.contentModificationDate, size: values?.fileSize, entry: summary)
            while order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
            return summary
        }
    }
}

private struct CachedSummary {
    let modified: Date?
    let size: Int?
    let entry: DocumentSidebarEntry
}
