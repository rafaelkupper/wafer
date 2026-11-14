import Foundation
import XCTest
@testable import WaferApp
@testable import WaferCore

final class LocalAssetLoaderTests: XCTestCase {
    func testFileURLExtractionRejectsInvalidLocalAssetURLs() {
        let allowedRoot = URL(fileURLWithPath: "/tmp")

        XCTAssertThrowsError(try LocalAssetLoader.fileURL(
            for: URL(string: "wafer-local://wrong?path=/tmp/file.png")!,
            allowedRootDirectories: [allowedRoot]
        ))
        XCTAssertThrowsError(try LocalAssetLoader.fileURL(
            for: URL(string: "wafer-local://asset")!,
            allowedRootDirectories: [allowedRoot]
        ))
    }

    func testLoadReturnsDataAndMimeTypeForLocalFiles() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "note.txt", contents: "hello")
        let requestURL = assetURL(forPath: fileURL.path)

        let response = try LocalAssetLoader.load(
            from: requestURL,
            allowedRootDirectories: [tempDirectory.url]
        )

        XCTAssertEqual(response.data, Data("hello".utf8))
        XCTAssertEqual(response.response.mimeType, "text/plain")
    }

    func testReadRefusesFilesOutsideTheSandboxScopeBeforeOpeningThem() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let other = try TemporaryTestDirectory()
        defer { other.remove() }
        let image = try directory.createFile(named: "image.png", contents: Data([1]))
        let elsewhere = FolderAccessScope(roots: [FileContainment(rootDirectory: other.url)])

        XCTAssertThrowsError(try LocalAssetLoader.read(
            image, allowedRootDirectories: [directory.url], maximumByteCount: 10, scope: elsewhere,
            beforeOpening: { XCTFail("opened a file outside the sandbox scope") }
        )) { error in
            XCTAssertEqual((error as? FolderAccessDeniedError)?.fileURL.lastPathComponent, "image.png")
        }
        let covering = FolderAccessScope(roots: [FileContainment(rootDirectory: directory.url)])
        XCTAssertEqual(try LocalAssetLoader.read(image, allowedRootDirectories: [directory.url], maximumByteCount: 10, scope: covering), Data([1]))
    }

    func testFileURLAllowsFilesInRootAndNestedSubdirectories() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let rootFile = try tempDirectory.createTextFile(named: "root.txt", contents: "root")
        let nestedDirectory = tempDirectory.url.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let nestedFile = nestedDirectory.appendingPathComponent("child.txt")
        try Data("nested".utf8).write(to: nestedFile)

        XCTAssertEqual(
            try LocalAssetLoader.fileURL(for: assetURL(forPath: rootFile.path), allowedRootDirectories: [tempDirectory.url]),
            rootFile.standardizedFileURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(
            try LocalAssetLoader.fileURL(for: assetURL(forPath: nestedFile.path), allowedRootDirectories: [tempDirectory.url]),
            nestedFile.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testFileURLRejectsSiblingDirectory() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let root = tempDirectory.url.appendingPathComponent("root", isDirectory: true)
        let sibling = tempDirectory.url.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let siblingFile = sibling.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: siblingFile)

        XCTAssertThrowsError(try LocalAssetLoader.fileURL(
            for: assetURL(forPath: siblingFile.path),
            allowedRootDirectories: [root]
        ))
    }

    func testFileURLRejectsEscapedRelativePath() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let root = tempDirectory.url.appendingPathComponent("root", isDirectory: true)
        let subdirectory = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let outsideFile = tempDirectory.url.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outsideFile)
        let escapingPath = subdirectory
            .appendingPathComponent("..")
            .appendingPathComponent("..")
            .appendingPathComponent("outside.txt")
            .path

        XCTAssertThrowsError(try LocalAssetLoader.fileURL(
            for: assetURL(forPath: escapingPath),
            allowedRootDirectories: [root]
        ))
    }

    func testFileURLRejectsEmptyAllowedRoots() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "note.txt", contents: "hello")

        XCTAssertThrowsError(try LocalAssetLoader.fileURL(
            for: assetURL(forPath: fileURL.path),
            allowedRootDirectories: []
        ))
    }

    func testFileURLRejectsSymlinkEscapes() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let root = tempDirectory.url.appendingPathComponent("root", isDirectory: true)
        let outside = tempDirectory.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secretFile = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secretFile)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try LocalAssetLoader.fileURL(
            for: assetURL(forPath: link.appendingPathComponent("secret.txt").path),
            allowedRootDirectories: [root]
        ))
    }

    func testReadRejectsParentSwappedToEscapingSymlinkAfterContainmentCheck() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("root")
        let parent = root.appendingPathComponent("images")
        let outside = directory.url.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("allowed".utf8).write(to: parent.appendingPathComponent("image.png"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("image.png"))
        XCTAssertThrowsError(try LocalAssetLoader.read(parent.appendingPathComponent("image.png"),
            allowedRootDirectories: [root], maximumByteCount: 100, beforeOpening: {
                try FileManager.default.moveItem(at: parent, to: root.appendingPathComponent("original"))
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
            }))
    }

    /// The swapped parent still lies inside the document's root, so only the
    /// sandbox scope, checked again on the opened path, refuses it.
    func testReadRejectsParentSwappedOutOfTheSandboxScopeAfterTheScopeCheck() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("root")
        let granted = root.appendingPathComponent("images")
        let ungranted = root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ungranted, withIntermediateDirectories: true)
        try Data("granted".utf8).write(to: granted.appendingPathComponent("image.png"))
        try Data("ungranted".utf8).write(to: ungranted.appendingPathComponent("image.png"))
        let scope = FolderAccessScope(roots: [FileContainment(rootDirectory: granted)])

        XCTAssertThrowsError(try LocalAssetLoader.read(granted.appendingPathComponent("image.png"),
            allowedRootDirectories: [root], maximumByteCount: 100, scope: scope, beforeOpening: {
                try FileManager.default.moveItem(at: granted, to: root.appendingPathComponent("original"))
                try FileManager.default.createSymbolicLink(at: granted, withDestinationURL: ungranted)
            })) { error in
            XCTAssertTrue(error is FolderAccessDeniedError, "refused as outside the scope, not read: \(error)")
        }
    }

    func testReadAcceptsSymlinkInsideRootAndRejectsEscapingFinalSymlink() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inside = root.appendingPathComponent("image.png")
        try Data("image".utf8).write(to: inside)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
        XCTAssertEqual(try LocalAssetLoader.read(link, allowedRootDirectories: [root], maximumByteCount: 10), Data("image".utf8))
        let outside = try directory.createTextFile(named: "secret.png", contents: "secret")
        let escape = root.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        XCTAssertThrowsError(try LocalAssetLoader.read(escape, allowedRootDirectories: [root], maximumByteCount: 10))
    }

    func testReadUsesActualVolumeCaseSensitivity() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("MixedCase")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("image.png")
        try Data("image".utf8).write(to: file)
        let alternateRoot = directory.url.appendingPathComponent("mixedcase")
        let caseSensitive = try XCTUnwrap(root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
        if caseSensitive {
            XCTAssertThrowsError(try LocalAssetLoader.read(file, allowedRootDirectories: [alternateRoot], maximumByteCount: 10))
        } else {
            XCTAssertEqual(try LocalAssetLoader.read(file, allowedRootDirectories: [alternateRoot], maximumByteCount: 10), Data("image".utf8))
        }
    }

    private func assetURL(forPath path: String) -> URL {
        var components = URLComponents()
        components.scheme = "wafer-local"
        components.host = "asset"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url!
    }
}
