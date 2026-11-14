import AppKit
import WebKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class DocumentWindowControllerTests: XCTestCase {
    func testWindowUsesUnifiedTitlebarChromeAndWrapsContentController() throws {
        let defaults = makeTestUserDefaults()
        let store = DocumentStatisticPreferenceStore(defaults: defaults)
        let contentViewController = NSViewController()
        let windowController = DocumentWindowController(
            contentViewController: contentViewController,
            statisticPreferenceStore: store,
            appearancePreferenceStore: testAppearancePreferenceStore()
        )
        defer { windowController.close() }

        let window = try XCTUnwrap(windowController.window)

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(
            window.backgroundColor.usingColorSpace(.deviceRGB),
            ReaderTheme.backgroundColor.usingColorSpace(.deviceRGB)
        )
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 2)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.first is NavigationHistoryAccessoryViewController)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.last is DocumentStatisticsAccessoryViewController)
        XCTAssertTrue(windowController.hostedContentViewController === contentViewController)
        XCTAssertFalse(window.contentViewController === contentViewController)
    }

    func testWindowUsesCenteredCustomDocumentTitle() {
        let windowController = testWindowController(contentViewController: NSViewController())
        defer { windowController.close() }

        windowController.showWindow(nil)
        windowController.setDisplayedTitle("RenderingShowcase.md")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(windowController.window?.title, "RenderingShowcase.md")
        XCTAssertEqual(windowController.displayedWindowTitleForTesting, "RenderingShowcase.md")

        let frameView = windowController.window?.contentView?.superview
        let titleLabel = frameView.flatMap { rootView in
            recursiveSubviews(in: rootView).compactMap { $0 as? NSTextField }.first {
                $0.stringValue == "RenderingShowcase.md"
                    && hasSuperview(named: "CenteredWindowTitleView", startingAt: $0)
            }
        }
        assertAppKitColor(titleLabel?.textColor, matches: ReaderThemePalette.dark.titlebarPrimaryText)
    }

    func testCenteredTitleInstallsIntoActualTitlebarHost() {
        let windowController = testWindowController(contentViewController: NSViewController())
        defer { windowController.close() }

        windowController.showWindow(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(windowController.titleViewHostClassNameForTesting, "NSTitlebarView")
    }

    func testWindowSuppressesSystemTitlebarBackgroundViews() throws {
        let windowController = testWindowController(contentViewController: NSViewController())
        defer { windowController.close() }

        let frameView = try XCTUnwrap(windowController.window?.contentView?.superview)
        let frameVisualEffectViews = frameView.subviews.compactMap { $0 as? NSVisualEffectView }
        let descendants = recursiveSubviews(in: frameView)
        let titlebarBackgroundViews = descendants.filter {
            let className = NSStringFromClass(type(of: $0))
            return className == "_NSTitlebarDecorationView" || className == "NSTitlebarBackgroundView"
        }

        XCTAssertFalse(frameVisualEffectViews.contains(where: { !$0.isHidden }))
        XCTAssertFalse(titlebarBackgroundViews.contains(where: { !$0.isHidden }))
    }

    func testThemeChangeUpdatesWindowAppearanceAndNativeChrome() throws {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let defaults = makeTestUserDefaults()
        let store = AppearancePreferenceStore(defaults: defaults, systemIsDark: { false })
        store.appearanceSelection = .dark
        let contentViewController = RecordingThemeApplyingViewController()
        let windowController = DocumentWindowController(
            contentViewController: contentViewController,
            appearancePreferenceStore: store
        )
        defer { windowController.close() }
        let window = try XCTUnwrap(windowController.window)

        XCTAssertEqual(window.appearance?.name, .darkAqua)
        assertAppKitColor(window.backgroundColor, matches: ReaderThemeColor(hex: ReaderThemePalette.dark.backgroundHex))

        store.appearanceSelection = .light
        windowController.handleReaderThemeDidChangeForTesting()

        XCTAssertEqual(window.appearance?.name, .aqua)
        assertAppKitColor(window.backgroundColor, matches: ReaderThemeColor(hex: ReaderThemePalette.light.backgroundHex))
        XCTAssertGreaterThan(contentViewController.applyThemeCount, 0)
    }

    func testEffectiveAppearanceChangeFollowsSystemSelectionOnly() {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let systemAppearance = SystemAppearanceStub(isDark: false)
        let defaults = makeTestUserDefaults()
        let store = AppearancePreferenceStore(defaults: defaults, systemIsDark: { systemAppearance.isDark })
        let windowController = DocumentWindowController(
            contentViewController: NSViewController(),
            appearancePreferenceStore: store
        )
        defer { windowController.close() }

        store.applyResolvedPalette()
        XCTAssertEqual(ReaderTheme.current, .light)

        systemAppearance.isDark = true
        windowController.handleEffectiveAppearanceChangeForTesting()
        XCTAssertEqual(ReaderTheme.current, .dark)

        store.appearanceSelection = .light
        systemAppearance.isDark = false
        windowController.handleEffectiveAppearanceChangeForTesting()
        XCTAssertEqual(ReaderTheme.current, .light)
    }

    func testChromeSuppressionRecognizesScrollPocketAndTitlebarArtifacts() {
        XCTAssertTrue(WindowChromeSuppression.shouldHideView(named: "NSVisualEffectView", topLevel: true))
        XCTAssertTrue(WindowChromeSuppression.shouldHideView(named: "_NSTitlebarDecorationView", topLevel: false))
        XCTAssertTrue(WindowChromeSuppression.shouldHideView(named: "NSTitlebarBackgroundView", topLevel: false))
        XCTAssertTrue(WindowChromeSuppression.shouldHideView(named: "NSScrollPocket", topLevel: false))
        XCTAssertTrue(WindowChromeSuppression.shouldStyleView(named: "NSTitlebarContainerView", superviewName: "NSThemeFrame"))
        XCTAssertTrue(WindowChromeSuppression.shouldStyleView(named: "NSTitlebarView", superviewName: "NSTitlebarContainerView"))
        XCTAssertTrue(WindowChromeSuppression.shouldStyleView(named: "NSView", superviewName: "NSTitlebarView"))
        XCTAssertFalse(WindowChromeSuppression.shouldHideView(named: "NSView", topLevel: false))
    }

    func testUnknownOSLeavesOptionalPrivateDecorationDisabled() {
        XCTAssertTrue(WindowChromeSuppression.supportsPrivateDecoration(on: 27))
        XCTAssertFalse(WindowChromeSuppression.supportsPrivateDecoration(on: 28))
        XCTAssertFalse(WindowChromeSuppression.shouldStyleView(named: "FutureTitlebar", superviewName: nil))
        XCTAssertFalse(WindowChromeSuppression.shouldHideView(named: "FutureDecoration", topLevel: true))
    }

    func testInitialContentSizeUsesDefaultWidthAndFullVisibleHeight() {
        let visibleFrame = NSRect(x: 100, y: 80, width: 1600, height: 1000)

        let contentSize = DocumentWindowController.initialContentSize(for: visibleFrame)

        XCTAssertEqual(contentSize.width, 1150)
        XCTAssertEqual(contentSize.height, visibleFrame.height)
    }

    func testInitialContentSizeClampsWidthToSmallVisibleFrames() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 900, height: 500)

        let contentSize = DocumentWindowController.initialContentSize(for: visibleFrame)

        XCTAssertEqual(contentSize.width, visibleFrame.width)
        XCTAssertEqual(contentSize.height, visibleFrame.height)
    }

    func testInitialFrameCentersWindowWithoutCascadeSource() {
        let visibleFrame = NSRect(x: 100, y: 80, width: 1600, height: 1000)
        let contentSize = DocumentWindowController.initialContentSize(for: visibleFrame)

        let frame = DocumentWindowController.initialFrame(
            contentSize: contentSize,
            visibleFrame: visibleFrame,
            cascadeFrom: nil
        )

        XCTAssertEqual(frame.origin.x, visibleFrame.midX - (contentSize.width / 2), accuracy: 0.5)
        XCTAssertEqual(frame.origin.y, visibleFrame.midY - (contentSize.height / 2), accuracy: 0.5)
        XCTAssertEqual(frame.maxY, visibleFrame.maxY, accuracy: 0.5)
    }

    func testInitialFrameCascadesDownAndRightFromSourceWindow() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let contentSize = NSSize(width: 900, height: 600)
        let sourceFrame = NSRect(x: 300, y: 200, width: contentSize.width, height: contentSize.height)

        let frame = DocumentWindowController.initialFrame(
            contentSize: contentSize,
            visibleFrame: visibleFrame,
            cascadeFrom: sourceFrame
        )

        XCTAssertEqual(frame.origin.x, sourceFrame.minX + DocumentWindowController.cascadeOffset, accuracy: 0.5)
        XCTAssertEqual(frame.origin.y, sourceFrame.minY - DocumentWindowController.cascadeOffset, accuracy: 0.5)
    }

    func testStatsAccessoryFormatsUpdatedStatistics() {
        let defaults = makeTestUserDefaults()
        let store = DocumentStatisticPreferenceStore(defaults: defaults)
        let windowController = DocumentWindowController(
            contentViewController: NSViewController(),
            statisticPreferenceStore: store,
            appearancePreferenceStore: testAppearancePreferenceStore()
        )
        defer { windowController.close() }

        windowController.apply(documentStatistics: DocumentStatistics(words: 870, minutes: 5, lines: 306, characters: 6708))
        windowController.window?.layoutIfNeeded()

        XCTAssertEqual(windowController.displayedStatisticTextForTesting, "870 Words")
        XCTAssertGreaterThan(windowController.window?.titlebarAccessoryViewControllers.last?.view.frame.width ?? 0, 0)
    }

    func testNavigationAccessoryLaysOutWithVisibleWidth() throws {
        // Regression: a bare-stack accessory root collapses to zero size and
        // renders invisible chevrons. The accessory must lay out with width.
        let windowController = testWindowController(contentViewController: NSViewController())
        defer { windowController.close() }

        windowController.window?.layoutIfNeeded()
        let accessory = try XCTUnwrap(windowController.window?.titlebarAccessoryViewControllers.first)
        XCTAssertTrue(accessory is NavigationHistoryAccessoryViewController)
        XCTAssertGreaterThan(accessory.view.fittingSize.width, 0)
        XCTAssertGreaterThan(accessory.view.frame.width, 0)
        XCTAssertGreaterThan(accessory.view.frame.height, 0)
    }

    func testSidebarStartsClosedDefaultsToDocumentsAndTogglesFromAccessory() {
        let windowController = testWindowController(contentViewController: NSViewController())
        defer { windowController.close() }

        XCTAssertFalse(windowController.isSidebarVisibleForTesting)
        XCTAssertFalse(windowController.isSidebarAttachedForTesting)
        XCTAssertEqual(windowController.sidebarModeForTesting, .documents)
        XCTAssertFalse(windowController.sidebarButtonIsActiveForTesting)

        windowController.triggerSidebarToggleForTesting()

        XCTAssertTrue(windowController.isSidebarVisibleForTesting)
        XCTAssertTrue(windowController.isSidebarAttachedForTesting)
        XCTAssertTrue(windowController.sidebarButtonIsActiveForTesting)
    }

    func testClosingSidebarDetachesItFromLayout() {
        let windowController = testWindowController(contentViewController: NSViewController())
        defer { windowController.close() }

        windowController.setReducedMotionForTesting(true)
        windowController.triggerSidebarToggleForTesting()
        XCTAssertTrue(windowController.isSidebarAttachedForTesting)

        windowController.triggerSidebarToggleForTesting()

        XCTAssertFalse(windowController.isSidebarVisibleForTesting)
        XCTAssertFalse(windowController.isSidebarAttachedForTesting)
        XCTAssertEqual(windowController.sidebarWidthForTesting, 0, accuracy: 0.001)
    }

    func testSidebarUsesIndentationFirstOutlineMetrics() {
        XCTAssertEqual(OutlineSidebarMetrics.leadingInset(for: 1), 16, accuracy: 0.001)
        XCTAssertEqual(OutlineSidebarMetrics.leadingInset(for: 2), 32, accuracy: 0.001)
        XCTAssertEqual(OutlineSidebarMetrics.leadingInset(for: 3), 48, accuracy: 0.001)
        XCTAssertEqual(OutlineSidebarMetrics.leadingInset(for: 4), 64, accuracy: 0.001)
        XCTAssertEqual(OutlineSidebarMetrics.leadingInset(for: 5), 80, accuracy: 0.001)
        XCTAssertEqual(OutlineSidebarMetrics.leadingInset(for: 6), 96, accuracy: 0.001)

        XCTAssertEqual(OutlineSidebarMetrics.fontSize, 12.5, accuracy: 0.001)
        XCTAssertEqual(OutlineSidebarMetrics.fontWeight(for: 1, isSelected: false), .semibold)
        XCTAssertEqual(OutlineSidebarMetrics.fontWeight(for: 3, isSelected: false), .regular)
        XCTAssertEqual(OutlineSidebarMetrics.fontWeight(for: 6, isSelected: false), .regular)
    }

    func testSidebarAnimationPreparesCollapsedVisibleOpenState() {
        let windowController = testWindowController(contentViewController: NSViewController())
        defer { windowController.close() }

        windowController.prepareSidebarForAnimatedOpenForTesting()

        XCTAssertTrue(windowController.isSidebarVisibleForTesting)
        XCTAssertEqual(windowController.sidebarWidthForTesting, 0, accuracy: 0.001)
        XCTAssertEqual(windowController.sidebarAlphaForTesting, 0, accuracy: 0.001)
        XCTAssertEqual(DocumentWindowController.sidebarAnimationDurationForTesting, 0.26, accuracy: 0.001)
    }

    func testSidebarAnimatedOpenKeepsContentFullWidthUntilCompletion() {
        let windowController = testWindowController(contentViewController: NSViewController())
        defer { windowController.close() }

        windowController.prepareSidebarForAnimatedOpenForTesting()

        XCTAssertTrue(windowController.isSidebarAttachedForTesting)
        XCTAssertFalse(windowController.isContentAlignedWithSidebarForTesting)
        XCTAssertEqual(windowController.sidebarWidthForTesting, 0, accuracy: 0.001)
    }

    func testSidebarReducedMotionPathOpensInstantly() {
        let windowController = testWindowController(contentViewController: NSViewController())
        defer { windowController.close() }

        windowController.setReducedMotionForTesting(true)
        windowController.triggerSidebarToggleForTesting()

        XCTAssertTrue(windowController.isSidebarVisibleForTesting)
        XCTAssertEqual(windowController.sidebarWidthForTesting, DocumentSidebarViewController.sidebarWidth, accuracy: 0.001)
        XCTAssertEqual(windowController.sidebarAlphaForTesting, 1, accuracy: 0.001)
    }

    func testSidebarToggleDoesNotChangeWindowFrameWidth() throws {
        let windowController = testWindowController(contentViewController: NSViewController())
        defer { windowController.close() }

        let window = try XCTUnwrap(windowController.window)
        windowController.showWindow(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let initialWidth = window.frame.width

        windowController.triggerSidebarToggleForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(DocumentWindowController.sidebarAnimationDurationForTesting / 2))
        XCTAssertEqual(window.frame.width, initialWidth, accuracy: 0.5)
        RunLoop.current.run(until: Date().addingTimeInterval(DocumentWindowController.sidebarAnimationDurationForTesting + 0.1))
        XCTAssertEqual(window.frame.width, initialWidth, accuracy: 0.5)

        windowController.triggerSidebarToggleForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(DocumentWindowController.sidebarAnimationDurationForTesting / 2))
        XCTAssertEqual(window.frame.width, initialWidth, accuracy: 0.5)
        RunLoop.current.run(until: Date().addingTimeInterval(DocumentWindowController.sidebarAnimationDurationForTesting + 0.1))
        XCTAssertEqual(window.frame.width, initialWidth, accuracy: 0.5)
    }

    func testSidebarModeIsWindowLocal() {
        let first = testWindowController(contentViewController: NSViewController())
        let second = testWindowController(contentViewController: NSViewController())
        defer {
            first.close()
            second.close()
        }

        first.setSidebarModeForTesting(.outline)

        XCTAssertEqual(first.sidebarModeForTesting, .outline)
        XCTAssertEqual(second.sidebarModeForTesting, .documents)
    }

    func testWindowRoutesFindActionsToHostedReader() throws {
        let reader = WebKitReaderViewController()
        reader.setSuppressFindExecutionForTesting(true)
        let windowController = testWindowController(contentViewController: reader)
        defer { windowController.close() }

        let window = try XCTUnwrap(windowController.window)
        windowController.showWindow(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let findItem = NSMenuItem(
            title: "Find…",
            action: #selector(WebKitReaderViewController.showFindInterface(_:)),
            keyEquivalent: "f"
        )
        let nextItem = NSMenuItem(
            title: "Find Next",
            action: #selector(WebKitReaderViewController.findNextMatch(_:)),
            keyEquivalent: "g"
        )

        XCTAssertTrue(window.validateUserInterfaceItem(findItem))
        XCTAssertFalse(window.validateUserInterfaceItem(nextItem))

        window.perform(#selector(WebKitReaderViewController.showFindInterface(_:)), with: findItem)
        reader.setFindQueryForTesting("Heading")
        XCTAssertTrue(window.validateUserInterfaceItem(nextItem))
        window.perform(#selector(WebKitReaderViewController.findNextMatch(_:)), with: nextItem)

        XCTAssertTrue(reader.isFindBarVisibleForTesting)
        XCTAssertEqual(reader.lastFindQueryForTesting, "Heading")
        XCTAssertEqual(reader.lastFindDirectionForTesting, "next")
    }

    func testWindowRoutesLibrarySearchCommandWhenLibraryOpen() throws {
        let suiteName = "dev.wafer.tests.window-library.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        let library = LibraryController(preferenceStore: LibraryPreferenceStore(defaults: defaults))
        let tempDirectory = try TemporaryTestDirectory()
        defer {
            library.closeLibrary()
            defaults.removePersistentDomain(forName: suiteName)
            tempDirectory.remove()
        }
        let windowController = testWindowController(
            contentViewController: NSViewController(), libraryController: library
        )
        let otherWindowController = testWindowController(contentViewController: NSViewController())
        defer { otherWindowController.close() }
        defer { windowController.close() }

        let window = try XCTUnwrap(windowController.window)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let searchLibraryItem = NSMenuItem(
            title: "Search Library…",
            action: #selector(DocumentWindowController.focusLibrarySearch(_:)),
            keyEquivalent: "F"
        )

        XCTAssertFalse(window.validateUserInterfaceItem(searchLibraryItem))

        try library.openLibrary(at: tempDirectory.url)

        XCTAssertTrue(window.validateUserInterfaceItem(searchLibraryItem))
        XCTAssertFalse(otherWindowController.canFocusLibrarySearch)

        window.perform(#selector(DocumentWindowController.focusLibrarySearch(_:)), with: searchLibraryItem)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(windowController.isSidebarVisibleForTesting)
        XCTAssertEqual(windowController.sidebarModeForTesting, .library)
        XCTAssertTrue(windowController.librarySearchFieldIsFocusedForTesting)

        library.closeLibrary()
        XCTAssertFalse(window.validateUserInterfaceItem(searchLibraryItem))
        XCTAssertEqual(windowController.sidebarModeForTesting, .documents)
    }

    func testWindowRoutesExportActionsOnlyWhenReaderContentIsReady() throws {
        let reader = WebKitReaderViewController()
        let exportController = RecordingDocumentExportController()
        let windowController = testWindowController(
            contentViewController: reader,
            exportController: exportController
        )
        defer { windowController.close() }

        let window = try XCTUnwrap(windowController.window)
        windowController.showWindow(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let printItem = NSMenuItem(
            title: "Print…",
            action: #selector(DocumentWindowController.printDocument(_:)),
            keyEquivalent: "p"
        )
        let exportPDFItem = NSMenuItem(
            title: "Export as PDF…",
            action: #selector(DocumentWindowController.exportPDF(_:)),
            keyEquivalent: ""
        )
        let exportHTMLItem = NSMenuItem(
            title: "Export as HTML…",
            action: #selector(DocumentWindowController.exportHTML(_:)),
            keyEquivalent: ""
        )

        XCTAssertFalse(window.validateUserInterfaceItem(printItem))
        XCTAssertFalse(window.validateUserInterfaceItem(exportPDFItem))
        XCTAssertFalse(window.validateUserInterfaceItem(exportHTMLItem))
        XCTAssertNil(windowController.currentExportContext())

        reader.loadHTMLForTesting("<!doctype html><html><body><p>Ready</p></body></html>")
        reader.markNavigationFinishedForTesting()

        XCTAssertTrue(window.validateUserInterfaceItem(printItem))
        XCTAssertTrue(window.validateUserInterfaceItem(exportPDFItem))
        XCTAssertTrue(window.validateUserInterfaceItem(exportHTMLItem))
        exportController.canExportHTML = false
        XCTAssertFalse(window.validateUserInterfaceItem(exportHTMLItem))
        exportController.canExportHTML = true

        window.perform(#selector(DocumentWindowController.printDocument(_:)), with: printItem)
        window.perform(#selector(DocumentWindowController.exportPDF(_:)), with: exportPDFItem)
        window.perform(#selector(DocumentWindowController.exportHTML(_:)), with: exportHTMLItem)

        XCTAssertEqual(exportController.printCalls.count, 1)
        XCTAssertEqual(exportController.pdfContexts.count, 1)
        XCTAssertEqual(exportController.htmlContexts.count, 1)
        XCTAssertTrue(exportController.printCalls.first?.webView === reader.webViewForExport)
        XCTAssertTrue(exportController.printCalls.first?.window === window)
        XCTAssertTrue(exportController.pdfContexts.first?.webView === reader.webViewForExport)
        XCTAssertTrue(exportController.pdfContexts.first?.window === window)
        XCTAssertTrue(exportController.htmlContexts.first?.readerController === reader)
        XCTAssertTrue(exportController.htmlContexts.first?.window === window)
    }

    func testSidebarForwardsDocumentAndOutlineSelections() {
        let windowController = testWindowController(contentViewController: NSViewController())
        defer { windowController.close() }

        let linkedURL = URL(fileURLWithPath: "/tmp/docs/Guide.md")
        windowController.apply(
            sidebarEntries: [
                DocumentSidebarEntry(
                    fileURL: linkedURL,
                    displayTitle: "Guide",
                    previewText: "Preview",
                    isCurrent: false,
                    isAvailable: true
                ),
            ],
            outlineItems: [
                DocumentOutlineItem(title: "Intro", level: 1, anchorID: "intro"),
            ]
        )

        var selectedDocumentURL: URL?
        var selectedAnchorID: String?
        windowController.onSelectSidebarDocument = { selectedDocumentURL = $0 }
        windowController.onSelectOutlineItem = { selectedAnchorID = $0 }

        windowController.triggerSidebarDocumentSelectionForTesting(linkedURL)
        windowController.triggerOutlineSelectionForTesting("intro")

        XCTAssertEqual(selectedDocumentURL, linkedURL)
        XCTAssertEqual(selectedAnchorID, "intro")
    }
}

@MainActor
private func testWindowController(
    contentViewController: NSViewController,
    libraryController: LibraryController = LibraryController(),
    statisticPreferenceStore: DocumentStatisticPreferenceStore = .shared,
    systemIsDark: Bool = true,
    exportController: DocumentExportControlling = DocumentExportController()
) -> DocumentWindowController {
    DocumentWindowController(
        contentViewController: contentViewController,
        libraryController: libraryController,
        statisticPreferenceStore: statisticPreferenceStore,
        appearancePreferenceStore: testAppearancePreferenceStore(systemIsDark: systemIsDark),
        exportController: exportController
    )
}

@MainActor
private func testAppearancePreferenceStore(systemIsDark: Bool = true) -> AppearancePreferenceStore {
    AppearancePreferenceStore(
        defaults: makeTestUserDefaults(),
        missingCustomThemeNotifier: { _ in },
        systemIsDark: { systemIsDark }
    )
}

@MainActor
private func recursiveSubviews(in rootView: NSView) -> [NSView] {
    rootView.subviews + rootView.subviews.flatMap(recursiveSubviews(in:))
}

@MainActor
private func hasSuperview(named classNameSuffix: String, startingAt view: NSView) -> Bool {
    var currentView = view.superview
    while let view = currentView {
        if NSStringFromClass(type(of: view)).hasSuffix(classNameSuffix) {
            return true
        }
        currentView = view.superview
    }
    return false
}

@MainActor
private func assertAppKitColor(
    _ color: NSColor?,
    matches token: ReaderThemeColor,
    accuracy: CGFloat = 0.003,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let rgb = color?.usingColorSpace(.deviceRGB) else {
        XCTFail("Missing color", file: file, line: line)
        return
    }
    let expected = components(for: token.hex, alpha: token.alpha)

    XCTAssertEqual(rgb.redComponent, expected.red, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(rgb.greenComponent, expected.green, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(rgb.blueComponent, expected.blue, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(rgb.alphaComponent, expected.alpha, accuracy: accuracy, file: file, line: line)
}

private func components(for hex: String, alpha: Double) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
    let digits = String(hex.dropFirst())
    var value: UInt64 = 0
    Scanner(string: digits).scanHexInt64(&value)
    return (
        red: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: CGFloat(alpha)
    )
}

@MainActor
private final class RecordingThemeApplyingViewController: NSViewController, ThemeApplying {
    private(set) var applyThemeCount = 0

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 320, height: 240)))
        view.wantsLayer = true
    }

    func applyCurrentTheme() {
        applyThemeCount += 1
        view.layer?.backgroundColor = ReaderTheme.backgroundColor.cgColor
    }
}

@MainActor
private final class RecordingDocumentExportController: DocumentExportControlling {
    private(set) var printCalls: [(webView: WKWebView, window: NSWindow)] = []
    private(set) var pdfContexts: [DocumentExportContext] = []
    private(set) var htmlContexts: [DocumentExportContext] = []
    var canExportHTML = true

    func printDocument(_ webView: WKWebView, window: NSWindow) {
        printCalls.append((webView, window))
    }

    func exportPDF(from context: DocumentExportContext) {
        pdfContexts.append(context)
    }

    func exportHTML(from context: DocumentExportContext) {
        htmlContexts.append(context)
    }

    func canExportHTML(from context: DocumentExportContext) -> Bool {
        canExportHTML
    }
}
