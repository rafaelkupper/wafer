import AppKit
import Foundation

/// Converts composed Quick Look HTML into the attributed text the native
/// preview shows. Kept in the core so it can be tested; the extension target is
/// an executable and cannot be imported by tests.
public enum PreviewAttributedText {
    /// Imports `html` as rich text and applies the palette's text and
    /// background colors. Falls back to tag-stripped plain text when AppKit's
    /// HTML import fails.
    public static func make(
        html: String,
        palette: ReaderThemePalette,
        importHTML: (Data) -> NSAttributedString? = Self.importHTML
    ) -> NSAttributedString {
        let attributed = importHTML(Data(html.utf8)).map(NSMutableAttributedString.init(attributedString:))
            ?? NSMutableAttributedString(string: fallbackText(from: html))
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes(
            [
                .foregroundColor: ReaderTheme.color(fromHex: palette.textHex),
                .backgroundColor: ReaderTheme.color(fromHex: palette.backgroundHex),
            ],
            range: fullRange
        )
        return attributed
    }

    public static func importHTML(_ data: Data) -> NSAttributedString? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        return try? NSAttributedString(data: data, options: options, documentAttributes: nil)
    }

    /// Plain-text rendering of `html` used when rich import fails.
    public static func fallbackText(from html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
