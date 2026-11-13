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

    func sanitize(_ fragment: String) -> String {
        var output = ""
        var index = fragment.startIndex
        var suppressedCloseCounts: [String: Int] = [:]

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

            guard let token = Self.parseTag(in: fragment, at: index) else {
                output += "&lt;"
                index = fragment.index(after: index)
                continue
            }

            if Self.rawTextTags.contains(token.name), !token.isClosing {
                index = Self.indexAfterRawTextElement(named: token.name, in: fragment, after: token.endIndex)
                continue
            }

            defer {
                index = token.endIndex
            }

            guard Self.allowedTags.contains(token.name) else {
                continue
            }

            if token.isClosing {
                if let count = suppressedCloseCounts[token.name], count > 0 {
                    suppressedCloseCounts[token.name] = count == 1 ? nil : count - 1
                    continue
                }
                if !Self.voidTags.contains(token.name) {
                    output += "</\(token.name)>"
                }
                continue
            }

            guard let tag = openingTag(for: token) else {
                suppressedCloseCounts[token.name, default: 0] += 1
                continue
            }
            output += tag
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

        let resolvedCandidates = Self.sourceSetCandidates(from: sourceSet).compactMap { candidate -> String? in
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

    private static func parseTag(in source: String, at startIndex: String.Index) -> HTMLTagToken? {
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
            return HTMLTagToken(
                name: name,
                isClosing: true,
                attributes: [],
                endIndex: endIndex
            )
        }

        guard let attributesSource = attributesSourceWithoutTrailingSlash(rawAttributes) else {
            return nil
        }
        guard let attributes = parseAttributes(attributesSource) else {
            return nil
        }

        return HTMLTagToken(
            name: name,
            isClosing: false,
            attributes: attributes,
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

    private static func parseAttributes(_ source: String) -> [HTMLAttribute]? {
        var attributes: [HTMLAttribute] = []
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
                attributes.append(HTMLAttribute(name: name, value: ""))
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

            attributes.append(HTMLAttribute(name: name, value: value))
        }
    }

    private static func indexAfterRawTextElement(
        named name: String,
        in source: String,
        after startIndex: String.Index
    ) -> String.Index {
        var searchRange = startIndex..<source.endIndex
        while let closeStart = source.range(
            of: "</\(name)",
            options: [.caseInsensitive],
            range: searchRange
        )?.lowerBound {
            if let closeToken = parseTag(in: source, at: closeStart),
               closeToken.isClosing,
               closeToken.name == name {
                return closeToken.endIndex
            }

            searchRange = source.index(after: closeStart)..<source.endIndex
        }

        return source.endIndex
    }

    private static func skipWhitespace(in source: String, index: inout String.Index) {
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-"
    }

    private static func isAttributeNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == ":"
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

    private static func sourceSetCandidates(from sourceSet: String) -> [HTMLSourceSetCandidate] {
        var candidates: [HTMLSourceSetCandidate] = []
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

            candidates.append(HTMLSourceSetCandidate(source: source, descriptor: descriptor))
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
}

private struct HTMLTagToken {
    let name: String
    let isClosing: Bool
    let attributes: [HTMLAttribute]
    let endIndex: String.Index
}

private struct HTMLAttribute {
    let name: String
    let value: String
}

private struct HTMLSourceSetCandidate {
    let source: String
    let descriptor: String?
}

private extension Character {
    var isASCIIAlphaNumeric: Bool {
        isASCII && (isLetter || isNumber)
    }
}
