import Foundation
import XCTest

final class TestUserDefaultsTests: XCTestCase {
    func testInheritedTypedAccessorsUseIsolatedMemoryStorage() {
        let first = makeTestUserDefaults()
        let second = makeTestUserDefaults()
        let data = Data([1, 2, 3])
        first.set(true, forKey: "enabled")
        first.set("value", forKey: "text")
        first.set(data, forKey: "data")

        XCTAssertTrue(first.bool(forKey: "enabled"))
        XCTAssertEqual(first.string(forKey: "text"), "value")
        XCTAssertEqual(first.data(forKey: "data"), data)
        XCTAssertEqual(first.dictionaryRepresentation().count, 3)
        XCTAssertTrue(second.dictionaryRepresentation().isEmpty)
        XCTAssertFalse(second.bool(forKey: "enabled"))
        XCTAssertNil(second.string(forKey: "text"))
        XCTAssertNil(second.data(forKey: "data"))

        first.removeObject(forKey: "text")
        XCTAssertNil(first.string(forKey: "text"))
        XCTAssertEqual(first.dictionaryRepresentation().count, 2)
    }
}
