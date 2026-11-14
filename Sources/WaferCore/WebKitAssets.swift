import Foundation

enum WebKitAssetURLs {
    static func local(for fileURL: URL) -> String {
        var components = URLComponents()
        components.scheme = "wafer-local"
        components.host = "asset"
        components.queryItems = [
            URLQueryItem(name: "path", value: fileURL.standardizedFileURL.path),
        ]
        return components.url?.absoluteString ?? fileURL.absoluteString
    }

    static func remote(for remoteURL: URL) -> String {
        var components = URLComponents()
        components.scheme = "wafer-remote"
        components.host = "image"
        components.queryItems = [
            URLQueryItem(name: "url", value: remoteURL.absoluteString),
        ]
        return components.url?.absoluteString ?? remoteURL.absoluteString
    }
}

final class PreviewAttachmentStore {
    private(set) var attachments: [String: URL] = [:]

    func cidSource(for fileURL: URL, allowedRootDirectory: URL?) -> String? {
        guard
            fileURL.isFileURL,
            let allowedRootDirectory,
            allowedRootDirectory.isFileURL
        else {
            return nil
        }

        let resolvedFileURL = URL(fileURLWithPath: fileURL.path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedRootURL = URL(fileURLWithPath: allowedRootDirectory.path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false

        guard
            Self.isAllowed(fileURL: resolvedFileURL, in: resolvedRootURL),
            FileManager.default.fileExists(atPath: resolvedFileURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return nil
        }

        if let existing = attachments.first(where: { $0.value == resolvedFileURL }) {
            return "cid:\(existing.key)"
        }

        let key = "preview-asset-\(attachments.count + 1)"
        attachments[key] = resolvedFileURL
        return "cid:\(key)"
    }

    private static func isAllowed(fileURL: URL, in rootDirectory: URL) -> Bool {
        let filePath = fileURL.path
        let rootPath = rootDirectory.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath == rootPath || filePath.hasPrefix(rootPrefix)
    }
}
