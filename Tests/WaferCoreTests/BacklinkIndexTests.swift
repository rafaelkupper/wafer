import Foundation
import XCTest
@testable import WaferCore

final class BacklinkIndexTests: XCTestCase {
    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ contents: String, named name: String, in root: URL) throws {
        try Data(contents.utf8).write(to: root.appendingPathComponent(name))
    }

    func testScanCollectsWikiAndMarkdownReferencesAndBuildsBacklinks() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Hub\n\nSee [[Target Note]] here and [the other](Other.md) too.\n\nAgain [[Target Note]] later.", named: "Hub.md", in: root)
        try write("# Target Note\n\nBody.", named: "Target Note.md", in: root)
        try write("# Other\n\nSelf link to [[Other]] ignored.\n\n`[[Target Note]]` in code ignored.\n\n```\n[[Target Note]]\n```", named: "Other.md", in: root)

        let scan = LibraryScanner.scan(rootURL: root)
        XCTAssertEqual(scan.files.count, 3)

        let hub = try XCTUnwrap(scan.files.first { $0.displayTitle == "Hub" })
        XCTAssertEqual(hub.outgoingReferences.count, 3)

        let backlinks = BacklinkIndex.build(files: scan.files)

        let targetIdentity = FileIdentity.identity(for: root.appendingPathComponent("Target Note.md"))
        let targetBacklinks = try XCTUnwrap(backlinks[targetIdentity])
        // Hub links Target Note twice -> ONE backlink with the FIRST context.
        XCTAssertEqual(targetBacklinks.count, 1)
        XCTAssertEqual(targetBacklinks[0].sourceTitle, "Hub")
        XCTAssertTrue(targetBacklinks[0].contextSnippet.contains("See [[Target Note]] here"))

        let otherIdentity = FileIdentity.identity(for: root.appendingPathComponent("Other.md"))
        let otherBacklinks = try XCTUnwrap(backlinks[otherIdentity])
        XCTAssertEqual(otherBacklinks.map(\.sourceTitle), ["Hub"])

        // Self-links and code-guarded wiki syntax never produce backlinks.
        let hubIdentity = FileIdentity.identity(for: root.appendingPathComponent("Hub.md"))
        XCTAssertNil(backlinks[hubIdentity])
    }

    func testSnippetCapsAt140CharactersFromContainingParagraph() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let longPrefix = String(repeating: "word ", count: 40)
        try write("# Long\n\n\(longPrefix)[[Target]] end.", named: "Long.md", in: root)
        try write("# Target", named: "Target.md", in: root)

        let scan = LibraryScanner.scan(rootURL: root)
        let backlinks = BacklinkIndex.build(files: scan.files)
        let targetBacklinks = try XCTUnwrap(
            backlinks[FileIdentity.identity(for: root.appendingPathComponent("Target.md"))]
        )
        XCTAssertLessThanOrEqual(targetBacklinks[0].contextSnippet.count, 141)
        XCTAssertTrue(targetBacklinks[0].contextSnippet.hasSuffix("…"))
    }
}
