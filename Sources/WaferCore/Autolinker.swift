import Foundation

enum Autolinker {
    enum Segment: Equatable {
        case plain(String)
        case link(text: String, href: String)
    }

    private struct Candidate {
        let text: String
        let href: String
        let endIndex: String.Index
    }

    static func segments(in text: String) -> [Segment] {
        guard text.contains(":")
            || text.contains("@")
            || text.range(of: "www.", options: [.caseInsensitive]) != nil
        else {
            return [.plain(text)]
        }

        var segments: [Segment] = []
        var plainStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            if let candidate = candidate(in: text, at: index) {
                appendPlain(text[plainStart..<index], to: &segments)
                segments.append(.link(text: candidate.text, href: candidate.href))
                index = candidate.endIndex
                plainStart = index
            } else {
                index = text.index(after: index)
            }
        }

        appendPlain(text[plainStart..<text.endIndex], to: &segments)
        return segments
    }

    private static func appendPlain(_ text: Substring, to segments: inout [Segment]) {
        guard !text.isEmpty else {
            return
        }

        segments.append(.plain(String(text)))
    }

    private static func candidate(in text: String, at index: String.Index) -> Candidate? {
        urlCandidate(in: text, at: index) ?? emailCandidate(in: text, at: index)
    }

    private static func urlCandidate(in text: String, at index: String.Index) -> Candidate? {
        guard hasURLLeftBoundary(in: text, at: index) else {
            return nil
        }

        let prefix: String
        let hrefPrefix: String
        if hasCaseInsensitivePrefix("https://", in: text, at: index) {
            prefix = "https://"
            hrefPrefix = ""
        } else if hasCaseInsensitivePrefix("http://", in: text, at: index) {
            prefix = "http://"
            hrefPrefix = ""
        } else if hasCaseInsensitivePrefix("www.", in: text, at: index) {
            prefix = "www."
            hrefPrefix = "http://"
        } else {
            return nil
        }

        let rawEnd = urlCandidateEnd(in: text, from: index)
        guard rawEnd > index else {
            return nil
        }

        let trimmedEnd = trimmedURLEnd(in: text, start: index, end: rawEnd)
        guard trimmedEnd > index else {
            return nil
        }

        let linkText = String(text[index..<trimmedEnd])
        guard hasValidHost(in: linkText, prefixLength: prefix.count) else {
            return nil
        }

        return Candidate(text: linkText, href: hrefPrefix + linkText, endIndex: trimmedEnd)
    }

    private static func emailCandidate(in text: String, at index: String.Index) -> Candidate? {
        guard hasEmailLeftBoundary(in: text, at: index), isEmailLocalCharacter(text[index]) else {
            return nil
        }

        var cursor = index
        while cursor < text.endIndex, isEmailLocalCharacter(text[cursor]) {
            cursor = text.index(after: cursor)
        }

        guard
            cursor < text.endIndex,
            text[cursor] == "@",
            cursor > index,
            text[text.index(before: cursor)] != "."
        else {
            return nil
        }

        cursor = text.index(after: cursor)
        let domainStart = cursor
        var sawDot = false
        var lastLabelLength = 0

        while cursor < text.endIndex {
            let labelStart = cursor
            while cursor < text.endIndex, isEmailDomainCharacter(text[cursor]) {
                cursor = text.index(after: cursor)
            }

            let labelLength = text.distance(from: labelStart, to: cursor)
            guard labelLength > 0 else {
                break
            }

            let labelEnd = text.index(before: cursor)
            guard text[labelStart] != "-", text[labelEnd] != "-" else {
                return nil
            }

            lastLabelLength = labelLength

            guard cursor < text.endIndex, text[cursor] == "." else {
                break
            }

            let afterDot = text.index(after: cursor)
            guard afterDot < text.endIndex, isEmailDomainAlphanumeric(text[afterDot]) else {
                break
            }

            sawDot = true
            cursor = afterDot
        }

        guard cursor > domainStart, sawDot, lastLabelLength >= 2 else {
            return nil
        }

        let linkText = String(text[index..<cursor])
        return Candidate(text: linkText, href: "mailto:\(linkText)", endIndex: cursor)
    }

    private static func hasCaseInsensitivePrefix(_ prefix: String, in text: String, at index: String.Index) -> Bool {
        guard let end = text.index(index, offsetBy: prefix.count, limitedBy: text.endIndex) else {
            return false
        }

        return text[index..<end].lowercased() == prefix
    }

    private static func urlCandidateEnd(in text: String, from index: String.Index) -> String.Index {
        var cursor = index
        while cursor < text.endIndex, !isURLTerminator(text[cursor]) {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private static func trimmedURLEnd(in text: String, start: String.Index, end: String.Index) -> String.Index {
        var trimmedEnd = end
        while trimmedEnd > start {
            let lastIndex = text.index(before: trimmedEnd)
            let character = text[lastIndex]
            guard isTrailingURLPunctuation(character) else {
                break
            }

            if character == ")" {
                let candidate = text[start..<trimmedEnd]
                let opens = candidate.filter { $0 == "(" }.count
                let closes = candidate.filter { $0 == ")" }.count
                guard closes > opens else {
                    break
                }
            }

            trimmedEnd = lastIndex
        }
        return trimmedEnd
    }

    private static func hasValidHost(in linkText: String, prefixLength: Int) -> Bool {
        guard let hostStart = linkText.index(linkText.startIndex, offsetBy: prefixLength, limitedBy: linkText.endIndex),
              hostStart < linkText.endIndex else {
            return false
        }

        let hostEnd = linkText[hostStart...].firstIndex { character in
            character == "/" || character == "?" || character == "#" || character == ":"
        } ?? linkText.endIndex
        let host = linkText[hostStart..<hostEnd]
        return host.contains(where: isHostCharacter)
    }

    private static func hasURLLeftBoundary(in text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else {
            return true
        }

        let previous = text[text.index(before: index)]
        return !(isASCIILetter(previous) || isASCIIDigit(previous) || previous == "_")
    }

    private static func hasEmailLeftBoundary(in text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else {
            return true
        }

        let previous = text[text.index(before: index)]
        return !isEmailLocalCharacter(previous) && !isEmailDomainCharacter(previous)
    }

    private static func isURLTerminator(_ character: Character) -> Bool {
        character == "<" || character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func isTrailingURLPunctuation(_ character: Character) -> Bool {
        switch character {
        case "?", "!", ".", ",", ":", "*", "_", "~", "'", "\"", ";", ")", "]":
            return true
        default:
            return false
        }
    }

    private static func isEmailLocalCharacter(_ character: Character) -> Bool {
        isASCIILetter(character)
            || isASCIIDigit(character)
            || ".!#$%&'*+/=?^_`{|}~-".contains(character)
    }

    private static func isEmailDomainCharacter(_ character: Character) -> Bool {
        isEmailDomainAlphanumeric(character) || character == "-"
    }

    private static func isEmailDomainAlphanumeric(_ character: Character) -> Bool {
        isASCIILetter(character) || isASCIIDigit(character)
    }

    private static func isHostCharacter(_ character: Character) -> Bool {
        isASCIILetter(character) || isASCIIDigit(character)
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.only else {
            return false
        }
        return (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.only else {
            return false
        }
        return (48...57).contains(scalar.value)
    }
}

private extension String.UnicodeScalarView {
    var only: UnicodeScalar? {
        count == 1 ? first : nil
    }
}
