import Foundation

public struct ScrollState: Codable, Equatable {
    public let fraction: Double
    public let updatedAt: Date

    public init(fraction: Double, updatedAt: Date = Date()) {
        self.fraction = min(max(fraction, 0), 1)
        self.updatedAt = updatedAt
    }
}

public final class ScrollStateStore {
    private static let keyPrefix = "scroll-state:"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults? = nil, suiteName: String = "dev.wafer.scroll-state") {
        if let defaults {
            self.defaults = defaults
        } else if let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
    }

    public func save(fraction: Double, for fileURL: URL, fingerprint: String, updatedAt: Date = Date()) {
        let state = ScrollState(fraction: fraction, updatedAt: updatedAt)
        guard let data = try? encoder.encode(state) else {
            return
        }

        defaults.set(data, forKey: key(for: fileURL, fingerprint: fingerprint))
    }

    public func load(for fileURL: URL, fingerprint: String) -> ScrollState? {
        guard let data = defaults.data(forKey: key(for: fileURL, fingerprint: fingerprint)) else {
            return nil
        }

        return try? decoder.decode(ScrollState.self, from: data)
    }

    public func remove(for fileURL: URL, fingerprint: String) {
        defaults.removeObject(forKey: key(for: fileURL, fingerprint: fingerprint))
    }

    public func pruneEntries(olderThan cutoff: Date) {
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(Self.keyPrefix) {
            guard
                let data = value as? Data,
                let state = try? decoder.decode(ScrollState.self, from: data),
                state.updatedAt >= cutoff
            else {
                defaults.removeObject(forKey: key)
                continue
            }
        }
    }

    private func key(for fileURL: URL, fingerprint: String) -> String {
        let identity = "\(fileURL.standardizedFileURL.path)|\(fingerprint)"
        return "\(Self.keyPrefix)\(FileFingerprint.sha256Hex(for: identity))"
    }
}
