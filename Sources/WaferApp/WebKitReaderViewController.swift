import AppKit
import Foundation
import WaferCore
import WebKit

@MainActor
class WebKitReaderViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler, NSUserInterfaceValidations, ThemeApplying {
    private static let headingScrollOffset: Int = 28
    private static let readerContentWorld = WKContentWorld.world(name: "dev.wafer.reader")

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
    private lazy var findController = ReaderFindController(
        find: { [weak self] query, configuration, completion in
            self?.webView.find(query, configuration: configuration) { completion($0.matchFound) }
        },
        clearSelection: { [weak self] script in self?.webView.evaluateJavaScript(script) },
        focusContent: { [weak self] in self?.focusContent() }
    )
    private var findBarView: ReaderFindBarView { findController.bar }
    private var pendingRestoreFraction: Double?
    private var hasRenderableContent = false
    private var displayedLoadingFileName: String?
    private var navigation = ReaderNavigationState()
    private var currentNavigation: WKNavigation?
    private var didInstallScriptMessageHandlers = false
    private var lastKnownScrollFraction: Double = 0
    private lazy var livePreview = ReaderLivePreviewController(
        evaluate: { [weak self] script, arguments, world, completion in
            self?.webView.callAsyncJavaScript(
                script, arguments: arguments, in: nil,
                in: world == .page ? .page : Self.readerContentWorld,
                completionHandler: completion
            )
        },
        isContentReady: { [weak self] in self?.isContentReadyForExport == true },
        reload: { [weak self] output in
            guard let self else { return }
            let fraction = self.lastKnownScrollFraction
            self.apply(renderOutput: output, initialScrollFraction: fraction >= 0.98 ? 1 : fraction)
        }
    )
    #if DEBUG
    var livePatchCountForTesting: Int { livePreview.livePatchCountForTesting }
    var liveFullReloadCountForTesting: Int { livePreview.liveFullReloadCountForTesting }
    #endif
    private(set) var currentActiveHeadingID: String?
    #if DEBUG
    var lastFindQueryForTesting: String? { findController.lastFindQueryForTesting }
    var lastFindDirectionForTesting: String? { findController.lastFindDirectionForTesting }
    var lastFindMatchFoundForTesting: Bool? { findController.lastFindMatchFoundForTesting }
    /// Re-installed on every reader load, after the reader's own user scripts.
    var additionalUserScriptsForTesting: [WKUserScript] = []
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
        // The reader only loads HTML it generates; Safe Browsing lookups are a sandbox denial with no benefit.
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
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
        contentController.add(messageHandler, contentWorld: Self.readerContentWorld, name: ScriptMessageName.contentReady)
        contentController.add(messageHandler, contentWorld: Self.readerContentWorld, name: ScriptMessageName.liveScroll)
        didInstallScriptMessageHandlers = true
        webView.navigationDelegate = self
        webView.wantsLayer = true
        webView.layer?.masksToBounds = true
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        configureScrollBehavior()
        _ = findController
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
        navigation.awaitingContentReady
    }
    #endif

    var isContentReadyForExport: Bool {
        hasRenderableContent && navigation.isReady
    }

    var webViewForExport: WKWebView? {
        isContentReadyForExport ? webView : nil
    }

    var allowedRootDirectoriesForExport: [URL] {
        isContentReadyForExport ? localAssetSchemeHandler.allowedRootDirectories : []
    }

    #if DEBUG
    func setSuppressFindExecutionForTesting(_ isSuppressed: Bool) {
        findController.suppressFindExecutionForTesting = isSuppressed
    }
    #endif

    #if DEBUG
    func setSuppressedFindMatchResultForTesting(_ matchFound: Bool?) {
        findController.suppressedFindMatchResultForTesting = matchFound
    }
    #endif

    #if DEBUG
    func setFindQueryForTesting(_ query: String) {
        findBarView.searchField.stringValue = query
    }

    func triggerFindQueryChangeForTesting() {
        findController.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: findBarView.searchField))
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
        _ = view
        findController.showFindInterface(sender)
    }

    @objc func findNextMatch(_ sender: Any?) {
        _ = view
        findController.findNextMatch(sender)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        _ = view
        findController.findPreviousMatch(sender)
    }

    @objc func hideFindInterface(_ sender: Any?) {
        _ = view
        findController.hideFindInterface(sender)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        findController.validateUserInterfaceItem(item)
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
        livePreview.reset(for: nil)
        hasRenderableContent = false
        pendingRestoreFraction = nil
        localAssetSchemeHandler.documentRootDirectory = nil
        loadReaderHTML(loadingHTML(for: fileName), baseURL: nil)
    }

    func apply(renderOutput: WebKitRenderOutput, initialScrollFraction: Double?) {
        displayedLoadingFileName = nil
        resetNavigationCompletionState(awaitsContentReady: renderOutput.waitsForContentReady)
        livePreview.reset(for: renderOutput)
        hasRenderableContent = true
        pendingRestoreFraction = initialScrollFraction
        lastKnownScrollFraction = initialScrollFraction ?? 0
        localAssetSchemeHandler.documentRootDirectory = renderOutput.baseURL
        loadReaderHTML(renderOutput.html, baseURL: renderOutput.baseURL)
    }

    private func loadReaderHTML(_ html: String, baseURL: URL?) {
        let readerURL = navigation.authorizeLoad(baseURL: baseURL)
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: """
            document.addEventListener('wafer-content-ready', function() {
              window.webkit.messageHandlers.waferContentReady.postMessage('\(navigation.id.uuidString)');
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.readerContentWorld))
        // The bundled Core renderer uses this page-world API. It is a DOM
        // relay only; the native message handler exists in the reader world.
        controller.addUserScript(WKUserScript(source: """
            window.webkit = window.webkit || {};
            window.webkit.messageHandlers = window.webkit.messageHandlers || {};
            window.webkit.messageHandlers.waferContentReady = {
              postMessage: function() { document.dispatchEvent(new Event('wafer-content-ready')); }
            };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        #if DEBUG
        additionalUserScriptsForTesting.forEach(controller.addUserScript)
        #endif
        currentNavigation = webView.loadHTMLString(html, baseURL: readerURL)
    }

    /// Update CSS and existing diagrams without replacing the reading surface.
    func updateTheme(_ palette: ReaderThemePalette) {
        let updateID = navigation.beginThemeUpdate()
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
                guard let self, self.navigation.finishThemeUpdate(id: updateID) else { return }
                self.onNavigationFinished?()
            }
    }

    #if DEBUG
    func loadHTMLForTesting(_ html: String, baseURL: URL? = nil, initialScrollFraction: Double? = nil) {
        displayedLoadingFileName = nil
        resetNavigationCompletionState(awaitsContentReady: false)
        livePreview.reset(for: nil)
        hasRenderableContent = true
        pendingRestoreFraction = initialScrollFraction
        lastKnownScrollFraction = initialScrollFraction ?? 0
        localAssetSchemeHandler.documentRootDirectory = baseURL
        loadReaderHTML(html, baseURL: baseURL)
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

    var supportsLivePreview: Bool { livePreview.supportsLivePreview }

    func applyLiveUpdate(
        renderOutput: WebKitRenderOutput,
        editorPosition: EditorScrollPosition? = nil,
        completion: (@MainActor (_ patched: Bool) -> Void)? = nil
    ) {
        livePreview.applyLiveUpdate(renderOutput: renderOutput, editorPosition: editorPosition, completion: completion)
    }

    func syncScroll(to position: EditorScrollPosition) {
        livePreview.syncScroll(to: position)
    }

    func updateScrollSyncMetrics(_ position: EditorScrollPosition) {
        livePreview.updateScrollSyncMetrics(position)
    }

    func sourceLineAtTop(for position: EditorScrollPosition, completion: @escaping @MainActor (Double?) -> Void) {
        livePreview.sourceLineAtTop(for: position, completion: completion)
    }

    func endLivePreview() {
        livePreview.endLivePreview()
    }

    #if DEBUG
    func markNavigationFinishedForTesting() {
        handleNavigationFinished()
    }
    #endif

    #if DEBUG
    func handleContentReadyForTesting() {
        handleContentReady(id: navigation.id.uuidString)
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
            if let id = message.body as? String { handleContentReady(id: id) }
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
        if navigation.navigationFinished() { completeNavigation() }
    }

    private func installReaderScriptThenFinishNavigation() {
        let expectedID = navigation.id
        webView.evaluateJavaScript(Self.scrollScript, in: nil, in: Self.readerContentWorld) { [weak self] _ in
            guard let self, self.navigation.id == expectedID else { return }
            self.handleNavigationFinished()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            decisionHandler(handleActivatedLink(url, modifierFlags: navigationAction.modifierFlags))
            return
        }
        let allowed = navigation.allowsNavigation(
            to: url, currentURL: webView.url,
            isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
            isOther: navigationAction.navigationType == .other
        )
        decisionHandler(allowed ? .allow : .cancel)
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
        navigation.reset(awaitsContentReady: awaitsContentReady)
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
        contentController.removeScriptMessageHandler(forName: ScriptMessageName.contentReady, contentWorld: Self.readerContentWorld)
        contentController.removeScriptMessageHandler(forName: ScriptMessageName.liveScroll, contentWorld: Self.readerContentWorld)
        didInstallScriptMessageHandlers = false
    }

    private func handleContentReady(id: String) {
        guard id == navigation.id.uuidString, navigation.awaitingContentReady else { return }
        configureScrollBehavior()
        if navigation.contentReady(id: id) { completeNavigation() }
    }

    private func completeNavigation() {
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
