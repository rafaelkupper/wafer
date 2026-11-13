import Foundation
import XCTest
@testable import WaferApp

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
            allowedRootDirectories: [tempDirectory.url],
            dataProvider: { try Data(contentsOf: $0) }
        )

        XCTAssertEqual(response.data, Data("hello".utf8))
        XCTAssertEqual(response.response.mimeType, "text/plain")
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

    private func assetURL(forPath path: String) -> URL {
        var components = URLComponents()
        components.scheme = "wafer-local"
        components.host = "asset"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url!
    }
}
