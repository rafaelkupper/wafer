import AppKit
import Foundation
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class DocumentHostWindowControllerTests: XCTestCase {
    // W3 canary: documents create a single-tab host that exposes the same
    // window/responder surface the pre-tab controller did.
    func testDocumentCreatesSingleTabHostWithUnchangedSurface() throws {
        let reader = RecordingReaderViewController()
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} },
            readerControllerFactory: { reader }
        )
        document.fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Canary.md")
        try document.read(from: Data("# Canary".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }

        let host = try XCTUnwrap(document.windowControllers.first as? DocumentHostWindowController)
        XCTAssertEqual(host.tabs.count, 1)
        XCTAssertEqual(host.activeTabIndex, 0)
        XCTAssertTrue(host.activeTab.document === document)
        XCTAssertTrue(host.activeTab.readerController === reader)

        // The host IS the document window controller every existing test casts to.
        XCTAssertNotNil(document.windowControllers.first as? DocumentWindowController)
        XCTAssertTrue(host.hostedContentViewController === reader)
        XCTAssertEqual(host.window?.titlebarAccessoryViewControllers.count, 2)
        XCTAssertFalse(host.isTabStripVisible)
    }

    // MARK: - W4 multi-tab engine

    private final class StubTabFactory {
        private(set) var readers: [String: RecordingReaderViewController] = [:]
        private(set) var completions: [String: [(WebKitRenderOutput) -> Void]] = [:]

        @MainActor
        func makeDocument(for url: URL) -> MarkdownReaderDocument {
            let reader = RecordingReaderViewController()
            let name = url.lastPathComponent
            readers[name] = reader
            let document = MarkdownReaderDocument(
                renderScheduler: { [weak self] _, baseURL, _, _, completion in
                    let key = baseURL?.lastPathComponent ?? ""
                    self?.completions[key, default: []].append(completion)
                    return DispatchWorkItem {}
                },
                readerControllerFactory: { reader }
            )
            document.fileURL = url
            try? document.read(from: Data("# \(name)".utf8), ofType: "dev.wafer.markdown")
            return document
        }
    }

    private func makeHost(
        firstFile: URL,
        factory: StubTabFactory
    ) -> (host: DocumentHostWindowController, document: MarkdownReaderDocument) {
        let document = factory.makeDocument(for: firstFile)
        document.makeWindowControllers()
        let host = document.windowControllers.first as! DocumentHostWindowController
        host.tabDocumentFactoryForTesting = { url in
            factory.makeDocument(for: url)
        }
        return (host, document)
    }

    private func closeAllTabs(of host: DocumentHostWindowController) {
        for tab in host.tabs {
            tab.document.close()
        }
    }

    func testOpenTabAppendsSelectsAndReusesExistingTabs() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")
        let factory = StubTabFactory()
        let (host, documentA) = makeHost(firstFile: fileA, factory: factory)
        defer { closeAllTabs(of: host) }

        XCTAssertFalse(host.isTabStripVisible)

        host.openTab(for: fileB)
        XCTAssertEqual(host.tabs.count, 2)
        XCTAssertEqual(host.activeTabIndex, 1)
        XCTAssertTrue(host.isTabStripVisible)
        XCTAssertTrue(host.hostedContentViewController === factory.readers["B.md"])
        XCTAssertTrue(host.document === host.activeTab.document)
        XCTAssertEqual(host.displayedWindowTitleForTesting, "B.md")
        XCTAssertEqual(host.tabStripViewForTesting.items.map(\.title), ["A.md", "B.md"])
        XCTAssertEqual(host.tabStripViewForTesting.selectedIndex, 1)

        // Re-opening an already tabbed file selects it instead of duplicating.
        host.openTab(for: fileA)
        XCTAssertEqual(host.tabs.count, 2)
        XCTAssertEqual(host.activeTabIndex, 0)
        XCTAssertTrue(host.activeTab.document === documentA)
    }

    func testCloseTabSelectsLeftNeighborAndClosesDocuments() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")
        let fileC = try tempDirectory.createTextFile(named: "C.md", contents: "# C")
        let factory = StubTabFactory()
        let (host, _) = makeHost(firstFile: fileA, factory: factory)
        defer { closeAllTabs(of: host) }

        host.openTab(for: fileB)
        host.openTab(for: fileC)
        XCTAssertEqual(host.activeTabIndex, 2)

        // Closing an inactive tab keeps the active tab and its index correct.
        host.closeTab(at: 1)
        XCTAssertEqual(host.tabs.map(\.document.fileURL?.lastPathComponent), ["A.md", "C.md"])
        XCTAssertEqual(host.activeTabIndex, 1)
        XCTAssertEqual(host.activeTab.document.fileURL?.lastPathComponent, "C.md")

        // Closing the active tab selects the neighbor to the left.
        host.closeTab(at: 1)
        XCTAssertEqual(host.tabs.count, 1)
        XCTAssertEqual(host.activeTabIndex, 0)
        XCTAssertEqual(host.activeTab.document.fileURL?.lastPathComponent, "A.md")
        XCTAssertFalse(host.isTabStripVisible)
        XCTAssertEqual(host.displayedWindowTitleForTesting, "A.md")
    }

    func testLastTabCloseClosesTheWindow() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let factory = StubTabFactory()
        let (host, document) = makeHost(firstFile: fileA, factory: factory)
        let window = try XCTUnwrap(host.window)

        let willClose = expectation(description: "window closes")
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            willClose.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        host.closeTab(at: 0)
        wait(for: [willClose], timeout: 5)
        document.close()
    }

    func testMoveTabReordersAndTracksActiveTab() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")
        let fileC = try tempDirectory.createTextFile(named: "C.md", contents: "# C")
        let factory = StubTabFactory()
        let (host, _) = makeHost(firstFile: fileA, factory: factory)
        defer { closeAllTabs(of: host) }

        host.openTab(for: fileB)
        host.openTab(for: fileC)
        host.selectTab(at: 0)

        host.moveTab(from: 0, to: 2)
        XCTAssertEqual(host.tabs.map(\.document.fileURL?.lastPathComponent), ["B.md", "C.md", "A.md"])
        XCTAssertEqual(host.activeTabIndex, 2)
        XCTAssertEqual(host.activeTab.document.fileURL?.lastPathComponent, "A.md")
        XCTAssertEqual(host.tabStripViewForTesting.selectedIndex, 2)

        host.moveActiveTabLeft(nil)
        XCTAssertEqual(host.tabs.map(\.document.fileURL?.lastPathComponent), ["B.md", "A.md", "C.md"])
        XCTAssertEqual(host.activeTabIndex, 1)
    }

    func testKeyboardCyclingWrapsAndValidates() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")
        let factory = StubTabFactory()
        let (host, _) = makeHost(firstFile: fileA, factory: factory)
        defer { closeAllTabs(of: host) }

        let nextItem = NSMenuItem(
            title: "Show Next Tab",
            action: #selector(DocumentHostWindowController.showNextTab(_:)),
            keyEquivalent: ""
        )
        let moveLeftItem = NSMenuItem(
            title: "Move Tab Left",
            action: #selector(DocumentHostWindowController.moveActiveTabLeft(_:)),
            keyEquivalent: ""
        )
        XCTAssertFalse(host.validateUserInterfaceItem(nextItem))

        host.openTab(for: fileB)
        XCTAssertTrue(host.validateUserInterfaceItem(nextItem))
        XCTAssertTrue(host.validateUserInterfaceItem(moveLeftItem))

        host.showNextTab(nil)
        XCTAssertEqual(host.activeTabIndex, 0)
        XCTAssertFalse(host.validateUserInterfaceItem(moveLeftItem))
        host.showPreviousTab(nil)
        XCTAssertEqual(host.activeTabIndex, 1)
    }

    func testInactiveTabRendersWithoutClobberingWindowChrome() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")
        let factory = StubTabFactory()
        let (host, documentA) = makeHost(firstFile: fileA, factory: factory)
        defer { closeAllTabs(of: host) }

        host.openTab(for: fileB)
        host.selectTab(at: 0)

        // Active tab A completes its render: window chrome shows A's statistics.
        let statsA = DocumentStatistics(words: 1, minutes: 1, lines: 1, characters: 1)
        factory.completions["A.md"]?.last?(
            WebKitRenderOutput(html: "<html>a</html>", baseURL: nil, statistics: statsA)
        )
        XCTAssertEqual(host.displayedStatisticTextForTesting, "1 Word")

        // Inactive tab B completes a render: its READER applies it, but the
        // window chrome must keep showing A's state.
        let statsB = DocumentStatistics(words: 99, minutes: 1, lines: 9, characters: 900)
        factory.completions["B.md"]?.last?(
            WebKitRenderOutput(html: "<html>b</html>", baseURL: nil, statistics: statsB)
        )
        XCTAssertEqual(factory.readers["B.md"]?.appliedOutputs.count, 1)
        XCTAssertEqual(host.displayedStatisticTextForTesting, "1 Word")
        XCTAssertEqual(host.displayedWindowTitleForTesting, "A.md")
        XCTAssertTrue(documentA.isActiveInHost)
        XCTAssertFalse(host.tabs[1].document.isActiveInHost)

        // Selecting B pulls its cached window-level state across.
        host.selectTab(at: 1)
        XCTAssertEqual(host.displayedStatisticTextForTesting, "99 Words")
        XCTAssertEqual(host.displayedWindowTitleForTesting, "B.md")
    }

    func testSidebarSelectionRoutesByCommandClick() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")
        let factory = StubTabFactory()
        let (host, _) = makeHost(firstFile: fileA, factory: factory)
        defer { closeAllTabs(of: host) }

        host.commandClickProviderForTesting = { true }
        host.triggerSidebarDocumentSelectionForTesting(fileB)
        XCTAssertEqual(host.tabs.count, 2)
        XCTAssertEqual(host.activeTab.document.fileURL?.lastPathComponent, "B.md")

        // Plain activation replaces in the current tab instead of opening one.
        host.commandClickProviderForTesting = { false }
        let replaced = expectation(description: "replace-in-tab render scheduled")
        host.triggerSidebarDocumentSelectionForTesting(fileA)
        Task { @MainActor in
            while host.activeTab.document.fileURL?.lastPathComponent != "A.md" {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            replaced.fulfill()
        }
        wait(for: [replaced], timeout: 5)
        XCTAssertEqual(host.tabs.count, 2)
    }

    func testOpenerFocusSelectsExistingTabInsteadOfNewWindow() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")
        let factory = StubTabFactory()
        let (host, _) = makeHost(firstFile: fileA, factory: factory)
        defer { closeAllTabs(of: host) }

        host.openTab(for: fileB)
        host.selectTab(at: 0)

        try MarkdownDocumentOpener.open(url: fileB)
        XCTAssertEqual(host.tabs.count, 2)
        XCTAssertEqual(host.activeTabIndex, 1)
        XCTAssertEqual(host.activeTab.document.fileURL?.lastPathComponent, "B.md")
    }

    func testExportContextFollowsActiveTab() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")
        let factory = StubTabFactory()
        let (host, _) = makeHost(firstFile: fileA, factory: factory)
        defer { closeAllTabs(of: host) }

        host.openTab(for: fileB)
        XCTAssertTrue(host.hostedContentViewController === factory.readers["B.md"])

        host.selectTab(at: 0)
        XCTAssertTrue(host.hostedContentViewController === factory.readers["A.md"])
    }

    func testCloseOtherTabsKeepsOnlyTheTarget() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")
        let fileC = try tempDirectory.createTextFile(named: "C.md", contents: "# C")
        let factory = StubTabFactory()
        let (host, _) = makeHost(firstFile: fileA, factory: factory)
        defer { closeAllTabs(of: host) }

        host.openTab(for: fileB)
        host.openTab(for: fileC)

        host.closeOtherTabs(around: 1)
        XCTAssertEqual(host.tabs.count, 1)
        XCTAssertEqual(host.activeTabIndex, 0)
        XCTAssertEqual(host.activeTab.document.fileURL?.lastPathComponent, "B.md")
        XCTAssertFalse(host.isTabStripVisible)
    }

    func testPerTabHistoryIsolation() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileA = try tempDirectory.createTextFile(named: "A.md", contents: "# A")
        let fileB = try tempDirectory.createTextFile(named: "B.md", contents: "# B")
        let fileC = try tempDirectory.createTextFile(named: "C.md", contents: "# C")
        let factory = StubTabFactory()
        let (host, documentA) = makeHost(firstFile: fileA, factory: factory)
        defer { closeAllTabs(of: host) }

        host.openTab(for: fileB)
        host.selectTab(at: 0)

        let navigated = expectation(description: "tab A navigates to C")
        documentA.navigateInCurrentWindow(to: fileC)
        Task { @MainActor in
            while documentA.fileURL != fileC {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            navigated.fulfill()
        }
        wait(for: [navigated], timeout: 5)

        XCTAssertTrue(documentA.navigationHistory.canGoBack)
        XCTAssertFalse(host.tabs[1].document.navigationHistory.canGoBack)
        XCTAssertFalse(host.tabs[1].document.navigationHistory.canGoForward)
    }
}
