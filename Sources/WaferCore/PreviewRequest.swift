import Foundation

public enum PreviewAppearance {
    public static func isDark(matchedAppearanceIsDark: Bool?, interfaceStyle: String?) -> Bool {
        matchedAppearanceIsDark ?? (interfaceStyle == "Dark")
    }
}

/// Main-thread delivery for the extension's background composition request.
@MainActor
public final class PreviewRequest {
    public nonisolated let cancellation = WorkCancellation()
    private var completion: ((Error?) -> Void)?

    public init(_ completion: @escaping (Error?) -> Void) { self.completion = completion }

    public func cancel() { cancellation.cancel() }

    public func finish(error: Error? = nil, applying: () -> Void = {}) {
        guard let completion else { return }
        self.completion = nil
        if cancellation.isCancelled {
            completion(CancellationError())
        } else {
            if error == nil { applying() }
            completion(error)
        }
    }
}
