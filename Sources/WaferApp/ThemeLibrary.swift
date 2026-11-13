import AppKit
import Foundation
import WaferCore

struct ThemeLibraryDiagnostic: Equatable {
    let fileName: String
    let message: String
}

struct ThemeLibraryLoadResult: Equatable {
    let palettes: [ReaderThemePalette]
    let diagnostics: [ThemeLibraryDiagnostic]
}

@MainActor
final class ThemeLibrary {
    typealias RevealHandler = @MainActor (URL) -> Void

    static let shared = ThemeLibrary()

    private let fileManager: FileManager
    private let revealHandler: RevealHandler
    private let expectedBundledFileNames: [String]

    let themesDirectoryURL: URL
    let bundledThemesDirectoryURL: URL?
    private(set) var palettesByName: [String: ReaderThemePalette] = [:]
    private(set) var diagnostics: [ThemeLibraryDiagnostic] = []

    init(
        themesDirectoryURL: URL = ThemeLibrary.defaultThemesDirectoryURL(),
        bundledThemesDirectoryURL: URL? = ThemeLibrary.defaultBundledThemesDirectoryURL(),
        expectedBundledFileNames: [String] = ThemeLibrary.bundledFileNames,
        fileManager: FileManager = .default,
        revealHandler: @escaping RevealHandler = ThemeLibrary.defaultRevealHandler
    ) {
        self.themesDirectoryURL = themesDirectoryURL
        self.bundledThemesDirectoryURL = bundledThemesDirectoryURL
        self.expectedBundledFileNames = expectedBundledFileNames
        self.fileManager = fileManager
        self.revealHandler = revealHandler
    }

    var palettes: [ReaderThemePalette] {
        palettesByName.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func palette(named name: String) -> ReaderThemePalette? {
        palettesByName[name]
    }

    @discardableResult
    func loadThemes() -> ThemeLibraryLoadResult {
        var loadDiagnostics: [ThemeLibraryDiagnostic] = []
        var loadedPalettes: [String: ReaderThemePalette] = [:]

        if let bundledThemesDirectoryURL {
            let bundledURLs: [URL]
            do {
                bundledURLs = try themeFileURLs(in: bundledThemesDirectoryURL)
                let presentNames = Set(bundledURLs.map(\.lastPathComponent))
                for name in expectedBundledFileNames where !presentNames.contains(name) {
                    loadDiagnostics.append(Self.bundledResourceFailure(
                        fileName: name, message: "Bundled theme is missing. This is a packaging defect."
                    ))
                }
            } catch {
                loadDiagnostics.append(Self.bundledResourceFailure(
                    fileName: "Themes", message: "Bundled themes are unreadable: \(error.localizedDescription)"
                ))
                bundledURLs = []
            }
            for url in bundledURLs {
                do {
                    let data = try Data(contentsOf: url)
                    let palette = try ThemeFile.decodePalette(from: data, fileName: url.lastPathComponent)
                    guard loadedPalettes[palette.name] == nil else {
                        loadDiagnostics.append(Self.bundledResourceFailure(
                            fileName: url.lastPathComponent,
                            message: "Duplicate bundled theme name '\(palette.name)' was skipped."
                        ))
                        continue
                    }
                    loadedPalettes[palette.name] = palette
                } catch {
                    loadDiagnostics.append(Self.bundledResourceFailure(
                        fileName: url.lastPathComponent,
                        message: error.localizedDescription
                    ))
                }
            }
        } else {
            loadDiagnostics.append(Self.bundledResourceFailure(
                fileName: "Themes", message: "Bundled themes directory is missing. This is a packaging defect."
            ))
        }

        if let diagnostic = ensureThemesDirectoryAndExample() {
            loadDiagnostics.append(diagnostic)
            palettesByName = loadedPalettes
            diagnostics = loadDiagnostics
            return ThemeLibraryLoadResult(palettes: palettes, diagnostics: loadDiagnostics)
        }

        let urls: [URL]
        do {
            urls = try themeFileURLs(in: themesDirectoryURL)
        } catch {
            loadDiagnostics.append(ThemeLibraryDiagnostic(
                fileName: themesDirectoryURL.lastPathComponent,
                message: "Could not list themes directory: \(error.localizedDescription)"
            ))
            palettesByName = loadedPalettes
            diagnostics = loadDiagnostics
            return ThemeLibraryLoadResult(palettes: palettes, diagnostics: loadDiagnostics)
        }

        var userThemeNames: Set<String> = []
        // Example.json is the copy-me template the app maintains in the themes
        // folder; it is not offered as a selectable theme.
        for url in urls where url.lastPathComponent != Self.exampleFileName {
            do {
                let data = try Data(contentsOf: url)
                let palette = try ThemeFile.decodePalette(from: data, fileName: url.lastPathComponent)
                guard !userThemeNames.contains(palette.name) else {
                    loadDiagnostics.append(ThemeLibraryDiagnostic(
                        fileName: url.lastPathComponent,
                        message: "Duplicate theme name '\(palette.name)' was skipped."
                    ))
                    continue
                }
                userThemeNames.insert(palette.name)
                // User themes override bundled themes with the same name.
                loadedPalettes[palette.name] = palette
            } catch {
                loadDiagnostics.append(ThemeLibraryDiagnostic(
                    fileName: url.lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }

        palettesByName = loadedPalettes
        diagnostics = loadDiagnostics
        return ThemeLibraryLoadResult(palettes: palettes, diagnostics: loadDiagnostics)
    }

    private func themeFileURLs(in directoryURL: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func revealThemesFolder() {
        _ = ensureThemesDirectoryAndExample()
        revealHandler(themesDirectoryURL)
    }

    static let exampleFileName = "Example.json"

    private func ensureThemesDirectoryAndExample() -> ThemeLibraryDiagnostic? {
        do {
            try fileManager.createDirectory(at: themesDirectoryURL, withIntermediateDirectories: true)
            let exampleURL = themesDirectoryURL.appendingPathComponent(Self.exampleFileName)
            if !fileManager.fileExists(atPath: exampleURL.path) {
                try ThemeFile.exampleData().write(to: exampleURL, options: .atomic)
            }
            return nil
        } catch {
            return ThemeLibraryDiagnostic(
                fileName: themesDirectoryURL.lastPathComponent,
                message: "Could not prepare themes directory: \(error.localizedDescription)"
            )
        }
    }

    static let bundledFileNames = [
        "Catppuccin Latte.json", "Catppuccin Mocha.json", "Dracula.json", "GitHub Dark.json",
        "GitHub Light.json", "Gruvbox Dark.json", "Monokai.json", "Nord.json", "One Dark.json",
        "Rose Pine.json", "Solarized Dark.json", "Solarized Light.json", "Synthwave '84.json",
        "Tokyo Night.json",
    ]

    private static func bundledResourceFailure(fileName: String, message: String) -> ThemeLibraryDiagnostic {
        WaferLog.resources.fault("Bundled theme resource failure in \(fileName, privacy: .public): \(message, privacy: .private)")
        return ThemeLibraryDiagnostic(fileName: fileName, message: message)
    }

    static func defaultBundledThemesDirectoryURL() -> URL? {
        // Resolve optionally rather than using SwiftPM's trapping Bundle.module accessor.
        var candidates = [Bundle.main.resourceURL, Bundle(for: ThemeLibrary.self).resourceURL, Bundle.main.bundleURL]
            .compactMap { $0 }
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            candidates.insert(URL(fileURLWithPath: override), at: 0)
        }
        #endif
        return bundledThemesDirectoryURL(in: candidates.map {
            $0.appendingPathComponent("Wafer_WaferApp.bundle", isDirectory: true)
        })
    }

    static func bundledThemesDirectoryURL(in bundleURLs: [URL]) -> URL? {
        for url in bundleURLs {
            if let themesURL = Bundle(url: url)?.url(forResource: "Themes", withExtension: nil) {
                return themesURL
            }
        }
        return nil
    }

    static let supportDirectoryName = "Wafer"

    private static func defaultThemesDirectoryURL() -> URL {
        resolveThemesDirectoryURL(
            inApplicationSupport: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        )
    }

    static func resolveThemesDirectoryURL(
        inApplicationSupport applicationSupportURL: URL
    ) -> URL {
        let supportURL = applicationSupportURL
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
        return supportURL.appendingPathComponent("Themes", isDirectory: true)
    }

    private static func defaultRevealHandler(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
