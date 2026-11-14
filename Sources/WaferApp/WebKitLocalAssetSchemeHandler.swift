import Foundation
import WebKit
import WaferCore

@MainActor
final class WebKitLocalAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Set for every page the reader loads. Once this handler has served
    /// its web view, each new page posts `.localAssetPageWillLoad`, so the
    /// window can drop refused images the new page no longer shows.
    var documentRootDirectory: URL? {
        didSet {
            guard let servedWebView else { return }
            NotificationCenter.default.post(name: .localAssetPageWillLoad, object: servedWebView)
        }
    }
    /// The web view whose requests this handler serves.
    private weak var servedWebView: WKWebView?

    private let coreResourceRootDirectory = ReaderTheme.resourceURL(named: "mermaid.min.js")?.deletingLastPathComponent()
    // Shared across reader windows, including bundled renderer/font requests.
    private static let readQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.wafer.local-assets"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    #if DEBUG
    static var readConcurrencyForTesting: Int { readQueue.maxConcurrentOperationCount }
    #endif
    static let maximumByteCount = WaferLimits.assetByteCount
    private let queue: OperationQueue
    private let byteLimit: Int
    private let accessScope: @MainActor () -> FolderAccessScope
    private var activeTasks: [ObjectIdentifier: Operation] = [:]

    /// `accessScope` is what the App Sandbox lets Wafer read; a request outside
    /// it fails at once and posts `.localAssetAccessDenied` for the web view,
    /// so its window can offer a folder grant.
    init(queue: OperationQueue = WebKitLocalAssetSchemeHandler.readQueue,
         maximumByteCount: Int = WebKitLocalAssetSchemeHandler.maximumByteCount,
         accessScope: @escaping @MainActor () -> FolderAccessScope = { FolderAccessStore.shared.scope }) {
        self.queue = queue
        self.byteLimit = maximumByteCount
        self.accessScope = accessScope
        super.init()
    }

    deinit {
        for operation in activeTasks.values { operation.cancel() }
    }

    var allowedRootDirectories: [URL] {
        [documentRootDirectory, coreResourceRootDirectory].compactMap { $0 }
    }

    nonisolated func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskBox = LocalAssetSchemeTaskBox(task: urlSchemeTask)
        MainActor.assumeIsolated {
            start(taskBox, webView: webView)
        }
    }

    nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskBox = LocalAssetSchemeTaskBox(task: urlSchemeTask)
        MainActor.assumeIsolated {
            activeTasks.removeValue(forKey: taskBox.identifier)?.cancel()
        }
    }

    private func start(_ taskBox: LocalAssetSchemeTaskBox, webView: WKWebView) {
        let urlSchemeTask = taskBox.task
        let taskID = taskBox.identifier
        servedWebView = webView

        do {
            guard let url = urlSchemeTask.request.url else {
                throw NSError(
                    domain: "WebKitLocalAssetSchemeHandler",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing local asset URL."]
                )
            }
            let fileURL = try LocalAssetLoader.fileURL(for: url, allowedRootDirectories: allowedRootDirectories)
            let scope = accessScope()
            guard scope.covers(fileURL) else {
                reportAccessDenied(to: fileURL, from: webView)
                throw FolderAccessDeniedError(fileURL: fileURL)
            }
            let mimeType = LocalAssetLoader.mimeType(for: fileURL)
            let completionBox = LocalAssetCompletionBox { [weak self, weak webView] result in
                if case .failure(let error as FolderAccessDeniedError) = result, let webView {
                    self?.reportAccessDenied(to: error.fileURL, from: webView)
                }
                self?.complete(
                    taskBox: taskBox,
                    taskID: taskID,
                    requestURL: url,
                    mimeType: mimeType,
                    result: result
                )
            }

            let operation = LocalAssetReadOperation(fileURL: fileURL, allowedRootDirectories: allowedRootDirectories, maximumByteCount: byteLimit,
                                                    scope: scope, completionBox: completionBox)
            activeTasks[taskID] = operation
            queue.addOperation(operation)
        } catch {
            fail(urlSchemeTask, taskID: taskID, error: error)
        }
    }

    private func complete(
        taskBox: LocalAssetSchemeTaskBox,
        taskID: ObjectIdentifier,
        requestURL: URL,
        mimeType: String,
        result: Result<Data, Error>
    ) {
        guard activeTasks.removeValue(forKey: taskID) != nil else {
            return
        }

        switch result {
        case let .success(data):
            WaferLog.rendering.debug("Served a local asset (\(mimeType, privacy: .public), \(data.count, privacy: .public) bytes)")
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            taskBox.task.didReceive(response)
            taskBox.task.didReceive(data)
            taskBox.task.didFinish()
        case let .failure(error):
            taskBox.task.didFailWithError(error)
        }
    }

    private func fail(_ urlSchemeTask: any WKURLSchemeTask, taskID: ObjectIdentifier, error: Error) {
        activeTasks.removeValue(forKey: taskID)
        urlSchemeTask.didFailWithError(error)
    }

    private func reportAccessDenied(to fileURL: URL, from webView: WKWebView) {
        NotificationCenter.default.post(name: .localAssetAccessDenied, object: webView, userInfo: ["fileURL": fileURL])
    }
}

// WebKit calls and all uses of the task stay on the main actor.
private final class LocalAssetSchemeTaskBox: @unchecked Sendable {
    let task: any WKURLSchemeTask
    let identifier: ObjectIdentifier

    init(task: any WKURLSchemeTask) {
        self.task = task
        self.identifier = ObjectIdentifier(task)
    }
}

private final class LocalAssetCompletionBox: Sendable {
    let completion: @MainActor (Result<Data, Error>) -> Void

    init(completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        self.completion = completion
    }
}

// Inputs are immutable; Operation owns synchronized cancellation state.
private final class LocalAssetReadOperation: Operation, @unchecked Sendable {
    private let fileURL: URL
    private let allowedRootDirectories: [URL]
    private let maximumByteCount: Int
    private let scope: FolderAccessScope
    private let completionBox: LocalAssetCompletionBox

    init(fileURL: URL, allowedRootDirectories: [URL], maximumByteCount: Int, scope: FolderAccessScope,
         completionBox: LocalAssetCompletionBox) {
        self.fileURL = fileURL
        self.allowedRootDirectories = allowedRootDirectories
        self.maximumByteCount = maximumByteCount
        self.scope = scope
        self.completionBox = completionBox
    }

    override func main() {
        guard !isCancelled else { return }
        let result = Result {
            try LocalAssetLoader.read(fileURL, allowedRootDirectories: allowedRootDirectories, maximumByteCount: maximumByteCount, scope: scope)
        }
        guard !isCancelled else { return }
        DispatchQueue.main.async { [completionBox] in
            completionBox.completion(result)
        }
    }
}
