import AppKit
import UniformTypeIdentifiers
import WaferCore

/// Opens what a clicked link points at outside the reader. Web and mail
/// links open in their apps and other external schemes are ignored. A file
/// that can run code (an app or other code bundle, an executable, a script,
/// a Terminal or Automator file, an installer package, or a location file
/// that can point at one) opens only after the user confirms. The opener,
/// the Finder reveal, and the confirmation are injectable for tests.
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
            guard Self.canRunCode(url) else {
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

    /// Types whose files run code or install something when opened.
    /// `script` covers shell, `.command`, and AppleScript files; `bundle`
    /// covers apps, plug-ins, and other code bundles, but not document
    /// packages such as `.rtfd`.
    nonisolated private static let codeTypes: [UTType] = [
        .executable, .application, .bundle, .script,
    ] + [
        "com.apple.terminal.settings",
        "com.apple.automator-workflow",
        "com.apple.installer-package-archive",
        "com.apple.internet-location",
        "com.microsoft.internet-shortcut",
    ].compactMap { UTType($0) }

    /// True when opening `url` could run code: the item (after resolving
    /// symlinks) or its extension has one of `codeTypes`, or it is a file
    /// with the execute bit set.
    nonisolated static func canRunCode(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isExecutableKey])
        if values?.isDirectory == false, values?.isExecutable == true {
            return true
        }

        let pathExtension = resolved.pathExtension
        let types = [
            values?.contentType,
            UTType(filenameExtension: pathExtension),
            UTType(filenameExtension: pathExtension, conformingTo: .directory),
        ].compactMap { $0 }
        return types.contains { type in
            codeTypes.contains { type.conforms(to: $0) }
        }
    }

    /// Default confirmation: an app-modal alert whose default button only
    /// shows the file in Finder.
    static func askBeforeOpening(_ url: URL) -> FileDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open \(url.lastPathComponent)?"
        alert.informativeText = "This link points to an app, script, or other file that can run code on your Mac. Open it only if you trust where it came from."
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
