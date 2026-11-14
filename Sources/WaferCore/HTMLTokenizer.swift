import Foundation

enum HTMLTokenizer {
    static func sourceSetCandidates(from sourceSet: String) -> [HTMLSourceSetCandidate] {
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

    static func skipSourceSetSeparators(in sourceSet: String, index: inout String.Index) {
        while index < sourceSet.endIndex, sourceSet[index].isWhitespace || sourceSet[index] == "," {
            index = sourceSet.index(after: index)
        }
    }

    static func skipInvalidSourceSetCandidate(in sourceSet: String, index: inout String.Index) {
        while index < sourceSet.endIndex, sourceSet[index] != "," {
            index = sourceSet.index(after: index)
        }
        if index < sourceSet.endIndex {
            index = sourceSet.index(after: index)
        }
    }

    static func isValidSourceSetDescriptor(_ descriptor: String) -> Bool {
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

    static func isPositiveDecimal(_ source: Substring) -> Bool {
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

    static func parseTag(in source: String, at startIndex: String.Index) -> HTMLTagToken? {
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
            return HTMLTagToken(
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
            return HTMLTagToken(
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

        return HTMLTagToken(
            name: name,
            isClosing: false,
            attributes: attributes,
            rawRange: startIndex..<endIndex,
            endIndex: endIndex
        )
    }

    static func tagEndIndex(in source: String, after startIndex: String.Index) -> String.Index? {
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

    static func attributesSourceWithoutTrailingSlash(_ source: String) -> String? {
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

    static func parseAttributes(_ source: String) -> [HTMLAttribute]? {
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

            attributes.append(HTMLAttribute(name: name, value: decodeEntities(value)))
        }
    }

    static func indexAfterRawTextElement(
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

    static func skipWhitespace(in source: String, index: inout String.Index) {
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
    }

    static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == ":"
    }

    static func isAttributeNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == ":"
    }
    private static let entityRegex = try! NSRegularExpression(pattern: #"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[a-zA-Z]+);?"#)

    static func decodeEntities(_ source: String) -> String {
        var result = source
        let named = ["quot": "\"", "apos": "'", "lt": "<", "gt": ">", "amp": "&", "colon": ":", "Tab": "\t", "NewLine": "\n"]
        for match in entityRegex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range, in: source), let keyRange = Range(match.range(at: 1), in: source) else { continue }
            let key = String(source[keyRange])
            var replacement = named[key]
            if key.hasPrefix("#") {
                let hex = key.lowercased().hasPrefix("#x")
                if let number = UInt32(key.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                   let scalar = UnicodeScalar(number), number != 0 {
                    replacement = String(scalar)
                }
            }
            if let replacement { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}

struct HTMLTagToken {
    let name: String
    let isClosing: Bool
    let attributes: [HTMLAttribute]
    let rawRange: Range<String.Index>
    let endIndex: String.Index

    var isContentSecurityPolicyMeta: Bool {
        firstAttribute(named: "http-equiv")?.decodedValue.lowercased() == "content-security-policy"
    }

    func hasAttribute(named name: String) -> Bool {
        attributes.contains { $0.name == name }
    }

    func firstAttribute(named name: String) -> HTMLAttribute? {
        attributes.first { $0.name == name }
    }
}

struct HTMLAttribute {
    let name: String
    let value: String

    var decodedValue: String {
        value
    }
}

struct HTMLSourceSetCandidate {
    let source: String
    let descriptor: String?
}
