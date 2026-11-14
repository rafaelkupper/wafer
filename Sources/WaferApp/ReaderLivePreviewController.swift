import Foundation
import WaferCore

/// Owns the current page's patch baseline and isolated scroll-sync requests.
@MainActor
final class ReaderLivePreviewController {
    enum World { case page, reader }
    typealias Evaluate = (
        _ script: String, _ arguments: [String: Any], _ world: World,
        _ completion: @escaping @MainActor (Result<Any, Error>) -> Void
    ) -> Void

    private let execute: Evaluate
    private let isContentReady: () -> Bool
    private let reload: (WebKitRenderOutput) -> Void
    private var generation = UUID()
    // Edit-mode live preview state for the current page.
    private var liveBodyHTML: String?
    private var liveHelpersInstalled = false
    private var livePatchStateReady = false
    private var pageHasMermaid = false
    private var pageHasMath = false
    private var scrollSyncInFlight = false
    private var pendingScrollSync: EditorScrollPosition?
    private var lastSyncedMetrics: EditorScrollPosition?
    #if DEBUG
    private(set) var livePatchCountForTesting = 0
    private(set) var liveFullReloadCountForTesting = 0
    #endif

    init(evaluate: @escaping Evaluate, isContentReady: @escaping () -> Bool, reload: @escaping (WebKitRenderOutput) -> Void) {
        execute = evaluate
        self.isContentReady = isContentReady
        self.reload = reload
    }

    private func evaluate(
        _ script: String, arguments: [String: Any], world: World,
        completion: @escaping @MainActor (Result<Any, Error>) -> Void
    ) {
        execute(script, arguments, world, completion)
    }

    /// True when the current page can be patched in place and scroll-synced.
    var supportsLivePreview: Bool {
        !ReaderLivePreviewScript.installer.isEmpty && liveBodyHTML != nil && isContentReady()
    }

    /// Patches the current page in place with a new render of the same
    /// document: edits while typing, and the renders that add or remove
    /// source-line annotations when edit mode starts or ends. Falls back to a
    /// full load, keeping the scroll position, when the page is not ready,
    /// lacks a renderer the new content needs, or cannot be matched.
    /// `editorPosition` is the editor's position after the edit, so the
    /// preview realigns in the same step.
    func applyLiveUpdate(
        renderOutput: WebKitRenderOutput,
        editorPosition: EditorScrollPosition? = nil,
        completion: (@MainActor (_ patched: Bool) -> Void)? = nil
    ) {
        guard
            let body = renderOutput.bodyHTML,
            supportsLivePreview,
            !renderOutput.hasMermaidDiagrams || pageHasMermaid,
            !renderOutput.hasMathDisplays || pageHasMath
        else {
            applyLiveFullReload(renderOutput)
            completion?(false)
            return
        }

        let expectedNavigationID = generation
        let previous: Any = livePatchStateReady ? NSNull() : (liveBodyHTML ?? "")
        var arguments = Self.scriptArguments(for: editorPosition ?? .zero)
        arguments["html"] = body
        arguments["previous"] = previous
        arguments["hasPosition"] = false
        if let editorPosition {
            lastSyncedMetrics = editorPosition
        }
        evaluate(ReaderLivePreviewScript.patchCall, arguments: arguments, world: .page) { [weak self] result in
            guard let self, self.generation == expectedNavigationID else { return }
            if case let .success(value) = result, let status = value as? String, status.hasPrefix("patched") {
                self.liveBodyHTML = body
                if let editorPosition { self.syncScroll(to: editorPosition) }
                self.livePatchStateReady = true
                #if DEBUG
                self.livePatchCountForTesting += 1
                #endif
                completion?(true)
            } else {
                self.applyLiveFullReload(renderOutput)
                completion?(false)
            }
        }
    }

    /// Aligns the preview with the editor's top line. Calls are coalesced so
    /// at most one is in flight; the latest position wins.
    func syncScroll(to position: EditorScrollPosition) {
        guard supportsLivePreview else {
            return
        }
        guard !scrollSyncInFlight else {
            pendingScrollSync = position
            return
        }

        scrollSyncInFlight = true
        lastSyncedMetrics = position
        let expectedNavigationID = generation
        let script = liveHelpersInstalled ? ReaderLivePreviewScript.installedScrollCall : ReaderLivePreviewScript.scrollCall
        liveHelpersInstalled = true
        evaluate(script, arguments: Self.scriptArguments(for: position), world: .reader) { [weak self] _ in
            guard let self, self.generation == expectedNavigationID else { return }
            self.scrollSyncInFlight = false
            if let next = self.pendingScrollSync {
                self.pendingScrollSync = nil
                self.syncScroll(to: next)
            }
        }
    }

    /// Tells the page the editor's scroll range changed (its text or size
    /// did) without moving the preview. No-op when nothing changed.
    func updateScrollSyncMetrics(_ position: EditorScrollPosition) {
        guard supportsLivePreview, liveHelpersInstalled, !position.hasSameMetrics(as: lastSyncedMetrics) else {
            return
        }

        lastSyncedMetrics = position
        evaluate(
            ReaderLivePreviewScript.updateMetricsCall,
            arguments: Self.scriptArguments(for: position),
            world: .reader
        ) { _ in }
    }

    /// The fractional source line at the top of the preview for an editor
    /// with the given scroll range, or nil when the page has no annotated
    /// blocks. The page takes this as the synced position, so the preview
    /// does not move.
    func sourceLineAtTop(for position: EditorScrollPosition, completion: @escaping @MainActor (Double?) -> Void) {
        guard supportsLivePreview else {
            completion(nil)
            return
        }

        liveHelpersInstalled = true
        lastSyncedMetrics = position
        evaluate(
            ReaderLivePreviewScript.lineAtTopCall,
            arguments: Self.scriptArguments(for: position),
            world: .reader
        ) { result in
            if case let .success(value) = result, let number = value as? NSNumber {
                completion(number.doubleValue)
            } else {
                completion(nil)
            }
        }
    }

    /// Stops scroll sync when edit mode ends; the page stays as it is.
    func endLivePreview() {
        pendingScrollSync = nil
        lastSyncedMetrics = nil
        guard liveHelpersInstalled else {
            return
        }

        evaluate(ReaderLivePreviewScript.deactivateCall, arguments: [:], world: .reader) { _ in }
    }

    private static func scriptArguments(for position: EditorScrollPosition) -> [String: Any] {
        [
            "line": position.line,
            "topLine": position.topLine,
            "bottomLine": position.bottomLine,
            "visibleLines": position.visibleLines,
            "totalLines": position.totalLines,
        ]
    }

    private func applyLiveFullReload(_ renderOutput: WebKitRenderOutput) {
        #if DEBUG
        liveFullReloadCountForTesting += 1
        #endif
        reload(renderOutput)
    }

    func reset(for renderOutput: WebKitRenderOutput?) {
        generation = UUID()
        liveBodyHTML = renderOutput?.bodyHTML
        liveHelpersInstalled = false
        livePatchStateReady = false
        pageHasMermaid = renderOutput?.hasMermaidDiagrams ?? false
        pageHasMath = renderOutput?.hasMathDisplays ?? false
        scrollSyncInFlight = false
        pendingScrollSync = nil
        lastSyncedMetrics = nil
    }

}
