import AppKit
import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import WaferCore

@objc(PreviewProvider)
final class PreviewProvider: NSViewController, @preconcurrency QLPreviewingController {
    private let queue = DispatchQueue(label: "dev.wafer.preview", qos: .userInitiated)
    private var cancellation: WorkCancellation?
    private var textView: NSTextView?

    override func loadView() {
        let frame = NSRect(x: 0, y: 0, width: 820, height: 640)
        let scrollView = NSScrollView(frame: frame)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 28, height: 20)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        scrollView.documentView = textView
        self.textView = textView
        view = scrollView
        preferredContentSize = frame.size
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        cancellation?.cancel()
        let token = WorkCancellation()
        cancellation = token
        let isDark = Self.isDarkAppearance
        let callback = PreviewCompletion(handler)
        queue.async { [weak self] in
            let result: Result<(String, String), Error>
            do {
                guard !token.isCancelled else { throw CancellationError() }
                let composition = try PreviewComposer().compose(fileURL: url, isDark: isDark, cancellation: token)
                let html = try PreviewComposer.inliningAttachments(in: composition, cancellation: token)
                result = .success((composition.title, html))
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !token.isCancelled else { callback.handler(CancellationError()); return }
                switch result {
                case .success(let (title, html)):
                    self.title = title
                    // AppKit's HTML importer and text storage stay on the main thread.
                    self.applyPreviewHTML(html, palette: isDark ? .dark : .light)
                    callback.handler(nil)
                case .failure(let error): callback.handler(error)
                }
            }
        }
    }

    private var previewTextView: NSTextView {
        if let textView {
            return textView
        }
        loadViewIfNeeded()
        guard let textView else {
            preconditionFailure("Preview text view was not created.")
        }
        return textView
    }

    private func applyPreviewHTML(_ html: String, palette: ReaderThemePalette) {
        let attributed = Self.attributedPreview(from: html, palette: palette)
        let textView = previewTextView
        textView.backgroundColor = Self.color(from: palette.backgroundHex)
        textView.insertionPointColor = Self.color(from: palette.textHex)
        textView.textStorage?.setAttributedString(attributed)
        textView.scrollToBeginningOfDocument(nil)
    }

    private static func attributedPreview(from html: String, palette: ReaderThemePalette) -> NSAttributedString {
        let data = Data(html.utf8)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        let attributed = (
            try? NSMutableAttributedString(
                data: data,
                options: options,
                documentAttributes: nil
            )
        ) ?? NSMutableAttributedString(string: fallbackText(from: html))

        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes(
            [
                .foregroundColor: color(from: palette.textHex),
                .backgroundColor: color(from: palette.backgroundHex),
            ],
            range: fullRange
        )
        return attributed
    }

    private static var isDarkAppearance: Bool {
        let appearanceMatch = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua])
        if appearanceMatch == .darkAqua {
            return true
        }
        if appearanceMatch == .aqua {
            return false
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private static func fallbackText(from html: String) -> String {
        let withoutTags = html.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        return withoutTags
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func color(from hex: String) -> NSColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)

        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64
        if digits.count == 8 {
            red = (value >> 24) & 0xFF
            green = (value >> 16) & 0xFF
            blue = (value >> 8) & 0xFF
            alpha = value & 0xFF
        } else {
            red = (value >> 16) & 0xFF
            green = (value >> 8) & 0xFF
            blue = value & 0xFF
            alpha = 0xFF
        }

        return NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }

}

private final class PreviewCompletion: @unchecked Sendable {
    let handler: (Error?) -> Void
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
}
