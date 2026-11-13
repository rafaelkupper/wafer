import Foundation

public enum FileIdentity {
    public static func normalized(_ url: URL) -> URL {
        guard url.isFileURL else {
            return url
        }

        return URL(fileURLWithPath: url.standardizedFileURL.path)
    }

    public static func identity(for url: URL) -> String {
        normalized(url).path
    }
}
