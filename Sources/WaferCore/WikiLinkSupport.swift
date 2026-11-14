import Foundation

/// Immutable snapshot resolving wiki-link targets to library files. Built by
/// the app once per library snapshot and passed into
/// the renderer like the palette (Sendable value; the renderer never touches
/// live library state).
public struct WikiLinkIndex: Equatable, Sendable {
    private let targetsByKey: [String: URL]
    private let targetsByPath: [String: URL]

    public init(entries: [(fileURL: URL, displayTitle: String)]) {
        self.init(entries: entries, paths: [])
    }

    public init(files: [LibraryFile]) {
        self.init(entries: files.map { ($0.fileURL, $0.displayTitle) },
            paths: files.map { ($0.relativePath, $0.fileURL) })
    }

    private init(entries: [(fileURL: URL, displayTitle: String)], paths: [(String, URL)]) {
        var candidatesByKey: [String: [URL]] = [:]
        for entry in entries {
            let nameKey = Self.fold(entry.fileURL.deletingPathExtension().lastPathComponent)
            let titleKey = Self.fold(entry.displayTitle)
            for key in Set([nameKey, titleKey]) where !key.isEmpty {
                candidatesByKey[key, default: []].append(entry.fileURL)
            }
        }

        targetsByKey = candidatesByKey.mapValues { candidates in
            // Ambiguity resolves to the shortest path, ties lexicographically.
            candidates.min { lhs, rhs in
                if lhs.path.count != rhs.path.count {
                    return lhs.path.count < rhs.path.count
                }
                return lhs.path < rhs.path
            }!
        }

        var pathCandidates: [String: [URL]] = [:]
        for (path, url) in paths {
            let fullPath = Self.fold(path)
            pathCandidates[fullPath, default: []].append(url)
            // Bare names retain filename/title ambiguity rules. Only paths with
            // a directory get an extensionless path alias.
            if path.contains("/") {
                let stem = Self.fold((path as NSString).deletingPathExtension)
                pathCandidates[stem, default: []].append(url)
            }
        }
        targetsByPath = pathCandidates.mapValues { $0.min { $0.path < $1.path }! }
    }

    public var isEmpty: Bool {
        targetsByKey.isEmpty
    }

    public func resolve(_ target: String) -> URL? {
        let key = Self.fold(target)
        return targetsByPath[key] ?? targetsByKey[key]
    }

    public static func fold(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The in-app href scheme for resolved wiki links. Clicking one navigates in
/// the CURRENT tab (pushing history) instead of the window-per-file behavior
/// regular markdown links keep. Exports rewrite these to relative hrefs.
public enum WikiLinkURL {
    public static let scheme = "wafer-wiki"

    public static func url(for fileURL: URL, anchorID: String?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        var queryItems = [URLQueryItem(name: "path", value: fileURL.standardizedFileURL.path)]
        if let anchorID, !anchorID.isEmpty {
            queryItems.append(URLQueryItem(name: "anchor", value: anchorID))
        }
        components.queryItems = queryItems
        return components.url
    }

    public static func destination(from url: URL) -> (fileURL: URL, anchorID: String?)? {
        guard
            url.scheme?.lowercased() == scheme,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
            !path.isEmpty
        else {
            return nil
        }

        let anchorID = components.queryItems?.first(where: { $0.name == "anchor" })?.value
        return (URL(fileURLWithPath: path), anchorID)
    }
}

/// Source-level wiki-link span scanning for one Text node.
public enum WikiLinkSyntax {
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "bmp", "tiff", "tif",
    ]

    public struct Span: Equatable {
        public let range: Range<String.Index>
        public let isEmbed: Bool
        public let target: String
        public let heading: String?
        public let alias: String?

        public var displayText: String {
            if let alias, !alias.isEmpty {
                return alias
            }
            if let heading, !heading.isEmpty {
                return target.isEmpty ? heading : "\(target) › \(heading)"
            }
            return target
        }

        public var targetIsImage: Bool {
            let ext = (target as NSString).pathExtension.lowercased()
            return WikiLinkSyntax.imageExtensions.contains(ext)
        }
    }

    /// Finds `[[target#heading|alias]]` / `![[...]]` spans. Nested brackets
    /// are not supported; unterminated spans stay literal text.
    public static func spans(in text: String) -> [Span] {
        var spans: [Span] = []
        var cursor = text.startIndex
        var opener: String.Index?
        var contentStart = text.startIndex

        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            if text[cursor] == "[" {
                opener = nil
                if next < text.endIndex, text[next] == "[" {
                    opener = cursor
                    contentStart = text.index(after: next)
                    cursor = contentStart
                } else {
                    cursor = next
                }
                continue
            }
            guard text[cursor] == "]", next < text.endIndex, text[next] == "]", let start = opener else {
                cursor = next
                continue
            }
            let inner = text[contentStart..<cursor]
            let end = text.index(after: next)
            opener = nil
            cursor = end
            guard !inner.isEmpty else { continue }

            var spanStart = start
            var isEmbed = false
            if spanStart > text.startIndex {
                let previousIndex = text.index(before: spanStart)
                if text[previousIndex] == "!" {
                    isEmbed = true
                    spanStart = previousIndex
                }
            }

            let aliasParts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let targetPart = String(aliasParts[0])
            let alias = aliasParts.count > 1 ? String(aliasParts[1]).trimmingCharacters(in: .whitespaces) : nil

            let headingParts = targetPart.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let target = String(headingParts[0]).trimmingCharacters(in: .whitespaces)
            let heading = headingParts.count > 1
                ? String(headingParts[1]).trimmingCharacters(in: .whitespaces)
                : nil

            guard !target.isEmpty || (heading?.isEmpty == false) else {
                continue
            }

            spans.append(
                Span(
                    range: spanStart..<end,
                    isEmbed: isEmbed,
                    target: target,
                    heading: heading,
                    alias: alias
                )
            )
        }

        return spans
    }
}
