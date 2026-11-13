import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class QuickOpenPanelControllerTests: XCTestCase {
    func testResultsUpdatePerQueryUsingInjectedFiles() {
        let controller = makeController(files: [
            libraryFile(path: "Guides/RenderingShowcase.md", title: "Rendering Showcase"),
            libraryFile(path: "Docs/DocumentSidebar.md", title: "Document Sidebar"),
            libraryFile(path: "Notes/Release.md", title: "Release Notes"),
        ])

        controller.setQueryForTesting("rsh")
        waitForSearch(controller)

        XCTAssertEqual(controller.resultTitlesForTesting, ["Rendering Showcase"])

        controller.setQueryForTesting("docside")
        waitForSearch(controller)

        XCTAssertEqual(controller.resultTitlesForTesting, ["Document Sidebar"])
    }

    func testSelectionWrapsThroughResults() {
        let controller = makeController(files: [
            libraryFile(path: "Alpha.md", title: "Alpha"),
            libraryFile(path: "Beta.md", title: "Beta"),
            libraryFile(path: "Gamma.md", title: "Gamma"),
        ])

        controller.setQueryForTesting("a")
        waitForSearch(controller)

        XCTAssertEqual(controller.selectedResultIndexForTesting, 0)

        controller.moveSelectionForTesting(by: -1)
        XCTAssertEqual(controller.selectedResultIndexForTesting, controller.resultCountForTesting - 1)

        controller.moveSelectionForTesting(by: 1)
        XCTAssertEqual(controller.selectedResultIndexForTesting, 0)
    }

    func testReturnInvokesCurrentWindowOpenCallbackWithSelectedURL() {
        let firstFile = libraryFile(path: "Intro.md", title: "Intro")
        let secondFile = libraryFile(path: "DeepDive.md", title: "Deep Dive")
        var currentWindowOpens: [URL] = []
        var newWindowOpens: [URL] = []
        let controller = makeController(
            files: [firstFile, secondFile],
            openInCurrentWindow: { url, _ in currentWindowOpens.append(url) },
            openInNewWindow: { url, _ in newWindowOpens.append(url) }
        )

        controller.setQueryForTesting("deep")
        waitForSearch(controller)
        controller.submitSelectionForTesting()

        XCTAssertEqual(currentWindowOpens, [secondFile.fileURL])
        XCTAssertTrue(newWindowOpens.isEmpty)
    }

    func testCommandReturnInvokesNewWindowOpenCallbackWithSelectedURL() {
        let file = libraryFile(path: "Intro.md", title: "Intro")
        var currentWindowOpens: [URL] = []
        var newWindowOpens: [URL] = []
        let controller = makeController(
            files: [file],
            openInCurrentWindow: { url, _ in currentWindowOpens.append(url) },
            openInNewWindow: { url, _ in newWindowOpens.append(url) }
        )

        controller.setQueryForTesting("intro")
        waitForSearch(controller)
        controller.submitSelectionForTesting(opensNewWindow: true)

        XCTAssertTrue(currentWindowOpens.isEmpty)
        XCTAssertEqual(newWindowOpens, [file.fileURL])
    }

    func testCancelOperationClosesVisiblePanel() {
        let controller = makeController(files: [libraryFile(path: "Intro.md", title: "Intro")])

        controller.showForTesting()
        XCTAssertTrue(controller.isPanelVisibleForTesting)

        controller.cancelOperation(nil)

        XCTAssertFalse(controller.isPanelVisibleForTesting)
    }

    func testMenuValidationReflectsLibraryAvailability() {
        let item = NSMenuItem(
            title: "Quick Open...",
            action: #selector(QuickOpenPanelController.showQuickOpen(_:)),
            keyEquivalent: "O"
        )
        let unavailableController = makeController(files: [], isLibraryAvailable: false)
        let availableController = makeController(files: [], isLibraryAvailable: true)

        XCTAssertFalse(unavailableController.validateMenuItem(item))
        XCTAssertTrue(availableController.validateMenuItem(item))
    }

    func testResultsAreCappedAtFiftyRows() {
        let files = (0..<60).map { index in
            libraryFile(path: "Guides/Guide-\(index).md", title: "Guide \(index)")
        }
        let controller = makeController(files: files)

        controller.setQueryForTesting("guide")
        waitForSearch(controller)

        XCTAssertEqual(controller.resultCountForTesting, 50)
    }

    func testImmediateReturnWaitsForLatestQueryInsteadOfOpeningStaleSelection() {
        let first = libraryFile(path: "First.md", title: "First")
        let second = libraryFile(path: "Second.md", title: "Second")
        var opened: [URL] = []
        let controller = makeController(files: [first, second], openInCurrentWindow: { url, _ in opened.append(url) })
        controller.setQueryForTesting("first")
        waitForSearch(controller)
        controller.setQueryForTesting("second")
        controller.submitSelectionForTesting()
        XCTAssertTrue(opened.isEmpty)
        waitForSearch(controller)
        XCTAssertEqual(opened, [second.fileURL])
    }

    private func waitForSearch(_ controller: QuickOpenPanelController) {
        let deadline = Date().addingTimeInterval(3)
        while controller.isSearchingForTesting, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(controller.isSearchingForTesting)
    }

    private func makeController(
        files: [LibraryFile],
        isLibraryAvailable: Bool = true,
        openInCurrentWindow: @escaping QuickOpenPanelController.CurrentWindowOpenHandler = { _, _ in },
        openInNewWindow: @escaping QuickOpenPanelController.NewWindowOpenHandler = { _, _ in }
    ) -> QuickOpenPanelController {
        QuickOpenPanelController(
            fileProvider: { files },
            isLibraryAvailable: { isLibraryAvailable },
            openInCurrentWindow: openInCurrentWindow,
            openInNewWindow: openInNewWindow
        )
    }

    private func libraryFile(path: String, title: String) -> LibraryFile {
        let baseURL = URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        return LibraryFile(
            fileURL: baseURL.appendingPathComponent(path),
            relativePathComponents: path.split(separator: "/").map(String.init),
            displayTitle: title,
            outlineItems: [],
            plainText: "",
            searchableText: "",
            contentFingerprint: LibraryFileFingerprint(modificationDate: Date(timeIntervalSince1970: 0), fileSize: 0)
        )
    }
}
