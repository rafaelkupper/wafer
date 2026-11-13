import Foundation
import WaferCore

enum ExportHTMLPreparationError: LocalizedError {
    case assetBudgetExceeded(maximumByteCount: Int)
    case contentNotReady
    case invalidDOMSnapshot

    var errorDescription: String? {
        switch self {
        case let .assetBudgetExceeded(maximumByteCount):
            return "The export contains more than \(maximumByteCount / 1024 / 1024) MB of inlined images."
        case .contentNotReady:
            return "The document is not ready to export yet."
        case .invalidDOMSnapshot:
            return "The document snapshot could not be created."
        }
    }
}

struct ExportImageAsset: Sendable {
    let data: Data
    let mimeType: String
}

final class ExportAssetInliner {
    static let defaultMaximumInlinedByteCount = 20 * 1024 * 1024

    private let allowedRootDirectories: [URL]
    private let remoteAssets: [String: ExportImageAsset]
    private let maximumInlinedByteCount: Int
    private let dataProvider: ((URL) throws -> Data)?
    private var inlinedByteCount = 0

    init(
        allowedRootDirectories: [URL],
        remoteAssets: [String: ExportImageAsset] = [:],
        maximumInlinedByteCount: Int = ExportAssetInliner.defaultMaximumInlinedByteCount,
        dataProvider: ((URL) throws -> Data)? = nil
    ) {
        self.allowedRootDirectories = allowedRootDirectories
        self.remoteAssets = remoteAssets
        self.maximumInlinedByteCount = maximumInlinedByteCount
        self.dataProvider = dataProvider
    }

    func inlineImage(source: String) throws -> String? {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "wafer-local":
            return try inlineLocalImage(from: url)
        case "wafer-remote":
            return try inlineRemoteImage(proxySource: source)
        case "https":
            return try inlineRemoteAsset(remoteAssets[source])
        default:
            return nil
        }
    }

    static func remoteImageURL(for source: String) -> URL? {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "https":
            return url
        case "wafer-remote":
            return remoteImageURL(from: url)
        default:
            return nil
        }
    }

    private func inlineLocalImage(from url: URL) throws -> String? {
        do {
            let asset = try LocalAssetLoader.load(
                from: url,
                allowedRootDirectories: allowedRootDirectories,
                dataProvider: { url in
                    if let dataProvider = self.dataProvider { return try dataProvider(url) }
                    return try BoundedFileReader.read(from: url,
                        maximumByteCount: self.maximumInlinedByteCount - self.inlinedByteCount)
                }
            )
            return try dataURI(data: asset.data, mimeType: asset.response.mimeType ?? "application/octet-stream")
        } catch BoundedFileReader.ReadError.tooLarge {
            throw ExportHTMLPreparationError.assetBudgetExceeded(maximumByteCount: maximumInlinedByteCount)
        } catch let error as ExportHTMLPreparationError {
            throw error
        } catch let error as ExportError {
            throw error
        } catch {
            return nil
        }
    }

    private func inlineRemoteImage(proxySource: String) throws -> String? {
        if let asset = remoteAssets[proxySource] {
            return try inlineRemoteAsset(asset)
        }

        guard let remoteURL = Self.remoteImageURL(for: proxySource) else {
            return nil
        }

        return try inlineRemoteAsset(remoteAssets[remoteURL.absoluteString])
    }

    private func inlineRemoteAsset(_ asset: ExportImageAsset?) throws -> String? {
        guard let asset else {
            return nil
        }

        return try dataURI(data: asset.data, mimeType: asset.mimeType)
    }

    private func dataURI(data: Data, mimeType: String) throws -> String {
        let nextByteCount = inlinedByteCount + data.count
        guard nextByteCount <= maximumInlinedByteCount else {
            throw ExportHTMLPreparationError.assetBudgetExceeded(maximumByteCount: maximumInlinedByteCount)
        }

        inlinedByteCount = nextByteCount
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private static func remoteImageURL(from proxyURL: URL) -> URL? {
        guard
            proxyURL.scheme == "wafer-remote",
            proxyURL.host == "image",
            let components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false),
            let rawURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
            let remoteURL = URL(string: rawURL),
            remoteURL.scheme?.lowercased() == "https"
        else {
            return nil
        }

        return remoteURL
    }
}
