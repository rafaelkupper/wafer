import Foundation

/// A resolved directory and its volume's case rules, captured before a file is opened.
/// Containment includes the directory itself. Unknown volumes use case-sensitive matching.
public struct FileContainment: Equatable, Sendable {
    /// A file resolved once (standardized, symlinks resolved), so it can be
    /// checked against several roots without resolving it again for each.
    public struct Candidate: Sendable {
        /// Nil for a URL that is not a file URL, which no root contains.
        fileprivate let pathComponents: [String]?

        public init(_ file: URL) {
            pathComponents = file.isFileURL ? file.standardizedFileURL.resolvingSymlinksInPath().pathComponents : nil
        }
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private let rootDirectory: URL
    /// `rootDirectory.pathComponents`, computed once.
    private let rootComponents: [String]
    private let caseSensitive: Bool

    public init(rootDirectory: URL) {
        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.rootDirectory = root
        self.rootComponents = root.pathComponents
        self.caseSensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? true
    }

    init(rootDirectory: URL, caseSensitive: Bool) {
        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.rootDirectory = root
        self.rootComponents = root.pathComponents
        self.caseSensitive = caseSensitive
    }

    public static func isContained(_ file: URL, in rootDirectory: URL) -> Bool {
        FileContainment(rootDirectory: rootDirectory).contains(file)
    }

    /// Resolve the candidate again, while retaining the original root across path changes.
    public func contains(_ file: URL) -> Bool {
        contains(Candidate(file))
    }

    /// The same check for a candidate resolved once by the caller.
    public func contains(_ candidate: Candidate) -> Bool {
        guard let fileParts = candidate.pathComponents, rootDirectory.isFileURL,
              fileParts.count >= rootComponents.count else { return false }
        return zip(fileParts, rootComponents).allSatisfy { filePart, rootPart in
            caseSensitive ? filePart == rootPart
                : filePart.compare(rootPart, options: [.caseInsensitive], locale: Self.posixLocale) == .orderedSame
        }
    }
}
