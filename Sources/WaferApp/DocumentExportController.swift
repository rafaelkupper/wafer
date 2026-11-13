import AppKit
import UniformTypeIdentifiers
import WaferCore
import WebKit

@MainActor
protocol ExportSavePanel: AnyObject {
    var allowedContentTypes: [UTType] { get set }
    var canCreateDirectories: Bool { get set }
    var nameFieldStringValue: String { get set }
    var directoryURL: URL? { get set }
    var url: URL? { get }

    func beginSheetModal(
        for window: NSWindow,
        completionHandler: @escaping (NSApplication.ModalResponse) -> Void
    )
}

extension NSSavePanel: ExportSavePanel {}

@MainActor
struct DocumentExportContext {
    let webView: WKWebView
    let window: NSWindow
    let documentURL: URL?
    let readerController: WebKitReaderViewController
}

@MainActor
protocol DocumentExportControlling: AnyObject {
    func printDocument(_ webView: WKWebView, window: NSWindow)
    func exportPDF(from context: DocumentExportContext)
    func exportHTML(from context: DocumentExportContext)
    func canExportHTML(from context: DocumentExportContext) -> Bool
}

extension DocumentExportControlling {
    func canExportHTML(from context: DocumentExportContext) -> Bool {
        true
    }
}

@MainActor
final class DocumentExportController: NSObject, DocumentExportControlling {
    enum PrintMode: Equatable {
        case printDialog
        case pdf(URL)
    }

    struct PanelConfiguration: Equatable {
        let showsPrintPanel: Bool
        let showsProgressPanel: Bool
    }

    private let savePanelFactory: () -> any ExportSavePanel
    private let remoteImageFetcher: RemoteImageFetching
    private let preferenceStore: ReaderBehaviorPreferenceStore
    private let htmlFileWriter: @Sendable (Data, URL) throws -> Void
    private let htmlPreparationObserver: @Sendable (Bool) -> Void
    private var reportsFailedOperations = Set<ObjectIdentifier>()
    private var activeHTMLExportWindows = Set<ObjectIdentifier>()
    private var exportOperations: [ObjectIdentifier: HTMLExportOperation] = [:]

    init(
        savePanelFactory: @escaping () -> any ExportSavePanel = { NSSavePanel() },
        remoteImageFetcher: RemoteImageFetching = RemoteImageURLSessionFetcher(),
        preferenceStore: ReaderBehaviorPreferenceStore = .shared,
        htmlFileWriter: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        },
        htmlPreparationObserver: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        self.savePanelFactory = savePanelFactory
        self.remoteImageFetcher = remoteImageFetcher
        self.preferenceStore = preferenceStore
        self.htmlFileWriter = htmlFileWriter
        self.htmlPreparationObserver = htmlPreparationObserver
    }

    func printDocument(_ webView: WKWebView, window: NSWindow) {
        let operation = makePrintOperation(for: webView, mode: .printDialog)
        run(operation, for: webView, window: window, reportsFailure: false)
    }

    func exportPDF(from context: DocumentExportContext) {
        let panel = configuredSavePanel(
            documentURL: context.documentURL,
            contentType: .pdf,
            fileExtension: "pdf"
        )
        panel.beginSheetModal(for: context.window) { [weak self, weak panel] response in
            guard
                response == .OK,
                let url = panel?.url
            else {
                return
            }

            let operation = Self.makePrintOperation(for: context.webView, mode: .pdf(url))
            self?.run(operation, for: context.webView, window: context.window, reportsFailure: true)
        }
    }

    func exportHTML(from context: DocumentExportContext) {
        guard canExportHTML(from: context) else {
            return
        }

        let panel = configuredSavePanel(
            documentURL: context.documentURL,
            contentType: .html,
            fileExtension: "html"
        )
        panel.beginSheetModal(for: context.window) { [weak self, weak panel] response in
            guard
                response == .OK,
                let url = panel?.url
            else {
                return
            }

            self?.startHTMLExport(from: context, to: url)
        }
    }

    func canExportHTML(from context: DocumentExportContext) -> Bool {
        !activeHTMLExportWindows.contains(ObjectIdentifier(context.window))
    }

    static func suggestedFileName(documentURL: URL?, fileExtension: String) -> String {
        let baseName = documentURL?
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBaseName: String
        if let baseName, !baseName.isEmpty {
            safeBaseName = baseName
        } else {
            safeBaseName = "Wafer Export"
        }
        return "\(safeBaseName).\(fileExtension)"
    }

    static func printInfo(for mode: PrintMode) -> NSPrintInfo {
        let printInfo = NSPrintInfo()
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false

        if case let .pdf(url) = mode {
            printInfo.jobDisposition = .save
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        }

        return printInfo
    }

    static func makePrintOperation(for webView: WKWebView, mode: PrintMode) -> NSPrintOperation {
        let operation = webView.printOperation(with: printInfo(for: mode))
        let panels = panelConfiguration(for: mode)
        operation.showsPrintPanel = panels.showsPrintPanel
        operation.showsProgressPanel = panels.showsProgressPanel
        return operation
    }

    static func panelConfiguration(for mode: PrintMode) -> PanelConfiguration {
        switch mode {
        case .printDialog:
            return PanelConfiguration(showsPrintPanel: true, showsProgressPanel: true)
        case .pdf:
            return PanelConfiguration(showsPrintPanel: false, showsProgressPanel: false)
        }
    }

    private func configuredSavePanel(
        documentURL: URL?,
        contentType: UTType,
        fileExtension: String
    ) -> any ExportSavePanel {
        let panel = savePanelFactory()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.suggestedFileName(documentURL: documentURL, fileExtension: fileExtension)
        panel.directoryURL = documentURL?.deletingLastPathComponent()
        return panel
    }

    private func makePrintOperation(for webView: WKWebView, mode: PrintMode) -> NSPrintOperation {
        Self.makePrintOperation(for: webView, mode: mode)
    }

    private func run(
        _ operation: NSPrintOperation,
        for webView: WKWebView,
        window: NSWindow,
        reportsFailure: Bool
    ) {
        if let printView = operation.view, printView.frame.isEmpty {
            printView.frame = webView.bounds.isEmpty
                ? NSRect(x: 0, y: 0, width: 800, height: 1000)
                : webView.bounds
        }

        if reportsFailure {
            reportsFailedOperations.insert(ObjectIdentifier(operation))
        }
        operation.runModal(
            for: window,
            delegate: self,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func printOperationDidRun(
        _ operation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let shouldReportFailure = reportsFailedOperations.remove(ObjectIdentifier(operation)) != nil
        guard shouldReportFailure, !success else {
            return
        }

        NSApp.presentError(ExportError.pdfWriteFailed)
    }

    private func startHTMLExport(from context: DocumentExportContext, to url: URL) {
        let window = context.window
        let windowID = ObjectIdentifier(window)
        activeHTMLExportWindows.insert(windowID)
        let operation = HTMLExportOperation()
        exportOperations[windowID] = operation
        operation.windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.completeHTMLExport(windowID: windowID, error: nil) }
        }

        let allowedRootDirectories = context.readerController.allowedRootDirectoriesForExport
        let remoteImagesEnabled = preferenceStore.loadsRemoteImages
        context.readerController.exportDOMSnapshot { [weak self, weak window] result in
            guard let self else {
                return
            }

            guard window != nil else {
                self.completeHTMLExport(windowID: windowID, error: nil)
                return
            }

            switch result {
            case let .success(domHTML):
                let loader = RemoteExportAssetLoader(fetcher: self.remoteImageFetcher,
                    sources: remoteImagesEnabled ? ExportSanitizer.remoteImageSources(in: domHTML) : [])
                operation.remoteLoader = loader
                loader.start { [weak self] result in
                    guard let self, !operation.cancellation.isCancelled else { return }
                    switch result {
                    case .success(let remoteAssets):
                        self.writeHTMLExport(domHTML: domHTML, outputURL: url,
                            allowedRootDirectories: allowedRootDirectories, remoteAssets: remoteAssets,
                            windowID: windowID, cancellation: operation.cancellation)
                    case .failure(let error):
                        self.completeHTMLExport(windowID: windowID, error: error)
                    }
                }
            case let .failure(error):
                self.completeHTMLExport(windowID: windowID, error: error)
            }
        }
    }

    nonisolated static func exportedWikiHref(for wikiHref: String, documentURL: URL?) -> String? {
        guard
            let url = URL(string: wikiHref),
            let destination = WikiLinkURL.destination(from: url)
        else {
            return nil
        }

        let targetPath = destination.fileURL.standardizedFileURL.path
        var href: String
        if let directoryPath = documentURL?.deletingLastPathComponent().standardizedFileURL.path {
            let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
            if targetPath.hasPrefix(prefix) {
                href = String(targetPath.dropFirst(prefix.count))
                    .split(separator: "/", omittingEmptySubsequences: false)
                    .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                    .joined(separator: "/")
            } else {
                href = destination.fileURL.absoluteString
            }
        } else {
            href = destination.fileURL.absoluteString
        }

        if let anchorID = destination.anchorID, !anchorID.isEmpty {
            let encoded = anchorID.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? anchorID
            href += "#" + encoded
        }
        return href
    }

    private func writeHTMLExport(
        domHTML: String,
        outputURL: URL,
        allowedRootDirectories: [URL],
        remoteAssets: [String: ExportImageAsset],
        windowID: ObjectIdentifier,
        cancellation: WorkCancellation
    ) {
        let htmlFileWriter = self.htmlFileWriter
        let htmlPreparationObserver = self.htmlPreparationObserver
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    let preparedExport = try Self.prepareHTMLExport(
                        domHTML: domHTML,
                        allowedRootDirectories: allowedRootDirectories,
                        remoteAssets: remoteAssets,
                        outputURL: outputURL
                    )
                    htmlPreparationObserver(preparedExport.ranOnMainThread)
                    guard !cancellation.isCancelled else { throw CancellationError() }
                    try htmlFileWriter(preparedExport.data, outputURL)
                    return Result<HTMLExportPreparationResult, Error>.success(preparedExport)
                } catch {
                    return Result<HTMLExportPreparationResult, Error>.failure(error)
                }
            }.value

            guard !cancellation.isCancelled else { return }
            switch result {
            case .success:
                self?.completeHTMLExport(windowID: windowID, error: nil)
            case let .failure(error):
                self?.completeHTMLExport(windowID: windowID, error: error)
            }
        }
    }

    nonisolated static func prepareHTMLExport(
        domHTML: String,
        allowedRootDirectories: [URL],
        remoteAssets: [String: ExportImageAsset],
        outputURL: URL
    ) throws -> HTMLExportPreparationResult {
        let inliner = ExportAssetInliner(
            allowedRootDirectories: allowedRootDirectories,
            remoteAssets: remoteAssets
        )
        let html = try ExportSanitizer.sanitize(
            domHTML: domHTML,
            policy: ExportSanitizer.ExportPolicy(
                inlineImage: { source in try inliner.inlineImage(source: source) },
                rewriteWikiLinkHref: { exportedWikiHref(for: $0, documentURL: outputURL) }
            )
        )
        return HTMLExportPreparationResult(
            data: Data(html.utf8),
            ranOnMainThread: Thread.isMainThread
        )
    }

    private func completeHTMLExport(windowID: ObjectIdentifier, error: Error?) {
        exportOperations.removeValue(forKey: windowID)?.cancel()
        activeHTMLExportWindows.remove(windowID)
        if let error {
            NSApp.presentError(error)
        }
    }
}

enum ExportError: LocalizedError {
    case pdfWriteFailed

    var errorDescription: String? {
        switch self {
        case .pdfWriteFailed:
            return "The PDF export could not be completed."
        }
    }
}

struct HTMLExportPreparationResult: Sendable {
    let data: Data
    let ranOnMainThread: Bool
}

@MainActor
private final class HTMLExportOperation {
    let cancellation = WorkCancellation()
    var remoteLoader: RemoteExportAssetLoader?
    nonisolated(unsafe) var windowObserver: NSObjectProtocol?

    deinit {
        cancellation.cancel()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    func cancel() {
        cancellation.cancel()
        remoteLoader?.cancel()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
    }
}
