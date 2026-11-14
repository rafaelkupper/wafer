import Foundation

public enum MarkdownSourceDecoding {
    /// A bounded file prefix can end inside a UTF-8 scalar or UTF-16 pair.
    /// Only discard an incomplete trailing scalar, never a malformed interior.
    public static func decodePrefix(_ data: Data, truncated: Bool) -> String? {
        guard truncated else { return decode(data) }
        let isUTF16 = data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE])
            || looksLikeUTF16LittleEndian(data) || looksLikeUTF16BigEndian(data)
        if isUTF16 {
            var prefix = data
            if !prefix.count.isMultiple(of: 2) { prefix.removeLast() }
            if let result = decode(prefix) { return result }
            return prefix.count >= 2 ? decode(Data(prefix.dropLast(2))) : ""
        }
        for dropped in 0...min(3, data.count) {
            if let result = String(data: data.dropLast(dropped), encoding: .utf8) { return result }
        }
        return nil
    }

    public static func decode(_ data: Data) -> String? {
        decodeDetectingEncoding(data)?.text
    }

    /// Decodes like `decode(_:)` and also reports which encoding and byte-order
    /// mark were found, so an editor can write the file back the same way.
    /// Foundation strips the byte-order mark from the decoded text.
    public static func decodeDetectingEncoding(
        _ data: Data
    ) -> (text: String, encoding: MarkdownTextEncoding, hasByteOrderMark: Bool)? {
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .unicode).map { ($0, .utf16BigEndian, true) }
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .unicode).map { ($0, .utf16LittleEndian, true) }
        }

        if data.count >= 2, data.count.isMultiple(of: 2) {
            if looksLikeUTF16LittleEndian(data) {
                return String(data: data, encoding: .utf16LittleEndian).map { ($0, .utf16LittleEndian, false) }
            }
            if looksLikeUTF16BigEndian(data) {
                return String(data: data, encoding: .utf16BigEndian).map { ($0, .utf16BigEndian, false) }
            }
        }

        if let decoded = String(data: data, encoding: .utf8) {
            return (decoded, .utf8, data.starts(with: [0xEF, 0xBB, 0xBF]))
        }

        return nil
    }

    private static func looksLikeUTF16LittleEndian(_ data: Data) -> Bool {
        let bytes = Array(data.prefix(512))
        let pairCount = bytes.count / 2
        guard pairCount >= 2 else {
            return false
        }

        let oddZeroCount = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        return oddZeroCount * 2 >= pairCount
    }

    private static func looksLikeUTF16BigEndian(_ data: Data) -> Bool {
        let bytes = Array(data.prefix(512))
        let pairCount = bytes.count / 2
        guard pairCount >= 2 else {
            return false
        }

        let evenZeroCount = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        return evenZeroCount * 2 >= pairCount
    }
}
