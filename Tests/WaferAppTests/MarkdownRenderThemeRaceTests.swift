import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class MarkdownRenderThemeRaceTests: XCTestCase {
    func testThemeChangedDuringFullRenderIsReappliedAfterPageLoad() throws {
        ReaderTheme.setCurrent(.dark)
        defer { ReaderTheme.resetToDefaultForTesting() }
        let suite = "Wafer.DocumentEditingReviewTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = AppearancePreferenceStore(defaults: defaults, systemIsDark: { true })
        appearance.appearanceSelection = .dark
        let reader = RecordingReaderViewController()
        var completions: [(WebKitRenderOutput) -> Void] = []
        var palettes: [ReaderThemePalette] = []
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { _, _, palette, _, completion in
                palettes.append(palette)
                completions.append(completion)
                return DispatchWorkItem {}
            },
            readerControllerFactory: { reader },
            appearancePreferenceStore: appearance
        )
        defer { document.close() }
        try document.read(from: Data("first".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        completions[0](WebKitRenderOutput(html: "first", baseURL: nil))
        reader.stubbedContentReady = true
        reader.onNavigationFinished?()
        // A full re-render is still running while the ready old page is patched.
        try document.read(from: Data("second".utf8), ofType: "dev.wafer.markdown")
        appearance.appearanceSelection = .light
        document.applyThemeIfNeeded()
        XCTAssertEqual(reader.updatedPalettes.map(\.name), ["Light"])
        reader.stubbedContentReady = false
        completions[1](WebKitRenderOutput(html: "second", baseURL: nil))
        reader.stubbedContentReady = true
        reader.onNavigationFinished?()
        XCTAssertEqual(palettes.map(\.name), ["Dark", "Dark"])
        XCTAssertEqual(reader.updatedPalettes.map(\.name), ["Light", "Light"], "The new dark page must catch up to the current light theme")
    }
}
