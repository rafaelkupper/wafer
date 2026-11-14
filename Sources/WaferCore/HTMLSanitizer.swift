import Foundation

struct HTMLSanitizerPolicy {
    let resolveImageSource: (String) -> String?
    let resolveLinkHref: (String) -> String?
    let allowsSourceElements: Bool

    init(
        resolveImageSource: @escaping (String) -> String?,
        resolveLinkHref: @escaping (String) -> String?,
        allowsSourceElements: Bool = true
    ) {
        self.resolveImageSource = resolveImageSource
        self.resolveLinkHref = resolveLinkHref
        self.allowsSourceElements = allowsSourceElements
    }
}

struct HTMLSanitizer {
    private static let allowedTags: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "caption", "cite", "code", "col", "colgroup",
        "dd", "del", "details", "div", "dl", "dt", "em", "figcaption", "figure", "h1", "h2",
        "h3", "h4", "h5", "h6", "hr", "i", "img", "ins", "kbd", "li", "mark", "ol", "p",
        "picture", "pre", "q", "s", "small", "source", "span", "strong", "sub", "summary",
        "sup", "table", "tbody", "td", "tfoot", "th", "thead", "time", "tr", "u", "ul", "wbr",
    ]
    private static let voidTags: Set<String> = ["br", "col", "hr", "img", "source", "wbr"]
    private static let rawTextTags: Set<String> = [
        "form", "iframe", "noembed", "noframes", "object", "plaintext", "script", "style", "textarea", "title", "xmp",
    ]
    private static let alignValues: Set<String> = ["left", "center", "right", "justify"]

    private let policy: HTMLSanitizerPolicy

    init(policy: HTMLSanitizerPolicy) {
        self.policy = policy
    }

    struct State {
        var elements: [(name: String, emitted: Bool)] = []

        mutating func finish() -> String {
            defer { elements.removeAll() }
            return elements.reversed().filter(\.emitted).map { "</\($0.name)>" }.joined()
        }
    }

    func sanitize(_ fragment: String) -> String {
        var state = State()
        return sanitize(fragment, state: &state) + state.finish()
    }

    func sanitize(_ fragment: String, state: inout State) -> String {
        var output = ""
        var index = fragment.startIndex

        while index < fragment.endIndex {
            guard fragment[index] == "<" else {
                output.append(fragment[index])
                index = fragment.index(after: index)
                continue
            }

            if fragment[index...].hasPrefix("<!--") {
                guard let commentEnd = fragment.range(of: "-->", range: index..<fragment.endIndex) else {
                    output += "&lt;"
                    index = fragment.index(after: index)
                    continue
                }
                index = commentEnd.upperBound
                continue
            }

            guard let token = HTMLTokenizer.parseTag(in: fragment, at: index) else {
                output += "&lt;"
                index = fragment.index(after: index)
                continue
            }

            if Self.rawTextTags.contains(token.name), !token.isClosing {
                index = HTMLTokenizer.indexAfterRawTextElement(named: token.name, in: fragment, after: token.endIndex)
                continue
            }

            defer {
                index = token.endIndex
            }

            guard Self.allowedTags.contains(token.name) else {
                continue
            }

            if token.isClosing {
                if let match = state.elements.lastIndex(where: { $0.name == token.name }) {
                    for element in state.elements[match...].reversed() where element.emitted {
                        output += "</\(element.name)>"
                    }
                    state.elements.removeSubrange(match...)
                }
                continue
            }

            let tag = openingTag(for: token)
            if !Self.voidTags.contains(token.name) {
                state.elements.append((token.name, tag != nil))
            }
            if let tag { output += tag }
        }

        return output
    }

    private func openingTag(for token: HTMLTagToken) -> String? {
        switch token.name {
        case "br", "hr", "wbr":
            return "<\(token.name) />"
        case "col":
            return "<col\(renderedAttributeString(colAttributes(from: token.attributes))) />"
        case "source":
            return sourceTag(for: token.attributes)
        case "img":
            return imageTag(for: token.attributes)
        case "a":
            return anchorTag(for: token.attributes)
        case "abbr":
            return normalTag(token.name, attributes: titleAttribute(from: token.attributes))
        case "div", "p", "span":
            return normalTag(token.name, attributes: alignAttribute(from: token.attributes))
        case "ol":
            return normalTag(token.name, attributes: orderedListAttributes(from: token.attributes))
        case "td", "th":
            return normalTag(token.name, attributes: tableCellAttributes(from: token.attributes))
        case "time":
            return normalTag(token.name, attributes: timeAttributes(from: token.attributes))
        default:
            return normalTag(token.name, attributes: [])
        }
    }

    private func imageTag(for attributes: [HTMLAttribute]) -> String? {
        guard
            let rawSource = firstAttributeValue(named: "src", in: attributes),
            let source = policy.resolveImageSource(rawSource)
        else {
            return nil
        }

        var rendered = [HTMLAttribute(name: "src", value: source)]
        if let alt = firstAttributeValue(named: "alt", in: attributes) {
            rendered.append(HTMLAttribute(name: "alt", value: alt))
        }
        if let width = digitsAttribute(named: "width", from: attributes) {
            rendered.append(width)
        }
        if let height = digitsAttribute(named: "height", from: attributes) {
            rendered.append(height)
        }

        return "<img\(renderedAttributeString(rendered)) />"
    }

    private func sourceTag(for attributes: [HTMLAttribute]) -> String? {
        guard policy.allowsSourceElements, let srcset = sourceSetAttribute(from: attributes) else {
            return nil
        }

        var rendered: [HTMLAttribute] = []
        if let media = mediaAttribute(from: attributes) {
            rendered.append(media)
        }
        if let type = imageTypeAttribute(from: attributes) {
            rendered.append(type)
        }
        rendered.append(srcset)
        return "<source\(renderedAttributeString(rendered)) />"
    }

    private func anchorTag(for attributes: [HTMLAttribute]) -> String? {
        guard
            let rawHref = firstAttributeValue(named: "href", in: attributes),
            let href = policy.resolveLinkHref(rawHref)
        else {
            return nil
        }

        var rendered = [HTMLAttribute(name: "href", value: href)]
        if let title = firstAttributeValue(named: "title", in: attributes) {
            rendered.append(HTMLAttribute(name: "title", value: title))
        }
        return normalTag("a", attributes: rendered)
    }

    private func normalTag(_ name: String, attributes: [HTMLAttribute]) -> String {
        "<\(name)\(renderedAttributeString(attributes))>"
    }

    private func titleAttribute(from attributes: [HTMLAttribute]) -> [HTMLAttribute] {
        guard let title = firstAttributeValue(named: "title", in: attributes) else {
            return []
        }
        return [HTMLAttribute(name: "title", value: title)]
    }

    private func alignAttribute(from attributes: [HTMLAttribute]) -> [HTMLAttribute] {
        guard
            let align = firstAttributeValue(named: "align", in: attributes)?.lowercased(),
            Self.alignValues.contains(align)
        else {
            return []
        }
        return [HTMLAttribute(name: "align", value: align)]
    }

    private func tableCellAttributes(from attributes: [HTMLAttribute]) -> [HTMLAttribute] {
        var rendered = alignAttribute(from: attributes)
        if let colspan = digitsAttribute(named: "colspan", from: attributes) {
            rendered.append(colspan)
        }
        if let rowspan = digitsAttribute(named: "rowspan", from: attributes) {
            rendered.append(rowspan)
        }
        return rendered
    }

    private func orderedListAttributes(from attributes: [HTMLAttribute]) -> [HTMLAttribute] {
        guard let start = digitsAttribute(named: "start", from: attributes) else {
            return []
        }
        return [start]
    }

    private func colAttributes(from attributes: [HTMLAttribute]) -> [HTMLAttribute] {
        guard let span = digitsAttribute(named: "span", from: attributes) else {
            return []
        }
        return [span]
    }

    private func timeAttributes(from attributes: [HTMLAttribute]) -> [HTMLAttribute] {
        guard let datetime = firstAttributeValue(named: "datetime", in: attributes) else {
            return []
        }
        return [HTMLAttribute(name: "datetime", value: datetime)]
    }

    private func mediaAttribute(from attributes: [HTMLAttribute]) -> HTMLAttribute? {
        guard
            let media = firstAttributeValue(named: "media", in: attributes),
            !media.isEmpty,
            media.allSatisfy(Self.isSafeMediaQueryCharacter)
        else {
            return nil
        }
        return HTMLAttribute(name: "media", value: media)
    }

    private func imageTypeAttribute(from attributes: [HTMLAttribute]) -> HTMLAttribute? {
        guard
            let type = firstAttributeValue(named: "type", in: attributes),
            Self.isAllowedImageMIMEType(type)
        else {
            return nil
        }
        return HTMLAttribute(name: "type", value: type)
    }

    private func sourceSetAttribute(from attributes: [HTMLAttribute]) -> HTMLAttribute? {
        guard let sourceSet = firstAttributeValue(named: "srcset", in: attributes) else {
            return nil
        }

        let resolvedCandidates = HTMLTokenizer.sourceSetCandidates(from: sourceSet).compactMap { candidate -> String? in
            guard let source = policy.resolveImageSource(candidate.source) else {
                return nil
            }
            if let descriptor = candidate.descriptor {
                return "\(source) \(descriptor)"
            }
            return source
        }

        guard !resolvedCandidates.isEmpty else {
            return nil
        }
        return HTMLAttribute(name: "srcset", value: resolvedCandidates.joined(separator: ", "))
    }

    private func digitsAttribute(named name: String, from attributes: [HTMLAttribute]) -> HTMLAttribute? {
        guard
            let value = firstAttributeValue(named: name, in: attributes),
            !value.isEmpty,
            value.allSatisfy(\.isNumber)
        else {
            return nil
        }
        return HTMLAttribute(name: name, value: value)
    }

    private func firstAttributeValue(named name: String, in attributes: [HTMLAttribute]) -> String? {
        attributes.first { $0.name == name }?.value
    }

    private func renderedAttributeString(_ attributes: [HTMLAttribute]) -> String {
        attributes
            .map { " \($0.name)=\"\($0.value.escapedHTMLAttribute)\"" }
            .joined()
    }

    private static func isSafeMediaQueryCharacter(_ character: Character) -> Bool {
        character.isASCIIAlphaNumeric || character.isWhitespace || "():,-".contains(character)
    }

    private static func isAllowedImageMIMEType(_ type: String) -> Bool {
        let lowercased = type.lowercased()
        guard lowercased.hasPrefix("image/") else {
            return false
        }

        let subtype = lowercased.dropFirst("image/".count)
        return !subtype.isEmpty && subtype.allSatisfy { character in
            character.isASCIIAlphaNumeric || "+.-".contains(character)
        }
    }

}

private extension Character {
    var isASCIIAlphaNumeric: Bool {
        isASCII && (isLetter || isNumber)
    }
}
