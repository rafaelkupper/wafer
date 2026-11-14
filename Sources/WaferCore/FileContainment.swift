import Foundation

/// A resolved directory and its volume's case rules, captured before a file is opened.
/// Containment includes the directory itself. Unknown volumes use case-sensitive matching.
public struct FileContainment: Equatable, Sendable {
    private let rootDirectory: URL
    private let caseSensitive: Bool

    public init(rootDirectory: URL) {
        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.rootDirectory = root
        self.caseSensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? true
    }

    init(rootDirectory: URL, caseSensitive: Bool) {
        self.rootDirectory = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.caseSensitive = caseSensitive
    }

    public static func isContained(_ file: URL, in rootDirectory: URL) -> Bool {
        FileContainment(rootDirectory: rootDirectory).contains(file)
    }

    /// Resolve the candidate again, while retaining the original root across path changes.
    public func contains(_ file: URL) -> Bool {
        guard file.isFileURL, rootDirectory.isFileURL else { return false }
        let fileParts = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rootParts = rootDirectory.pathComponents
        guard fileParts.count >= rootParts.count else { return false }
        return zip(fileParts, rootParts).allSatisfy { filePart, rootPart in
            caseSensitive ? filePart == rootPart
                : filePart.compare(rootPart, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
        }
    }
}
