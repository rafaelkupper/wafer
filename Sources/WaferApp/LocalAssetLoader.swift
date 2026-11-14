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
        maximumByteCount: Int = WaferLimits.assetByteCount,
        scope: FolderAccessScope = .unrestricted
    ) throws -> LocalAssetResponse {
        let fileURL = try fileURL(for: requestURL, allowedRootDirectories: allowedRootDirectories)
        let data = try read(fileURL, allowedRootDirectories: allowedRootDirectories, maximumByteCount: maximumByteCount, scope: scope)
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

    /// `scope` is what the App Sandbox lets Wafer read. A file outside it is
    /// refused with `FolderAccessDeniedError` before it is opened, so the
    /// sandbox never logs a violation for it. The path the descriptor really
    /// opened (`F_GETPATH`) is checked against the roots and the scope again.
    static func read(
        _ fileURL: URL, allowedRootDirectories: [URL], maximumByteCount: Int,
        scope: FolderAccessScope = .unrestricted, beforeOpening: () throws -> Void = {}
    ) throws -> Data {
        let roots = allowedRoots(allowedRootDirectories)
        let resolved = resolvedFileURL(forPath: fileURL.path)
        guard isAllowed(fileURL: resolved, in: roots) else { throw CocoaError(.fileReadNoPermission) }
        guard scope.covers(resolved) else { throw FolderAccessDeniedError(fileURL: resolved) }
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
        // A parent swapped for a symlink between the checks and the open can
        // land outside either set of roots; check what was actually opened.
        guard isAllowed(fileURL: openedURL, in: roots) else { throw CocoaError(.fileReadNoPermission) }
        guard scope.covers(openedURL) else { throw FolderAccessDeniedError(fileURL: openedURL) }
        guard info.st_size <= maximumByteCount else { throw BoundedFileReader.ReadError.tooLarge }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(maximumByteCount - data.count + 1, WaferLimits.fileReadChunkByteCount)), !chunk.isEmpty {
            guard chunk.count <= maximumByteCount - data.count else { throw BoundedFileReader.ReadError.tooLarge }
            data.append(chunk)
        }
        return data
    }

    private static func allowedRoots(_ directories: [URL]) -> [FileContainment] {
        directories.map { FileContainment(rootDirectory: $0) }
    }

    private static func isAllowed(fileURL: URL, in roots: [FileContainment]) -> Bool {
        let candidate = FileContainment.Candidate(fileURL)
        return roots.contains { $0.contains(candidate) }
    }

    private static func resolvedFileURL(forPath path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }
}
