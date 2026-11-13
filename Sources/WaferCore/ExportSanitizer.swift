import Foundation

public enum ExportSanitizer {
    public static let chromeAttributeName = "data-wafer-chrome"
    public static let chromeAttributeValue = "true"
    public static let strippedChromeSelectors = ["[\(chromeAttributeName)]"]
    public static let exportedContentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline';"

    public struct ExportPolicy {
        public let inlineImage: (String) throws -> String?
        public let rewriteWikiLinkHref: (String) -> String?

        public init(
            inlineImage: @escaping (String) throws -> String?,
            rewriteWikiLinkHref: @escaping (String) -> String? = { _ in nil }
        ) {
            self.inlineImage = inlineImage
            self.rewriteWikiLinkHref = rewriteWikiLinkHref
        }
    }

    public static func sanitize(domHTML: String, policy: ExportPolicy) throws -> String {
        var processor = ExportHTMLProcessor(source: domHTML, policy: policy)
        return try processor.sanitizedHTML()
    }

    public static func remoteImageSources(in domHTML: String) -> [String] {
        ExportHTMLProcessor.remoteImageSources(in: domHTML)
    }
}

private struct ExportHTMLProcessor {
    private static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

    let source: String
    let policy: ExportSanitizer.ExportPolicy
    var rewroteCSP = false

    mutating func sanitizedHTML() throws -> String {
        var output = ""
        var index = source.startIndex

        while index < source.endIndex {
            guard source[index] == "<" else {
                output.append(source[index])
                index = source.index(after: index)
                continue
            }

            if source[index...].hasPrefix("<!--") {
                guard let commentEnd = source.range(of: "-->", range: index..<source.endIndex) else {
                    output += "&lt;"
                    index = source.index(after: index)
                    continue
                }
                output += source[index..<commentEnd.upperBound]
                index = commentEnd.upperBound
                continue
            }

            guard let token = Self.parseTag(in: source, at: index) else {
                output += "&lt;"
                index = source.index(after: index)
                continue
            }

            if !token.isClosing, token.name == "script" {
                index = Self.indexAfterRawTextElement(named: token.name, in: source, after: token.endIndex)
                continue
            }

            if !token.isClosing, token.hasAttribute(named: ExportSanitizer.chromeAttributeName) {
                index = Self.voidTags.contains(token.name)
                    ? token.endIndex
                    : Self.indexAfterElement(named: token.name, in: source, after: token.endIndex)
                continue
            }

            if !token.isClosing, token.name == "meta", token.isContentSecurityPolicyMeta {
                output += Self.exportedCSPMetaTag()
                rewroteCSP = true
                index = token.endIndex
                continue
            }

            if !token.isClosing, token.name == "img" {
                if let tag = try imageTag(for: token) {
                    output += tag
                }
                index = token.endIndex
                continue
            }

            if !token.isClosing, token.name == "source" {
                if let tag = try sourceTag(for: token) {
                    output += tag
                }
                index = token.endIndex
                continue
            }

            if !token.isClosing,
               token.name == "a",
               let href = token.firstAttribute(named: "href"),
               href.decodedValue.lowercased().hasPrefix("wafer-wiki:") {
                output += wikiAnchorTag(for: token, wikiHref: href.decodedValue)
                index = token.endIndex
                continue
            }

            if !token.isClosing, token.attributes.contains(where: { $0.decodedValue.containsWaferScheme }) {
                output += openingTagByDroppingWaferAttributes(for: token)
                index = token.endIndex
                continue
            }

            output += source[token.rawRange]
            index = token.endIndex
        }

        if !rewroteCSP {
            output = Self.insertExportedCSPMetaIfPossible(into: output)
        }

        return Self.ensureDoctype(output)
    }

    static func remoteImageSources(in source: String) -> [String] {
        var sources: [String] = []
        var seenSources = Set<String>()
        var index = source.startIndex

        while index < source.endIndex {
            guard source[index] == "<" else {
                index = source.index(after: index)
                continue
            }

            if source[index...].hasPrefix("<!--") {
                guard let commentEnd = source.range(of: "-->", range: index..<source.endIndex) else {
                    index = source.index(after: index)
                    continue
                }
                index = commentEnd.upperBound
                continue
            }

            guard let token = parseTag(in: source, at: index) else {
                index = source.index(after: index)
                continue
            }

            if !token.isClosing, token.name == "script" {
                index = indexAfterRawTextElement(named: token.name, in: source, after: token.endIndex)
                continue
            }

            if !token.isClosing,
               token.name == "img",
               let source = token.firstAttribute(named: "src")?.decodedValue,
               isRemoteImageSource(source),
               seenSources.insert(source).inserted {
                sources.append(source)
            }

            if !token.isClosing,
               token.name == "source",
               let sourceSet = token.firstAttribute(named: "srcset")?.decodedValue {
                for candidate in sourceSetCandidates(from: sourceSet) where isRemoteImageSource(candidate.source) {
                    guard seenSources.insert(candidate.source).inserted else {
                        continue
                    }
                    sources.append(candidate.source)
                }
            }

            index = token.endIndex
        }

        return sources
    }

    private func imageTag(for token: ExportHTMLTagToken) throws -> String? {
        guard
            let sourceAttribute = token.firstAttribute(named: "src")
        else {
            return nil
        }

        let decodedSource = sourceAttribute.decodedValue
        if decodedSource.lowercased().hasPrefix("data:image/") {
            return "<img\(Self.renderedAttributeString(filteredImageAttributes(token.attributes, sourceValue: decodedSource)))>"
        }

        guard let inlinedSource = try policy.inlineImage(decodedSource) else {
            return nil
        }

        let attributes = filteredImageAttributes(token.attributes, sourceValue: inlinedSource)
        return "<img\(Self.renderedAttributeString(attributes))>"
    }

    private func sourceTag(for token: ExportHTMLTagToken) throws -> String? {
        guard
            let sourceSetAttribute = token.firstAttribute(named: "srcset"),
            let inlinedSourceSet = try inlinedSourceSet(from: sourceSetAttribute.decodedValue)
        else {
            return nil
        }

        let attributes = filteredSourceAttributes(token.attributes, sourceSetValue: inlinedSourceSet)
        return "<source\(Self.renderedAttributeString(attributes))>"
    }

    private func filteredImageAttributes(
        _ attributes: [ExportHTMLAttribute],
        sourceValue: String
    ) -> [ExportHTMLAttribute] {
        attributes.compactMap { attribute in
            if attribute.name == "src" {
                return ExportHTMLAttribute(name: "src", value: sourceValue)
            }

            return attribute.decodedValue.containsWaferScheme ? nil : attribute
        }
    }

    private func filteredSourceAttributes(
        _ attributes: [ExportHTMLAttribute],
        sourceSetValue: String
    ) -> [ExportHTMLAttribute] {
        attributes.compactMap { attribute in
            switch attribute.name {
            case "srcset":
                ExportHTMLAttribute(name: "srcset", value: sourceSetValue)
            case "media", "type":
                attribute.decodedValue.containsWaferScheme ? nil : attribute
            default:
                nil
            }
        }
    }

    private func inlinedSourceSet(from sourceSet: String) throws -> String? {
        let candidates = Self.sourceSetCandidates(from: sourceSet)
        guard !candidates.isEmpty else {
            return nil
        }

        var rendered: [String] = []
        for candidate in candidates {
            guard let source = try inlinedImageSource(candidate.source) else {
                return nil
            }
            if let descriptor = candidate.descriptor {
                rendered.append("\(source) \(descriptor)")
            } else {
                rendered.append(source)
            }
        }

        return rendered.joined(separator: ", ")
    }

    private func inlinedImageSource(_ source: String) throws -> String? {
        if source.lowercased().hasPrefix("data:image/") {
            return source
        }

        return try policy.inlineImage(source)
    }

    private func wikiAnchorTag(for token: ExportHTMLTagToken, wikiHref: String) -> String {
        let rewritten = policy.rewriteWikiLinkHref(wikiHref)
        let attributes = token.attributes.compactMap { attribute -> ExportHTMLAttribute? in
            if attribute.name == "href" {
                guard let rewritten else {
                    return nil
                }
                return ExportHTMLAttribute(name: "href", value: rewritten)
            }
            return attribute.decodedValue.containsWaferScheme ? nil : attribute
        }
        return "<a\(Self.renderedAttributeString(attributes))>"
    }

    private func openingTagByDroppingWaferAttributes(for token: ExportHTMLTagToken) -> String {
        let attributes = token.attributes.filter { !$0.decodedValue.containsWaferScheme }
        return "<\(token.name)\(Self.renderedAttributeString(attributes))>"
    }

    private static func exportedCSPMetaTag() -> String {
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(ExportSanitizer.exportedContentSecurityPolicy.escapedHTMLAttribute)\">"
    }

    private static func insertExportedCSPMetaIfPossible(into html: String) -> String {
        guard
            let headStart = html.range(of: #"<head(?:\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive])
        else {
            let doctypeRange = html.range(
                of: #"^\s*<!doctype[^>]*>"#,
                options: [.regularExpression, .caseInsensitive]
            )
            guard let doctypeRange else {
                return "\(exportedCSPMetaTag())\n\(html)"
            }

            return String(html[..<doctypeRange.upperBound])
                + "\n\(exportedCSPMetaTag())"
                + String(html[doctypeRange.upperBound...])
        }

        return String(html[..<headStart.upperBound])
            + "\n  \(exportedCSPMetaTag())"
            + String(html[headStart.upperBound...])
    }

    private static func ensureDoctype(_ html: String) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.lowercased().hasPrefix("<!doctype") else {
            return html
        }

        return "<!doctype html>\n\(html)"
    }

    private static func renderedAttributeString(_ attributes: [ExportHTMLAttribute]) -> String {
        attributes
            .map { " \($0.name)=\"\($0.value.escapedHTMLAttribute)\"" }
            .joined()
    }

    private static func isRemoteImageSource(_ source: String) -> Bool {
        guard let scheme = URL(string: source)?.scheme?.lowercased() else {
            return false
        }

        return scheme == "https" || scheme == "wafer-remote"
    }

    private static func sourceSetCandidates(from sourceSet: String) -> [ExportHTMLSourceSetCandidate] {
        var candidates: [ExportHTMLSourceSetCandidate] = []
        var index = sourceSet.startIndex

        while true {
            skipSourceSetSeparators(in: sourceSet, index: &index)
            guard index < sourceSet.endIndex else {
                return candidates
            }

            let sourceStart = index
            while index < sourceSet.endIndex, !sourceSet[index].isWhitespace, sourceSet[index] != "," {
                index = sourceSet.index(after: index)
            }
            let source = String(sourceSet[sourceStart..<index])
            skipWhitespace(in: sourceSet, index: &index)

            var descriptor: String?
            if index < sourceSet.endIndex, sourceSet[index] != "," {
                let descriptorStart = index
                while index < sourceSet.endIndex, !sourceSet[index].isWhitespace, sourceSet[index] != "," {
                    index = sourceSet.index(after: index)
                }
                let candidateDescriptor = String(sourceSet[descriptorStart..<index])
                skipWhitespace(in: sourceSet, index: &index)
                guard index == sourceSet.endIndex || sourceSet[index] == ",",
                      isValidSourceSetDescriptor(candidateDescriptor) else {
                    skipInvalidSourceSetCandidate(in: sourceSet, index: &index)
                    continue
                }
                descriptor = candidateDescriptor
            }

            candidates.append(ExportHTMLSourceSetCandidate(source: source, descriptor: descriptor))
            if index < sourceSet.endIndex, sourceSet[index] == "," {
                index = sourceSet.index(after: index)
            }
        }
    }

    private static func skipSourceSetSeparators(in sourceSet: String, index: inout String.Index) {
        while index < sourceSet.endIndex, sourceSet[index].isWhitespace || sourceSet[index] == "," {
            index = sourceSet.index(after: index)
        }
    }

    private static func skipInvalidSourceSetCandidate(in sourceSet: String, index: inout String.Index) {
        while index < sourceSet.endIndex, sourceSet[index] != "," {
            index = sourceSet.index(after: index)
        }
        if index < sourceSet.endIndex {
            index = sourceSet.index(after: index)
        }
    }

    private static func isValidSourceSetDescriptor(_ descriptor: String) -> Bool {
        guard !descriptor.isEmpty, descriptor.allSatisfy({ !$0.isWhitespace }) else {
            return false
        }

        if descriptor.hasSuffix("w") {
            let number = descriptor.dropLast()
            return !number.isEmpty && number.allSatisfy(\.isNumber)
        }

        if descriptor.hasSuffix("x") {
            let number = descriptor.dropLast()
            return isPositiveDecimal(number)
        }

        return false
    }

    private static func isPositiveDecimal(_ source: Substring) -> Bool {
        var sawDigit = false
        var sawDecimalSeparator = false

        for character in source {
            if character == "." {
                guard !sawDecimalSeparator else {
                    return false
                }
                sawDecimalSeparator = true
                continue
            }

            guard character.isNumber else {
                return false
            }
            sawDigit = true
        }

        return sawDigit
    }

    private static func parseTag(in source: String, at startIndex: String.Index) -> ExportHTMLTagToken? {
        guard source[startIndex] == "<" else {
            return nil
        }

        var index = source.index(after: startIndex)
        skipWhitespace(in: source, index: &index)

        var isClosing = false
        if index < source.endIndex, source[index] == "/" {
            isClosing = true
            index = source.index(after: index)
            skipWhitespace(in: source, index: &index)
        } else if index < source.endIndex, source[index] == "!" || source[index] == "?" {
            guard let tagEnd = tagEndIndex(in: source, after: index) else {
                return nil
            }
            let endIndex = source.index(after: tagEnd)
            return ExportHTMLTagToken(
                name: "",
                isClosing: false,
                attributes: [],
                rawRange: startIndex..<endIndex,
                endIndex: endIndex
            )
        }

        let nameStart = index
        while index < source.endIndex, isNameCharacter(source[index]) {
            index = source.index(after: index)
        }
        guard nameStart < index else {
            return nil
        }

        let name = String(source[nameStart..<index]).lowercased()
        guard let tagEnd = tagEndIndex(in: source, after: index) else {
            return nil
        }

        let endIndex = source.index(after: tagEnd)
        let rawAttributes = String(source[index..<tagEnd])

        if isClosing {
            guard rawAttributes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return ExportHTMLTagToken(
                name: name,
                isClosing: true,
                attributes: [],
                rawRange: startIndex..<endIndex,
                endIndex: endIndex
            )
        }

        guard let attributesSource = attributesSourceWithoutTrailingSlash(rawAttributes),
              let attributes = parseAttributes(attributesSource) else {
            return nil
        }

        return ExportHTMLTagToken(
            name: name,
            isClosing: false,
            attributes: attributes,
            rawRange: startIndex..<endIndex,
            endIndex: endIndex
        )
    }

    private static func tagEndIndex(in source: String, after startIndex: String.Index) -> String.Index? {
        var index = startIndex
        var quote: Character?

        while index < source.endIndex {
            let character = source[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "<" {
                return nil
            } else if character == ">" {
                return index
            }
            index = source.index(after: index)
        }

        return nil
    }

    private static func attributesSourceWithoutTrailingSlash(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("/") else {
            return source
        }

        var endIndex = source.endIndex
        while endIndex > source.startIndex {
            let previous = source.index(before: endIndex)
            if source[previous].isWhitespace {
                endIndex = previous
                continue
            }
            if source[previous] == "/" {
                return String(source[..<previous])
            }
            break
        }

        return nil
    }

    private static func parseAttributes(_ source: String) -> [ExportHTMLAttribute]? {
        var attributes: [ExportHTMLAttribute] = []
        var index = source.startIndex

        while true {
            skipWhitespace(in: source, index: &index)
            guard index < source.endIndex else {
                return attributes
            }
            guard isAttributeNameCharacter(source[index]) else {
                return nil
            }

            let nameStart = index
            while index < source.endIndex, isAttributeNameCharacter(source[index]) {
                index = source.index(after: index)
            }
            let name = String(source[nameStart..<index]).lowercased()

            skipWhitespace(in: source, index: &index)
            guard index < source.endIndex, source[index] == "=" else {
                attributes.append(ExportHTMLAttribute(name: name, value: ""))
                continue
            }

            index = source.index(after: index)
            skipWhitespace(in: source, index: &index)
            guard index < source.endIndex else {
                return nil
            }

            let value: String
            if source[index] == "\"" || source[index] == "'" {
                let quote = source[index]
                index = source.index(after: index)
                let valueStart = index
                while index < source.endIndex, source[index] != quote {
                    index = source.index(after: index)
                }
                guard index < source.endIndex else {
                    return nil
                }
                value = String(source[valueStart..<index])
                index = source.index(after: index)
            } else {
                let valueStart = index
                while index < source.endIndex, !source[index].isWhitespace {
                    guard source[index] != "<", source[index] != ">" else {
                        return nil
                    }
                    index = source.index(after: index)
                }
                value = String(source[valueStart..<index])
            }

            attributes.append(ExportHTMLAttribute(name: name, value: value))
        }
    }

    private static func indexAfterRawTextElement(
        named name: String,
        in source: String,
        after startIndex: String.Index
    ) -> String.Index {
        var searchRange = startIndex..<source.endIndex
        while let closeStart = source.range(of: "</\(name)", options: [.caseInsensitive], range: searchRange)?.lowerBound {
            if let closeToken = parseTag(in: source, at: closeStart),
               closeToken.isClosing,
               closeToken.name == name {
                return closeToken.endIndex
            }

            searchRange = source.index(after: closeStart)..<source.endIndex
        }

        return source.endIndex
    }

    private static func indexAfterElement(
        named name: String,
        in source: String,
        after startIndex: String.Index
    ) -> String.Index {
        var depth = 1
        var index = startIndex

        while index < source.endIndex {
            guard source[index] == "<" else {
                index = source.index(after: index)
                continue
            }

            if source[index...].hasPrefix("<!--") {
                guard let commentEnd = source.range(of: "-->", range: index..<source.endIndex) else {
                    index = source.index(after: index)
                    continue
                }
                index = commentEnd.upperBound
                continue
            }

            guard let token = parseTag(in: source, at: index) else {
                index = source.index(after: index)
                continue
            }

            if token.name == name {
                if token.isClosing {
                    depth -= 1
                    if depth == 0 {
                        return token.endIndex
                    }
                } else if !voidTags.contains(token.name) {
                    depth += 1
                }
            }

            index = token.endIndex
        }

        return source.endIndex
    }

    private static func skipWhitespace(in source: String, index: inout String.Index) {
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == ":"
    }

    private static func isAttributeNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == ":"
    }
}

private struct ExportHTMLTagToken {
    let name: String
    let isClosing: Bool
    let attributes: [ExportHTMLAttribute]
    let rawRange: Range<String.Index>
    let endIndex: String.Index

    var isContentSecurityPolicyMeta: Bool {
        firstAttribute(named: "http-equiv")?.decodedValue.lowercased() == "content-security-policy"
    }

    func hasAttribute(named name: String) -> Bool {
        attributes.contains { $0.name == name }
    }

    func firstAttribute(named name: String) -> ExportHTMLAttribute? {
        attributes.first { $0.name == name }
    }
}

private struct ExportHTMLAttribute {
    let name: String
    let value: String

    var decodedValue: String {
        value.decodedHTMLAttribute
    }
}

private struct ExportHTMLSourceSetCandidate {
    let source: String
    let descriptor: String?
}

private extension String {
    var decodedHTMLAttribute: String {
        replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    var containsWaferScheme: Bool {
        range(
            of: #"(?i)(^|[^a-z0-9+.-])wafer-[a-z0-9+.-]*:"#,
            options: .regularExpression
        ) != nil
    }
}
