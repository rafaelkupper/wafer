import Darwin
import Foundation
import WaferCore
import UniformTypeIdentifiers

struct LocalAssetResponse: Sendable {
    let response: URLResponse
    let data: Data
}

enum LocalAssetLoader {
    static func load(
        from requestURL: URL,
        allowedRootDirectories: [URL],
        maximumByteCount: Int = 25 * 1024 * 1024
    ) throws -> LocalAssetResponse {
        let fileURL = try fileURL(for: requestURL, allowedRootDirectories: allowedRootDirectories)
        let data = try read(fileURL, allowedRootDirectories: allowedRootDirectories, maximumByteCount: maximumByteCount)
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
        guard isAllowed(fileURL: fileURL, in: allowedRoots(allowedRootDirectories)) else {
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

    static func read(
        _ fileURL: URL, allowedRootDirectories: [URL], maximumByteCount: Int,
        beforeOpening: () throws -> Void = {}
    ) throws -> Data {
        let roots = allowedRoots(allowedRootDirectories)
        let resolved = resolvedFileURL(forPath: fileURL.path)
        guard isAllowed(fileURL: resolved, in: roots) else { throw CocoaError(.fileReadNoPermission) }
        // The hook lets tests swap a parent directory at the check/open boundary.
        try beforeOpening()
        let descriptor = open(resolved.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnknown)
        }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { throw CocoaError(.fileReadUnknown) }
        let pathBytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let openedURL = URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self)).standardizedFileURL
        guard isAllowed(fileURL: openedURL, in: roots) else { throw CocoaError(.fileReadNoPermission) }
        guard info.st_size <= maximumByteCount else { throw BoundedFileReader.ReadError.tooLarge }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(maximumByteCount - data.count + 1, 64 * 1024)), !chunk.isEmpty {
            guard chunk.count <= maximumByteCount - data.count else { throw BoundedFileReader.ReadError.tooLarge }
            data.append(chunk)
        }
        return data
    }

    private static func allowedRoots(_ directories: [URL]) -> [(url: URL, caseSensitive: Bool)] {
        directories.map { directory in
            let root = resolvedFileURL(forPath: directory.path)
            let caseSensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
                .volumeSupportsCaseSensitiveNames ?? true
            return (root, caseSensitive)
        }
    }

    private static func isAllowed(fileURL: URL, in roots: [(url: URL, caseSensitive: Bool)]) -> Bool {
        roots.contains { contains(fileURL, in: $0.url, caseSensitive: $0.caseSensitive) }
    }

    static func contains(_ file: URL, in root: URL, caseSensitive: Bool) -> Bool {
        let fileParts = file.standardizedFileURL.pathComponents
        let rootParts = root.standardizedFileURL.pathComponents
        guard fileParts.count >= rootParts.count else { return false }
        return zip(fileParts, rootParts).allSatisfy { filePart, rootPart in
            caseSensitive ? filePart == rootPart
                : filePart.compare(rootPart, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
        }
    }

    private static func resolvedFileURL(forPath path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }
}
