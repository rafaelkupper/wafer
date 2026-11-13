import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class MarkdownReaderDocumentTests: XCTestCase {
    func testObjectiveCNewPathCanInstantiateMarkdownDocument() throws {
        let document = try XCTUnwrap(
            (MarkdownReaderDocument.self as AnyObject)
                .perform(NSSelectorFromString("new"))?
                .takeRetainedValue() as? MarkdownReaderDocument
        )

        document.close()
    }

    func testDocumentCreatesConcreteWebKitReaderWindowController() throws {
        let reader = RecordingReaderViewController()
        let document = MarkdownReaderDocument(readerControllerFactory: { reader })
        document.fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Test.md")
        try document.read(from: Data("# Title".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()

        let windowController = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        XCTAssertTrue(windowController.hostedContentViewController is WebKitReaderViewController)
        document.close()
    }

    func testCopySourceWritesMarkdownOnlyAfterSourceLoads() throws {
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} },
            readerControllerFactory: { RecordingReaderViewController() }
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer {
            pasteboard.releaseGlobally()
            document.close()
        }

        XCTAssertFalse(document.copySourceToPasteboard(pasteboard))

        let source = "# Guide\n\nSome **bold** text.\n"
        try document.read(from: Data(source.utf8), ofType: "dev.wafer.markdown")

        XCTAssertTrue(document.copySourceToPasteboard(pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), source)
    }

    func testCopyFileWritesFileURLOnlyAfterSourceLoads() throws {
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} },
            readerControllerFactory: { RecordingReaderViewController() }
        )
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Guide.md")
        document.fileURL = fileURL
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer {
            pasteboard.releaseGlobally()
            document.close()
        }

        XCTAssertFalse(document.copyFileToPasteboard(pasteboard))

        try document.read(from: Data("# Guide".utf8), ofType: "dev.wafer.markdown")

        XCTAssertTrue(document.copyFileToPasteboard(pasteboard))
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls?.map(\.standardizedFileURL), [fileURL.standardizedFileURL])
    }

    func testSchedulesRenderAfterReadAndWindowCreation() throws {
        let reader = RecordingReaderViewController()
        var scheduledSource: String?
        var capturedCompletion: ((WebKitRenderOutput) -> Void)?
        let document = MarkdownReaderDocument(
            renderScheduler: { source, _, _, _, completion in
                scheduledSource = source
                capturedCompletion = completion
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Guide.md")

        try document.read(from: Data("# Guide".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()

        XCTAssertEqual(scheduledSource, "# Guide")
        XCTAssertEqual(reader.displayedLoadingNames.last, "Guide.md")

        capturedCompletion?(WebKitRenderOutput(html: "<html><body>Done</body></html>", baseURL: nil))

        XCTAssertEqual(reader.appliedOutputs.count, 1)
        XCTAssertEqual(reader.appliedOutputs.first?.html, "<html><body>Done</body></html>")
        document.close()
    }

    func testRenderCompletionUpdatesWindowStatistics() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = DocumentStatisticPreferenceStore(defaults: defaults)
        let reader = RecordingReaderViewController()
        var capturedCompletion: ((WebKitRenderOutput) -> Void)?
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, _, _, completion in
                capturedCompletion = completion
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            statisticPreferenceStore: store
        )
        document.fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Stats.md")

        try document.read(from: Data("# Stats".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()

        let windowController = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        XCTAssertNil(windowController.displayedStatisticTextForTesting)

        capturedCompletion?(
            WebKitRenderOutput(
                html: "<html><body>Stats</body></html>",
                baseURL: nil,
                statistics: DocumentStatistics(words: 12, minutes: 1, lines: 3, characters: 64),
                sidebarEntries: [
                    DocumentSidebarEntry(
                        fileURL: URL(fileURLWithPath: "/tmp/Stats.md"),
                        displayTitle: "Stats",
                        previewText: "Preview",
                        isCurrent: true,
                        isAvailable: true
                    ),
                ],
                outlineItems: [
                    DocumentOutlineItem(title: "Stats", level: 1, anchorID: "stats"),
                ]
            )
        )

        XCTAssertEqual(windowController.displayedStatisticTextForTesting, "12 Words")
        XCTAssertEqual(windowController.sidebarDocumentTitlesForTesting, ["Stats"])
        XCTAssertEqual(windowController.outlineTitlesForTesting, ["Stats"])
        document.close()
    }

    func testRestoresPersistedScrollFractionIntoRenderedReader() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ScrollStateStore(defaults: defaults)
        let reader = RecordingReaderViewController()
        var capturedCompletion: ((WebKitRenderOutput) -> Void)?
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Restore.md")
        let data = Data("# Restore".utf8)
        let fingerprint = FileFingerprint.sha256Hex(for: data)
        store.save(fraction: 0.42, for: fileURL, fingerprint: fingerprint)

        let document = MarkdownReaderDocument(
            scrollStateStore: store,
            renderScheduler: { _, _, _, _, completion in
                capturedCompletion = completion
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = fileURL

        try document.read(from: data, ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        capturedCompletion?(WebKitRenderOutput(html: "<html><body>Rendered</body></html>", baseURL: nil))

        XCTAssertEqual(try XCTUnwrap(reader.appliedInitialScrollFractions.last ?? nil), 0.42, accuracy: 0.0001)
        document.close()
    }

    func testPersistsCurrentScrollFractionOnClose() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ScrollStateStore(defaults: defaults)
        let reader = RecordingReaderViewController()
        reader.stubbedCurrentScrollFraction = 0.73

        let document = MarkdownReaderDocument(
            scrollStateStore: store,
            renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} },
            readerControllerFactory: { reader }
        )
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Persist.md")
        let data = Data("# Persist".utf8)
        let fingerprint = FileFingerprint.sha256Hex(for: data)
        document.fileURL = fileURL

        try document.read(from: data, ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        document.close()

        let saved = store.load(for: fileURL, fingerprint: fingerprint)
        XCTAssertEqual(saved?.fraction ?? -1, 0.73, accuracy: 0.0001)
    }

    func testScrollPositionChangesPersistOnlyLatestFractionAfterDebounce() throws {
        let defaults = RecordingUserDefaults()
        let store = ScrollStateStore(defaults: defaults)
        let reader = RecordingReaderViewController()
        reader.stubbedCurrentScrollFraction = 0.84

        let document = MarkdownReaderDocument(
            scrollStateStore: store,
            renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} },
            readerControllerFactory: { reader },
            scrollPersistenceDebounceInterval: 0.05
        )
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Debounce.md")
        let data = Data("# Debounce".utf8)
        let fingerprint = FileFingerprint.sha256Hex(for: data)
        document.fileURL = fileURL

        try document.read(from: data, ofType: "dev.wafer.markdown")
        document.makeWindowControllers()

        reader.onScrollPositionChange?(0.21)
        reader.onScrollPositionChange?(0.84)

        XCTAssertNil(store.load(for: fileURL, fingerprint: fingerprint))
        XCTAssertEqual(defaults.setCount, 0)

        let persisted = expectation(description: "debounced scroll position persisted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            persisted.fulfill()
        }
        wait(for: [persisted], timeout: 1)

        XCTAssertEqual(defaults.setCount, 1)
        XCTAssertEqual(store.load(for: fileURL, fingerprint: fingerprint)?.fraction ?? -1, 0.84, accuracy: 0.0001)
        document.close()
    }

    func testIgnoresStaleAsyncRenderCompletions() throws {
        let reader = RecordingReaderViewController()
        var completions: [(WebKitRenderOutput) -> Void] = []
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, _, _, completion in
                completions.append(completion)
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Async.md")

        try document.read(from: Data("# First".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        try document.read(from: Data("# Second".utf8), ofType: "dev.wafer.markdown")

        XCTAssertEqual(completions.count, 2)

        completions[0](WebKitRenderOutput(html: "<html>old</html>", baseURL: nil))
        XCTAssertTrue(reader.appliedOutputs.isEmpty)

        completions[1](WebKitRenderOutput(html: "<html>new</html>", baseURL: nil))
        XCTAssertEqual(reader.appliedOutputs.count, 1)
        XCTAssertEqual(reader.appliedOutputs.first?.html, "<html>new</html>")
        document.close()
    }

    func testRoutesLinksThroughInjectedTargetHandler() throws {
        let reader = RecordingReaderViewController()
        var handledTargets: [LinkTarget] = []
        var openedMarkdownLinks: [(URL, String?)] = []
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} },
            markdownLinkOpener: { url, anchorID in
                openedMarkdownLinks.append((url, anchorID))
            },
            linkTargetHandler: { handledTargets.append($0) },
            readerControllerFactory: { reader }
        )
        document.fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Links.md")

        try document.read(from: Data("# Links".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()

        reader.onOpenLink?(URL(string: "https://example.com")!)
        reader.onOpenLink?(URL(fileURLWithPath: "/tmp/docs/Guide.md"))
        reader.onOpenLink?(URL(fileURLWithPath: "/tmp/docs/notes.txt"))

        XCTAssertEqual(handledTargets.count, 2)
        XCTAssertEqual(openedMarkdownLinks.count, 1)
        XCTAssertEqual(handledTargets[0], .external(URL(string: "https://example.com")!))
        XCTAssertEqual(handledTargets[1], .otherFile(URL(fileURLWithPath: "/tmp/docs/notes.txt")))
        XCTAssertEqual(openedMarkdownLinks[0].0, URL(fileURLWithPath: "/tmp/docs/Guide.md"))
        XCTAssertNil(openedMarkdownLinks[0].1)
        document.close()
    }

    func testSameDocumentFragmentLinkScrollsInCurrentReaderWithoutOpeningNewDocument() throws {
        let reader = RecordingReaderViewController()
        var handledTargets: [LinkTarget] = []
        var openedMarkdownLinks: [(URL, String?)] = []
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} },
            markdownLinkOpener: { url, anchorID in
                openedMarkdownLinks.append((url, anchorID))
            },
            linkTargetHandler: { handledTargets.append($0) },
            readerControllerFactory: { reader }
        )
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Anchor.md")
        document.fileURL = fileURL

        try document.read(from: Data("# Anchor".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()

        var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
        components?.fragment = "heading-ladder"
        reader.onOpenLink?(try XCTUnwrap(components?.url))

        XCTAssertEqual(reader.scrolledHeadingIDs, ["heading-ladder"])
        XCTAssertTrue(handledTargets.isEmpty)
        XCTAssertTrue(openedMarkdownLinks.isEmpty)
        document.close()
    }

    func testCrossDocumentFragmentLinkUsesMarkdownOpenPathAndPreservesAnchor() throws {
        let reader = RecordingReaderViewController()
        var openedMarkdownLinks: [(URL, String?)] = []
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} },
            markdownLinkOpener: { url, anchorID in
                openedMarkdownLinks.append((url, anchorID))
            },
            readerControllerFactory: { reader }
        )
        let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Source.md")
        let targetURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Guide.md")
        document.fileURL = sourceURL

        try document.read(from: Data("# Source".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()

        var components = URLComponents(url: targetURL, resolvingAgainstBaseURL: false)
        components?.fragment = "deep-link"
        reader.onOpenLink?(try XCTUnwrap(components?.url))

        XCTAssertEqual(openedMarkdownLinks.count, 1)
        XCTAssertEqual(openedMarkdownLinks[0].0, targetURL)
        XCTAssertEqual(openedMarkdownLinks[0].1, "deep-link")
        XCTAssertTrue(reader.scrolledHeadingIDs.isEmpty)
        document.close()
    }

    func testSidebarNavigationReplacesCurrentFileInSameWindow() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let firstURL = try tempDirectory.createTextFile(named: "One.md", contents: "# One")
        let secondURL = try tempDirectory.createTextFile(named: "Two.md", contents: "# Two")

        let reader = RecordingReaderViewController()
        var scheduledURLs: [URL] = []
        var completions: [(WebKitRenderOutput) -> Void] = []
        let secondRenderScheduled = expectation(description: "second render scheduled")
        let document = MarkdownReaderDocument(
            renderScheduler: { _, baseURL, _, _, completion in
                if let baseURL {
                    scheduledURLs.append(baseURL)
                }
                completions.append(completion)
                if baseURL == secondURL {
                    secondRenderScheduled.fulfill()
                }
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = firstURL

        try document.read(from: Data("# One".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        completions[0](WebKitRenderOutput(html: "<html>one</html>", baseURL: nil))

        document.navigateInCurrentWindow(to: secondURL)

        wait(for: [secondRenderScheduled], timeout: 5)
        let windowController = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        XCTAssertEqual(document.fileURL, secondURL)
        XCTAssertEqual(windowController.window?.title, "Two.md")
        XCTAssertEqual(reader.displayedLoadingNames.last, "Two.md")
        XCTAssertEqual(scheduledURLs.last, secondURL)

        completions[1](
            WebKitRenderOutput(
                html: "<html>two</html>",
                baseURL: nil,
                statistics: DocumentStatistics(words: 8, minutes: 1, lines: 2, characters: 32),
                sidebarEntries: [
                    DocumentSidebarEntry(
                        fileURL: secondURL,
                        displayTitle: "Two",
                        previewText: "Second preview",
                        isCurrent: true,
                        isAvailable: true
                    ),
                ],
                outlineItems: [
                    DocumentOutlineItem(title: "Two", level: 1, anchorID: "two"),
                ]
            )
        )

        XCTAssertEqual(windowController.displayedStatisticTextForTesting, "8 Words")
        XCTAssertEqual(windowController.sidebarDocumentTitlesForTesting, ["Two"])
        XCTAssertEqual(windowController.outlineTitlesForTesting, ["Two"])
        document.close()
    }

    func testFileMonitorStartsRestartsAndStopsWithDocumentLifecycle() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let firstURL = try tempDirectory.createTextFile(named: "One.md", contents: "# One")
        let secondURL = try tempDirectory.createTextFile(named: "Two.md", contents: "# Two")

        let reader = RecordingReaderViewController()
        var monitors: [FakeFileMonitor] = []
        let secondRenderScheduled = expectation(description: "second render scheduled")
        let document = MarkdownReaderDocument(
            renderScheduler: { _, baseURL, _, _, _ in
                if baseURL == secondURL {
                    secondRenderScheduled.fulfill()
                }
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            fileMonitorFactory: { fileURL, onChange in
                let monitor = FakeFileMonitor(fileURL: fileURL, onChange: onChange)
                monitors.append(monitor)
                return monitor
            }
        )
        document.fileURL = firstURL

        try document.read(from: Data("# One".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()

        XCTAssertEqual(monitors.count, 1)
        XCTAssertEqual(monitors[0].fileURL, firstURL)
        XCTAssertEqual(monitors[0].startCount, 1)
        XCTAssertEqual(monitors[0].stopCount, 0)

        document.navigateInCurrentWindow(to: secondURL)
        wait(for: [secondRenderScheduled], timeout: 5)

        XCTAssertEqual(monitors.count, 2)
        XCTAssertEqual(monitors[0].stopCount, 1)
        XCTAssertEqual(monitors[1].fileURL, secondURL)
        XCTAssertEqual(monitors[1].startCount, 1)

        document.close()

        XCTAssertEqual(monitors[1].stopCount, 1)
    }

    func testLiveReloadChangedContentRendersWithoutLoadingPlaceholder() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "Live.md", contents: "# Live")
        let changedData = Data("# Live\nChanged".utf8)

        let reader = RecordingReaderViewController()
        var monitors: [FakeFileMonitor] = []
        var scheduledSources: [String] = []
        var completions: [(WebKitRenderOutput) -> Void] = []
        let reloadRenderScheduled = expectation(description: "reload render scheduled")
        let document = MarkdownReaderDocument(
            renderScheduler: { source, _, _, _, completion in
                scheduledSources.append(source)
                completions.append(completion)
                if scheduledSources.count == 2 {
                    reloadRenderScheduled.fulfill()
                }
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            sourceLoader: { _ in
                LoadedMarkdownSource(
                    sourceText: String(decoding: changedData, as: UTF8.self),
                    fingerprint: FileFingerprint.sha256Hex(for: changedData)
                )
            },
            fileMonitorFactory: { fileURL, onChange in
                let monitor = FakeFileMonitor(fileURL: fileURL, onChange: onChange)
                monitors.append(monitor)
                return monitor
            }
        )
        document.fileURL = fileURL

        try document.read(from: Data("# Live".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        completions[0](
            WebKitRenderOutput(
                html: "<html><body>Live</body></html>",
                baseURL: nil,
                statistics: DocumentStatistics(words: 3, minutes: 1, lines: 1, characters: 12),
                outlineItems: [
                    DocumentOutlineItem(title: "Live", level: 1, anchorID: "live"),
                ]
            )
        )
        reader.onActiveHeadingChange?("live")

        let windowController = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let loadingCountBeforeReload = reader.displayedLoadingNames.count
        XCTAssertEqual(windowController.displayedStatisticTextForTesting, "3 Words")
        XCTAssertEqual(windowController.activeOutlineAnchorIDForTesting, "live")

        monitors[0].fireChange()

        wait(for: [reloadRenderScheduled], timeout: 5)

        XCTAssertEqual(scheduledSources, ["# Live", "# Live\nChanged"])
        XCTAssertEqual(reader.displayedLoadingNames.count, loadingCountBeforeReload)
        XCTAssertEqual(windowController.displayedStatisticTextForTesting, "3 Words")
        XCTAssertEqual(windowController.activeOutlineAnchorIDForTesting, "live")
        document.close()
    }

    func testThemeChangeUpdatesReadyDocumentWithoutRenderingOrLoadingPlaceholder() throws {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let reader = RecordingReaderViewController()
        reader.stubbedCurrentScrollFraction = 0.37
        let appearanceDefaults = UserDefaults(suiteName: UUID().uuidString)!
        let appearanceStore = AppearancePreferenceStore(
            defaults: appearanceDefaults,
            systemIsDark: { false }
        )
        var scheduledPalettes: [ReaderThemePalette] = []
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, palette, _, completion in
                scheduledPalettes.append(palette)
                completion(WebKitRenderOutput(html: "<html><body>Rendered</body></html>", baseURL: nil))
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            appearancePreferenceStore: appearanceStore
        )
        document.fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Theme.md")

        try document.read(from: Data("# Theme".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        let loadingCountBeforeThemeChange = reader.displayedLoadingNames.count

        reader.stubbedContentReady = true
        appearanceStore.appearanceSelection = .light

        XCTAssertEqual(reader.displayedLoadingNames.count, loadingCountBeforeThemeChange)
        XCTAssertEqual(reader.currentScrollFraction, 0.37, accuracy: 0.0001)
        XCTAssertEqual(scheduledPalettes, [.dark])
        XCTAssertEqual(reader.updatedPalettes, [.light])
        document.close()
    }

    func testLiveReloadWithIdenticalFingerprintSchedulesNoRender() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "Same.md", contents: "# Same")
        let data = Data("# Same".utf8)

        let reader = RecordingReaderViewController()
        var monitors: [FakeFileMonitor] = []
        var renderCount = 0
        let reloadSettled = expectation(description: "reload settled")
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, _, _, _ in
                renderCount += 1
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            sourceLoader: { _ in
                LoadedMarkdownSource(
                    sourceText: String(decoding: data, as: UTF8.self),
                    fingerprint: FileFingerprint.sha256Hex(for: data)
                )
            },
            fileMonitorFactory: { fileURL, onChange in
                let monitor = FakeFileMonitor(fileURL: fileURL, onChange: onChange)
                monitors.append(monitor)
                return monitor
            }
        )
        document.fileURL = fileURL

        try document.read(from: data, ofType: "dev.wafer.markdown")
        document.makeWindowControllers()

        monitors[0].fireChange()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            reloadSettled.fulfill()
        }
        wait(for: [reloadSettled], timeout: 1)

        XCTAssertEqual(renderCount, 1)
        document.close()
    }

    func testAutoReloadDisabledIgnoresMonitorButManualReloadStillReloads() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "Manual.md", contents: "# Manual")
        let changedData = Data("# Manual\nChanged".utf8)
        let preferenceStore = ReaderBehaviorPreferenceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        preferenceStore.automaticallyReloadsDocuments = false

        let reader = RecordingReaderViewController()
        var monitors: [FakeFileMonitor] = []
        var scheduledSources: [String] = []
        let manualReloadScheduled = expectation(description: "manual reload scheduled")
        let document = MarkdownReaderDocument(
            renderScheduler: { source, _, _, _, _ in
                scheduledSources.append(source)
                if scheduledSources.count == 2 {
                    manualReloadScheduled.fulfill()
                }
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            readerBehaviorPreferenceStore: preferenceStore,
            sourceLoader: { _ in
                LoadedMarkdownSource(
                    sourceText: String(decoding: changedData, as: UTF8.self),
                    fingerprint: FileFingerprint.sha256Hex(for: changedData)
                )
            },
            fileMonitorFactory: { fileURL, onChange in
                let monitor = FakeFileMonitor(fileURL: fileURL, onChange: onChange)
                monitors.append(monitor)
                return monitor
            }
        )
        document.fileURL = fileURL

        try document.read(from: Data("# Manual".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()

        monitors[0].fireChange()
        XCTAssertEqual(scheduledSources, ["# Manual"])

        document.reloadDocument(nil)
        wait(for: [manualReloadScheduled], timeout: 5)

        XCTAssertEqual(scheduledSources, ["# Manual", "# Manual\nChanged"])
        document.close()
    }

    func testReloadDocumentValidationRequiresFileURL() throws {
        let document = MarkdownReaderDocument(renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} })
        let reloadItem = NSMenuItem(
            title: "Reload",
            action: #selector(MarkdownReaderDocument.reloadDocument(_:)),
            keyEquivalent: "r"
        )

        XCTAssertFalse(document.validateUserInterfaceItem(reloadItem))

        document.fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Reload.md")

        XCTAssertTrue(document.validateUserInterfaceItem(reloadItem))
        document.close()
    }

    func testLiveReloadPreservesScrollFractionAndSticksAtBottom() throws {
        try assertLiveReloadRestores(currentFraction: 0.5, expectedRestoredFraction: 0.5)
        try assertLiveReloadRestores(currentFraction: 0.99, expectedRestoredFraction: 1.0)
    }

    func testStaleLiveReloadCompletionDoesNotClobberNavigation() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let firstURL = try tempDirectory.createTextFile(named: "One.md", contents: "# One")
        let secondURL = try tempDirectory.createTextFile(named: "Two.md", contents: "# Two")
        let delayedReloadCanFinish = DispatchSemaphore(value: 0)

        let reader = RecordingReaderViewController()
        var monitors: [FakeFileMonitor] = []
        var scheduledURLs: [URL] = []
        let secondRenderScheduled = expectation(description: "second render scheduled")
        let staleReloadSettled = expectation(description: "stale reload settled")
        let document = MarkdownReaderDocument(
            renderScheduler: { _, baseURL, _, _, _ in
                if let baseURL {
                    scheduledURLs.append(baseURL)
                    if baseURL == secondURL {
                        secondRenderScheduled.fulfill()
                    }
                }
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            sourceLoader: { url in
                if url == firstURL {
                    delayedReloadCanFinish.wait()
                    return LoadedMarkdownSource(
                        sourceText: "# One\nStale",
                        fingerprint: FileFingerprint.sha256Hex(for: Data("# One\nStale".utf8))
                    )
                }

                return LoadedMarkdownSource(
                    sourceText: "# Two",
                    fingerprint: FileFingerprint.sha256Hex(for: Data("# Two".utf8))
                )
            },
            fileMonitorFactory: { fileURL, onChange in
                let monitor = FakeFileMonitor(fileURL: fileURL, onChange: onChange)
                monitors.append(monitor)
                return monitor
            }
        )
        document.fileURL = firstURL

        try document.read(from: Data("# One".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        monitors[0].fireChange()
        document.navigateInCurrentWindow(to: secondURL)

        wait(for: [secondRenderScheduled], timeout: 5)
        delayedReloadCanFinish.signal()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            staleReloadSettled.fulfill()
        }
        wait(for: [staleReloadSettled], timeout: 1)

        XCTAssertEqual(document.fileURL, secondURL)
        XCTAssertEqual(scheduledURLs, [firstURL, secondURL])
        document.close()
    }

    func testSidebarNavigationPersistsOldScrollAndRestoresTargetScroll() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ScrollStateStore(defaults: defaults)
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let firstContents = "# One"
        let secondContents = "# Two"
        let firstURL = try tempDirectory.createTextFile(named: "One.md", contents: firstContents)
        let secondURL = try tempDirectory.createTextFile(named: "Two.md", contents: secondContents)

        let firstFingerprint = FileFingerprint.sha256Hex(for: Data(firstContents.utf8))
        let secondFingerprint = FileFingerprint.sha256Hex(for: Data(secondContents.utf8))
        store.save(fraction: 0.41, for: secondURL, fingerprint: secondFingerprint)

        let reader = RecordingReaderViewController()
        reader.stubbedCurrentScrollFraction = 0.73

        var completions: [(WebKitRenderOutput) -> Void] = []
        let secondRenderScheduled = expectation(description: "second render scheduled")
        let document = MarkdownReaderDocument(
            scrollStateStore: store,
            renderScheduler: { _, baseURL, _, _, completion in
                completions.append(completion)
                if baseURL == secondURL {
                    secondRenderScheduled.fulfill()
                }
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = firstURL

        try document.read(from: Data(firstContents.utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        completions[0](WebKitRenderOutput(html: "<html>one</html>", baseURL: nil))

        document.navigateInCurrentWindow(to: secondURL)
        wait(for: [secondRenderScheduled], timeout: 5)
        completions[1](WebKitRenderOutput(html: "<html>two</html>", baseURL: nil))

        XCTAssertEqual(store.load(for: firstURL, fingerprint: firstFingerprint)?.fraction ?? -1, 0.73, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(reader.appliedInitialScrollFractions.last ?? nil), 0.41, accuracy: 0.0001)
        document.close()
    }

    func testPendingAnchorOverridesPersistedScrollRestoreAndScrollsAfterRenderFinishes() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ScrollStateStore(defaults: defaults)
        let reader = RecordingReaderViewController()
        var capturedCompletion: ((WebKitRenderOutput) -> Void)?
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Anchored.md")
        let data = Data("# Anchored".utf8)
        let fingerprint = FileFingerprint.sha256Hex(for: data)
        store.save(fraction: 0.58, for: fileURL, fingerprint: fingerprint)

        let document = MarkdownReaderDocument(
            scrollStateStore: store,
            renderScheduler: { _, _, _, _, completion in
                capturedCompletion = completion
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = fileURL
        document.navigateToAnchor(id: "deep-link")

        try document.read(from: data, ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        capturedCompletion?(WebKitRenderOutput(html: "<html><body>Anchored</body></html>", baseURL: nil))
        reader.stubbedContentReady = true
        reader.onNavigationFinished?()

        XCTAssertNil(reader.appliedInitialScrollFractions.last ?? nil)
        XCTAssertEqual(reader.scrolledHeadingIDs, ["deep-link"])
        document.close()
    }

    func testNavigateInCurrentWindowWithAnchorScrollsAfterReplacementRenderFinishes() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let firstURL = try tempDirectory.createTextFile(named: "One.md", contents: "# One")
        let secondURL = try tempDirectory.createTextFile(named: "Two.md", contents: "# Two\n\n## Target")

        let reader = RecordingReaderViewController()
        var completions: [((WebKitRenderOutput) -> Void)] = []
        let secondRenderScheduled = expectation(description: "second render scheduled")
        let document = MarkdownReaderDocument(
            renderScheduler: { _, baseURL, _, _, completion in
                completions.append(completion)
                if baseURL == secondURL {
                    secondRenderScheduled.fulfill()
                }
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = firstURL

        try document.read(from: Data("# One".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        completions[0](WebKitRenderOutput(html: "<html>one</html>", baseURL: nil))

        document.navigateInCurrentWindow(to: secondURL, anchorID: "target")
        wait(for: [secondRenderScheduled], timeout: 5)
        completions[1](WebKitRenderOutput(html: "<html>two</html>", baseURL: nil))
        reader.stubbedContentReady = true
        reader.onNavigationFinished?()

        XCTAssertNil(reader.appliedInitialScrollFractions.last ?? nil)
        XCTAssertEqual(reader.scrolledHeadingIDs, ["target"])
        document.close()
    }

    func testOutlineSelectionScrollsReaderToHeading() throws {
        let reader = RecordingReaderViewController()
        var capturedCompletion: ((WebKitRenderOutput) -> Void)?
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, _, _, completion in
                capturedCompletion = completion
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Outline.md")

        try document.read(from: Data("# Outline".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        capturedCompletion?(
            WebKitRenderOutput(
                html: "<html><body>Outline</body></html>",
                baseURL: nil,
                outlineItems: [DocumentOutlineItem(title: "Outline", level: 1, anchorID: "outline")]
            )
        )

        let windowController = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        windowController.triggerOutlineSelectionForTesting("outline")

        XCTAssertEqual(reader.scrolledHeadingIDs, ["outline"])
        document.close()
    }

    func testActiveHeadingUpdatesWindowOutlineSelection() throws {
        let reader = RecordingReaderViewController()
        var capturedCompletion: ((WebKitRenderOutput) -> Void)?
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, _, _, completion in
                capturedCompletion = completion
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        document.fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Outline.md")

        try document.read(from: Data("# Outline".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        capturedCompletion?(
            WebKitRenderOutput(
                html: "<html><body>Outline</body></html>",
                baseURL: nil,
                outlineItems: [DocumentOutlineItem(title: "Outline", level: 1, anchorID: "outline")]
            )
        )

        let windowController = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        reader.onActiveHeadingChange?("outline")

        XCTAssertEqual(windowController.activeOutlineAnchorIDForTesting, "outline")
        document.close()
    }

    private func assertLiveReloadRestores(currentFraction: Double, expectedRestoredFraction: Double) throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "Scroll.md", contents: "# Scroll")
        let changedData = Data("# Scroll\nChanged \(currentFraction)".utf8)

        let reader = RecordingReaderViewController()
        reader.stubbedCurrentScrollFraction = currentFraction
        var monitors: [FakeFileMonitor] = []
        let reloadRenderScheduled = expectation(description: "reload render scheduled")
        let document = MarkdownReaderDocument(
            renderScheduler: { _, _, _, _, completion in
                if reader.appliedInitialScrollFractions.count == 1 {
                    reloadRenderScheduled.fulfill()
                }
                completion(WebKitRenderOutput(html: "<html><body>Rendered</body></html>", baseURL: nil))
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            sourceLoader: { _ in
                LoadedMarkdownSource(
                    sourceText: String(decoding: changedData, as: UTF8.self),
                    fingerprint: FileFingerprint.sha256Hex(for: changedData)
                )
            },
            fileMonitorFactory: { fileURL, onChange in
                let monitor = FakeFileMonitor(fileURL: fileURL, onChange: onChange)
                monitors.append(monitor)
                return monitor
            }
        )
        document.fileURL = fileURL

        try document.read(from: Data("# Scroll".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        monitors[0].fireChange()

        wait(for: [reloadRenderScheduled], timeout: 5)

        XCTAssertEqual(try XCTUnwrap(reader.appliedInitialScrollFractions.last ?? nil), expectedRestoredFraction, accuracy: 0.0001)
        document.close()
    }
}

private final class RecordingUserDefaults: UserDefaults {
    private var storage: [String: Any] = [:]
    private(set) var setCount = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        setCount += 1
        storage[defaultName] = value
    }

    override func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    override func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }

    override func dictionaryRepresentation() -> [String: Any] {
        storage
    }
}

@MainActor
private final class FakeFileMonitor: FileChangeMonitoring {
    let fileURL: URL
    let onChange: () -> Void
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(fileURL: URL, onChange: @escaping () -> Void) {
        self.fileURL = fileURL
        self.onChange = onChange
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func fireChange() {
        onChange()
    }
}
