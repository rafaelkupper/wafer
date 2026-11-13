import Foundation

public struct FootnoteDefinition: Equatable, Sendable {
    public let label: String
    public let content: String

    public init(label: String, content: String) {
        self.label = label
        self.content = content
    }
}

enum MarkdownFootnoteSupport {
    struct Reference {
        let range: Range<String.Index>
        let normalizedLabel: String
    }

    static func normalizedLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func definitionMap(from definitions: [FootnoteDefinition]) -> [String: FootnoteDefinition] {
        var map: [String: FootnoteDefinition] = [:]
        for definition in definitions {
            let normalized = normalizedLabel(definition.label)
            guard !normalized.isEmpty, map[normalized] == nil else {
                continue
            }
            map[normalized] = definition
        }
        return map
    }

    static func references(in text: String) -> [Reference] {
        guard text.contains("[^") else {
            return []
        }

        var references: [Reference] = []
        var cursor = text.startIndex

        while let markerRange = text.range(of: "[^", range: cursor..<text.endIndex) {
            let labelStart = markerRange.upperBound
            guard let closingBracket = text[labelStart...].firstIndex(of: "]") else {
                break
            }

            let label = String(text[labelStart..<closingBracket])
            let normalized = normalizedLabel(label)
            let referenceEnd = text.index(after: closingBracket)
            if !normalized.isEmpty {
                references.append(Reference(
                    range: markerRange.lowerBound..<referenceEnd,
                    normalizedLabel: normalized
                ))
            }
            cursor = referenceEnd
        }

        return references
    }

    static func replacingKnownReferences(
        in text: String,
        knownLabels: Set<String>,
        replacement: (Reference) -> String
    ) -> String? {
        let references = references(in: text)
        guard references.contains(where: { knownLabels.contains($0.normalizedLabel) }) else {
            return nil
        }

        var output = ""
        var cursor = text.startIndex
        for reference in references {
            output.append(contentsOf: text[cursor..<reference.range.lowerBound])
            if knownLabels.contains(reference.normalizedLabel) {
                output.append(replacement(reference))
            } else {
                output.append(contentsOf: text[reference.range])
            }
            cursor = reference.range.upperBound
        }
        output.append(contentsOf: text[cursor...])
        return output
    }

    static func strippingKnownReferences(in text: String, knownLabels: Set<String>) -> String {
        replacingKnownReferences(in: text, knownLabels: knownLabels) { _ in "" } ?? text
    }
}

extension String {
    func strippingKnownFootnoteReferences(knownLabels: Set<String>) -> String {
        MarkdownFootnoteSupport.strippingKnownReferences(in: self, knownLabels: knownLabels)
    }
}
