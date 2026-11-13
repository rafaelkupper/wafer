import Foundation

/// Shared policy for document links in reader HTML, raw HTML, and exports.
public enum LinkURLPolicy {
    /// The only non-file schemes a document link may use.
    public static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    public static func allows(_ url: URL) -> Bool {
        url.isFileURL || url.scheme.map { externalSchemes.contains($0.lowercased()) } == true
    }

    public static func allows(_ destination: String) -> Bool {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        guard let url = URL(string: trimmed) else { return false }
        return url.scheme == nil || allows(url)
    }
}
