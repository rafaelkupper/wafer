import Foundation

public enum LinkTarget: Equatable {
    case external(URL)
    case markdownFile(URL)
    case otherFile(URL)
    case unresolved(String)
}

public final class AssetResolver {
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    public init() {}

    public func resolve(destination: String, relativeTo baseURL: URL?) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let absoluteURL = URL(string: trimmed), absoluteURL.scheme != nil {
            return absoluteURL
        }

        if trimmed.hasPrefix("#"), let baseURL {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
            components?.fragment = String(trimmed.dropFirst()).removingPercentEncoding ?? String(trimmed.dropFirst())
            return components?.url
        }

        if let baseURL, !baseURL.isFileURL, !trimmed.hasPrefix("/") {
            return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        }

        guard let destination = URLComponents(string: trimmed) else { return nil }
        let directoryURL = baseURL.map { $0.hasDirectoryPath ? $0 : $0.deletingLastPathComponent() }
        var resolvedURL = URL(fileURLWithPath: destination.path, relativeTo: directoryURL).standardizedFileURL
        if let fragment = destination.fragment {
            var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: true)
            components?.fragment = fragment
            resolvedURL = components?.url ?? resolvedURL
        }

        return resolvedURL
    }

    public func imageURL(for source: String, relativeTo baseURL: URL?) -> URL? {
        guard let resolved = resolve(destination: source, relativeTo: baseURL) else {
            return nil
        }

        if resolved.isFileURL || isRemoteImageURL(resolved) {
            return resolved
        }

        return nil
    }

    public func isRemoteImageURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    public func linkTarget(for destination: String, relativeTo baseURL: URL?) -> LinkTarget {
        guard let resolved = resolve(destination: destination, relativeTo: baseURL) else {
            return .unresolved(destination)
        }

        return classify(resolved)
    }

    public func classify(_ url: URL) -> LinkTarget {
        if let scheme = url.scheme?.lowercased(), LinkURLPolicy.externalSchemes.contains(scheme) {
            return .external(url)
        }

        if url.isFileURL, Self.markdownExtensions.contains(url.pathExtension.lowercased()) {
            return .markdownFile(url.standardizedFileURLPreservingFragment())
        }

        if url.isFileURL {
            return .otherFile(url.standardizedFileURLPreservingFragment())
        }

        return .unresolved(url.absoluteString)
    }
}
