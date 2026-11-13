import Foundation
import WaferCore

/// One serial worker with cooperative cancellation and latest-result delivery.
@MainActor
final class LatestWorkQueue<Input: Sendable, Output: Sendable> {
    private let queue = DispatchQueue(label: "dev.wafer.latest-work", qos: .userInitiated)
    private var cancellation: WorkCancellation?
    private var pending: DispatchWorkItem?

    func cancel() {
        cancellation?.cancel()
        pending?.cancel()
        pending = nil
        cancellation = nil
    }

    func submit(
        _ input: Input,
        delay: TimeInterval = 0.06,
        work: @escaping @Sendable (Input, WorkCancellation) -> Output,
        completion: @escaping @MainActor @Sendable (Output) -> Void
    ) {
        cancel()
        let cancellation = WorkCancellation()
        self.cancellation = cancellation
        let item = DispatchWorkItem { @Sendable in
            guard !cancellation.isCancelled else { return }
            let output = work(input, cancellation)
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async {
                guard !cancellation.isCancelled else { return }
                completion(output)
            }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

struct LibrarySearchInput: Sendable {
    let query: String
    let files: [LibraryFile]
}
