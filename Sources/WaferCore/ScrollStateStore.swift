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
    private static let keyPrefix = "scroll-state-v2:"
    private static let legacyKeyPrefix = "scroll-state:"

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

    /// Call once at application launch; construction and document opens do not enumerate preferences.
    public func pruneLegacyEntries() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.legacyKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    public func save(fraction: Double, for fileURL: URL, fingerprint: String, updatedAt: Date = Date()) {
        let entry = Entry(fingerprint: fingerprint, state: ScrollState(fraction: fraction, updatedAt: updatedAt))
        guard let data = try? encoder.encode(entry) else { return }
        defaults.set(data, forKey: key(for: fileURL))
    }

    public func load(for fileURL: URL, fingerprint: String) -> ScrollState? {
        guard let data = defaults.data(forKey: key(for: fileURL)),
              let entry = try? decoder.decode(Entry.self, from: data), entry.fingerprint == fingerprint else { return nil }
        return entry.state
    }

    public func pruneEntries(olderThan cutoff: Date) {
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(Self.keyPrefix) || key.hasPrefix(Self.legacyKeyPrefix) {
            if key.hasPrefix(Self.legacyKeyPrefix) {
                defaults.removeObject(forKey: key)
                continue
            }
            guard
                let data = value as? Data,
                let entry = try? decoder.decode(Entry.self, from: data),
                entry.state.updatedAt >= cutoff
            else {
                defaults.removeObject(forKey: key)
                continue
            }
        }
    }

    private struct Entry: Codable {
        let fingerprint: String
        let state: ScrollState
    }

    private func key(for fileURL: URL) -> String {
        "\(Self.keyPrefix)\(FileFingerprint.sha256Hex(for: fileURL.standardizedFileURL.path))"
    }
}
