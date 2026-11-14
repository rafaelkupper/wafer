import AppKit
import XCTest
@testable import WaferApp
import WaferCore

@MainActor
final class MarkdownSaveBoundsTests: XCTestCase {
    func testOversizedDiskVersionIsABoundedConflictAndIsNotOverwritten() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Large.md", contents: "original")
        let originalFingerprint = FileFingerprint.sha256Hex(for: Data("original".utf8))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(MarkdownReaderDocument.maximumSourceByteCount + 1))
        try handle.close()
        let request = MarkdownSaveRequest(
            fileURL: url, snapshot: EditSnapshot(text: "mine", revision: 1), savedText: "original",
            expectedFingerprint: originalFingerprint, format: .default, overwrite: false
        )

        let result = MarkdownSaveWorker().perform(request)

        guard case .conflict(.changedOnDisk, let diskData) = result else {
            return XCTFail("An oversized disk file must be reported as changed on disk")
        }
        XCTAssertNil(diskData, "Do not read or retain the oversized file for the conflict prompt")
        XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       MarkdownReaderDocument.maximumSourceByteCount + 1)
    }

    func testUTF8EncodedSaveLimitIncludesMultibyteTextAndBOM() throws {
        let limit = MarkdownSourceLoader.maximumSourceByteCount
        try checkEncodedBoundary(
            text: String(repeating: "é", count: (limit - 4) / 2) + "a", extra: "a",
            format: .init(encoding: .utf8, hasByteOrderMark: true, lineEnding: .lf)
        )
    }

    func testUTF16LittleEndianEncodedSaveLimitIncludesBOM() throws {
        try checkEncodedBoundary(
            text: String(repeating: "a", count: MarkdownSourceLoader.maximumSourceByteCount / 2 - 1), extra: "😀",
            format: .init(encoding: .utf16LittleEndian, hasByteOrderMark: true, lineEnding: .lf)
        )
    }

    func testUTF16BigEndianEncodedSaveLimitIncludesBOM() throws {
        try checkEncodedBoundary(
            text: String(repeating: "a", count: MarkdownSourceLoader.maximumSourceByteCount / 2 - 1), extra: "a",
            format: .init(encoding: .utf16BigEndian, hasByteOrderMark: true, lineEnding: .lf)
        )
    }

    func testCRLFExpansionCountsTowardEncodedSaveLimit() throws {
        try checkEncodedBoundary(
            text: String(repeating: "a", count: MarkdownSourceLoader.maximumSourceByteCount - 4) + "\n\n", extra: "\n",
            format: .init(encoding: .utf8, hasByteOrderMark: false, lineEnding: .crlf)
        )
    }

    func testUTF16CRLFExpansionCountsTowardEncodedSaveLimit() throws {
        try checkEncodedBoundary(
            text: String(repeating: "a", count: MarkdownSourceLoader.maximumSourceByteCount / 2 - 3) + "\n", extra: "\n",
            format: .init(encoding: .utf16LittleEndian, hasByteOrderMark: true, lineEnding: .crlf)
        )
    }

    func testOversizedSaveCopyPreservesTheOriginalCopyAndUnsavedText() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Note.md", contents: "original")
        let copyURL = try directory.createTextFile(named: "Copy.md", contents: "existing copy")
        var prompts = 0
        let session = MarkdownEditSession(
            fileURL: url, text: "original", fingerprint: FileFingerprint.sha256Hex(for: Data("original".utf8)),
            format: .default, resolveConflict: { _, _ in
                prompts += 1
                return prompts == 1 ? .saveCopy(copyURL) : .cancel
            }
        )
        let text = String(repeating: "x", count: MarkdownSourceLoader.maximumSourceByteCount + 1)
        XCTAssertEqual(session.save(text, interactive: true), .keptInMemory)
        XCTAssertEqual(prompts, 2)
        XCTAssertTrue(session.hasUnsavedChanges(text))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: copyURL, encoding: .utf8), "existing copy")
    }

    private func checkEncodedBoundary(text: String, extra: String, format: MarkdownTextFormat) throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Boundary.md", contents: "original")
        var errors: [EditConflictKind] = []
        let session = MarkdownEditSession(
            fileURL: url, text: "original", fingerprint: FileFingerprint.sha256Hex(for: Data("original".utf8)),
            format: format, resolveConflict: { kind, _ in errors.append(kind); return .cancel }
        )
        XCTAssertEqual(session.save(text, interactive: true), .saved)
        XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, MarkdownSourceLoader.maximumSourceByteCount)
        let savedFingerprint = session.savedFingerprint
        let oversized = text + extra
        XCTAssertEqual(session.save(oversized, interactive: true), .keptInMemory)
        XCTAssertTrue(session.hasUnsavedChanges(oversized))
        XCTAssertTrue(session.savedText == text)
        XCTAssertEqual(session.savedFingerprint, savedFingerprint)
        guard case .writeFailed(let message) = errors.last else {
            return XCTFail("The encoded limit must give an actionable write error")
        }
        XCTAssertTrue(message.contains("32 MB"))
        XCTAssertTrue(message.contains("Shorten"))
        XCTAssertTrue(message.contains("unsaved"))
        XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, MarkdownSourceLoader.maximumSourceByteCount)
        XCTAssertEqual(FileFingerprint.sha256Hex(for: try Data(contentsOf: url)), savedFingerprint)
        // Keep My Edits must not bypass the encoded limit either.
        let overwrite = MarkdownSaveRequest(
            fileURL: url, snapshot: .init(text: oversized, revision: nil), savedText: text,
            expectedFingerprint: savedFingerprint, format: format, overwrite: true
        )
        guard case .conflict(.writeFailed, _) = MarkdownSaveWorker().perform(overwrite) else {
            return XCTFail("Overwrite must enforce the same encoded limit")
        }
    }

}
