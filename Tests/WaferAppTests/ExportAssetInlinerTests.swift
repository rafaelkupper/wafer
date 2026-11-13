import Foundation
import XCTest
@testable import WaferApp

final class ExportAssetInlinerTests: XCTestCase {
    func testLocalImageUsesLocalAssetLoaderAndProducesDataURI() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let imageURL = try tempDirectory.createFile(named: "pixel.png", contents: tinyPNGData())
        let inliner = ExportAssetInliner(allowedRootDirectories: [tempDirectory.url])

        let dataURI = try XCTUnwrap(try inliner.inlineImage(source: assetURL(forPath: imageURL.path).absoluteString))

        XCTAssertTrue(dataURI.hasPrefix("data:image/png;base64,"))
        let encoded = try XCTUnwrap(dataURI.components(separatedBy: ",").last)
        XCTAssertEqual(Data(base64Encoded: encoded), tinyPNGData())
    }

    func testLocalImageOutsideAllowedRootsDropsInsteadOfInlining() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let root = tempDirectory.url.appendingPathComponent("root", isDirectory: true)
        let outside = tempDirectory.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secretFile = outside.appendingPathComponent("secret.png")
        try tinyPNGData().write(to: secretFile)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let inliner = ExportAssetInliner(allowedRootDirectories: [root])

        let dataURI = try inliner.inlineImage(source: assetURL(forPath: link.appendingPathComponent("secret.png").path).absoluteString)

        XCTAssertNil(dataURI)
    }

    func testRemoteImagesAreLookupOnlyAndRejectHTTP() throws {
        let remoteURL = URL(string: "https://example.com/image.png")!
        let asset = ExportImageAsset(data: Data("remote".utf8), mimeType: "image/png")
        let inliner = ExportAssetInliner(
            allowedRootDirectories: [],
            remoteAssets: [remoteURL.absoluteString: asset]
        )

        let dataURI = try inliner.inlineImage(source: remoteURL.absoluteString)
        let httpDataURI = try inliner.inlineImage(source: "http://example.com/image.png")

        XCTAssertEqual(dataURI, "data:image/png;base64,cmVtb3Rl")
        XCTAssertNil(httpDataURI)
    }

    func testRemoteProxyCanUseEitherProxyOrRemoteLookupKey() throws {
        let remoteURL = URL(string: "https://example.com/image.png")!
        let proxyURL = remoteProxyURL(for: remoteURL)
        let asset = ExportImageAsset(data: Data("remote".utf8), mimeType: "image/png")
        let inliner = ExportAssetInliner(
            allowedRootDirectories: [],
            remoteAssets: [remoteURL.absoluteString: asset]
        )

        let dataURI = try inliner.inlineImage(source: proxyURL.absoluteString)

        XCTAssertEqual(dataURI, "data:image/png;base64,cmVtb3Rl")
    }

    func testImageBudgetThrowsTypedError() throws {
        let firstURL = URL(string: "https://example.com/one.png")!
        let secondURL = URL(string: "https://example.com/two.png")!
        let inliner = ExportAssetInliner(
            allowedRootDirectories: [],
            remoteAssets: [
                firstURL.absoluteString: ExportImageAsset(data: Data([0, 1]), mimeType: "image/png"),
                secondURL.absoluteString: ExportImageAsset(data: Data([2, 3]), mimeType: "image/png"),
            ],
            maximumInlinedByteCount: 3
        )

        XCTAssertNotNil(try inliner.inlineImage(source: firstURL.absoluteString))
        XCTAssertThrowsError(try inliner.inlineImage(source: secondURL.absoluteString)) { error in
            guard case ExportHTMLPreparationError.assetBudgetExceeded(maximumByteCount: 3) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testLocalImageBudgetThrowsTypedError() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let imageURL = try tempDirectory.createFile(named: "oversized.png", contents: Data([0, 1, 2, 3]))
        let inliner = ExportAssetInliner(
            allowedRootDirectories: [tempDirectory.url],
            maximumInlinedByteCount: 3
        )

        XCTAssertThrowsError(try inliner.inlineImage(source: assetURL(forPath: imageURL.path).absoluteString)) { error in
            guard case ExportHTMLPreparationError.assetBudgetExceeded(maximumByteCount: 3) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    private func assetURL(forPath path: String) -> URL {
        var components = URLComponents()
        components.scheme = "wafer-local"
        components.host = "asset"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url!
    }

    private func remoteProxyURL(for remoteURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = "wafer-remote"
        components.host = "image"
        components.queryItems = [URLQueryItem(name: "url", value: remoteURL.absoluteString)]
        return components.url!
    }
}
