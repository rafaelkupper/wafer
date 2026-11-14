import Foundation
import WaferCore

/// Owns a document's render lifetime. Live requests wait for the active render
/// and snapshot the newest editor state only when they can start.
@MainActor
final class DocumentRenderCoordinator {
    struct Request {
        let source: String
        let baseURL: URL?
        let palette: ReaderThemePalette
        let wikiLinkIndex: WikiLinkIndex?
        let annotatesSourceLines: Bool
        let apply: @MainActor (WebKitRenderOutput) -> Void
    }

    typealias Completion = @MainActor @Sendable (WebKitRenderOutput) -> Void
    typealias Scheduler = @MainActor (Request, @escaping Completion) -> DispatchWorkItem

    private let schedule: Scheduler
    private let cancelWorker: () -> Void
    private var workItem: DispatchWorkItem?
    private var generation = UUID()
    private var pendingLiveRender: (@MainActor () -> Request?)?
    private(set) var isRendering = false
    private(set) var renderedPalette: ReaderThemePalette?

    init(scheduler: Scheduler? = nil) {
        let worker = MarkdownRenderWorker()
        schedule = scheduler ?? { request, completion in
            worker.schedule(
                source: request.source, baseURL: request.baseURL,
                palette: request.palette, wikiLinkIndex: request.wikiLinkIndex,
                annotatesSourceLines: request.annotatesSourceLines, completion: completion
            )
        }
        cancelWorker = { worker.cancel() }
    }

    func request(live: Bool, snapshot: @escaping @MainActor () -> Request?) {
        if live, isRendering {
            pendingLiveRender = snapshot
            return
        }
        guard let request = snapshot() else { return }
        pendingLiveRender = nil
        isRendering = true
        let token = UUID()
        generation = token
        workItem?.cancel()
        let item = schedule(request) { [weak self] output in
            guard let self, self.generation == token else { return }
            self.isRendering = false
            self.workItem = nil
            // A live body patch keeps the page's existing palette.
            if !live { self.renderedPalette = request.palette }
            request.apply(output)
            if let pending = self.pendingLiveRender {
                self.pendingLiveRender = nil
                self.request(live: true, snapshot: pending)
            }
        }
        // Injected schedulers may complete synchronously.
        if generation == token, isRendering { workItem = item }
    }

    func applyThemeIfNeeded(
        _ palette: ReaderThemePalette,
        isContentReady: Bool,
        apply: (ReaderThemePalette) -> Void
    ) {
        guard palette != renderedPalette, isContentReady else { return }
        renderedPalette = palette
        apply(palette)
    }

    func cancel() {
        generation = UUID()
        isRendering = false
        pendingLiveRender = nil
        workItem?.cancel()
        workItem = nil
        cancelWorker()
    }
}
