import Foundation

/// Page-world JavaScript for the edit-mode live preview. Installed lazily on
/// the first edit-mode call against a page; a full page load discards it.
///
/// - `patch(html, previous, position)` replaces only the changed top-level
///   `#write` nodes. Nodes are compared by their rendered HTML with
///   `data-source-line` attributes stripped, so a block keeps its DOM (images,
///   rendered Mermaid SVG, KaTeX) unless its own Markdown changed. Kept nodes
///   get their line attributes updated, added (entering edit mode) or removed
///   (leaving it), so neither transition reloads the page. Returns "reload"
///   when the DOM cannot be matched or a needed renderer is missing; the
///   caller then does a full load.
/// - Scroll sync maps the editor's fractional top source line to a preview
///   offset through the annotated blocks. The mapping is continuous and
///   monotonic and reaches both ends together: the editor's first and last
///   scroll positions map to the preview's, with the difference blended in
///   over about one screen of lines. `scrollToLine` applies it for editor
///   scrolls; user scrolls of the preview are inverted and posted to
///   `waferLiveScroll` so the editor follows.
/// - `lineAtTop(...)` adopts the preview's current position as the synced
///   one and returns its line, used to align the editor without moving the
///   preview.
enum ReaderLivePreviewScript {
    static let installer = ReaderScriptResource.load("reader-live-preview")

    private static let positionArguments = "line, topLine, bottomLine, visibleLines, totalLines"
    private static let metricsArguments = "topLine, bottomLine, visibleLines, totalLines"

    /// Arguments: html, previous, hasPosition, and the position fields.
    static let patchCall = installer + """

    return window.waferLive.patch(html, previous, hasPosition ? { line: line, topLine: topLine, bottomLine: bottomLine, visibleLines: visibleLines, totalLines: totalLines } : null);
    """
    static let scrollCall = installer + "\nreturn window.waferLive.scrollToLine(\(positionArguments));"
    /// Short form once the helpers are known to be installed on this page.
    static let installedScrollCall = "return window.waferLive.scrollToLine(\(positionArguments));"
    static let updateMetricsCall = "return window.waferLive ? window.waferLive.updateMetrics(\(metricsArguments)) : false;"
    static let lineAtTopCall = installer + "\nreturn window.waferLive.lineAtTop(\(metricsArguments));"
    static let deactivateCall = "if (window.waferLive) { window.waferLive.setActive(false); } return true;"
}
