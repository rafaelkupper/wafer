import Foundation
import UniformTypeIdentifiers

struct LocalAssetResponse {
    let response: URLResponse
    let data: Data
}

enum LocalAssetLoader {
    static func load(
        from requestURL: URL,
        allowedRootDirectories: [URL],
        dataProvider: (URL) throws -> Data
    ) throws -> LocalAssetResponse {
        let fileURL = try fileURL(for: requestURL, allowedRootDirectories: allowedRootDirectories)
        let data = try dataProvider(fileURL)
        let response = URLResponse(
            url: requestURL,
            mimeType: mimeType(for: fileURL),
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        return LocalAssetResponse(response: response, data: data)
    }

    static func fileURL(for requestURL: URL, allowedRootDirectories: [URL]) throws -> URL {
        guard
            let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
            components.host == "asset",
            let filePath = components.queryItems?.first(where: { $0.name == "path" })?.value
        else {
            throw NSError(
                domain: "LocalAssetLoader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid local asset URL."]
            )
        }

        let fileURL = resolvedFileURL(forPath: filePath)
        guard isAllowed(fileURL: fileURL, in: allowedRootDirectories) else {
            throw NSError(
                domain: "LocalAssetLoader",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Local asset path is outside allowed roots: \(fileURL.path)"]
            )
        }

        return fileURL
    }

    static func mimeType(for fileURL: URL) -> String {
        let fileExtension = fileURL.pathExtension
        if
            let type = UTType(filenameExtension: fileExtension),
            let mimeType = type.preferredMIMEType
        {
            return mimeType
        }

        return "application/octet-stream"
    }

    private static func isAllowed(fileURL: URL, in rootDirectories: [URL]) -> Bool {
        let filePath = fileURL.path

        return rootDirectories.contains { rootDirectory in
            let rootPath = resolvedFileURL(forPath: rootDirectory.path).path
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return filePath == rootPath || filePath.hasPrefix(rootPrefix)
        }
    }

    private static func resolvedFileURL(forPath path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }
}
