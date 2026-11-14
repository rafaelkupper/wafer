import Foundation
import XCTest
@testable import WaferCore

final class ScrollStateStoreTests: XCTestCase {
    func testConstructionDoesNotEnumerateDefaultsAndMigrationIsExplicit() throws {
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: "dev.wafer.tests.counting.\(UUID().uuidString)"))
        defaults.set("obsolete", forKey: "scroll-state:legacy")
        defaults.set("keep", forKey: "unrelated")
        for _ in 0..<20 { _ = ScrollStateStore(defaults: defaults) }
        XCTAssertEqual(defaults.enumerationCount, 0)
        XCTAssertEqual(defaults.string(forKey: "scroll-state:legacy"), "obsolete")
        let store = ScrollStateStore(defaults: defaults)
        store.save(fraction: 0.5, for: URL(fileURLWithPath: "/tmp/note.md"), fingerprint: "v2")
        store.pruneLegacyEntries()
        XCTAssertEqual(defaults.enumerationCount, 1)
        XCTAssertNil(defaults.object(forKey: "scroll-state:legacy"))
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
        XCTAssertEqual(store.load(for: URL(fileURLWithPath: "/tmp/note.md"), fingerprint: "v2")?.fraction, 0.5)
        store.pruneLegacyEntries()
        XCTAssertEqual(defaults.enumerationCount, 2)
    }

    func testSavesAndLoadsScrollFraction() {
        let defaults = makeTestUserDefaults()
        let store = ScrollStateStore(defaults: defaults)
        let fileURL = URL(fileURLWithPath: "/tmp/example.md")

        store.save(fraction: 0.42, for: fileURL, fingerprint: "fingerprint")
        let loaded = store.load(for: fileURL, fingerprint: "fingerprint")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.fraction ?? -1, 0.42, accuracy: 0.0001)
    }

    func testDifferentFingerprintProducesDifferentEntry() {
        let defaults = makeTestUserDefaults()
        let store = ScrollStateStore(defaults: defaults)
        let fileURL = URL(fileURLWithPath: "/tmp/example.md")

        store.save(fraction: 0.9, for: fileURL, fingerprint: "old")

        XCTAssertNil(store.load(for: fileURL, fingerprint: "new"))
    }

    func testPruneRemovesOldAndInvalidScrollEntriesOnly() {
        let defaults = makeTestUserDefaults()
        let store = ScrollStateStore(defaults: defaults)
        let fileURL = URL(fileURLWithPath: "/tmp/example.md")
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)

        store.save(
            fraction: 0.2,
            for: fileURL,
            fingerprint: "old",
            updatedAt: cutoff.addingTimeInterval(-1)
        )
        store.save(
            fraction: 0.8,
            for: fileURL,
            fingerprint: "fresh",
            updatedAt: cutoff
        )
        defaults.set(Data("not json".utf8), forKey: "scroll-state:invalid")
        defaults.set("keep me", forKey: "unrelated")

        store.pruneEntries(olderThan: cutoff)

        XCTAssertNil(store.load(for: fileURL, fingerprint: "old"))
        XCTAssertEqual(store.load(for: fileURL, fingerprint: "fresh")?.fraction ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertNil(defaults.object(forKey: "scroll-state:invalid"))
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep me")
    }
}

/// In-memory, so the suite never reaches ~/Library/Preferences. Single-threaded test use only.
private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    var enumerationCount = 0
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
    override func synchronize() -> Bool { true }

    override func dictionaryRepresentation() -> [String: Any] {
        enumerationCount += 1
        return values
    }
}
