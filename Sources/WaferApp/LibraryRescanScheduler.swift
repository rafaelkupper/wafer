import Foundation

@MainActor
struct LibraryRescanScheduler {
    var now: () -> TimeInterval
    var schedule: (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> DispatchWorkItem

    static let main = LibraryRescanScheduler(
        now: { ProcessInfo.processInfo.systemUptime },
        schedule: { delay, action in
            let work = DispatchWorkItem {
                MainActor.assumeIsolated { action() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    )
}
