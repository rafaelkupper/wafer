import Foundation
import XCTest
@testable import WaferCore

final class ScrollStateStoreTests: XCTestCase {
    func testSavesAndLoadsScrollFraction() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ScrollStateStore(defaults: defaults)
        let fileURL = URL(fileURLWithPath: "/tmp/example.md")

        store.save(fraction: 0.42, for: fileURL, fingerprint: "fingerprint")
        let loaded = store.load(for: fileURL, fingerprint: "fingerprint")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.fraction ?? -1, 0.42, accuracy: 0.0001)
    }

    func testDifferentFingerprintProducesDifferentEntry() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ScrollStateStore(defaults: defaults)
        let fileURL = URL(fileURLWithPath: "/tmp/example.md")

        store.save(fraction: 0.9, for: fileURL, fingerprint: "old")

        XCTAssertNil(store.load(for: fileURL, fingerprint: "new"))
    }

    func testPruneRemovesOldAndInvalidScrollEntriesOnly() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
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
