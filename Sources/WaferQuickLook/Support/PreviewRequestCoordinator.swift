import Foundation
import WaferCore

@MainActor
public final class PreviewRequestCoordinator {
    private var current: PreviewRequest?

    public init() {}

    public func begin(_ completion: @escaping (Error?) -> Void) -> PreviewRequest {
        let request = PreviewRequest(completion)
        let previous = current
        current = request
        previous?.cancel()
        previous?.finish()
        return request
    }

    public func finish(_ request: PreviewRequest, error: Error? = nil, applying: () throws -> Void = {}) {
        guard current === request else {
            request.cancel()
            request.finish()
            return
        }
        current = nil
        guard error == nil, !request.cancellation.isCancelled else {
            request.finish(error: error)
            return
        }
        do {
            try applying()
            request.finish()
        } catch {
            request.finish(error: error)
        }
    }

    deinit {
        let request = current
        request?.cancellation.cancel()
        Task { @MainActor in request?.finish() }
    }
}
