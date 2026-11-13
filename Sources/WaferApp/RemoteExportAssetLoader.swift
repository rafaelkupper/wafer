import Foundation

/// Export images are fetched one at a time using the remaining aggregate budget.
@MainActor
final class RemoteExportAssetLoader {
    private let fetcher: RemoteImageFetching
    private let sources: [String]
    private let maximumByteCount: Int
    private var remainingBytes: Int
    private var index = 0
    private var assets: [String: ExportImageAsset] = [:]
    private var request: RemoteImageFetchCancellable?
    private var completion: ((Result<[String: ExportImageAsset], Error>) -> Void)?

    init(fetcher: RemoteImageFetching, sources: [String],
         maximumByteCount: Int = ExportAssetInliner.defaultMaximumInlinedByteCount) {
        self.fetcher = fetcher
        self.sources = sources
        self.maximumByteCount = maximumByteCount
        self.remainingBytes = maximumByteCount
    }

    func start(completion: @escaping (Result<[String: ExportImageAsset], Error>) -> Void) {
        self.completion = completion
        fetchNext()
    }

    func cancel() {
        completion = nil
        request?.cancel()
        request = nil
        assets.removeAll()
    }

    private func finish(_ result: Result<[String: ExportImageAsset], Error>) {
        let callback = completion
        completion = nil
        request = nil
        assets.removeAll()
        callback?(result)
    }

    private func fetchNext() {
        guard completion != nil else { return }
        while index < sources.count {
            let source = sources[index]
            index += 1
            guard let url = ExportAssetInliner.remoteImageURL(for: source) else { continue }
            guard remainingBytes > 0 else {
                finish(.failure(ExportHTMLPreparationError.assetBudgetExceeded(maximumByteCount: maximumByteCount)))
                return
            }
            var urlRequest = URLRequest(url: url)
            urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            urlRequest.timeoutInterval = 10
            urlRequest.httpShouldHandleCookies = false
            urlRequest.setValue("Wafer HTMLExporter", forHTTPHeaderField: "User-Agent")
            request = fetcher.fetch(urlRequest, maximumByteCount: remainingBytes) { [weak self] result in
                // Also handles fetchers that complete synchronously without recursive growth.
                DispatchQueue.main.async { [weak self] in self?.received(result, source: source) }
            }
            return
        }
        finish(.success(assets))
    }

    private func received(_ result: Result<RemoteImageResponse, Error>, source: String) {
        guard completion != nil else { return }
        request = nil
        switch result {
        case .success(let response):
            guard response.data.count <= remainingBytes else {
                finish(.failure(ExportHTMLPreparationError.assetBudgetExceeded(maximumByteCount: maximumByteCount)))
                return
            }
            remainingBytes -= response.data.count
            assets[source] = ExportImageAsset(data: response.data, mimeType: response.response.mimeType ?? "application/octet-stream")
        case .failure(RemoteImageError.responseTooLarge):
            finish(.failure(ExportHTMLPreparationError.assetBudgetExceeded(maximumByteCount: maximumByteCount)))
            return
        case .failure:
            break // Unavailable images retain the established omitted-image behavior.
        }
        fetchNext()
    }
}
