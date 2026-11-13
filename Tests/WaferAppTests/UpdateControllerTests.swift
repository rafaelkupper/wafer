import AppKit
import XCTest
@testable import WaferApp

@MainActor
final class UpdateControllerTests: XCTestCase {
    /// The test host's bundle has no feed, so nothing here starts Sparkle or
    /// reaches the network.
    func testControllerWithoutFeedStaysInertAndDisablesItsMenuItems() {
        let controller = UpdateController(bundle: Bundle(for: Self.self))

        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.postponesQuitAfterLastWindowClosed())

        let checkItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(UpdateController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        XCTAssertFalse(controller.validateMenuItem(checkItem))

        let automaticItem = NSMenuItem(
            title: "Automatically Check for Updates",
            action: #selector(UpdateController.toggleAutomaticallyChecksForUpdates(_:)),
            keyEquivalent: ""
        )
        XCTAssertFalse(controller.validateMenuItem(automaticItem))
        XCTAssertEqual(automaticItem.state, .off)

        controller.toggleAutomaticallyChecksForUpdates(automaticItem)
        XCTAssertEqual(automaticItem.state, .off)
    }

    func testQuitWaitsForActiveUpdateAndTerminatesOnceWhenCycleEnds() {
        var active = true
        var terminations = 0
        let controller = UpdateController(
            bundle: Bundle(for: Self.self), sessionInProgress: { active },
            hasVisibleWindows: { false }, terminate: { terminations += 1 }
        )

        XCTAssertTrue(controller.postponesQuitAfterLastWindowClosed())
        XCTAssertTrue(controller.postponesQuitAfterLastWindowClosed())
        XCTAssertEqual(terminations, 0)
        active = false
        controller.updateCycleDidFinish()
        XCTAssertEqual(terminations, 1)
        controller.updateCycleDidFinish()
        XCTAssertEqual(terminations, 1)
        XCTAssertFalse(controller.postponesQuitAfterLastWindowClosed())
    }

    func testWindowOpenedDuringUpdateCancelsDeferredQuit() {
        var visible = false
        var terminations = 0
        let controller = UpdateController(
            bundle: Bundle(for: Self.self), sessionInProgress: { true },
            hasVisibleWindows: { visible }, terminate: { terminations += 1 }
        )

        XCTAssertTrue(controller.postponesQuitAfterLastWindowClosed())
        visible = true
        controller.updateCycleDidFinish()
        XCTAssertEqual(terminations, 0)
        visible = false
        controller.updateCycleDidFinish()
        XCTAssertEqual(terminations, 0, "the deferred quit must have been cleared")
        XCTAssertTrue(controller.postponesQuitAfterLastWindowClosed())
        controller.updateCycleDidFinish()
        XCTAssertEqual(terminations, 1)
    }

    func testCycleEndingWithoutDeferredQuitDoesNotTerminate() {
        var terminations = 0
        let controller = UpdateController(
            bundle: Bundle(for: Self.self), sessionInProgress: { false },
            hasVisibleWindows: { false }, terminate: { terminations += 1 }
        )

        XCTAssertFalse(controller.postponesQuitAfterLastWindowClosed())
        controller.updateCycleDidFinish()
        XCTAssertEqual(terminations, 0)
    }

    func testSharedControllerIsInertInTheTestHost() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL"))
        XCTAssertFalse(UpdateController.shared.canCheckForUpdates)
    }

    func testAppBundleManifestConfiguresUpdateIdentity() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Info.plist")
        let manifest = try XCTUnwrap(NSDictionary(contentsOf: manifestURL) as? [String: Any])

        let feed = try XCTUnwrap(manifest["SUFeedURL"] as? String)
        let feedURL = try XCTUnwrap(URL(string: feed))
        XCTAssertEqual(feedURL.scheme, "https")
        XCTAssertEqual(feedURL.lastPathComponent, "appcast.xml")
        let publicKey = try XCTUnwrap(manifest["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)
        XCTAssertEqual(manifest["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(manifest["SUEnableSystemProfiling"] as? Bool, false)
    }
}
