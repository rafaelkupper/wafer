import Foundation
import UniformTypeIdentifiers

public struct PreviewComposition: Equatable, Sendable {
    public let html: String
    public let attachments: [String: URL]
    public let title: String
    public let truncated: Bool
    fileprivate let attachmentContainments: [String: FileContainment]

    public init(html: String, attachments: [String: URL], title: String, truncated: Bool) {
        self.html = html
        self.attachments = attachments
        self.attachmentContainments = attachments.mapValues {
            FileContainment(rootDirectory: $0.deletingLastPathComponent())
        }
        self.title = title
        self.truncated = truncated
    }
}

public enum PreviewComposerError: Error, Equatable {
    case undecodableFile(URL)
}

public struct PreviewComposer {
    public static let sourceByteLimit = 2 * 1024 * 1024
    public static let attachmentByteLimit = 10 * 1024 * 1024

    private let allowsLocalImages: Bool

    /// Finder's sandbox grants the requested file, not general access to its siblings.
    public init(allowsLocalImages: Bool = true) { self.allowsLocalImages = allowsLocalImages }

    public func compose(fileURL: URL, isDark: Bool, cancellation: WorkCancellation? = nil) throws -> PreviewComposition {
        let prefix = try BoundedFileReader.prefix(from: fileURL, maximumByteCount: Self.sourceByteLimit)
        guard let decoded = MarkdownSourceDecoding.decodePrefix(prefix.data, truncated: prefix.truncated) else {
            throw PreviewComposerError.undecodableFile(fileURL)
        }

        if cancellation?.isCancelled == true { throw CancellationError() }
        let preparedSource = Self.sourceWithinPreviewBudget(decoded, truncated: prefix.truncated)
        let document = MarkdownParser().parse(source: preparedSource.source, baseURL: fileURL)
        let palette: ReaderThemePalette = isDark ? .dark : .light
        if cancellation?.isCancelled == true { throw CancellationError() }
        let renderOutput = WebKitHTMLRenderer(palette: palette, target: .preview, allowsPreviewLocalImages: allowsLocalImages).render(document: document)
        let title = DocumentSidebarDataBuilder.documentDisplayTitle(for: document, fallbackURL: fileURL)

        let attachments = Self.attachmentsWithinPreviewBudget(renderOutput.previewAttachments)

        return PreviewComposition(
            html: Self.removingSkippedAttachments(from: renderOutput.html, acceptedAttachmentKeys: Set(attachments.keys)),
            attachments: attachments,
            title: title,
            truncated: preparedSource.truncated
        )
    }

    /// Recheck attachment sizes at read time and build the HTML in a single pass.
    public static func inliningAttachments(in composition: PreviewComposition, cancellation: WorkCancellation? = nil) throws -> String {
        let html = composition.html
        let regex = try NSRegularExpression(pattern: #"<img\b[^>]*\bsrc="cid:([^"]+)"[^>]*>"#)
        var result = ""
        var cursor = html.startIndex
        var remaining = attachmentByteLimit
        for match in regex.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)) {
            if cancellation?.isCancelled == true { throw CancellationError() }
            guard let range = Range(match.range, in: html), let keyRange = Range(match.range(at: 1), in: html) else { continue }
            result += html[cursor..<range.lowerBound]
            let key = String(html[keyRange])
            let data: Data?
            if let url = composition.attachments[key] {
                do {
                    guard composition.attachmentContainments[key]?.contains(url) == true else {
                        throw CocoaError(.fileReadNoPermission)
                    }
                    data = try BoundedFileReader.read(from: url, maximumByteCount: remaining)
                } catch {
                    WaferLog.rendering.info("Preview omitted image \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                    data = nil
                }
            } else {
                data = nil
            }
            if let url = composition.attachments[key], let data {
                remaining -= data.count
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let image = String(html[range]).replacingOccurrences(of: "cid:" + key, with: "data:\(mime);base64,\(data.base64EncodedString())")
                result += image
            } else {
                result += #"<p class="fallback-block">[Image omitted]</p>"#
            }
            cursor = range.upperBound
        }
        result += html[cursor...]
        return result
    }

    private static func sourceWithinPreviewBudget(_ source: String, truncated: Bool) -> (source: String, truncated: Bool) {
        guard truncated || source.utf8.count > sourceByteLimit else {
            return (source, false)
        }

        var byteCount = 0
        var limitIndex = source.startIndex
        while limitIndex < source.endIndex {
            let nextIndex = source.index(after: limitIndex)
            let characterByteCount = String(source[limitIndex..<nextIndex]).utf8.count
            guard byteCount + characterByteCount <= sourceByteLimit else {
                break
            }
            byteCount += characterByteCount
            limitIndex = nextIndex
        }

        let prefix = String(source[..<limitIndex])
        let boundary = prefix.range(of: "\n", options: .backwards)?.lowerBound ?? prefix.endIndex
        let truncated = String(prefix[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        let note = "> Preview truncated — open in Wafer for the full document."
        let prepared = truncated.isEmpty ? note : "\(truncated)\n\n\(note)"
        return (prepared, true)
    }

    private static func attachmentsWithinPreviewBudget(_ attachments: [String: URL]) -> [String: URL] {
        var remainingBytes = attachmentByteLimit
        var accepted: [String: URL] = [:]

        for key in attachments.keys.sorted() {
            guard
                let fileURL = attachments[key],
                let fileSize = fileSize(for: fileURL),
                fileSize <= remainingBytes
            else {
                continue
            }

            accepted[key] = fileURL
            remainingBytes -= fileSize
        }

        return accepted
    }

    private static func removingSkippedAttachments(from html: String, acceptedAttachmentKeys: Set<String>) -> String {
        let cidPattern = #"<img\b[^>]*\bsrc="cid:([^"]+)"[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: cidPattern) else {
            return html
        }

        var result = ""
        var cursor = html.startIndex
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html))

        for match in matches {
            guard
                let matchRange = Range(match.range(at: 0), in: html),
                let cidRange = Range(match.range(at: 1), in: html)
            else {
                continue
            }

            result.append(contentsOf: html[cursor..<matchRange.lowerBound])
            let cid = String(html[cidRange])
            if acceptedAttachmentKeys.contains(cid) {
                result.append(contentsOf: html[matchRange])
            } else {
                result.append(#"<p class="fallback-block">[Image omitted]</p>"#)
            }
            cursor = matchRange.upperBound
        }

        result.append(contentsOf: html[cursor...])
        return result
    }

    private static func fileSize(for fileURL: URL) -> Int? {
        guard
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            let fileSize = values.fileSize
        else {
            return nil
        }

        return fileSize
    }
}
