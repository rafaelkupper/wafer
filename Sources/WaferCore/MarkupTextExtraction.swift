import Foundation
import Markdown

extension Markup {
    var plainText: String {
        switch self {
        case let text as Text:
            text.string
        case is SoftBreak:
            " "
        case is LineBreak:
            "\n"
        case let inlineCode as InlineCode:
            inlineCode.code
        case let symbolLink as SymbolLink:
            symbolLink.destination ?? ""
        case let inlineAttributes as InlineAttributes:
            inlineAttributes.children.map(\.plainText).joined()
        case let inlineHTML as InlineHTML:
            plainText(fromInlineHTML: inlineHTML)
        case let html as HTMLBlock:
            MarkdownSemanticSupport.strippedHTMLText(from: html.format())
        case let blockQuote as BlockQuote:
            plainText(fromBlockQuote: blockQuote)
        case let directive as BlockDirective:
            plainText(fromBlockDirective: directive)
        default:
            children.map(\.plainText).joined()
        }
    }

    private func plainText(fromInlineHTML inlineHTML: InlineHTML) -> String {
        let source = inlineHTML.format()
        if MarkdownSemanticSupport.inlineHTMLTransition(from: source) == "kbd" {
            return ""
        }

        return MarkdownSemanticSupport.strippedHTMLText(from: source)
    }

    private func plainText(fromBlockQuote blockQuote: BlockQuote) -> String {
        if let alert = MarkdownSemanticSupport.gitHubAlert(for: blockQuote) {
            let body = MarkdownSemanticSupport.gitHubAlertBodyPlainText(from: blockQuote, alert: alert)
            return body.isEmpty ? alert.definition.label : "\(alert.definition.label) \(body)"
        }

        return blockQuote.children.map(\.plainText).joined()
    }

    private func plainText(fromBlockDirective directive: BlockDirective) -> String {
        if let callout = MarkdownSemanticSupport.calloutDefinition(for: directive) {
            let body = directive.children
                .map(\.plainText)
                .map(\.collapsingWhitespace)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return body.isEmpty ? callout.label : "\(callout.label) \(body)"
        }

        return directive.format()
    }
}
