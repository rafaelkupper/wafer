import Foundation
import XCTest

final class PackagingScriptTests: XCTestCase {
    func testBuildAppCopiesCoreResourceBundleIntoQuickLookExtension() throws {
        let script = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains(#""$QUICKLOOK_APPEX/Contents/Resources""#))
        XCTAssertTrue(script.contains(#""$bundle_name" == "Wafer_WaferCore.bundle""#))
        XCTAssertTrue(script.contains(#"cp -R "$resource_bundle" "$QUICKLOOK_APPEX/Contents/Resources/""#))
    }

    func testVerifyAppexRequiresCoreResourceBundle() throws {
        let script = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/verify-appex.sh"), encoding: .utf8)
        let entitlements = try String(contentsOf: repositoryRoot.appendingPathComponent("App/QuickLook.entitlements"), encoding: .utf8)

        XCTAssertTrue(script.contains(#"CORE_RESOURCE_BUNDLE="$QUICKLOOK_APPEX/Contents/Resources/Wafer_WaferCore.bundle""#))
        XCTAssertTrue(script.contains(#""$CORE_RESOURCE_BUNDLE/reader-theme.css""#))
        XCTAssertTrue(script.contains(#""$CORE_RESOURCE_BUNDLE/gemoji-shortcodes.json""#))
        XCTAssertTrue(script.contains(#""$CORE_RESOURCE_BUNDLE/gemoji-LICENSE.txt""#))
        XCTAssertTrue(script.contains(#""$CORE_RESOURCE_BUNDLE/katex.min.js""#))
        XCTAssertTrue(script.contains(#""$CORE_RESOURCE_BUNDLE/katex.min.css""#))
        XCTAssertTrue(script.contains(#""$CORE_RESOURCE_BUNDLE/katex-LICENSE.txt""#))
        XCTAssertTrue(script.contains(#""$CORE_RESOURCE_BUNDLE/KaTeX_Main-Regular.woff2""#))
        XCTAssertTrue(script.contains("com.apple.security.network.client"))
        XCTAssertTrue(script.contains("must not request com.apple.security.network.client"))
        XCTAssertFalse(entitlements.contains("com.apple.security.network.client"))
    }

    func testPackageReleaseCreatesExtractorSafeZipArchives() throws {
        let script = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/package-release.sh"), encoding: .utf8)
        let safeDittoCommand = "ditto -c -k --norsrc --noextattr --noacl --keepParent"

        XCTAssertEqual(script.numberOfMatches(of: safeDittoCommand), 2)
        XCTAssertTrue(script.contains(#""$APP_BUNDLE" "$NOTARIZATION_ZIP""#))
        XCTAssertTrue(script.contains(#""$APP_BUNDLE" "$FINAL_ZIP""#))
        XCTAssertFalse(script.contains(#"ditto -c -k --keepParent "$APP_BUNDLE" "$FINAL_ZIP""#))
    }

    func testBundledResourceFilenamesUseASCIIForSignaturePortability() throws {
        try assertASCIIResourceNames(in: repositoryRoot.appendingPathComponent("Sources/WaferApp/Resources"))
        try assertASCIIResourceNames(in: repositoryRoot.appendingPathComponent("Sources/WaferCore/Resources"))
    }

    func testQuickLookProviderUsesViewBasedPreviewController() throws {
        let provider = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/WaferQuickLook/PreviewProvider.swift"),
            encoding: .utf8
        )
        let package = try String(contentsOf: repositoryRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let infoPlist = try String(contentsOf: repositoryRoot.appendingPathComponent("App/QuickLook-Info.plist"), encoding: .utf8)

        XCTAssertFalse(provider.contains("import WebKit\n"))
        XCTAssertTrue(provider.contains("NSViewController, @preconcurrency QLPreviewingController"))
        XCTAssertTrue(provider.contains("NSScrollView(frame: frame)"))
        XCTAssertTrue(provider.contains("NSTextView(frame: scrollView.contentView.bounds)"))
        XCTAssertTrue(provider.contains("textView.textContainerInset = NSSize(width: 28, height: 20)"))
        XCTAssertTrue(provider.contains("preferredContentSize = frame.size"))
        XCTAssertTrue(provider.contains("preparePreviewOfFile(at url: URL"))
        XCTAssertTrue(provider.contains("applyPreviewHTML(html, palette: isDark ? .dark : .light)"))
        XCTAssertTrue(provider.contains("NSAttributedString.DocumentType.html"))
        XCTAssertTrue(provider.contains("fallbackText(from: html)"))
        XCTAssertTrue(provider.contains("PreviewComposer.inliningAttachments"))
        XCTAssertTrue(provider.contains("queue.async"))
        XCTAssertTrue(package.contains(#".linkedFramework("QuickLookUI")"#))
        XCTAssertFalse(package.contains(#".linkedFramework("WebKit")"#))
        XCTAssertFalse(infoPlist.contains("QLIsDataBasedPreview"))
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

private extension String {
    func numberOfMatches(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
