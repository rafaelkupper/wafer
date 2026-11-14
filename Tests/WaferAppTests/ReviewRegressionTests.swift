import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class ReviewRegressionTests: XCTestCase {
    func testReaderDeallocatesWithoutTestOnlyInvalidation() {
        weak var releasedReader: WebKitReaderViewController?
        autoreleasepool {
            let reader = WebKitReaderViewController()
            releasedReader = reader
        }
        XCTAssertNil(releasedReader)
    }

    func testEmptyAndUTF16ReadsUseNormalRenderPath() throws {
        let reader = RecordingReaderViewController()
        var sources: [String] = []
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { source, _, _, _, _ in
                sources.append(source)
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader }
        )
        defer { document.close() }
        document.makeWindowControllers()
        try document.read(from: Data(), ofType: "dev.wafer.markdown")
        try document.read(from: "# Café".data(using: .utf16)!, ofType: "dev.wafer.markdown")
        try document.read(from: Data(), ofType: "dev.wafer.markdown")
        XCTAssertEqual(sources, ["", "# Café", ""])
    }

    func testAnchorRequestedAfterReaderCreationWaitsForRenderedContent() throws {
        let reader = RecordingReaderViewController()
        var completion: ((WebKitRenderOutput) -> Void)?
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { _, _, _, _, callback in
                completion = callback
                return DispatchWorkItem {}
            }, readerControllerFactory: { reader }
        )
        defer { document.close() }
        try document.read(from: Data("# Destination".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        document.navigateToAnchor(id: "destination")
        XCTAssertTrue(reader.scrolledHeadingIDs.isEmpty)
        completion?(WebKitRenderOutput(html: "<h1 id='destination'>Destination</h1>", baseURL: nil))
        reader.onNavigationFinished?()
        XCTAssertTrue(reader.scrolledHeadingIDs.isEmpty, "A loading placeholder must not consume the anchor")
        reader.stubbedContentReady = true
        reader.onNavigationFinished?()
        XCTAssertEqual(reader.scrolledHeadingIDs, ["destination"])
    }
    func testInactiveTabAdoptsThemeWhenSelectedWithoutAnotherRender() throws {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = AppearancePreferenceStore(defaults: defaults, systemIsDark: { true })
        appearance.appearanceSelection = .dark
        let firstReader = RecordingReaderViewController()
        let secondReader = RecordingReaderViewController()
        var renderCount = 0
        let scheduler: MarkdownReaderDocument.RenderScheduler = { _, _, _, _, completion in
            renderCount += 1
            completion(WebKitRenderOutput(html: "<html><body>Note</body></html>", baseURL: nil))
            return DispatchWorkItem {}
        }
        let first = MarkdownReaderDocument(librarySnapshotProvider: emptyTestLibrarySnapshot, scrollStateStore: makeTestScrollStateStore(), renderScheduler: scheduler, readerControllerFactory: { firstReader }, appearancePreferenceStore: appearance)
        let second = MarkdownReaderDocument(librarySnapshotProvider: emptyTestLibrarySnapshot, scrollStateStore: makeTestScrollStateStore(), renderScheduler: scheduler, readerControllerFactory: { secondReader }, appearancePreferenceStore: appearance)
        defer { first.close(); second.close() }
        try first.read(from: Data("# First".utf8), ofType: "dev.wafer.markdown")
        first.makeWindowControllers()
        let host = try XCTUnwrap(first.windowControllers.first as? DocumentHostWindowController)
        try second.read(from: Data("# Second".utf8), ofType: "dev.wafer.markdown")
        host.tabDocumentFactoryForTesting = { _ in second }
        host.openTab(for: URL(fileURLWithPath: "/tmp/wafer-theme-regression.md"))
        firstReader.stubbedContentReady = true
        secondReader.stubbedContentReady = true
        appearance.appearanceSelection = .light
        second.applyThemeIfNeeded()
        XCTAssertTrue(firstReader.updatedPalettes.isEmpty)
        host.selectTab(at: 0)
        XCTAssertEqual(firstReader.updatedPalettes, [.light])
        XCTAssertEqual(secondReader.updatedPalettes, [.light])
        XCTAssertEqual(renderCount, 2)
    }

}
