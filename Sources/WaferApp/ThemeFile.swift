import Foundation
import WaferCore

struct ThemeFile: Codable, Equatable {
    let palette: ReaderThemePalette

    init(palette: ReaderThemePalette) {
        self.palette = palette
    }

    init(from decoder: Decoder) throws {
        palette = try ReaderThemePalette(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try palette.encode(to: encoder)
    }

    static func decodePalette(from data: Data, fileName: String) throws -> ReaderThemePalette {
        do {
            let file = try JSONDecoder().decode(ThemeFile.self, from: data)
            try validate(file.palette)
            return file.palette
        } catch let error as ThemeFileError {
            throw error
        } catch let DecodingError.keyNotFound(key, context) {
            throw ThemeFileError.missingKey(keyPath(context.codingPath + [key]))
        } catch let DecodingError.typeMismatch(_, context) {
            throw ThemeFileError.invalidValue(
                key: keyPath(context.codingPath),
                reason: context.debugDescription
            )
        } catch let DecodingError.valueNotFound(_, context) {
            throw ThemeFileError.invalidValue(
                key: keyPath(context.codingPath),
                reason: context.debugDescription
            )
        } catch let DecodingError.dataCorrupted(context) {
            throw ThemeFileError.invalidValue(
                key: keyPath(context.codingPath),
                reason: context.debugDescription
            )
        } catch {
            throw ThemeFileError.invalidValue(key: fileName, reason: error.localizedDescription)
        }
    }

    static func exampleData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ThemeFile(palette: .dark))
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        object["name"] = "Example"
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func validate(_ palette: ReaderThemePalette) throws {
        guard !palette.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ThemeFileError.invalidValue(key: "name", reason: "must not be empty")
        }

        try validateValue(palette, path: [])
    }

    private static func validateValue(_ value: Any, path: [String]) throws {
        if let color = value as? ReaderThemeColor {
            try validateHex(color.hex, key: keyPath(path + ["hex"]))
            guard (0...1).contains(color.alpha) else {
                throw ThemeFileError.invalidValue(
                    key: keyPath(path + ["alpha"]),
                    reason: "must be between 0 and 1"
                )
            }
            return
        }

        if let string = value as? String {
            let key = keyPath(path)
            guard nonColorStringKeys.contains(key) else {
                try validateHex(string, key: key)
                return
            }

            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ThemeFileError.invalidValue(key: key, reason: "must not be empty")
            }
            return
        }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            for child in mirror.children {
                try validateValue(child.value, path: path)
            }
            return
        }

        for child in mirror.children {
            guard let label = child.label else {
                continue
            }
            try validateValue(child.value, path: path + [label])
        }
    }

    private static func validateHex(_ value: String, key: String) throws {
        guard value.range(of: #"^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"#, options: .regularExpression) != nil else {
            throw ThemeFileError.invalidHex(key: key, value: value)
        }
    }

    private static func keyPath(_ path: [CodingKey]) -> String {
        keyPath(path.map(\.stringValue))
    }

    private static func keyPath(_ path: [String]) -> String {
        path.isEmpty ? "<root>" : path.joined(separator: ".")
    }

    private static let nonColorStringKeys: Set<String> = [
        "name",
        "mermaid.theme",
        "mermaid.fontFamily",
    ]
}

enum ThemeFileError: LocalizedError, Equatable {
    case missingKey(String)
    case invalidHex(key: String, value: String)
    case invalidValue(key: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let key):
            "Missing required theme key '\(key)'."
        case .invalidHex(let key, let value):
            "Theme key '\(key)' must be a #RRGGBB or #RRGGBBAA hex color, got '\(value)'."
        case .invalidValue(let key, let reason):
            "Theme key '\(key)' is invalid: \(reason)."
        }
    }
}
