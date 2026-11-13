import AppKit
import Foundation
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class DocumentNavigationHistoryTests: XCTestCase {
    func testCrossDocumentNavigationPushesAndTraversalRestoresFiles() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")
        let fileC = try tempDirectory.createTextFile(named: "C.md", contents: "# C")

        let reader = RecordingReaderViewController()
        var renderExpectations: [String: XCTestExpectation] = [:]
        let document = MarkdownReaderDocument(
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { _, baseURL, _, _, _ in
                if let name = baseURL?.lastPathComponent {
                    renderExpectations.removeValue(forKey: name)?.fulfill()
                }
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = fileA
        try document.read(from: Data("# A".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }

        func awaitNavigation(to url: URL, _ action: () -> Void) {
            let navigated = expectation(description: "navigated to \(url.lastPathComponent)")
            renderExpectations[url.lastPathComponent] = navigated
            action()
            wait(for: [navigated], timeout: 5)
        }

        awaitNavigation(to: fileB) { document.navigateInCurrentWindow(to: fileB) }
        awaitNavigation(to: fileC) { document.navigateInCurrentWindow(to: fileC) }
        XCTAssertEqual(document.fileURL, fileC)
        XCTAssertTrue(document.navigationHistory.canGoBack)
        XCTAssertFalse(document.navigationHistory.canGoForward)

        awaitNavigation(to: fileB) { document.goBackInHistory(nil) }
        XCTAssertEqual(document.fileURL, fileB)
        XCTAssertTrue(document.navigationHistory.canGoForward)

        awaitNavigation(to: fileA) { document.goBackInHistory(nil) }
        XCTAssertEqual(document.fileURL, fileA)
        XCTAssertFalse(document.navigationHistory.canGoBack)
        XCTAssertTrue(document.navigationHistory.canGoForward)

        awaitNavigation(to: fileB) { document.goForwardInHistory(nil) }
        XCTAssertEqual(document.fileURL, fileB)

        // Organic navigation clears the forward stack (C is no longer ahead).
        awaitNavigation(to: fileA) { document.navigateInCurrentWindow(to: fileA) }
        XCTAssertFalse(document.navigationHistory.canGoForward)
        XCTAssertTrue(document.navigationHistory.canGoBack)

        let backItem = NSMenuItem(
            title: "Back",
            action: #selector(MarkdownReaderDocument.goBackInHistory(_:)),
            keyEquivalent: ""
        )
        let forwardItem = NSMenuItem(
            title: "Forward",
            action: #selector(MarkdownReaderDocument.goForwardInHistory(_:)),
            keyEquivalent: ""
        )
        XCTAssertTrue(document.validateUserInterfaceItem(backItem))
        XCTAssertFalse(document.validateUserInterfaceItem(forwardItem))
    }

    func testSameFileAnchorsAndLiveReloadsDoNotPushHistory() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A\n\n## Target")

        let reader = RecordingReaderViewController()
        var renderCount = 0
        let secondRender = expectation(description: "reload render scheduled")
        let document = MarkdownReaderDocument(
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { _, _, _, _, _ in
                renderCount += 1
                if renderCount == 2 {
                    secondRender.fulfill()
                }
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = fileA
        try document.read(from: Data("# A\n\n## Target".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }

        reader.stubbedContentReady = true
        document.navigateInCurrentWindow(to: fileA, anchorID: "target")
        XCTAssertEqual(reader.scrolledHeadingIDs, ["target"])
        XCTAssertFalse(document.navigationHistory.canGoBack)

        try Data("# A updated".utf8).write(to: fileA)
        document.reloadDocument(nil)
        wait(for: [secondRender], timeout: 5)
        XCTAssertFalse(document.navigationHistory.canGoBack)
        XCTAssertFalse(document.navigationHistory.canGoForward)
    }

    func testTitlebarChevronsFollowHistoryAndNavigate() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")

        let reader = RecordingReaderViewController()
        var renderExpectations: [String: XCTestExpectation] = [:]
        let document = MarkdownReaderDocument(
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { _, baseURL, _, _, _ in
                if let name = baseURL?.lastPathComponent {
                    renderExpectations.removeValue(forKey: name)?.fulfill()
                }
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = fileA
        try document.read(from: Data("# A".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }

        let windowController = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        XCTAssertFalse(windowController.navigationBackEnabledForTesting)
        XCTAssertFalse(windowController.navigationForwardEnabledForTesting)

        let toB = expectation(description: "to B")
        renderExpectations["B.md"] = toB
        document.navigateInCurrentWindow(to: fileB)
        wait(for: [toB], timeout: 5)
        XCTAssertTrue(windowController.navigationBackEnabledForTesting)
        XCTAssertFalse(windowController.navigationForwardEnabledForTesting)

        let backToA = expectation(description: "chevron back to A")
        renderExpectations["A.md"] = backToA
        windowController.triggerNavigationBackForTesting()
        wait(for: [backToA], timeout: 5)
        XCTAssertEqual(document.fileURL, fileA)
        XCTAssertFalse(windowController.navigationBackEnabledForTesting)
        XCTAssertTrue(windowController.navigationForwardEnabledForTesting)

        // Disabled chevron is inert.
        windowController.triggerNavigationBackForTesting()
        XCTAssertEqual(document.fileURL, fileA)
    }

    func testChevronsReThemeThroughPaletteTokens() throws {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let accessory = NavigationHistoryAccessoryViewController()
        accessory.loadViewIfNeeded()

        ReaderTheme.setCurrent(.dark)
        accessory.applyCurrentTheme()
        let darkTint = accessory.backButtonForTesting.imageTintForTesting

        ReaderTheme.setCurrent(.light)
        accessory.applyCurrentTheme()
        let lightTint = accessory.backButtonForTesting.imageTintForTesting

        XCTAssertNotEqual(darkTint, lightTint)
        XCTAssertEqual(lightTint, ReaderTheme.statisticsIconButtonColor)
        XCTAssertEqual(accessory.backButtonForTesting.imageAlphaForTesting, 0.35)
    }

    func testScrollPositionPersistsOnDepartureAndRestoresOnBack() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")

        let reader = RecordingReaderViewController()
        let scrollStore = makeTestScrollStateStore()
        var completions: [(name: String, completion: (WebKitRenderOutput) -> Void)] = []
        var renderExpectations: [String: XCTestExpectation] = [:]
        let document = MarkdownReaderDocument(
            scrollStateStore: scrollStore,
            renderScheduler: { _, baseURL, _, _, completion in
                let name = baseURL?.lastPathComponent ?? ""
                completions.append((name, completion))
                renderExpectations.removeValue(forKey: name)?.fulfill()
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = fileA
        try document.read(from: Data("# A".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }

        reader.stubbedCurrentScrollFraction = 0.5

        let toB = expectation(description: "to B")
        renderExpectations["B.md"] = toB
        document.navigateInCurrentWindow(to: fileB)
        wait(for: [toB], timeout: 5)

        let fingerprintA = FileFingerprint.sha256Hex(for: Data("# A".utf8))
        XCTAssertEqual(scrollStore.load(for: fileA, fingerprint: fingerprintA)?.fraction, 0.5)

        let backToA = expectation(description: "back to A")
        renderExpectations["A.md"] = backToA
        document.goBackInHistory(nil)
        wait(for: [backToA], timeout: 5)

        let lastACompletion = try XCTUnwrap(completions.last(where: { $0.name == "A.md" })?.completion)
        lastACompletion(WebKitRenderOutput(html: "<html>a</html>", baseURL: nil))
        XCTAssertEqual(reader.appliedInitialScrollFractions.last ?? nil, 0.5)
    }
}
