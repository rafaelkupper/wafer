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
            includesMermaid ? scriptTag(url: mermaidRuntimeURL, nonce: nonce) : nil,
            includesMath ? scriptTag(url: mathRuntimeURL, nonce: nonce) : nil,
        ]
            .compactMap { $0 }
            .joined(separator: "\n")

        return """
        \(externalScripts)
        <script nonce="\(nonce.escapedHTMLAttribute)" data-wafer-renderer="\(rendererConfiguration(for: palette).escapedHTMLAttribute)">
        \(asyncRendererScript ?? "")
        \(includesMermaid ? (mermaidScript ?? "") : "")
        \(includesMath ? (mathScript ?? "") : "")
        </script>
        """
    }

    private static func scriptTag(url: URL?, nonce: String) -> String {
        guard let scriptURL = url else {
            return ""
        }

        let source = WebKitAssetURLs.local(for: scriptURL)
        return "<script src=\"\(source.escapedHTMLAttribute)\" nonce=\"\(nonce.escapedHTMLAttribute)\"></script>"
    }

    static let katexStyleSheet: String? = {
        guard let url = ReaderTheme.resourceURL(named: "katex/katex.min.css") else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8).replacingKaTeXFontURLs()
        } catch {
            WaferLog.resources.fault("KaTeX CSS is unreadable; math stays as a code fence.")
            return nil
        }
    }()

    static var canRenderMermaid: Bool {
        mermaidRuntimeURL != nil && asyncRendererScript != nil && mermaidScript != nil
    }

    static var canRenderMath: Bool {
        mathRuntimeURL != nil && asyncRendererScript != nil && mathScript != nil && katexStyleSheet != nil
    }

    private static let mermaidRuntimeURL = ReaderTheme.resourceURL(named: "mermaid.min.js")
    private static let mathRuntimeURL = ReaderTheme.resourceURL(named: "katex/katex.min.js")
    private static let asyncRendererScript = bundledScript(named: "async-renderer.js")
    private static let mermaidScript = bundledScript(named: "mermaid-bootstrap.js")
    private static let mathScript = bundledScript(named: "katex-bootstrap.js")

    static func bundledScript(named name: String) -> String? {
        guard let url = ReaderTheme.resourceURL(named: name) else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            WaferLog.resources.fault("Renderer resource \(name, privacy: .public) is unreadable; affected fences stay as code.")
            return nil
        }
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
    static let katexFontURLRegex = try! NSRegularExpression(pattern: #"url\((['"]?)(fonts/[^)'"]+)\1\)"#)

    func replacingKaTeXFontURLs() -> String {
        var result = self
        let matches = Self.katexFontURLRegex.matches(in: self, range: NSRange(startIndex..<endIndex, in: self))
        for match in matches.reversed() where match.numberOfRanges >= 3 {
            guard
                let fullRange = Range(match.range(at: 0), in: result),
                let fontRange = Range(match.range(at: 2), in: result)
            else {
                continue
            }

            let fontPath = String(result[fontRange])
            if let fontURL = ReaderTheme.resourceURL(named: "katex/\(fontPath)") {
                let assetURL = WebKitAssetURLs.local(for: fontURL)
                result.replaceSubrange(fullRange, with: "url('\(assetURL.escapedCSSString)')")
            } else {
                // A missing bundled face falls back to the system's serif font.
                result.replaceSubrange(fullRange, with: "local('serif')")
            }
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
