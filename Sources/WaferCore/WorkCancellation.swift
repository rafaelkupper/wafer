import Foundation

/// Cooperative cancellation for synchronous parsing and filesystem work.
public final class WorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() { lock.withLock { cancelled = true } }
}
