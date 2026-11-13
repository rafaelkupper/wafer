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

    let themesDirectoryURL: URL
    let bundledThemesDirectoryURL: URL?
    private(set) var palettesByName: [String: ReaderThemePalette] = [:]
    private(set) var diagnostics: [ThemeLibraryDiagnostic] = []

    init(
        themesDirectoryURL: URL = ThemeLibrary.defaultThemesDirectoryURL(),
        bundledThemesDirectoryURL: URL? = ThemeLibrary.defaultBundledThemesDirectoryURL(),
        fileManager: FileManager = .default,
        revealHandler: @escaping RevealHandler = ThemeLibrary.defaultRevealHandler
    ) {
        self.themesDirectoryURL = themesDirectoryURL
        self.bundledThemesDirectoryURL = bundledThemesDirectoryURL
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
            } catch {
                WaferLog.resources.fault("Bundled themes are unreadable: \(error.localizedDescription, privacy: .public)")
                bundledURLs = []
            }
            for url in bundledURLs {
                do {
                    let data = try Data(contentsOf: url)
                    let palette = try ThemeFile.decodePalette(from: data, fileName: url.lastPathComponent)
                    guard loadedPalettes[palette.name] == nil else {
                        loadDiagnostics.append(ThemeLibraryDiagnostic(
                            fileName: url.lastPathComponent,
                            message: "Duplicate bundled theme name '\(palette.name)' was skipped."
                        ))
                        continue
                    }
                    loadedPalettes[palette.name] = palette
                } catch {
                    loadDiagnostics.append(ThemeLibraryDiagnostic(
                        fileName: url.lastPathComponent,
                        message: error.localizedDescription
                    ))
                }
            }
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

    static func defaultBundledThemesDirectoryURL() -> URL? {
        // In the packaged .app, SwiftPM resource bundles are copied into
        // Contents/Resources; Bundle.module covers `swift run` and tests.
        if
            let resourceURL = Bundle.main.resourceURL,
            let packagedBundle = Bundle(
                url: resourceURL.appendingPathComponent("Wafer_WaferApp.bundle", isDirectory: true)
            ),
            let themesURL = packagedBundle.url(forResource: "Themes", withExtension: nil)
        {
            return themesURL
        }

        return Bundle.module.url(forResource: "Themes", withExtension: nil)
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
