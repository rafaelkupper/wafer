import Foundation
import XCTest
@testable import WaferApp

final class ReaderScriptResourceTests: XCTestCase {
    func testPackagedBundleWinsWithoutEvaluatingSwiftPMFallback() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let bundle = try scriptBundle(at: directory.url, script: "packaged")
        func fallback() -> Bundle? { XCTFail("Packaged apps must not evaluate Bundle.module"); return nil }
        XCTAssertEqual(ReaderScriptResource.load("reader-scroll", packagedBundle: bundle, fallbackBundle: fallback()), "packaged")
    }

    func testFallsBackWhenPackagedBundleIsAbsent() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let bundle = try scriptBundle(at: directory.url, script: "fallback")
        XCTAssertEqual(ReaderScriptResource.load("reader-scroll", packagedBundle: nil, fallbackBundle: bundle), "fallback")
    }

    func testMissingScriptDisablesHelpersWithoutCrashing() {
        XCTAssertEqual(ReaderScriptResource.load("missing", packagedBundle: nil, fallbackBundle: nil), "")
        XCTAssertFalse(ReaderScriptResource.load("reader-scroll").isEmpty)
        XCTAssertFalse(ReaderScriptResource.load("reader-live-preview").isEmpty)
    }

    private func scriptBundle(at directory: URL, script: String) throws -> Bundle {
        let url = directory.appendingPathComponent("Fixture.bundle")
        let resources = url.appendingPathComponent("Contents/Resources/Scripts")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "dev.wafer.fixture.\(UUID().uuidString)", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(script.utf8).write(to: resources.appendingPathComponent("reader-scroll.js"))
        return try XCTUnwrap(Bundle(url: url))
    }
}
