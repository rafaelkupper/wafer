import Foundation
import Markdown

public struct Backlink: Equatable, Sendable {
    public let sourceFileURL: URL
    public let sourceTitle: String
    public let contextSnippet: String

    public init(sourceFileURL: URL, sourceTitle: String, contextSnippet: String) {
        self.sourceFileURL = sourceFileURL
        self.sourceTitle = sourceTitle
        self.contextSnippet = contextSnippet
    }
}

/// One outgoing reference found while scanning a library file: either an
/// already-resolved local markdown link, or a wiki target string that must be
/// resolved against the finished scan's own index (second pass).
public struct OutgoingReference: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case markdownFile(URL)
        case wikiTarget(String)
    }

    public let target: Target
    public let contextSnippet: String

    public init(target: Target, contextSnippet: String) {
        self.target = target
        self.contextSnippet = contextSnippet
    }
}

/// Pure inverted index: destination file -> the files that link to it.
public enum BacklinkIndex {
    public static func build(files: [LibraryFile], wikiIndex: WikiLinkIndex? = nil) -> [String: [Backlink]] {
        let wikiIndex = wikiIndex ?? WikiLinkIndex(files: files)
        var backlinksByIdentity: [String: [Backlink]] = [:]

        for file in files {
            var seenDestinations = Set<String>()
            for reference in file.outgoingReferences {
                let destinationURL: URL?
                switch reference.target {
                case .markdownFile(let url):
                    destinationURL = url
                case .wikiTarget(let target):
                    destinationURL = wikiIndex.resolve(target)
                }

                guard let destinationURL else {
                    continue
                }

                let identity = FileIdentity.identity(for: destinationURL)
                // Self-links are not backlinks; the FIRST linking context wins.
                guard
                    identity != file.identity,
                    seenDestinations.insert(identity).inserted
                else {
                    continue
                }

                backlinksByIdentity[identity, default: []].append(
                    Backlink(
                        sourceFileURL: file.fileURL,
                        sourceTitle: file.displayTitle,
                        contextSnippet: reference.contextSnippet
                    )
                )
            }
        }

        for identity in backlinksByIdentity.keys {
            backlinksByIdentity[identity]?.sort {
                $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle) == .orderedAscending
            }
        }
        return backlinksByIdentity
    }
}

/// Walks one parsed document collecting outgoing references with their
/// surrounding context. Wiki spans inside code (inline or fenced) never
/// count.
public struct OutgoingReferenceCollector: MarkupVisitor {
    public typealias Result = [OutgoingReference]

    private let baseURL: URL?
    private let assetResolver: AssetResolver

    public static func collect(
        from document: MarkdownDocument,
        assetResolver: AssetResolver
    ) -> [OutgoingReference] {
        var collector = OutgoingReferenceCollector(
            baseURL: document.baseURL,
            assetResolver: assetResolver
        )
        return collector.visit(document.ast)
    }

    init(baseURL: URL?, assetResolver: AssetResolver) {
        self.baseURL = baseURL
        self.assetResolver = assetResolver
    }

    public mutating func visit(_ markup: Markup) -> [OutgoingReference] {
        markup.accept(&self)
    }

    public mutating func defaultVisit(_ markup: Markup) -> [OutgoingReference] {
        markup.children.flatMap { visit($0) }
    }

    public mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> [OutgoingReference] {
        []
    }

    public mutating func visitInlineCode(_ inlineCode: InlineCode) -> [OutgoingReference] {
        []
    }

    public mutating func visitHTMLBlock(_ html: HTMLBlock) -> [OutgoingReference] {
        []
    }

    public mutating func visitLink(_ link: Link) -> [OutgoingReference] {
        var references: [OutgoingReference] = []
        if
            let destination = link.destination,
            case .markdownFile(let url) = assetResolver.linkTarget(for: destination, relativeTo: baseURL)
        {
            references.append(
                OutgoingReference(
                    target: .markdownFile(FileIdentity.normalized(url)),
                    contextSnippet: Self.snippet(for: link)
                )
            )
        }
        return references + defaultVisit(link)
    }

    public mutating func visitText(_ text: Text) -> [OutgoingReference] {
        WikiLinkSyntax.spans(in: text.string).compactMap { span in
            guard !span.isEmbed, !span.target.isEmpty else {
                return nil
            }

            return OutgoingReference(
                target: .wikiTarget(span.target),
                contextSnippet: Self.snippet(for: text)
            )
        }
    }

    private static func snippet(for markup: Markup) -> String {
        var container: Markup = markup
        while let parent = container.parent, !(container is Paragraph) {
            container = parent
        }

        let text = container.plainText.collapsingWhitespace
        guard text.count > 140 else {
            return text
        }

        let endIndex = text.index(text.startIndex, offsetBy: 140)
        return text[..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
