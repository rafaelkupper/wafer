import os

/// Cooperative cancellation for synchronous parsing and filesystem work.
public final class WorkCancellation: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public var isCancelled: Bool { cancelled.withLock { $0 } }

    public func cancel() { cancelled.withLock { $0 = true } }
}
