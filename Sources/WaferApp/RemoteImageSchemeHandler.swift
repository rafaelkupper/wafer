import Foundation
import WebKit

struct RemoteImageResponse: @unchecked Sendable {
    let response: URLResponse
    let data: Data
}

protocol RemoteImageFetchCancellable: AnyObject {
    func cancel()
}

protocol RemoteImageFetching: AnyObject {
    @MainActor
    func fetch(
        _ request: URLRequest,
        completion: @escaping @MainActor (Result<RemoteImageResponse, Error>) -> Void
    ) -> RemoteImageFetchCancellable
    @MainActor
    func fetch(_ request: URLRequest, maximumByteCount: Int,
        completion: @escaping @MainActor (Result<RemoteImageResponse, Error>) -> Void) -> RemoteImageFetchCancellable

}

extension RemoteImageFetching {
    @MainActor
    func fetch(_ request: URLRequest, maximumByteCount: Int,
        completion: @escaping @MainActor (Result<RemoteImageResponse, Error>) -> Void) -> RemoteImageFetchCancellable {
        fetch(request) { result in
            if case .success(let response) = result, response.data.count > maximumByteCount {
                completion(.failure(RemoteImageError.responseTooLarge))
            } else { completion(result) }
        }
    }
}

@MainActor
final class RemoteImageSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let defaultMaximumByteCount = 25 * 1024 * 1024

    var remoteImagesEnabled: Bool {
        get {
            preferenceStore.loadsRemoteImages
        }
        set {
            preferenceStore.loadsRemoteImages = newValue
        }
    }

    private let fetcher: RemoteImageFetching
    private let maximumByteCount: Int
    private let preferenceStore: ReaderBehaviorPreferenceStore
    private var activeTasks: [ObjectIdentifier: RemoteImageFetchCancellable] = [:]

    init(
        fetcher: RemoteImageFetching = RemoteImageURLSessionFetcher(),
        maximumByteCount: Int = RemoteImageSchemeHandler.defaultMaximumByteCount,
        preferenceStore: ReaderBehaviorPreferenceStore = .shared
    ) {
        self.fetcher = fetcher
        self.maximumByteCount = maximumByteCount
        self.preferenceStore = preferenceStore
        super.init()
    }

    nonisolated func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskBox = RemoteImageSchemeTaskBox(task: urlSchemeTask)
        MainActor.assumeIsolated {
            start(taskBox)
        }
    }

    nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskBox = RemoteImageSchemeTaskBox(task: urlSchemeTask)
        MainActor.assumeIsolated {
            activeTasks.removeValue(forKey: taskBox.identifier)?.cancel()
        }
    }

    private func start(_ taskBox: RemoteImageSchemeTaskBox) {
        do {
            guard remoteImagesEnabled else {
                throw RemoteImageError.disabled
            }

            let remoteURL = try Self.remoteImageURL(from: taskBox.task.request.url)
            var request = URLRequest(url: remoteURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 15
            request.httpShouldHandleCookies = false
            request.setValue(Self.userAgent(), forHTTPHeaderField: "User-Agent")

            let taskID = taskBox.identifier
            let token = fetcher.fetch(request) { [weak self] result in
                self?.complete(taskBox: taskBox, taskID: taskID, result: result)
            }
            activeTasks[taskID] = token
        } catch {
            taskBox.task.didFailWithError(error)
        }
    }

    private func complete(
        taskBox: RemoteImageSchemeTaskBox,
        taskID: ObjectIdentifier,
        result: Result<RemoteImageResponse, Error>
    ) {
        guard activeTasks.removeValue(forKey: taskID) != nil else {
            return
        }

        switch result {
        case let .success(remoteResponse):
            do {
                try validate(remoteResponse)
                let requestURL = taskBox.task.request.url ?? remoteResponse.response.url
                let response = URLResponse(
                    url: requestURL ?? URL(string: "wafer-remote://image")!,
                    mimeType: remoteResponse.response.mimeType,
                    expectedContentLength: remoteResponse.data.count,
                    textEncodingName: nil
                )
                taskBox.task.didReceive(response)
                taskBox.task.didReceive(remoteResponse.data)
                taskBox.task.didFinish()
            } catch {
                taskBox.task.didFailWithError(error)
            }
        case let .failure(error):
            taskBox.task.didFailWithError(error)
        }
    }

    private func validate(_ response: RemoteImageResponse) throws {
        let mimeType = response.response.mimeType?.lowercased() ?? ""
        guard mimeType.hasPrefix("image/") else {
            throw RemoteImageError.unsupportedMimeType(mimeType)
        }

        if response.response.expectedContentLength > Int64(maximumByteCount) {
            throw RemoteImageError.responseTooLarge
        }

        guard response.data.count <= maximumByteCount else {
            throw RemoteImageError.responseTooLarge
        }
    }

    static func userAgent(bundle: Bundle = .main) -> String {
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Wafer/\(version.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown") RemoteImageLoader"
    }

    static func remoteImageURL(from proxyURL: URL?) throws -> URL {
        guard
            let proxyURL,
            proxyURL.scheme == "wafer-remote",
            proxyURL.host == "image",
            let components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false),
            let rawURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
            let remoteURL = URL(string: rawURL),
            remoteURL.scheme?.lowercased() == "https"
        else {
            throw RemoteImageError.invalidURL
        }

        return remoteURL
    }
}

enum RemoteImageError: LocalizedError {
    case disabled
    case invalidURL
    case unsupportedMimeType(String)
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Remote image loading is disabled."
        case .invalidURL:
            return "Invalid remote image URL."
        case let .unsupportedMimeType(mimeType):
            return "Unsupported remote image MIME type: \(mimeType)."
        case .responseTooLarge:
            return "Remote image exceeds the maximum allowed size."
        }
    }
}

final class RemoteImageURLSessionFetcher: NSObject, RemoteImageFetching, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let delegate: RemoteImageSessionDelegate
    // Accessed only by fetch on the main actor and during teardown.
    private var session: URLSession?

    init(
        maximumByteCount: Int = RemoteImageSchemeHandler.defaultMaximumByteCount,
        configuration: URLSessionConfiguration = RemoteImageURLSessionFetcher.ephemeralConfiguration()
    ) {
        self.configuration = configuration
        self.delegate = RemoteImageSessionDelegate(maximumByteCount: maximumByteCount)
        super.init()
    }

    deinit { session?.invalidateAndCancel() }

    @MainActor
    func fetch(
        _ request: URLRequest,
        completion: @escaping @MainActor (Result<RemoteImageResponse, Error>) -> Void
    ) -> RemoteImageFetchCancellable {
        fetch(request, maximumByteCount: delegate.maximumByteCount, completion: completion)
    }

    @MainActor
    func fetch(_ request: URLRequest, maximumByteCount: Int,
        completion: @escaping @MainActor (Result<RemoteImageResponse, Error>) -> Void) -> RemoteImageFetchCancellable {
        let session = self.session ?? URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        delegate.register(task: task, maximumByteCount: maximumByteCount, completion: completion)
        task.resume()
        return RemoteImageURLSessionToken(task: task)
    }

    static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }

}

/// The session owns this delegate, which never owns the fetcher or session.
private final class RemoteImageSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maximumByteCount: Int
    private let lock = NSLock()
    private var states: [Int: RemoteImageURLSessionState] = [:]

    init(maximumByteCount: Int) { self.maximumByteCount = maximumByteCount }

    func register(task: URLSessionTask, maximumByteCount: Int, completion: @escaping @MainActor (Result<RemoteImageResponse, Error>) -> Void) {
        lock.withLock { states[task.taskIdentifier] = RemoteImageURLSessionState(maximumByteCount: min(self.maximumByteCount, max(0, maximumByteCount)), completion: completion) }
    }

    private func complete(task: URLSessionTask, result: Result<RemoteImageResponse, Error>) {
        let state = lock.withLock {
            states.removeValue(forKey: task.taskIdentifier)
        }
        guard let state else {
            return
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                state.completion(result)
            }
        }
    }

    private func fail(task: URLSessionTask, error: Error) {
        task.cancel()
        complete(task: task, result: .failure(error))
    }
}

extension RemoteImageSessionDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let mimeType = response.mimeType?.lowercased() ?? ""
        guard mimeType.hasPrefix("image/") else {
            completionHandler(.cancel)
            fail(task: dataTask, error: RemoteImageError.unsupportedMimeType(mimeType))
            return
        }

        let byteLimit = lock.withLock { states[dataTask.taskIdentifier]?.maximumByteCount ?? 0 }
        if response.expectedContentLength > Int64(byteLimit) {
            completionHandler(.cancel)
            fail(task: dataTask, error: RemoteImageError.responseTooLarge)
            return
        }

        lock.withLock {
            states[dataTask.taskIdentifier]?.response = response
        }
        completionHandler(.allow)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let didExceedLimit = lock.withLock {
            guard let state = states[dataTask.taskIdentifier] else {
                return false
            }

            guard data.count <= state.maximumByteCount - state.data.count else { return true }
            state.data.append(data)
            return false
        }

        if didExceedLimit {
            fail(task: dataTask, error: RemoteImageError.responseTooLarge)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            fail(task: task, error: RemoteImageError.invalidURL)
            return
        }

        completionHandler(request)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            complete(task: task, result: .failure(error))
            return
        }

        let snapshot = lock.withLock {
            states[task.taskIdentifier].map { ($0.response, $0.data) }
        }
        guard let snapshot, let response = snapshot.0 else {
            complete(task: task, result: .failure(RemoteImageError.invalidURL))
            return
        }

        complete(
            task: task,
            result: .success(RemoteImageResponse(response: response, data: snapshot.1))
        )
    }
}

private final class RemoteImageURLSessionState: @unchecked Sendable {
    let completion: @MainActor (Result<RemoteImageResponse, Error>) -> Void
    let maximumByteCount: Int
    var response: URLResponse?
    var data = Data()

    init(maximumByteCount: Int, completion: @escaping @MainActor (Result<RemoteImageResponse, Error>) -> Void) {
        self.maximumByteCount = maximumByteCount
        self.completion = completion
    }
}

private final class RemoteImageURLSessionToken: RemoteImageFetchCancellable {
    private let task: URLSessionTask

    init(task: URLSessionTask) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

private final class RemoteImageSchemeTaskBox: @unchecked Sendable {
    let task: any WKURLSchemeTask
    let identifier: ObjectIdentifier

    init(task: any WKURLSchemeTask) {
        self.task = task
        self.identifier = ObjectIdentifier(task)
    }
}
