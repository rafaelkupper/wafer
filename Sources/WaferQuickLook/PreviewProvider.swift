import AppKit
import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import WaferCore

@objc(PreviewProvider)
final class PreviewProvider: NSViewController, @preconcurrency QLPreviewingController {
    private let queue = DispatchQueue(label: "dev.wafer.preview", qos: .userInitiated)
    private var request: PreviewRequest?
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
        request?.cancel()
        let request = PreviewRequest(handler)
        self.request = request
        let token = request.cancellation
        let isDark = Self.isDarkAppearance
        queue.async { [weak self] in
            let result: Result<(String, String), Error>
            do {
                guard !token.isCancelled else { throw CancellationError() }
                let composition = try PreviewComposer(allowsLocalImages: false).compose(fileURL: url, isDark: isDark, cancellation: token)
                let html = try PreviewComposer.inliningAttachments(in: composition, cancellation: token)
                result = .success((composition.title, html))
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { request.cancel(); request.finish(); return }
                switch result {
                case .success(let (title, html)):
                    request.finish {
                        self.title = title
                        self.applyPreviewHTML(html, palette: isDark ? .dark : .light)
                    }
                case .failure(let error): request.finish(error: error)
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
        let attributed = PreviewAttributedText.make(html: html, palette: palette)
        let textView = previewTextView
        textView.backgroundColor = ReaderTheme.color(fromHex: palette.backgroundHex)
        textView.insertionPointColor = ReaderTheme.color(fromHex: palette.textHex)
        textView.textStorage?.setAttributedString(attributed)
        textView.scrollToBeginningOfDocument(nil)
    }

    private static var isDarkAppearance: Bool {
        let appearanceMatch = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua])
        return PreviewAppearance.isDark(
            matchedAppearanceIsDark: appearanceMatch.map { $0 == .darkAqua },
            interfaceStyle: UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        )
    }
}
