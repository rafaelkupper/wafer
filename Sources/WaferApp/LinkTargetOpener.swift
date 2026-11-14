import AppKit
import UniformTypeIdentifiers
import WaferCore

/// Opens known passive files directly and asks before opening other files,
/// directories, and packages. Open, reveal, and confirmation are injectable.
@MainActor
struct LinkTargetOpener {
    enum FileDecision: Equatable {
        case open
        case reveal
        case cancel
    }

    /// The external schemes links may open; the same policy the renderer applies.
    nonisolated static let allowedExternalSchemes = LinkURLPolicy.externalSchemes

    var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var revealInFinder: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var confirmOpeningFile: @MainActor (URL) -> FileDecision = LinkTargetOpener.askBeforeOpening
    var openMarkdownFile: @MainActor (URL) -> Void = { MarkdownDocumentOpener.open(urls: [$0]) }
    /// True when the file is readable now. Otherwise asks for a folder grant
    /// and calls the closure once one covers the file. Another app can open,
    /// and Finder can show, only files the App Sandbox lets Wafer read.
    var ensureAccess: @MainActor (URL, _ onGranted: @escaping @MainActor () -> Void) -> Bool = { url, onGranted in
        FolderAccessFlow.ensureAccess(to: url, requestedBy: nil, window: NSApp.keyWindow, onGranted: onGranted)
    }

    func handle(_ target: LinkTarget) {
        switch target {
        case .external(let url):
            guard Self.opensExternally(url) else {
                return
            }
            openURL(url)
        case .markdownFile(let url):
            openMarkdownFile(url)
        case .otherFile(let url):
            guard ensureAccess(url, { handle(target) }) else {
                return
            }
            if Self.opensWithoutConfirmation(url) {
                openURL(url)
                return
            }
            switch confirmOpeningFile(url) {
            case .open:
                openURL(url)
            case .reveal:
                revealInFinder(url)
            case .cancel:
                break
            }
        case .unresolved:
            break
        }
    }

    nonisolated static func opensExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return allowedExternalSchemes.contains(scheme)
    }

    nonisolated private static let activeMarkupTypes: [UTType] = [
        .svg, .xml, .html, .webArchive,
    ]

    nonisolated private static let passiveTypes: [UTType] = [
        .image, .pdf, .audio, .movie, .rtf,
    ]

    // Do not allow all UTType.text: HTML, scripts, and other active types
    // conform to it. Office macro-enabled formats are intentionally absent.
    nonisolated private static let passiveExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv", "json", "yaml", "yml", "toml",
        "docx", "xlsx", "pptx",
    ]

    nonisolated static func opensWithoutConfirmation(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [
            .contentTypeKey, .isRegularFileKey, .isExecutableKey,
        ]), values.isRegularFile == true, values.isExecutable == false else {
            return false
        }
        let pathExtension = resolved.pathExtension.lowercased()
        guard let type = values.contentType ?? UTType(filenameExtension: pathExtension),
              !activeMarkupTypes.contains(where: { type.conforms(to: $0) }) else { return false }
        // XHTML conforms to XML and HTML. Check active markup before either
        // allowlist: SVG also conforms to image, but can run scripts.
        if passiveExtensions.contains(pathExtension) { return true }
        return passiveTypes.contains { type.conforms(to: $0) }
    }

    /// Default confirmation: an app-modal alert whose default button only
    /// shows the file in Finder.
    static func askBeforeOpening(_ url: URL) -> FileDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open \(url.lastPathComponent)?"
        alert.informativeText = "This link points to a file, folder, or package outside the known passive file types. It may run code or make changes on your Mac. Open it only if you trust where it came from."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .reveal
        case .alertSecondButtonReturn:
            return .open
        default:
            return .cancel
        }
    }
}
