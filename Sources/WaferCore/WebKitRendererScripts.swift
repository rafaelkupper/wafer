import Foundation

extension WebKitHTMLRenderer {
    static func scriptNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func contentSecurityPolicy(allowsPageScripts: Bool, scriptNonce: String) -> String {
        let scriptSource = allowsPageScripts ? "'nonce-\(scriptNonce)'" : "'none'"
        return [
            "default-src 'none'",
            "img-src wafer-local: wafer-remote:",
            "style-src 'unsafe-inline' wafer-local:",
            "font-src wafer-local:",
            "connect-src 'none'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            "script-src \(scriptSource)",
        ].joined(separator: "; ") + ";"
    }

    static func rendererScripts(
        nonce: String,
        palette: ReaderThemePalette,
        includesMermaid: Bool,
        includesMath: Bool
    ) -> String {
        let externalScripts = [
            includesMermaid ? scriptTag(resourceName: "mermaid.min.js", nonce: nonce) : nil,
            includesMath ? scriptTag(resourceName: "katex/katex.min.js", nonce: nonce) : nil,
        ]
            .compactMap { $0 }
            .joined(separator: "\n")

        return """
        \(externalScripts)
        <script nonce="\(nonce.escapedHTMLAttribute)" data-wafer-renderer="\(rendererConfiguration(for: palette).escapedHTMLAttribute)">
        \(asyncRendererScript)
        \(includesMermaid ? mermaidScript : "")
        \(includesMath ? mathScript : "")
        </script>
        """
    }

    private static func scriptTag(resourceName: String, nonce: String) -> String {
        guard let scriptURL = ReaderTheme.resourceURL(named: resourceName) else {
            return ""
        }

        let source = WebKitAssetURLs.local(for: scriptURL)
        return "<script src=\"\(source.escapedHTMLAttribute)\" nonce=\"\(nonce.escapedHTMLAttribute)\"></script>"
    }

    static func katexStyleSheet() -> String {
        guard
            let styleSheetURL = ReaderTheme.resourceURL(named: "katex/katex.min.css"),
            let styleSheet = try? String(contentsOf: styleSheetURL, encoding: .utf8)
        else {
            return ""
        }

        return styleSheet.replacingKaTeXFontURLs(relativeTo: styleSheetURL)
    }

    private static let asyncRendererScript = bundledScript(named: "async-renderer.js")
    private static let mermaidScript = bundledScript(named: "mermaid-bootstrap.js")
    private static let mathScript = bundledScript(named: "katex-bootstrap.js")

    private static func bundledScript(named name: String) -> String {
        guard let url = ReaderTheme.resourceURL(named: name), let script = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing renderer resource: \(name)")
        }
        return script
    }

    private static func rendererConfiguration(for palette: ReaderThemePalette) -> String {
        let variables = Dictionary(palette.mermaid.themeVariables + [("fontFamily", palette.mermaid.fontFamily)], uniquingKeysWith: { _, last in last })
        let configuration: [String: Any] = [
            "theme": palette.mermaid.theme, "variables": variables,
            "chromeAttributeName": ExportSanitizer.chromeAttributeName,
            "chromeAttributeValue": ExportSanitizer.chromeAttributeValue,
        ]
        let data = try! JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

}

private extension String {
    func replacingKaTeXFontURLs(relativeTo styleSheetURL: URL) -> String {
        let pattern = #"url\((['"]?)(fonts/[^)'"]+)\1\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return self
        }

        var result = self
        let matches = regex.matches(in: self, range: NSRange(startIndex..<endIndex, in: self))
        for match in matches.reversed() where match.numberOfRanges >= 3 {
            guard
                let fullRange = Range(match.range(at: 0), in: result),
                let fontRange = Range(match.range(at: 2), in: result)
            else {
                continue
            }

            let fontPath = String(result[fontRange])
            let fontURL = ReaderTheme.resourceURL(named: "katex/\(fontPath)")
                ?? ReaderTheme.resourceURL(named: fontPath)
                ?? styleSheetURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(fontPath)
            let assetURL = WebKitAssetURLs.local(for: fontURL)
            result.replaceSubrange(fullRange, with: "url('\(assetURL.escapedCSSString)')")
        }
        return result
    }

    var escapedCSSString: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\a ")
            .replacingOccurrences(of: "\r", with: "\\d ")
    }
}

