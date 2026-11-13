import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class AppDelegateTests: XCTestCase {
    func testApplicationOpenURLsForwardsAllValues() {
        var opened: [URL] = []
        let delegate = AppDelegate(openURLs: { opened.append(contentsOf: $0) }, reopenPersistedLibrary: {})
        let urls = [
            URL(fileURLWithPath: "/tmp/docs/One.md"),
            URL(fileURLWithPath: "/tmp/docs/Two.md"),
        ]

        delegate.application(NSApplication.shared, open: urls)

        XCTAssertEqual(opened, urls)
    }

    func testApplicationOpenRoutesDirectoriesToLibraryAndFilesToDocumentOpener() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "Guide.md", contents: "# Guide")
        var openedDocuments: [URL] = []
        var openedLibraries: [URL] = []
        var pendingFirstScanCompletion: LibraryController.FirstScanCompletion?
        var openedInitialFiles: [[LibraryFile]] = []
        let delegate = AppDelegate(
            openURLs: { openedDocuments.append(contentsOf: $0) },
            openLibrary: { url, onFirstScanCompletion in
                openedLibraries.append(url)
                pendingFirstScanCompletion = onFirstScanCompletion
            },
            openInitialLibraryDocument: { openedInitialFiles.append($0) },
            reopenPersistedLibrary: {}
        )

        delegate.application(NSApplication.shared, open: [tempDirectory.url, fileURL])

        XCTAssertEqual(openedLibraries, [tempDirectory.url])
        XCTAssertTrue(openedInitialFiles.isEmpty)
        XCTAssertEqual(openedDocuments, [fileURL])

        let files = [libraryFile(url: fileURL, title: "Guide")]
        pendingFirstScanCompletion?(files)

        XCTAssertEqual(openedInitialFiles, [files])
    }

    func testLaunchAppliesResolvedAppearanceBeforeDocumentsOpen() throws {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let themeLibrary = ThemeLibrary(
            themesDirectoryURL: tempDirectory.url.appendingPathComponent("Themes", isDirectory: true),
            bundledThemesDirectoryURL: nil,
            revealHandler: { _ in }
        )
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AppearancePreferenceStore(defaults: defaults, themeLibrary: themeLibrary, systemIsDark: { true })
        var reopenedLibrary = false
        let delegate = AppDelegate(
            openURLs: { _ in },
            reopenPersistedLibrary: { reopenedLibrary = true },
            appearancePreferenceStore: store
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(ReaderTheme.current, .dark)
        XCTAssertTrue(FileManager.default.fileExists(atPath: themeLibrary.themesDirectoryURL.path))
        XCTAssertTrue(reopenedLibrary)
    }
}

private func libraryFile(url: URL, title: String) -> LibraryFile {
    LibraryFile(
        fileURL: url,
        relativePathComponents: [url.lastPathComponent],
        displayTitle: title,
        outlineItems: [],
        plainText: "",
        searchableText: "",
        contentFingerprint: LibraryFileFingerprint(
            modificationDate: Date(timeIntervalSince1970: 0),
            fileSize: 0
        )
    )
}
