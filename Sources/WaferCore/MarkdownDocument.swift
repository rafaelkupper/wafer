import CryptoKit
import Foundation
import Markdown

public struct MarkdownDocument {
    public let source: String
    public let baseURL: URL?
    public let ast: Document
    public let fingerprint: String
    public let frontMatter: String?
    public let footnotes: [FootnoteDefinition]
    /// Maps parsed AST lines back to source lines, accounting for front matter
    /// and extracted footnote definitions. Index `n` holds the 1-based source
    /// line of AST line `n + 1`. Empty when unknown.
    public let sourceLineMap: [Int]

    public init(
        source: String,
        baseURL: URL?,
        ast: Document,
        fingerprint: String,
        frontMatter: String? = nil,
        footnotes: [FootnoteDefinition] = [],
        sourceLineMap: [Int] = []
    ) {
        self.source = source
        self.baseURL = baseURL
        self.ast = ast
        self.fingerprint = fingerprint
        self.frontMatter = frontMatter
        self.footnotes = footnotes
        self.sourceLineMap = sourceLineMap
    }

    /// The 1-based source line for a 1-based AST line, if known.
    public func sourceLine(forASTLine line: Int) -> Int? {
        guard line >= 1, line <= sourceLineMap.count else {
            return nil
        }

        return sourceLineMap[line - 1]
    }
}

public enum FileFingerprint {
    public static func sha256Hex(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(for string: String) -> String {
        sha256Hex(for: Data(string.utf8))
    }
}
