import AppKit
import Foundation
import WaferCore
import WebKit

@MainActor
class WebKitReaderViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler, NSUserInterfaceValidations, NSSearchFieldDelegate, ThemeApplying {
    private static let headingScrollOffset: Int = 28
    private static let readerContentWorld = WKContentWorld.world(name: "dev.wafer.reader")

    private enum FindDirection {
        case next
        case previous
    }

    private enum ScriptMessageName {
        static let scroll = "waferScroll"
        static let activeHeading = "waferActiveHeading"
        static let contentReady = "waferContentReady"
        static let openLinkInNewTab = "waferOpenLinkInNewTab"
        static let copyCode = "waferCopyCode"
        static let liveScroll = "waferLiveScroll"
    }

    private let localAssetSchemeHandler = WebKitLocalAssetSchemeHandler()
    private let remoteImageSchemeHandler: RemoteImageSchemeHandler
    private let rootView = NSView()
    private let webView: WKWebView
    private let findBarView = ReaderFindBarView()
    #if DEBUG
    private var suppressFindExecutionForTesting = false
    private var suppressedFindMatchResultForTesting: Bool?
    #endif
    private var pendingRestoreFraction: Double?
    private var hasRenderableContent = false
    private var displayedLoadingFileName: String?
    private var navigationID = UUID()
    private var currentNavigation: WKNavigation?
    private var themeUpdateID: UUID?
    private var awaitingContentReady = false
    private var didFinishCurrentNavigation = false
    private var didCompleteCurrentNavigation = false
    private var didInstallScriptMessageHandlers = false
    private var lastKnownScrollFraction: Double = 0
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
    private(set) var currentActiveHeadingID: String?
    #if DEBUG
    private(set) var lastFindQueryForTesting: String?
    private(set) var lastFindDirectionForTesting: String?
    private(set) var lastFindMatchFoundForTesting: Bool?
    #endif

    var onOpenLink: ((URL) -> Void)?
    var onOpenLinkInNewTab: ((URL) -> Void)?
    var onScrollPositionChange: ((Double) -> Void)?
    var onActiveHeadingChange: ((String?) -> Void)?
    var onNavigationFinished: (() -> Void)?
    /// The user scrolled the live preview: the fractional source line now at
    /// its top, for the editor to follow.
    var onLiveScroll: ((Double) -> Void)?

    init(remoteImageSchemeHandler: RemoteImageSchemeHandler = RemoteImageSchemeHandler()) {
        self.remoteImageSchemeHandler = remoteImageSchemeHandler
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        configuration.userContentController = contentController
        configuration.preferences.isTextInteractionEnabled = true
        configuration.setURLSchemeHandler(localAssetSchemeHandler, forURLScheme: "wafer-local")
        configuration.setURLSchemeHandler(remoteImageSchemeHandler, forURLScheme: "wafer-remote")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView

        super.init(nibName: nil, bundle: nil)

        let messageHandler = WeakReaderMessageHandler(self)
        contentController.add(messageHandler, contentWorld: Self.readerContentWorld, name: ScriptMessageName.scroll)
        contentController.add(messageHandler, contentWorld: Self.readerContentWorld, name: ScriptMessageName.activeHeading)
        contentController.add(messageHandler, contentWorld: Self.readerContentWorld, name: ScriptMessageName.openLinkInNewTab)
        contentController.add(messageHandler, contentWorld: Self.readerContentWorld, name: ScriptMessageName.copyCode)
        contentController.add(messageHandler, name: ScriptMessageName.contentReady)
        contentController.add(messageHandler, name: ScriptMessageName.liveScroll)
        didInstallScriptMessageHandlers = true
        webView.navigationDelegate = self
        webView.wantsLayer = true
        webView.layer?.masksToBounds = true
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        configureScrollBehavior()
        configureFindUI()
        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var currentScrollFraction: Double {
        lastKnownScrollFraction
    }

    #if DEBUG
    var horizontalScrollElasticityForTesting: NSScrollView.Elasticity? {
        webContentScrollView()?.horizontalScrollElasticity
    }

    var hasHorizontalScrollerForTesting: Bool? {
        webContentScrollView()?.hasHorizontalScroller
    }

    var isFindBarVisibleForTesting: Bool {
        !findBarView.isHidden
    }

    var findStatusTextForTesting: String {
        findBarView.statusLabel.stringValue
    }

    var findQueryForTesting: String {
        findBarView.searchField.stringValue
    }

    var isAwaitingContentReadyForTesting: Bool {
        awaitingContentReady
    }
    #endif

    var isContentReadyForExport: Bool {
        hasRenderableContent && didCompleteCurrentNavigation && !awaitingContentReady && themeUpdateID == nil
    }

    var webViewForExport: WKWebView? {
        isContentReadyForExport ? webView : nil
    }

    var allowedRootDirectoriesForExport: [URL] {
        isContentReadyForExport ? localAssetSchemeHandler.allowedRootDirectories : []
    }

    #if DEBUG
    func setSuppressFindExecutionForTesting(_ isSuppressed: Bool) {
        suppressFindExecutionForTesting = isSuppressed
    }
    #endif

    #if DEBUG
    func setSuppressedFindMatchResultForTesting(_ matchFound: Bool?) {
        suppressedFindMatchResultForTesting = matchFound
    }
    #endif

    #if DEBUG
    func setFindQueryForTesting(_ query: String) {
        findBarView.searchField.stringValue = query
    }

    func triggerFindQueryChangeForTesting() {
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: findBarView.searchField))
    }

    static var scrollScriptSourceForTesting: String {
        scrollScript
    }
    #endif

    override func loadView() {
        rootView.frame = NSRect(x: 0, y: 0, width: 920, height: 760)
        rootView.wantsLayer = true
        view = rootView
        configureRootLayout()
        configureScrollBehavior()
        applyCurrentTheme()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        rootView.window?.appearance = ReaderTheme.windowAppearance
        configureScrollBehavior()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        configureScrollBehavior()
    }

    func applyCurrentTheme() {
        webView.layer?.backgroundColor = ReaderTheme.backgroundColor.cgColor
        rootView.layer?.backgroundColor = ReaderTheme.backgroundColor.cgColor
        findBarView.layer?.backgroundColor = ReaderTheme.findBarBackgroundColor.cgColor
        findBarView.layer?.borderColor = ReaderTheme.findBarBorderColor.cgColor
        findBarView.statusLabel.textColor = ReaderTheme.sidebarSecondaryTextColor
        for button in [findBarView.previousButton, findBarView.nextButton, findBarView.closeButton] {
            button.contentTintColor = ReaderTheme.sidebarPrimaryTextColor
        }
        view.window?.appearance = ReaderTheme.windowAppearance
    }

    @objc func showFindInterface(_ sender: Any?) {
        ensureFindBarVisible()
        view.window?.makeFirstResponder(findBarView.searchField)
        findBarView.searchField.selectText(nil)
    }

    @objc func findNextMatch(_ sender: Any?) {
        guard !normalizedFindQuery().isEmpty else {
            showFindInterface(sender)
            updateFindStatus(nil)
            return
        }

        ensureFindBarVisible()
        performFind(direction: .next)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        guard !normalizedFindQuery().isEmpty else {
            showFindInterface(sender)
            updateFindStatus(nil)
            return
        }

        ensureFindBarVisible()
        performFind(direction: .previous)
    }

    @objc func hideFindInterface(_ sender: Any?) {
        findBarView.isHidden = true
        updateFindStatus(nil)
        clearBrowserSelection()
        view.window?.makeFirstResponder(webView)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(showFindInterface(_:)):
            return true
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)):
            return !normalizedFindQuery().isEmpty
        default:
            return true
        }
    }

    func displayLoading(for fileName: String) {
        // Window creation and the first render schedule both request the
        // placeholder; reloading it for the same file would queue a second
        // WebKit navigation ahead of the real content load for nothing.
        guard displayedLoadingFileName != fileName else {
            return
        }

        displayedLoadingFileName = fileName
        resetNavigationCompletionState(awaitsContentReady: false)
        resetLivePreviewState(for: nil)
        hasRenderableContent = false
        pendingRestoreFraction = nil
        localAssetSchemeHandler.documentRootDirectory = nil
        currentNavigation = webView.loadHTMLString(loadingHTML(for: fileName), baseURL: nil)
    }

    func apply(renderOutput: WebKitRenderOutput, initialScrollFraction: Double?) {
        displayedLoadingFileName = nil
        resetNavigationCompletionState(awaitsContentReady: renderOutput.waitsForContentReady)
        resetLivePreviewState(for: renderOutput)
        hasRenderableContent = true
        pendingRestoreFraction = initialScrollFraction
        lastKnownScrollFraction = initialScrollFraction ?? 0
        localAssetSchemeHandler.documentRootDirectory = renderOutput.baseURL
        let html = renderOutput.html.replacingOccurrences(of: "<head>", with: "<head><meta name=\"wafer-navigation\" content=\"\(navigationID.uuidString)\">")
        currentNavigation = webView.loadHTMLString(html, baseURL: renderOutput.baseURL)
    }

    /// Update CSS and existing diagrams without replacing the reading surface.
    func updateTheme(_ palette: ReaderThemePalette) {
        let updateID = UUID()
        themeUpdateID = updateID
        let variables = Dictionary(uniqueKeysWithValues: palette.mermaid.themeVariables + [("fontFamily", palette.mermaid.fontFamily)])
        webView.callAsyncJavaScript("""
            let style = document.getElementById('wafer-palette');
            if (!style) {
              style = document.createElement('style');
              style.id = 'wafer-palette';
              document.head.appendChild(style);
            }
            style.textContent = css;
            if (window.waferApplyMermaidTheme) {
              await window.waferApplyMermaidTheme(theme, variables);
            }
            """, arguments: ["css": ReaderTheme.generatedRootBlock(for: palette),
                              "theme": palette.mermaid.theme, "variables": variables],
            in: nil, in: .page) { [weak self] _ in
                guard let self, self.themeUpdateID == updateID else { return }
                self.themeUpdateID = nil
                self.onNavigationFinished?()
            }
    }

    #if DEBUG
    func loadHTMLForTesting(_ html: String, baseURL: URL? = nil, initialScrollFraction: Double? = nil) {
        displayedLoadingFileName = nil
        resetNavigationCompletionState(awaitsContentReady: false)
        resetLivePreviewState(for: nil)
        hasRenderableContent = true
        pendingRestoreFraction = initialScrollFraction
        lastKnownScrollFraction = initialScrollFraction ?? 0
        localAssetSchemeHandler.documentRootDirectory = baseURL
        currentNavigation = webView.loadHTMLString(html, baseURL: baseURL)
    }
    #endif

    #if DEBUG
    func evaluateJavaScriptForTesting(
        _ script: String,
        completionHandler: (@Sendable (Any?, Error?) -> Void)? = nil
    ) {
        webView.evaluateJavaScript(script, completionHandler: completionHandler)
    }
    #endif

    func exportDOMSnapshot(completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        guard isContentReadyForExport else {
            completion(.failure(ExportHTMLPreparationError.contentNotReady))
            return
        }

        // Edit-mode source-line annotations are preview plumbing, not content.
        let snapshotScript = """
        (function() {
          if (!document.querySelector('[data-source-line]')) { return document.documentElement.outerHTML; }
          const root = document.documentElement.cloneNode(true);
          root.querySelectorAll('[data-source-line]').forEach(function(element) { element.removeAttribute('data-source-line'); });
          return root.outerHTML;
        })()
        """
        webView.evaluateJavaScript(snapshotScript) { value, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let html = value as? String, !html.isEmpty else {
                completion(.failure(ExportHTMLPreparationError.invalidDOMSnapshot))
                return
            }

            completion(.success(html))
        }
    }

    #if DEBUG
    func evaluateReaderContentJavaScriptForTesting(
        _ script: String,
        completionHandler: (@Sendable (Any?, Error?) -> Void)? = nil
    ) {
        webView.evaluateJavaScript(script, in: nil, in: Self.readerContentWorld) { result in
            switch result {
            case let .success(value):
                completionHandler?(value, nil)
            case let .failure(error):
                completionHandler?(nil, error)
            }
        }
    }
    #endif

    #if DEBUG
    func invalidateForTesting() {
        shutdown()
    }
    #endif

    func shutdown() {
        invalidateWebViewCallbacks()
        onOpenLink = nil
        onOpenLinkInNewTab = nil
        onScrollPositionChange = nil
        onActiveHeadingChange = nil
        onNavigationFinished = nil
        onLiveScroll = nil
    }

    /// Gives keyboard focus to the rendered document.
    func focusContent() {
        view.window?.makeFirstResponder(webView)
    }

    func scrollToHeading(id: String) {
        webView.evaluateJavaScript(Self.scrollToHeadingScript(for: id))
    }

    // MARK: Edit-mode live preview

    /// True when the current page can be patched in place and scroll-synced.
    var supportsLivePreview: Bool {
        !ReaderLivePreviewScript.installer.isEmpty && liveBodyHTML != nil && isContentReadyForExport
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

        let expectedNavigationID = navigationID
        let previous: Any = livePatchStateReady ? NSNull() : (liveBodyHTML ?? "")
        var arguments = Self.scriptArguments(for: editorPosition ?? .zero)
        arguments["html"] = body
        arguments["previous"] = previous
        arguments["hasPosition"] = editorPosition != nil
        if let editorPosition {
            lastSyncedMetrics = editorPosition
        }
        webView.callAsyncJavaScript(ReaderLivePreviewScript.patchCall, arguments: arguments, in: nil, in: .page) { [weak self] result in
            guard let self, self.navigationID == expectedNavigationID else { return }
            if case let .success(value) = result, let status = value as? String, status.hasPrefix("patched") {
                self.liveBodyHTML = body
                self.liveHelpersInstalled = true
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
        let expectedNavigationID = navigationID
        let script = liveHelpersInstalled ? ReaderLivePreviewScript.installedScrollCall : ReaderLivePreviewScript.scrollCall
        liveHelpersInstalled = true
        webView.callAsyncJavaScript(script, arguments: Self.scriptArguments(for: position), in: nil, in: .page) { [weak self] _ in
            guard let self else { return }
            self.scrollSyncInFlight = false
            guard self.navigationID == expectedNavigationID else {
                self.pendingScrollSync = nil
                return
            }
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
        webView.callAsyncJavaScript(
            ReaderLivePreviewScript.updateMetricsCall,
            arguments: Self.scriptArguments(for: position),
            in: nil,
            in: .page
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
        webView.callAsyncJavaScript(
            ReaderLivePreviewScript.lineAtTopCall,
            arguments: Self.scriptArguments(for: position),
            in: nil,
            in: .page
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

        webView.callAsyncJavaScript(ReaderLivePreviewScript.deactivateCall, arguments: [:], in: nil, in: .page) { _ in }
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
        let fraction = lastKnownScrollFraction
        apply(renderOutput: renderOutput, initialScrollFraction: fraction >= 0.98 ? 1 : fraction)
    }

    private func resetLivePreviewState(for renderOutput: WebKitRenderOutput?) {
        liveBodyHTML = renderOutput?.bodyHTML
        liveHelpersInstalled = false
        livePatchStateReady = false
        pageHasMermaid = renderOutput?.hasMermaidDiagrams ?? false
        pageHasMath = renderOutput?.hasMathDisplays ?? false
        pendingScrollSync = nil
        lastSyncedMetrics = nil
    }

    #if DEBUG
    func markNavigationFinishedForTesting() {
        handleNavigationFinished()
    }
    #endif

    #if DEBUG
    func handleContentReadyForTesting() {
        handleContentReady()
    }
    #endif

    static func scrollToHeadingScript(for id: String) -> String {
        // JSON encodes control characters and quotes; escaping '<' also keeps
        // the value safe if this script is ever embedded in an HTML element.
        let json = try! JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed])
        let encodedID = String(decoding: json, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return """
        (function() {
          const target = document.getElementById(\(encodedID));
          if (!target) {
            return false;
          }
          const offset = \(headingScrollOffset);
          const targetTop = window.scrollY + target.getBoundingClientRect().top - offset;
          window.scrollTo({ top: Math.max(targetTop, 0), behavior: 'auto' });
          return true;
        })();
        """
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case ScriptMessageName.scroll:
            if let fraction = message.body as? Double {
                handleReportedScrollFraction(fraction)
            }
        case ScriptMessageName.activeHeading:
            if let headingID = message.body as? String {
                handleReportedActiveHeading(headingID.isEmpty ? nil : headingID)
            } else if message.body is NSNull {
                handleReportedActiveHeading(nil)
            }
        case ScriptMessageName.openLinkInNewTab:
            if let href = message.body as? String, let url = URL(string: href) {
                handleOpenLinkInNewTab(url)
            }
        case ScriptMessageName.copyCode:
            if let text = message.body as? String {
                handleCopyCode(text)
            }
        case ScriptMessageName.contentReady:
            if message.body as? String == navigationID.uuidString { handleContentReady() }
        case ScriptMessageName.liveScroll:
            if let line = (message.body as? NSNumber)?.doubleValue, line.isFinite {
                onLiveScroll?(line)
            }
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === currentNavigation else { return }
        installReaderScriptThenFinishNavigation()
    }

    private func handleNavigationFinished() {
        configureScrollBehavior()
        didFinishCurrentNavigation = true
        completeNavigationIfReady()
    }

    private func installReaderScriptThenFinishNavigation() {
        let expectedID = navigationID
        webView.evaluateJavaScript(Self.scrollScript, in: nil, in: Self.readerContentWorld) { [weak self] _ in
            guard let self, self.navigationID == expectedID else { return }
            self.handleNavigationFinished()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard
            navigationAction.navigationType == .linkActivated,
            let url = navigationAction.request.url
        else {
            decisionHandler(.allow)
            return
        }

        decisionHandler(handleActivatedLink(url, modifierFlags: navigationAction.modifierFlags))
    }

    func handleActivatedLink(_ url: URL, modifierFlags: NSEvent.ModifierFlags = []) -> WKNavigationActionPolicy {
        if modifierFlags.contains(.command) {
            handleOpenLinkInNewTab(url)
        } else {
            onOpenLink?(url)
        }
        return .cancel
    }

    func handleOpenLinkInNewTab(_ url: URL) {
        (onOpenLinkInNewTab ?? onOpenLink)?(url)
    }

    #if DEBUG
    /// Test seam; nil writes to the general pasteboard.
    var pasteboardForCopyCodeForTesting: NSPasteboard?
    #endif

    func handleCopyCode(_ text: String) {
        #if DEBUG
        let pasteboard = pasteboardForCopyCodeForTesting ?? NSPasteboard.general
        #else
        let pasteboard = NSPasteboard.general
        #endif
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === findBarView.searchField else {
            return
        }

        if normalizedFindQuery().isEmpty {
            #if DEBUG
            lastFindQueryForTesting = nil
            lastFindMatchFoundForTesting = nil
            #endif
            updateFindStatus(nil)
            clearBrowserSelection()
            return
        }

        performFind(direction: .next)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === findBarView.searchField else {
            return false
        }

        switch commandSelector {
        case #selector(cancelOperation(_:)):
            hideFindInterface(control)
            return true
        case #selector(insertNewline(_:)):
            findNextMatch(control)
            return true
        default:
            return false
        }
    }

    func handleReportedScrollFraction(_ fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        lastKnownScrollFraction = clamped
        onScrollPositionChange?(clamped)
    }

    func handleReportedActiveHeading(_ headingID: String?) {
        guard currentActiveHeadingID != headingID else {
            return
        }

        currentActiveHeadingID = headingID
        onActiveHeadingChange?(headingID)
    }

    private func restorePendingScrollIfNeeded() {
        guard let fraction = pendingRestoreFraction else {
            return
        }

        pendingRestoreFraction = nil
        let clamped = min(max(fraction, 0), 1)
        let script = """
        (function() {
          const root = document.scrollingElement || document.documentElement;
          const maxOffset = Math.max(root.scrollHeight - window.innerHeight, 0);
          window.scrollTo(0, maxOffset * fraction);
        })();
        """
        webView.callAsyncJavaScript(script, arguments: ["fraction": clamped], in: nil, in: .page) { _ in }
        lastKnownScrollFraction = clamped
    }

    private func resetNavigationCompletionState(awaitsContentReady: Bool) {
        navigationID = UUID()
        themeUpdateID = nil
        awaitingContentReady = awaitsContentReady
        didFinishCurrentNavigation = false
        didCompleteCurrentNavigation = false
    }

    private func invalidateWebViewCallbacks() {
        guard didInstallScriptMessageHandlers else {
            return
        }

        webView.stopLoading()
        webView.navigationDelegate = nil
        let contentController = webView.configuration.userContentController
        contentController.removeScriptMessageHandler(forName: ScriptMessageName.scroll, contentWorld: Self.readerContentWorld)
        contentController.removeScriptMessageHandler(forName: ScriptMessageName.activeHeading, contentWorld: Self.readerContentWorld)
        contentController.removeScriptMessageHandler(forName: ScriptMessageName.openLinkInNewTab, contentWorld: Self.readerContentWorld)
        contentController.removeScriptMessageHandler(forName: ScriptMessageName.copyCode, contentWorld: Self.readerContentWorld)
        contentController.removeScriptMessageHandler(forName: ScriptMessageName.contentReady)
        contentController.removeScriptMessageHandler(forName: ScriptMessageName.liveScroll)
        didInstallScriptMessageHandlers = false
    }

    private func handleContentReady() {
        guard awaitingContentReady else {
            return
        }

        configureScrollBehavior()
        awaitingContentReady = false
        completeNavigationIfReady()
    }

    private func completeNavigationIfReady() {
        guard didFinishCurrentNavigation, !awaitingContentReady, !didCompleteCurrentNavigation else {
            return
        }

        didCompleteCurrentNavigation = true
        restorePendingScrollIfNeeded()
        onNavigationFinished?()
    }

    private func loadingHTML(for fileName: String) -> String {
        let escapedFileName = fileName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body {
              margin: 0;
              min-height: 100%;
              background: \(ReaderTheme.backgroundHex);
              color: \(ReaderTheme.secondaryTextHex);
              font-family: \(ReaderTheme.bodyFontStack);
              font-size: 16px;
              line-height: \(ReaderTheme.bodyLineHeight);
              overflow-x: hidden;
              overscroll-behavior-x: none;
            }
            #write {
              box-sizing: border-box;
              max-width: \(ReaderTheme.contentMaxWidth)px;
              margin: 0 auto;
              padding: 0 \(ReaderTheme.contentHorizontalPadding)px 43px;
            }
          </style>
        </head>
        <body>
          <div id="write"><p>Opening \(escapedFileName)...</p></div>
        </body>
        </html>
        """
    }

    private func configureScrollBehavior() {
        let scrollViews = webContentScrollViews()
        guard !scrollViews.isEmpty else {
            return
        }

        for scrollView in scrollViews {
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.horizontalScrollElasticity = .none
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets()
            scrollView.scrollerInsets = NSEdgeInsets()
        }
    }

    private func configureRootLayout() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        findBarView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(webView)
        rootView.addSubview(findBarView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: rootView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            findBarView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
            findBarView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -16),
        ])
    }

    private func configureFindUI() {
        findBarView.configure(target: self, delegate: self)
        updateFindStatus(nil)
    }

    private func webContentScrollView() -> NSScrollView? {
        webContentScrollViews().first
    }

    private func webContentScrollViews() -> [NSScrollView] {
        findScrollViews(in: webView)
    }

    private func findScrollViews(in view: NSView) -> [NSScrollView] {
        let localScrollViews = (view as? NSScrollView).map { [$0] } ?? []
        return localScrollViews + view.subviews.flatMap(findScrollViews(in:))
    }

    private func ensureFindBarVisible() {
        findBarView.isHidden = false
    }

    private func normalizedFindQuery() -> String {
        findBarView.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func performFind(direction: FindDirection) {
        let query = normalizedFindQuery()
        guard !query.isEmpty else {
            updateFindStatus(nil)
            return
        }

        #if DEBUG
        lastFindQueryForTesting = query
        lastFindDirectionForTesting = direction == .previous ? "previous" : "next"
        #endif

        #if DEBUG
        if suppressFindExecutionForTesting {
            let matchFound = suppressedFindMatchResultForTesting ?? true
            #if DEBUG
            lastFindMatchFoundForTesting = matchFound
            #endif
            updateFindStatus(matchFound ? nil : "No matches")
            return
        }

        #endif

        let configuration = WKFindConfiguration()
        configuration.backwards = direction == .previous
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(query, configuration: configuration) { [weak self] result in
            guard let self else {
                return
            }

            #if DEBUG
            self.lastFindMatchFoundForTesting = result.matchFound
            #endif
            self.updateFindStatus(result.matchFound ? nil : "No matches")
        }
    }

    private func updateFindStatus(_ text: String?) {
        findBarView.statusLabel.stringValue = text ?? ""
        findBarView.statusLabel.isHidden = text == nil || text?.isEmpty == true
    }

    private func clearBrowserSelection() {
        webView.evaluateJavaScript("""
        (function() {
          const selection = window.getSelection && window.getSelection();
          if (selection) {
            selection.removeAllRanges();
          }
          return true;
        })();
        """)
    }

    private static let scrollScript = ReaderScriptResource.load("reader-scroll")

}

@MainActor
private final class WeakReaderMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var reader: WebKitReaderViewController?

    init(_ reader: WebKitReaderViewController) { self.reader = reader }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        reader?.userContentController(userContentController, didReceive: message)
    }
}
