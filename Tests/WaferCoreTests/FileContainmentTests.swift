import Foundation
import XCTest
@testable import WaferCore

final class FileContainmentTests: XCTestCase {
    func testCaseRulesAndSiblingComponentBoundaries() {
        let root = URL(fileURLWithPath: "/a/doc")
        let insensitive = FileContainment(rootDirectory: root, caseSensitive: false)
        let sensitive = FileContainment(rootDirectory: root, caseSensitive: true)
        XCTAssertTrue(insensitive.contains(URL(fileURLWithPath: "/a/DOC/image.png")))
        XCTAssertTrue(insensitive.contains(URL(fileURLWithPath: "/A/DOC")))
        XCTAssertFalse(sensitive.contains(URL(fileURLWithPath: "/a/DOC/image.png")))
        for policy in [insensitive, sensitive] {
            XCTAssertTrue(policy.contains(root))
            XCTAssertTrue(policy.contains(root.appendingPathComponent("image.png")))
            XCTAssertFalse(policy.contains(URL(fileURLWithPath: "/a/doc2/image.png")))
            XCTAssertFalse(policy.contains(URL(fileURLWithPath: "/a/doc/../secret.png")))
            XCTAssertFalse(policy.contains(URL(string: "https://example.com/a/doc")!))
        }
    }

    func testActualVolumeCaseRulesAndPreviewCollection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("MixedCase")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("image.png")
        try Data([1, 2, 3]).write(to: file)
        let alternateRoot = directory.appendingPathComponent("mixedcase")
        let sensitive = try XCTUnwrap(root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
        XCTAssertEqual(FileContainment.isContained(file, in: alternateRoot), !sensitive)
        XCTAssertEqual(PreviewAttachmentStore().cidSource(for: file, allowedRootDirectory: alternateRoot) != nil, !sensitive)
    }

    func testStandardizationAndSymlinkEscapes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("doc")
        let sibling = directory.appendingPathComponent("doc2")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let inside = root.appendingPathComponent("image.png")
        let outside = sibling.appendingPathComponent("secret.png")
        try Data([1]).write(to: inside)
        try Data([2]).write(to: outside)
        let rootAlias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: root)
        XCTAssertTrue(FileContainment.isContained(rootAlias.appendingPathComponent("image.png"), in: root))
        XCTAssertTrue(FileContainment.isContained(inside, in: rootAlias))
        let escape = root.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        XCTAssertFalse(FileContainment.isContained(escape, in: root))
        XCTAssertNil(PreviewAttachmentStore().cidSource(for: escape, allowedRootDirectory: root))
        XCTAssertNil(PreviewAttachmentStore().cidSource(for: outside, allowedRootDirectory: root))
    }

    func testPreviewReadRejectsParentDirectorySwap() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("doc")
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("image.png")
        try Data("allowed".utf8).write(to: file)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("image.png"))
        let composition = PreviewComposition(html: #"<img src="cid:image">"#, attachments: ["image": file], title: "", truncated: false)
        try FileManager.default.moveItem(at: root, to: directory.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        let html = try PreviewComposer.inliningAttachments(in: composition)
        XCTAssertTrue(html.contains("[Image omitted]"))
        XCTAssertFalse(html.contains(Data("secret".utf8).base64EncodedString()))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wafer-containment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
