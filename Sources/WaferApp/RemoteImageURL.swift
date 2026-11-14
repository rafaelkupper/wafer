import Foundation

enum RemoteImageURL {
    static func parse(_ proxyURL: URL?) throws -> URL {
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
