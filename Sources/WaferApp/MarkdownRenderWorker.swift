import Foundation
import WaferCore

/// Renders one document's Markdown off the main thread. The parse and its
/// metadata are confined to the serial queue and kept only for the last
/// source, so wiki-index and theme re-renders reuse them. The only state
/// shared with the caller is the current request's cancellation, behind a lock.
final class MarkdownRenderWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.wafer.document-render", qos: .userInitiated)
    private let lock = NSLock()
    private var cancellation: WorkCancellation?
    private var parsed: MarkdownDocument?
    private var metadata: DocumentRenderMetadata?

    func cancel() {
        lock.withLock { cancellation?.cancel() }
        queue.async { [weak self] in
            self?.parsed = nil
            self?.metadata = nil
        }
    }

    /// Cancels the previous request and renders `source`. `annotatesSourceLines`
    /// adds the edit-mode `data-source-line` attributes; it is part of this
    /// request only. `completion` runs on the main queue unless cancelled.
    func schedule(
        source: String,
        baseURL: URL?,
        palette: ReaderThemePalette,
        wikiLinkIndex: WikiLinkIndex?,
        annotatesSourceLines: Bool,
        completion: @escaping (WebKitRenderOutput) -> Void
    ) -> DispatchWorkItem {
        let token = WorkCancellation()
        lock.withLock { cancellation?.cancel(); cancellation = token }
        let completionBox = RenderCompletionBox(completion: completion)
        let workItem = DispatchWorkItem { @Sendable [self] in
            guard !token.isCancelled else { return }
            let renderer = WebKitHTMLRenderer(
                palette: palette,
                wikiLinkIndex: wikiLinkIndex,
                annotatesSourceLines: annotatesSourceLines
            )
            if parsed?.source != source || parsed?.baseURL != baseURL {
                parsed = MarkdownParser().parse(source: source, baseURL: baseURL)
                metadata = nil
            }
            guard !token.isCancelled, let parsed else { return }
            if metadata == nil { metadata = renderer.metadata(for: parsed) }
            guard !token.isCancelled, let metadata else { return }
            let output = renderer.render(document: parsed, metadata: metadata)
            guard !token.isCancelled else { return }
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                completionBox.completion(output)
            }
        }
        queue.async(execute: workItem)
        return workItem
    }
}

private final class RenderCompletionBox: @unchecked Sendable {
    let completion: (WebKitRenderOutput) -> Void

    init(completion: @escaping (WebKitRenderOutput) -> Void) {
        self.completion = completion
    }
}
