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
    private static let forbiddenElements: Set<String> = ["script", "iframe", "object", "form", "textarea", "title", "xmp", "noembed", "noframes", "plaintext", "animate", "animatemotion", "animatetransform", "set"]
    private static let forbiddenVoidElements: Set<String> = ["base", "embed", "link"]

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

            guard let token = HTMLTokenizer.parseTag(in: source, at: index) else {
                output += "&lt;"
                index = source.index(after: index)
                continue
            }

            if !token.isClosing, Self.forbiddenElements.contains(token.name) {
                index = HTMLTokenizer.indexAfterRawTextElement(named: token.name, in: source, after: token.endIndex)
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

            if Self.forbiddenElements.contains(token.name) || Self.forbiddenVoidElements.contains(token.name)
                || (token.name == "meta" && !token.isContentSecurityPolicyMeta) {
                index = token.endIndex
                continue
            }
            if token.isClosing || token.name.isEmpty || token.attributes.allSatisfy(Self.isSafeAttribute) {
                output += source[token.rawRange]
            } else {
                output += "<\(token.name)\(Self.renderedAttributeString(token.attributes))>"
            }
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

            guard let token = HTMLTokenizer.parseTag(in: source, at: index) else {
                index = source.index(after: index)
                continue
            }

            if !token.isClosing, Self.forbiddenElements.contains(token.name) {
                index = HTMLTokenizer.indexAfterRawTextElement(named: token.name, in: source, after: token.endIndex)
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
                for candidate in HTMLTokenizer.sourceSetCandidates(from: sourceSet) where isRemoteImageSource(candidate.source) {
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

    private func imageTag(for token: HTMLTagToken) throws -> String? {
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

    private func sourceTag(for token: HTMLTagToken) throws -> String? {
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
        _ attributes: [HTMLAttribute],
        sourceValue: String
    ) -> [HTMLAttribute] {
        attributes.compactMap { attribute in
            if attribute.name == "src" {
                return HTMLAttribute(name: "src", value: sourceValue)
            }

            return attribute.decodedValue.containsWaferScheme ? nil : attribute
        }
    }

    private func filteredSourceAttributes(
        _ attributes: [HTMLAttribute],
        sourceSetValue: String
    ) -> [HTMLAttribute] {
        attributes.compactMap { attribute in
            switch attribute.name {
            case "srcset":
                HTMLAttribute(name: "srcset", value: sourceSetValue)
            case "media", "type":
                attribute.decodedValue.containsWaferScheme ? nil : attribute
            default:
                nil
            }
        }
    }

    private func inlinedSourceSet(from sourceSet: String) throws -> String? {
        let candidates = HTMLTokenizer.sourceSetCandidates(from: sourceSet)
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

    private func wikiAnchorTag(for token: HTMLTagToken, wikiHref: String) -> String {
        let rewritten = policy.rewriteWikiLinkHref(wikiHref)
        let attributes = token.attributes.compactMap { attribute -> HTMLAttribute? in
            if attribute.name == "href" {
                guard let rewritten else {
                    return nil
                }
                return HTMLAttribute(name: "href", value: rewritten)
            }
            return attribute.decodedValue.containsWaferScheme ? nil : attribute
        }
        return "<a\(Self.renderedAttributeString(attributes))>"
    }

    private func openingTagByDroppingWaferAttributes(for token: HTMLTagToken) -> String {
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

    private static func renderedAttributeString(_ attributes: [HTMLAttribute]) -> String {
        attributes
            .filter(isSafeAttribute)
            .map { " \($0.name)=\"\($0.value.escapedHTMLAttribute)\"" }
            .joined()
    }

    private static func isSafeAttribute(_ attribute: HTMLAttribute) -> Bool {
        guard attribute.value.range(of: #"(?i)(javascript|vbscript)\s*:"#, options: .regularExpression) == nil,
              !attribute.name.hasPrefix("on"), !["srcdoc", "action", "formaction", "xlink:href"].contains(attribute.name),
              !attribute.value.containsWaferScheme else { return false }
        if attribute.name == "href" {
            return LinkURLPolicy.allows(attribute.value)
        }
        if ["src", "poster", "background"].contains(attribute.name) {
            return attribute.value.lowercased().hasPrefix("data:image/") || LinkURLPolicy.allows(attribute.value)
        }
        return true
    }

    private static func isRemoteImageSource(_ source: String) -> Bool {
        guard let scheme = URL(string: source)?.scheme?.lowercased() else {
            return false
        }

        return scheme == "https" || scheme == "wafer-remote"
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

            guard let token = HTMLTokenizer.parseTag(in: source, at: index) else {
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

}

private extension String {
    var containsWaferScheme: Bool {
        range(
            of: #"(?i)(^|[^a-z0-9+.-])wafer-[a-z0-9+.-]*:"#,
            options: .regularExpression
        ) != nil
    }
}
