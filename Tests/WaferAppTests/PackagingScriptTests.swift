import Foundation
import XCTest

final class PackagingScriptTests: XCTestCase {
    func testBundledResourceFilenamesUseASCIIForSignaturePortability() throws {
        try assertASCIIResourceNames(in: repositoryRoot.appendingPathComponent("Sources/WaferApp/Resources"))
        try assertASCIIResourceNames(in: repositoryRoot.appendingPathComponent("Sources/WaferCore/Resources"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func assertASCIIResourceNames(in directoryURL: URL) throws {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
        let urls = try XCTUnwrap(enumerator?.compactMap { $0 as? URL })

        for url in urls {
            let relativePath = url.pathComponents.dropFirst(directoryURL.pathComponents.count).joined(separator: "/")
            for component in url.pathComponents.dropFirst(directoryURL.deletingLastPathComponent().pathComponents.count) {
                let isASCII = component.unicodeScalars.allSatisfy { $0.value < 128 }
                XCTAssertTrue(isASCII, "Bundled resource path must be ASCII for code-signing portability: \(relativePath)")
            }
        }
    }
}
