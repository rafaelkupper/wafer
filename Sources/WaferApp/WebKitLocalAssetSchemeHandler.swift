import Foundation
import WebKit
import WaferCore

@MainActor
final class WebKitLocalAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    var documentRootDirectory: URL?

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
    static let maximumByteCount = 25 * 1024 * 1024
    private let queue: OperationQueue
    private let byteLimit: Int
    private var activeTasks: [ObjectIdentifier: Operation] = [:]

    init(queue: OperationQueue = WebKitLocalAssetSchemeHandler.readQueue,
         maximumByteCount: Int = WebKitLocalAssetSchemeHandler.maximumByteCount) {
        self.queue = queue
        self.byteLimit = maximumByteCount
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
            start(taskBox)
        }
    }

    nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskBox = LocalAssetSchemeTaskBox(task: urlSchemeTask)
        MainActor.assumeIsolated {
            activeTasks.removeValue(forKey: taskBox.identifier)?.cancel()
        }
    }

    private func start(_ taskBox: LocalAssetSchemeTaskBox) {
        let urlSchemeTask = taskBox.task
        let taskID = taskBox.identifier

        do {
            guard let url = urlSchemeTask.request.url else {
                throw NSError(
                    domain: "WebKitLocalAssetSchemeHandler",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing local asset URL."]
                )
            }
            let fileURL = try LocalAssetLoader.fileURL(for: url, allowedRootDirectories: allowedRootDirectories)
            let mimeType = LocalAssetLoader.mimeType(for: fileURL)
            let completionBox = LocalAssetCompletionBox { [weak self] result in
                self?.complete(
                    taskBox: taskBox,
                    taskID: taskID,
                    requestURL: url,
                    mimeType: mimeType,
                    result: result
                )
            }

            let operation = LocalAssetReadOperation(fileURL: fileURL, allowedRootDirectories: allowedRootDirectories, maximumByteCount: byteLimit,
                                                    completionBox: completionBox)
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
    private let completionBox: LocalAssetCompletionBox

    init(fileURL: URL, allowedRootDirectories: [URL], maximumByteCount: Int, completionBox: LocalAssetCompletionBox) {
        self.fileURL = fileURL
        self.allowedRootDirectories = allowedRootDirectories
        self.maximumByteCount = maximumByteCount
        self.completionBox = completionBox
    }

    override func main() {
        guard !isCancelled else { return }
        let result = Result { try LocalAssetLoader.read(fileURL, allowedRootDirectories: allowedRootDirectories, maximumByteCount: maximumByteCount) }
        guard !isCancelled else { return }
        DispatchQueue.main.async { [completionBox] in
            completionBox.completion(result)
        }
    }
}
