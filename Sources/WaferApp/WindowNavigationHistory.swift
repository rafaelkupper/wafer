import Foundation
import WaferCore

struct WindowNavigationHistoryEntry: Equatable {
    let fileURL: URL
    let anchorID: String?

    init(fileURL: URL, anchorID: String? = nil) {
        self.fileURL = FileIdentity.normalized(fileURL)
        self.anchorID = anchorID
    }
}

/// Cross-document back/forward history for one reading surface (a tab).
/// Organic navigation pushes the departing entry and clears the forward
/// stack; traversal moves entries between stacks and never pushes.
struct WindowNavigationHistory: Equatable {
    static let maximumEntryCount = 50

    private(set) var backEntries: [WindowNavigationHistoryEntry] = []
    private(set) var forwardEntries: [WindowNavigationHistoryEntry] = []

    var canGoBack: Bool {
        !backEntries.isEmpty
    }

    var canGoForward: Bool {
        !forwardEntries.isEmpty
    }

    /// Records an organic navigation away from `departing`.
    mutating func push(departing entry: WindowNavigationHistoryEntry) {
        backEntries.append(entry)
        trimOldest(&backEntries)
        forwardEntries.removeAll()
    }

    /// Returns the entry to show, recording `current` on the forward stack.
    mutating func goBack(from current: WindowNavigationHistoryEntry) -> WindowNavigationHistoryEntry? {
        guard let target = backEntries.popLast() else {
            return nil
        }

        forwardEntries.append(current)
        trimOldest(&forwardEntries)
        return target
    }

    /// Returns the entry to show, recording `current` on the back stack.
    mutating func goForward(from current: WindowNavigationHistoryEntry) -> WindowNavigationHistoryEntry? {
        guard let target = forwardEntries.popLast() else {
            return nil
        }

        backEntries.append(current)
        trimOldest(&backEntries)
        return target
    }

    private func trimOldest(_ entries: inout [WindowNavigationHistoryEntry]) {
        let overflow = entries.count - Self.maximumEntryCount
        if overflow > 0 {
            entries.removeFirst(overflow)
        }
    }
}
