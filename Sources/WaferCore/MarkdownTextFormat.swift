import Foundation

public enum MarkdownTextEncoding: Equatable, Sendable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
}

public enum MarkdownLineEnding: String, Equatable, Sendable {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"
}

/// How a Markdown file is stored on disk: encoding, byte-order mark, and the
/// dominant line ending. The editor works on LF-normalized text; saving
/// converts back so files keep their original shape.
public struct MarkdownTextFormat: Equatable, Sendable {
    public var encoding: MarkdownTextEncoding
    public var hasByteOrderMark: Bool
    public var lineEnding: MarkdownLineEnding

    public static let `default` = MarkdownTextFormat(encoding: .utf8, hasByteOrderMark: false, lineEnding: .lf)

    public init(encoding: MarkdownTextEncoding, hasByteOrderMark: Bool, lineEnding: MarkdownLineEnding) {
        self.encoding = encoding
        self.hasByteOrderMark = hasByteOrderMark
        self.lineEnding = lineEnding
    }

    /// Decodes file bytes and reports their format. Returns nil for bytes
    /// `MarkdownSourceDecoding` cannot decode.
    public static func decode(_ data: Data) -> (text: String, format: MarkdownTextFormat)? {
        guard let decoded = MarkdownSourceDecoding.decodeDetectingEncoding(data) else {
            return nil
        }

        let format = MarkdownTextFormat(
            encoding: decoded.encoding,
            hasByteOrderMark: decoded.hasByteOrderMark,
            lineEnding: dominantLineEnding(in: decoded.text)
        )
        return (decoded.text, format)
    }

    /// The most frequent line ending. Ties and text without line breaks
    /// resolve to LF, then CRLF.
    public static func dominantLineEnding(in text: String) -> MarkdownLineEnding {
        var lf = 0
        var crlf = 0
        var cr = 0
        var previousWasCR = false
        for unit in text.utf16 {
            if unit == 0x0A {
                if previousWasCR {
                    crlf += 1
                    cr -= 1
                } else {
                    lf += 1
                }
                previousWasCR = false
            } else if unit == 0x0D {
                cr += 1
                previousWasCR = true
            } else {
                previousWasCR = false
            }
        }

        if crlf > lf, crlf >= cr {
            return .crlf
        }
        if cr > lf, cr > crlf {
            return .cr
        }
        return .lf
    }

    /// Converts CRLF and lone CR to LF.
    public static func normalizingLineEndings(_ text: String) -> String {
        guard text.utf16.contains(0x0D) else {
            return text
        }

        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Encodes LF-normalized text in this format.
    public func encode(_ input: String) -> Data {
        let normalizedText = Self.normalizingLineEndings(input)
        let text = lineEnding == .lf
            ? normalizedText
            : normalizedText.replacingOccurrences(of: "\n", with: lineEnding.rawValue)

        var data = Data()
        switch encoding {
        case .utf8:
            if hasByteOrderMark {
                data.append(contentsOf: [0xEF, 0xBB, 0xBF])
            }
            data.append(contentsOf: Array(text.utf8))
        case .utf16LittleEndian:
            if hasByteOrderMark {
                data.append(contentsOf: [0xFF, 0xFE])
            }
            data.reserveCapacity(data.count + text.utf16.count * 2)
            for unit in text.utf16 {
                data.append(UInt8(unit & 0xFF))
                data.append(UInt8(unit >> 8))
            }
        case .utf16BigEndian:
            if hasByteOrderMark {
                data.append(contentsOf: [0xFE, 0xFF])
            }
            data.reserveCapacity(data.count + text.utf16.count * 2)
            for unit in text.utf16 {
                data.append(UInt8(unit >> 8))
                data.append(UInt8(unit & 0xFF))
            }
        }
        return data
    }
}
