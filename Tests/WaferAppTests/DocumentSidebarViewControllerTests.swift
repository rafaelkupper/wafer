import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class DocumentSidebarViewControllerTests: XCTestCase {
    func testLibraryModeAppearsAfterOpeningLibraryAndFallsBackWhenClosed() throws {
        let fixture = try makeLibrarySidebar(files: [])
        defer { fixture.tempDirectory.remove() }

        fixture.sidebar.loadViewIfNeeded()

        XCTAssertEqual(fixture.sidebar.availableModeTitlesForTesting, ["Docs", "Outline"])

        try fixture.controller.openLibrary(at: fixture.tempDirectory.url)
        waitForLibraryIdle(fixture.controller)

        XCTAssertEqual(fixture.sidebar.availableModeTitlesForTesting, ["Library", "Docs", "Outline"])

        fixture.sidebar.setMode(.library)
        XCTAssertEqual(fixture.sidebar.mode, .library)

        fixture.controller.closeLibrary()

        XCTAssertEqual(fixture.sidebar.mode, .documents)
        XCTAssertEqual(fixture.sidebar.availableModeTitlesForTesting, ["Docs", "Outline"])
    }

    func testLibraryModeBuildsSortedFolderTree() throws {
        let fixture = try makeLibrarySidebar(files: [
            libraryFile(path: "Guides/Intro.md", title: "Intro"),
            libraryFile(path: "README.md", title: "Read Me"),
            libraryFile(path: "Guides/Deep/Topic.md", title: "Topic"),
        ])
        defer { fixture.tempDirectory.remove() }
        fixture.sidebar.loadViewIfNeeded()

        try fixture.controller.openLibrary(at: fixture.tempDirectory.url)
        waitForLibraryIdle(fixture.controller)
        fixture.sidebar.setMode(.library)

        XCTAssertEqual(fixture.sidebar.libraryRowTitlesForTesting, ["Guides", "Deep", "Topic", "Intro", "Read Me"])
    }

    func testLibraryFolderCollapseSurvivesRefresh() throws {
        let fixture = try makeLibrarySidebar(files: [
            libraryFile(path: "Guides/Intro.md", title: "Intro"),
            libraryFile(path: "README.md", title: "Read Me"),
        ])
        defer { fixture.tempDirectory.remove() }
        fixture.sidebar.loadViewIfNeeded()

        try fixture.controller.openLibrary(at: fixture.tempDirectory.url)
        waitForLibraryIdle(fixture.controller)
        fixture.sidebar.setMode(.library)

        XCTAssertEqual(fixture.sidebar.libraryRowTitlesForTesting, ["Guides", "Intro", "Read Me"])

        fixture.sidebar.toggleLibraryFolderForTesting("Guides")
        XCTAssertEqual(fixture.sidebar.libraryRowTitlesForTesting, ["Guides", "Read Me"])

        fixture.controller.refreshLibrary()
        waitForLibraryIdle(fixture.controller)

        XCTAssertEqual(fixture.sidebar.libraryRowTitlesForTesting, ["Guides", "Read Me"])
    }

    func testLibraryFileSelectionRoutesToDocumentSelection() throws {
        let selectedFile = libraryFile(path: "Guides/Intro.md", title: "Intro")
        let fixture = try makeLibrarySidebar(files: [selectedFile])
        defer { fixture.tempDirectory.remove() }
        var selectedURLs: [URL] = []
        fixture.sidebar.onSelectDocument = { selectedURLs.append($0) }
        fixture.sidebar.loadViewIfNeeded()

        try fixture.controller.openLibrary(at: fixture.tempDirectory.url)
        waitForLibraryIdle(fixture.controller)
        fixture.sidebar.setMode(.library)
        fixture.sidebar.triggerLibrarySelectionForTesting(relativePath: "Guides/Intro.md")

        XCTAssertEqual(selectedURLs, [selectedFile.fileURL])
    }

    func testLibraryModeMarksCurrentFileSelected() throws {
        let currentFile = libraryFile(path: "Guides/Intro.md", title: "Intro")
        let fixture = try makeLibrarySidebar(files: [
            currentFile,
            libraryFile(path: "Guides/Other.md", title: "Other"),
        ])
        defer { fixture.tempDirectory.remove() }
        fixture.sidebar.loadViewIfNeeded()
        fixture.sidebar.apply(
            sidebarEntries: [
                DocumentSidebarEntry(
                    fileURL: currentFile.fileURL,
                    displayTitle: "Intro",
                    previewText: "",
                    isCurrent: true,
                    isAvailable: true
                ),
            ],
            outlineItems: []
        )

        try fixture.controller.openLibrary(at: fixture.tempDirectory.url)
        waitForLibraryIdle(fixture.controller)
        fixture.sidebar.setMode(.library)

        XCTAssertEqual(fixture.sidebar.selectedLibraryFilePathsForTesting, ["Guides/Intro.md"])
    }

    func testLibraryModeShowsTruncationFooter() throws {
        let fixture = try makeLibrarySidebar(
            files: [libraryFile(path: "README.md", title: "Read Me")],
            truncated: true
        )
        defer { fixture.tempDirectory.remove() }
        fixture.sidebar.loadViewIfNeeded()

        try fixture.controller.openLibrary(at: fixture.tempDirectory.url)
        waitForLibraryIdle(fixture.controller)
        fixture.sidebar.setMode(.library)

        XCTAssertEqual(fixture.sidebar.libraryFooterTextsForTesting, ["Showing first 2,000 files"])
    }

    func testLibraryRowsReapplyCurrentTheme() throws {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let fixture = try makeLibrarySidebar(files: [libraryFile(path: "README.md", title: "Read Me")])
        defer { fixture.tempDirectory.remove() }
        fixture.sidebar.loadViewIfNeeded()

        try fixture.controller.openLibrary(at: fixture.tempDirectory.url)
        waitForLibraryIdle(fixture.controller)
        fixture.sidebar.setMode(.library)
        let darkColor = try XCTUnwrap(fixture.sidebar.libraryPrimaryTextColorsForTesting.first)

        ReaderTheme.setCurrent(.light)
        fixture.sidebar.applyCurrentTheme()

        XCTAssertNotEqual(fixture.sidebar.libraryPrimaryTextColorsForTesting.first, darkColor)
        XCTAssertEqual(fixture.sidebar.libraryPrimaryTextColorsForTesting.first, ReaderTheme.sidebarPrimaryTextColor)
    }

    func testLibrarySearchResultsReplaceTreeAndClearingRestoresTree() throws {
        let fixture = try makeLibrarySidebar(files: [
            libraryFile(path: "Guides/Topic.md", title: "Topic", plainText: "alpha beta"),
            libraryFile(path: "README.md", title: "Read Me", plainText: "overview"),
        ])
        defer { fixture.tempDirectory.remove() }
        fixture.sidebar.loadViewIfNeeded()

        try fixture.controller.openLibrary(at: fixture.tempDirectory.url)
        waitForLibraryIdle(fixture.controller)
        fixture.sidebar.setMode(.library)

        XCTAssertEqual(fixture.sidebar.libraryRowTitlesForTesting, ["Guides", "Topic", "Read Me"])

        fixture.sidebar.setLibrarySearchQueryForTesting("alpha")
        waitUntil { fixture.sidebar.librarySearchResultTitlesForTesting == ["Topic"] }

        XCTAssertEqual(fixture.sidebar.libraryRowTitlesForTesting, [])

        fixture.sidebar.setLibrarySearchQueryForTesting("")

        XCTAssertEqual(fixture.sidebar.libraryRowTitlesForTesting, ["Guides", "Topic", "Read Me"])
    }

    func testLibrarySearchResultActivationCarriesMatchedAnchor() throws {
        let matchedFile = libraryFile(
            path: "Guides/Anchors.md",
            title: "Anchors",
            outlineItems: [
                DocumentOutlineItem(title: "Duplicate", level: 1, anchorID: "duplicate"),
                DocumentOutlineItem(title: "Duplicate", level: 2, anchorID: "duplicate-1"),
            ],
            plainText: "body"
        )
        let fixture = try makeLibrarySidebar(files: [matchedFile])
        defer { fixture.tempDirectory.remove() }
        var selections: [(URL, String?)] = []
        fixture.sidebar.onSelectDocumentWithAnchor = { selections.append(($0, $1)) }
        fixture.sidebar.loadViewIfNeeded()

        try fixture.controller.openLibrary(at: fixture.tempDirectory.url)
        waitForLibraryIdle(fixture.controller)
        fixture.sidebar.setMode(.library)
        fixture.sidebar.setLibrarySearchQueryForTesting("duplicate")
        waitUntil { fixture.sidebar.librarySearchResultTitlesForTesting == ["Anchors"] }

        fixture.sidebar.triggerLibrarySearchResultSelectionForTesting(relativePath: "Guides/Anchors.md")

        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections.first?.0, matchedFile.fileURL)
        XCTAssertEqual(selections.first?.1, "duplicate")
    }

    func testLibrarySearchShowsNoResultsRow() throws {
        let fixture = try makeLibrarySidebar(files: [
            libraryFile(path: "README.md", title: "Read Me", plainText: "overview"),
        ])
        defer { fixture.tempDirectory.remove() }
        fixture.sidebar.loadViewIfNeeded()

        try fixture.controller.openLibrary(at: fixture.tempDirectory.url)
        waitForLibraryIdle(fixture.controller)
        fixture.sidebar.setMode(.library)
        fixture.sidebar.setLibrarySearchQueryForTesting("missing")
        waitUntil { fixture.sidebar.librarySearchNoResultTextsForTesting == ["No results"] }

        XCTAssertEqual(fixture.sidebar.librarySearchResultTitlesForTesting, [])
    }

    func testEmptyLibrarySearchQueryDoesNotRunSearch() throws {
        let recorder = LibrarySearchCallRecorder()
        let fixture = try makeLibrarySidebar(
            files: [libraryFile(path: "README.md", title: "Read Me", plainText: "overview")],
            librarySearchRunner: recorder.run(query:files:)
        )
        defer { fixture.tempDirectory.remove() }
        fixture.sidebar.loadViewIfNeeded()

        try fixture.controller.openLibrary(at: fixture.tempDirectory.url)
        waitForLibraryIdle(fixture.controller)
        fixture.sidebar.setMode(.library)
        fixture.sidebar.setLibrarySearchQueryForTesting("")

        XCTAssertEqual(recorder.count, 0)
    }

    func testLibrarySearchRunsOffMainThread() throws {
        let fixture = try makeLibrarySidebar(files: [
            libraryFile(path: "README.md", title: "Read Me", plainText: "needle"),
        ])
        defer { fixture.tempDirectory.remove() }
        fixture.sidebar.loadViewIfNeeded()

        try fixture.controller.openLibrary(at: fixture.tempDirectory.url)
        waitForLibraryIdle(fixture.controller)
        fixture.sidebar.setMode(.library)
        fixture.sidebar.setLibrarySearchQueryForTesting("needle")
        waitUntil { fixture.sidebar.lastLibrarySearchRanOnMainThreadForTesting != nil }

        XCTAssertEqual(fixture.sidebar.lastLibrarySearchRanOnMainThreadForTesting, false)
    }

    func testDocumentsModeKeepsRowsGroupedAtTopWhenContentIsSparse() {
        let controller = DocumentSidebarViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: DocumentSidebarViewController.sidebarWidth, height: 520)

        controller.apply(
            sidebarEntries: [
                DocumentSidebarEntry(
                    fileURL: URL(fileURLWithPath: "/tmp/Current.md"),
                    displayTitle: "Current",
                    previewText: "Preview",
                    isCurrent: true,
                    isAvailable: true
                ),
                DocumentSidebarEntry(
                    fileURL: URL(fileURLWithPath: "/tmp/Linked.md"),
                    displayTitle: "Linked",
                    previewText: "Preview",
                    isCurrent: false,
                    isAvailable: true
                ),
            ],
            outlineItems: []
        )
        controller.view.layoutSubtreeIfNeeded()

        let frames = controller.arrangedRowFramesForTesting
        XCTAssertEqual(frames.count, 2)

        let sorted = frames.sorted { $0.minY > $1.minY }
        let gap = sorted[0].minY - sorted[1].maxY
        XCTAssertLessThan(gap, 60)
    }

    func testOutlineModeUsesActualIndentedLeadingInsetsPerLevel() {
        let controller = DocumentSidebarViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: DocumentSidebarViewController.sidebarWidth, height: 520)
        controller.setMode(.outline)
        controller.apply(
            sidebarEntries: [],
            outlineItems: [
                DocumentOutlineItem(title: "One", level: 1, anchorID: "one"),
                DocumentOutlineItem(title: "Two", level: 2, anchorID: "two"),
                DocumentOutlineItem(title: "Three", level: 3, anchorID: "three"),
                DocumentOutlineItem(title: "Four", level: 4, anchorID: "four"),
            ]
        )

        XCTAssertEqual(controller.outlineLeadingInsetsForTesting, [16, 32, 48, 64])

        let positions = controller.outlineLabelMinXPositionsForTesting
        XCTAssertEqual(positions.count, 4)
        XCTAssertLessThan(positions[0], positions[1])
        XCTAssertLessThan(positions[1], positions[2])
        XCTAssertLessThan(positions[2], positions[3])
    }

    func testOutlineRowsStayCompactAndOverflowIntoScrollView() {
        let controller = DocumentSidebarViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: DocumentSidebarViewController.sidebarWidth, height: 520)
        controller.setMode(.outline)
        controller.apply(
            sidebarEntries: [],
            outlineItems: (1...40).map { index in
                DocumentOutlineItem(
                    title: "Heading \(index)",
                    level: min((index % 6) + 1, 6),
                    anchorID: "heading-\(index)"
                )
            }
        )
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(controller.arrangedRowHeightsForTesting.isEmpty)
        XCTAssertLessThan(controller.arrangedRowHeightsForTesting.max() ?? 0, 28)
        XCTAssertGreaterThan(controller.scrollDocumentHeightForTesting, controller.scrollViewportHeightForTesting)
    }

    func testActiveOutlineSelectionUpdatesRowsInPlace() {
        let controller = DocumentSidebarViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: DocumentSidebarViewController.sidebarWidth, height: 520)
        controller.setMode(.outline)
        controller.apply(sidebarEntries: [], outlineItems: sampleOutlineItems())

        let initialRowIdentifiers = controller.arrangedRowObjectIdentifiersForTesting

        controller.setActiveOutlineAnchorID("two")

        XCTAssertEqual(controller.arrangedRowObjectIdentifiersForTesting, initialRowIdentifiers)
        XCTAssertEqual(controller.selectedOutlineAnchorIDsForTesting, ["two"])

        controller.setActiveOutlineAnchorID("three")

        XCTAssertEqual(controller.arrangedRowObjectIdentifiersForTesting, initialRowIdentifiers)
        XCTAssertEqual(controller.selectedOutlineAnchorIDsForTesting, ["three"])
    }

    func testStoredOutlineSelectionAppliesAfterSwitchingToOutlineMode() {
        let controller = DocumentSidebarViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: DocumentSidebarViewController.sidebarWidth, height: 520)
        controller.apply(
            sidebarEntries: [
                DocumentSidebarEntry(
                    fileURL: URL(fileURLWithPath: "/tmp/Current.md"),
                    displayTitle: "Current",
                    previewText: "Preview",
                    isCurrent: true,
                    isAvailable: true
                ),
            ],
            outlineItems: sampleOutlineItems()
        )

        controller.setActiveOutlineAnchorID("two")

        XCTAssertEqual(controller.selectedOutlineAnchorIDsForTesting, [])

        controller.setMode(.outline)

        XCTAssertEqual(controller.selectedOutlineAnchorIDsForTesting, ["two"])
    }

    private func sampleOutlineItems() -> [DocumentOutlineItem] {
        [
            DocumentOutlineItem(title: "One", level: 1, anchorID: "one"),
            DocumentOutlineItem(title: "Two", level: 2, anchorID: "two"),
            DocumentOutlineItem(title: "Three", level: 2, anchorID: "three"),
        ]
    }

    private func makeLibrarySidebar(
        files: [LibraryFile],
        truncated: Bool = false,
        librarySearchRunner: @escaping DocumentSidebarViewController.LibrarySearchRunner = { query, files in
            SidebarLibrarySearchRunResult(
                matches: LibrarySearch.fullTextMatches(query: query, in: files),
                ranOnMainThread: Thread.isMainThread
            )
        }
    ) throws -> (
        sidebar: DocumentSidebarViewController,
        controller: LibraryController,
        tempDirectory: TemporaryTestDirectory
    ) {
        let tempDirectory = try TemporaryTestDirectory()
        let notificationCenter = NotificationCenter()
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!,
                notificationCenter: notificationCenter
            ),
            notificationCenter: notificationCenter,
            scanner: { _ in LibraryScanner.Result(files: files, truncated: truncated) },
            monitorFactory: { rootURL, onChange in
                FakeSidebarDirectoryMonitor(rootURL: rootURL, onChange: onChange)
            }
        )
        let sidebar = DocumentSidebarViewController(
            libraryController: controller,
            notificationCenter: notificationCenter,
            librarySearchRunner: librarySearchRunner
        )

        return (sidebar, controller, tempDirectory)
    }

    private func libraryFile(
        path: String,
        title: String,
        outlineItems: [DocumentOutlineItem] = [],
        plainText: String = ""
    ) -> LibraryFile {
        let baseURL = URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        return LibraryFile(
            fileURL: baseURL.appendingPathComponent(path),
            relativePathComponents: path.split(separator: "/").map(String.init),
            displayTitle: title,
            outlineItems: outlineItems,
            plainText: plainText,
            searchableText: plainText.libraryFoldedSearchText,
            contentFingerprint: LibraryFileFingerprint(modificationDate: Date(timeIntervalSince1970: 0), fileSize: 0)
        )
    }

    private func waitForLibraryIdle(_ controller: LibraryController, timeout: TimeInterval = 2) {
        waitUntil(timeout: timeout) {
            !controller.isScanning
        }
    }

    private func waitUntil(timeout: TimeInterval = 2, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class FakeSidebarDirectoryMonitor: DirectoryMonitoring {
    let rootURL: URL
    let onChange: () -> Void

    init(rootURL: URL, onChange: @escaping () -> Void) {
        self.rootURL = rootURL
        self.onChange = onChange
    }

    func start() {}
    func stop() {}
}

private final class LibrarySearchCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    var count: Int {
        lock.withLock { callCount }
    }

    func run(query: String, files: [LibraryFile]) -> SidebarLibrarySearchRunResult {
        lock.withLock {
            callCount += 1
        }
        return SidebarLibrarySearchRunResult(
            matches: LibrarySearch.fullTextMatches(query: query, in: files),
            ranOnMainThread: Thread.isMainThread
        )
    }
}
