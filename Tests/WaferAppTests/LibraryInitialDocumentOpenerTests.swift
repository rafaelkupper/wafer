import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class LibraryInitialDocumentOpenerTests: XCTestCase {
    func testOpensFirstScannedFileWhenNoMarkdownWindowIsVisible() {
        let firstURL = URL(fileURLWithPath: "/tmp/library/Guide.md")
        let laterURL = URL(fileURLWithPath: "/tmp/library/Later.md")
        var openedURLs: [URL] = []

        LibraryInitialDocumentOpener.openFirstDocumentIfNoMarkdownWindow(
            files: [
                libraryFile(url: firstURL, title: "Guide"),
                libraryFile(url: laterURL, title: "Later"),
            ],
            hasVisibleMarkdownWindow: { false },
            openDocument: { openedURLs.append($0) },
            presentError: { XCTFail("Unexpected error: \($0)") }
        )

        XCTAssertEqual(openedURLs, [firstURL])
    }

    func testDoesNotOpenInitialDocumentWhenReaderWindowAlreadyExists() {
        var openedURLs: [URL] = []

        LibraryInitialDocumentOpener.openFirstDocumentIfNoMarkdownWindow(
            files: [libraryFile(url: URL(fileURLWithPath: "/tmp/library/Guide.md"), title: "Guide")],
            hasVisibleMarkdownWindow: { true },
            openDocument: { openedURLs.append($0) },
            presentError: { XCTFail("Unexpected error: \($0)") }
        )

        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testEmptyLibraryDoesNotPresentError() {
        var openedURLs: [URL] = []
        var presentedErrors: [Error] = []

        LibraryInitialDocumentOpener.openFirstDocumentIfNoMarkdownWindow(
            files: [],
            hasVisibleMarkdownWindow: { false },
            openDocument: { openedURLs.append($0) },
            presentError: { presentedErrors.append($0) }
        )

        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertTrue(presentedErrors.isEmpty)
    }

    func testPresentsThrownOpenErrors() {
        enum OpenFailure: Error, Equatable {
            case failed
        }

        var presentedErrors: [OpenFailure] = []

        LibraryInitialDocumentOpener.openFirstDocumentIfNoMarkdownWindow(
            files: [libraryFile(url: URL(fileURLWithPath: "/tmp/library/Guide.md"), title: "Guide")],
            hasVisibleMarkdownWindow: { false },
            openDocument: { _ in throw OpenFailure.failed },
            presentError: { error in
                if let error = error as? OpenFailure {
                    presentedErrors.append(error)
                }
            }
        )

        XCTAssertEqual(presentedErrors, [.failed])
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
}
