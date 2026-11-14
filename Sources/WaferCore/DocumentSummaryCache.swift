import Foundation
import os

/// A small shared cache for summaries requested by visible document rows.
public final class DocumentSummaryCache: Sendable {
    public static let shared = DocumentSummaryCache()
    private struct State: Sendable {
        var entries: [String: CachedSummary] = [:]
        var order: [String] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let capacity: Int

    public init(capacity: Int = 256) { self.capacity = max(1, capacity) }

    public func summary(for url: URL) -> DocumentSidebarEntry {
        let identity = FileIdentity.identity(for: url)
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate
        let size = values?.fileSize
        @Sendable func cachedSummary(in state: State) -> DocumentSidebarEntry? {
            guard let cached = state.entries[identity], cached.modified == modified,
                  cached.size == size else { return nil }
            return cached.entry
        }
        if let cached = state.withLock({ cachedSummary(in: $0) }) { return cached }
        let summary = DocumentSidebarDataBuilder.summary(for: url)
        // A failed read is not kept: access granted later (or a file that
        // appears) can make the same, unchanged file readable.
        guard summary.isAvailable else { return summary }
        return state.withLock { state in
            if let cached = cachedSummary(in: state) { return cached }
            if state.entries[identity] == nil { state.order.append(identity) }
            state.entries[identity] = CachedSummary(modified: modified, size: size, entry: summary)
            while state.order.count > capacity { state.entries.removeValue(forKey: state.order.removeFirst()) }
            return summary
        }
    }
}

private struct CachedSummary: Sendable {
    let modified: Date?
    let size: Int?
    let entry: DocumentSidebarEntry
}
