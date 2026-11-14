import AppKit
import XCTest
@testable import WaferApp

@MainActor
final class MarkdownEditConflictAlertTests: XCTestCase {
    func testChangedFileChoicesKeepTheirOrderAndOfferCancel() throws {
        try assertChoices(
            for: .changedOnDisk,
            titles: ["Keep My Edits", "Use Disk Version", "Save a Copy…", "Cancel"],
            resolutions: [.overwrite, .discardMine, nil, .cancel]
        )
    }

    func testMissingFileChoicesKeepTheirOrderAndOfferCancel() throws {
        try assertChoices(
            for: .missingOnDisk,
            titles: ["Save", "Save a Copy…", "Discard My Edits", "Cancel"],
            resolutions: [.overwrite, nil, .discardMine, .cancel]
        )
    }

    func testWriteFailureChoicesKeepTheirOrderAndOfferCancel() throws {
        try assertChoices(
            for: .writeFailed("Read-only volume"),
            titles: ["Save a Copy…", "Discard My Edits", "Cancel"],
            resolutions: [nil, .discardMine, .cancel]
        )
    }

    private func assertChoices(
        for kind: EditConflictKind,
        titles: [String],
        resolutions: [EditConflictResolution?],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let prompt = MarkdownEditSession.ConflictAlert(kind, fileURL: URL(fileURLWithPath: "/Notes/Doc.md"))
        XCTAssertEqual(prompt.alert.buttons.map(\.title), titles, file: file, line: line)
        for (index, resolution) in resolutions.enumerated() {
            let response = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
            XCTAssertEqual(prompt.resolution(for: response), resolution, file: file, line: line)
        }

        XCTAssertEqual(prompt.alert.buttons.first?.keyEquivalent, "\r", "Return keeps the original default", file: file, line: line)
        let cancel = try XCTUnwrap(prompt.alert.buttons.first { $0.title == "Cancel" }, file: file, line: line)
        XCTAssertEqual(cancel.keyEquivalent, "\u{1b}", "Escape cancels the save", file: file, line: line)
        XCTAssertEqual(prompt.resolution(for: .abort), .cancel, file: file, line: line)
    }
}
