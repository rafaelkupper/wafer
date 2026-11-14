import AppKit
import Foundation
import WaferCore

/// What a folder prompt asks for.
struct FolderAccessRequest: Equatable {
    /// A file whose folder is too broad to offer (see `FolderAccessRange`).
    struct OutOfRange: Equatable {
        /// The explanation's title.
        let title: String
        /// The panel's message if the user chooses a folder anyway.
        let panelMessage: String
        /// Where that panel opens: the requesting document's folder when it
        /// may be offered, otherwise the panel's own default.
        let startingFolder: URL?
    }

    /// Where the panel opens; Grant Access with nothing selected chooses
    /// it. Nil for a file outside the range Wafer offers, which is explained
    /// first, with a panel only if the user asks for one.
    let suggestedFolder: URL?
    let message: String
    var prompt = "Grant Access"
    var outOfRange: OutOfRange?
}

/// Asking for a folder grant and refreshing documents once it arrives.
@MainActor
enum FolderAccessFlow {
    typealias FolderChooser = @MainActor (
        _ request: FolderAccessRequest, _ window: NSWindow?, _ completion: @escaping @MainActor (URL?) -> Void
    ) -> Void
    typealias DocumentRefresher = @MainActor (_ documentIdentities: Set<String>) -> Void

    /// Replaced in tests.
    static var chooseFolder: FolderChooser = FolderAccessFlow.runOpenPanel
    static var refreshDocuments: DocumentRefresher = FolderAccessFlow.reloadOpenDocuments

    /// True when Wafer can read `url` now, or with `.readWrite` also change
    /// it. Otherwise asks for a folder that holds it, returns false, and
    /// calls `onGranted` once the grant allows it. `access` defaults to
    /// read-write while the requesting document is being edited (see
    /// `accessMode(requestedBy:)`), and read-only otherwise.
    @discardableResult
    static func ensureAccess(
        to url: URL, requestedBy documentURL: URL?, window: NSWindow?,
        access: FolderAccessMode? = nil, onGranted: @escaping @MainActor () -> Void
    ) -> Bool {
        let store = FolderAccessStore.shared
        let access = access ?? accessMode(requestedBy: documentURL)
        guard !allows(access, url, in: store) else { return true }
        if let documentURL, !store.covers(url) {
            store.recordUnreadableFile(url, forDocumentAt: documentURL)
        }
        requestAccess(to: url, requestedBy: documentURL, window: window, access: access, onGranted: onGranted)
        return false
    }

    /// Asks for a folder that holds `url`, even when Wafer believes it can
    /// read it (after a refused read), and calls `onGranted` once a grant
    /// allows `access`. The panel offers only the file's own folder, never
    /// one too broad to offer. It may be a sheet, so callers continue only
    /// from `onGranted`, never after this returns.
    static func requestAccess(
        to url: URL, requestedBy documentURL: URL? = nil, window: NSWindow?,
        access: FolderAccessMode = .readOnly, onGranted: @escaping @MainActor () -> Void
    ) {
        let store = FolderAccessStore.shared
        chooseFolder(request(opening: url, requestedBy: documentURL, access: access, range: store.range), window) { chosen in
            guard let chosen else { return }
            refreshDocuments(store.grantAccess(to: chosen, mode: access))
            if allows(access, url, in: store) { onGranted() }
        }
    }

    /// Grant Access… in a document window: offers the document's folder,
    /// widened within the range Wafer offers to hold the files it needs.
    /// The grant is read-only unless the document is being edited.
    static func requestAccess(
        forDocumentAt documentURL: URL, window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        let store = FolderAccessStore.shared
        guard let suggestion = store.suggestion(forDocumentAt: documentURL) else {
            completion(false)
            return
        }
        let access = accessMode(requestedBy: documentURL)
        chooseFolder(request(showing: documentURL, suggestion: suggestion, access: access, range: store.range), window) { chosen in
            guard let chosen else {
                completion(false)
                return
            }
            refreshDocuments(store.grantAccess(to: chosen, mode: access))
            completion(true)
        }
    }

    /// Grants made to show a document's images and links only read. One
    /// asked for while the requesting document is being edited is
    /// read-write: a link followed while editing opens in the editor, and
    /// a read-only grant would leave its edits unsaveable.
    static func accessMode(requestedBy documentURL: URL?) -> FolderAccessMode {
        guard let documentURL, OpenDocumentRegistry.shared.document(for: documentURL)?.isEditing == true else {
            return .readOnly
        }
        return .readWrite
    }

    private static func allows(_ access: FolderAccessMode, _ url: URL, in store: FolderAccessStore) -> Bool {
        access == .readWrite ? store.allowsWriting(url) : store.covers(url)
    }

    /// The bar's text for the folder the window offers.
    static func noticeMessage(for suggestion: FolderAccessSuggestion, documentName: String) -> String {
        switch suggestion {
        case .folder(let folder, _):
            "Allow Wafer to read the folder “\(folder.lastPathComponent)” to show linked files and images."
        case .outOfRange:
            "“\(documentName)” needs files outside the folders Wafer offers."
        }
    }

    static func request(
        opening url: URL, requestedBy documentURL: URL?, access: FolderAccessMode = .readOnly, range: FolderAccessRange
    ) -> FolderAccessRequest {
        switch range.suggestion(for: url) {
        case .folder(let folder, _):
            let purpose = access == .readWrite
                ? "To open “\(url.lastPathComponent)” in the editor and save your changes"
                : "To open “\(url.lastPathComponent)”"
            return FolderAccessRequest(suggestedFolder: folder, message: "\(introduction(for: access)) \(purpose), grant access to its folder, “\(folder.lastPathComponent)” (\(folder.path))."
                + parentFolderHint(for: folder, isWidened: false, range: range))
        case .outOfRange(let file, _):
            return outOfRangeRequest(for: file, requestedBy: documentURL, range: range)
        }
    }

    static func request(
        showing documentURL: URL, suggestion: FolderAccessSuggestion, access: FolderAccessMode = .readOnly,
        range: FolderAccessRange
    ) -> FolderAccessRequest {
        switch suggestion {
        case .folder(let folder, let isWidened):
            let purpose = access == .readWrite
                ? "To show the images and linked files in “\(documentURL.lastPathComponent)” and save the files you edit there"
                : "To show the images and linked files in “\(documentURL.lastPathComponent)”"
            return FolderAccessRequest(suggestedFolder: folder, message: "\(introduction(for: access)) \(purpose), grant access to “\(folder.lastPathComponent)” (\(folder.path))."
                + parentFolderHint(for: folder, isWidened: isWidened, range: range))
        case .outOfRange(let file, _):
            return outOfRangeRequest(for: file, requestedBy: documentURL, range: range)
        }
    }

    private static func introduction(for access: FolderAccessMode) -> String {
        access == .readWrite
            ? "Wafer can read and change only the files and folders you choose."
            : "Wafer can read only the files and folders you choose, and remembers this folder for reading only."
    }

    /// Mentions a parent folder only while the suggestion is narrow: not
    /// once it was widened, and not when its parent is too broad to offer.
    private static func parentFolderHint(for folder: URL, isWidened: Bool, range: FolderAccessRange) -> String {
        guard !isWidened, !range.isTooBroad(folder.deletingLastPathComponent()) else { return "" }
        return " Choosing a parent folder instead covers more of your documents."
    }

    private static func outOfRangeRequest(for file: URL, requestedBy documentURL: URL?, range: FolderAccessRange) -> FolderAccessRequest {
        let name = file.lastPathComponent
        let documentFolder = documentURL.map { FileIdentity.normalized($0).deletingLastPathComponent() }
        return FolderAccessRequest(
            suggestedFolder: nil,
            message: "“\(name)” (\(file.path)) is outside the folders Wafer offers. Wafer never offers your home folder, a whole disk, or a folder above them, because a document's links decide which file is asked for. To allow it anyway, choose a folder that contains it yourself.",
            outOfRange: .init(
                title: "“\(name)” is outside the folders Wafer offers",
                panelMessage: "Choose a folder that contains “\(name)” (\(file.path)).",
                startingFolder: documentFolder.flatMap { range.isTooBroad($0) ? nil : $0 }
            )
        )
    }

    /// The default chooser: a folder-only open panel at the suggested
    /// folder, or for a file outside the range Wafer offers, an explanation
    /// and a panel only if the user asks for one. Each is a sheet when a
    /// window is free for one.
    static func runOpenPanel(_ request: FolderAccessRequest, window: NSWindow?, completion: @escaping @MainActor (URL?) -> Void) {
        guard let outOfRange = request.outOfRange, request.suggestedFolder == nil else {
            presentPanel(prompt: request.prompt, message: request.message, startingAt: request.suggestedFolder,
                         window: window, completion: completion)
            return
        }
        let alert = NSAlert()
        alert.messageText = outOfRange.title
        alert.informativeText = request.message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Choose Folder…")
        let respond: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertSecondButtonReturn else {
                completion(nil)
                return
            }
            presentPanel(prompt: request.prompt, message: outOfRange.panelMessage, startingAt: outOfRange.startingFolder,
                         window: window, completion: completion)
        }
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { respond($0) }
        } else {
            respond(alert.runModal())
        }
    }

    private static func presentPanel(
        prompt: String, message: String, startingAt folder: URL?, window: NSWindow?,
        completion: @escaping @MainActor (URL?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let folder { panel.directoryURL = folder }
        panel.prompt = prompt
        panel.message = message
        if let window, window.isVisible, window.attachedSheet == nil {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }

    /// Reloads open documents whose needed files became readable, so images,
    /// summaries, and links work without reopening (like File > Reload).
    static func reloadOpenDocuments(_ documentIdentities: Set<String>) {
        guard !documentIdentities.isEmpty else { return }
        for case let document as MarkdownReaderDocument in NSDocumentController.shared.documents {
            guard let fileURL = document.fileURL, documentIdentities.contains(FileIdentity.identity(for: fileURL)) else {
                continue
            }
            document.reloadDocument(nil)
        }
    }
}

/// A read, or edit mode, that the App Sandbox refused. Presented errors
/// offer Grant Access….
struct FolderAccessDeniedError: LocalizedError, CustomNSError, RecoverableError {
    enum Purpose: Sendable {
        /// Reading the file; the grant reopens it.
        case reading
        /// Editing a file Wafer may only read; the read-write grant starts edit mode.
        case editing
    }

    let fileURL: URL
    var purpose = Purpose.reading

    static var errorDomain: String { "dev.wafer.folder-access" }
    var errorCode: Int { purpose == .reading ? 1 : 2 }
    var errorUserInfo: [String: Any] {
        [NSURLErrorKey: fileURL, NSFilePathErrorKey: fileURL.path]
    }

    var errorDescription: String? {
        switch purpose {
        case .reading: "Wafer doesn't have permission to read “\(fileURL.lastPathComponent)”."
        case .editing: "Wafer doesn't have permission to save changes to “\(fileURL.lastPathComponent)”."
        }
    }

    var recoverySuggestion: String? {
        switch purpose {
        case .reading:
            "macOS lets Wafer read only the files and folders you choose. Grant access to the folder that contains it."
        case .editing:
            "Its folder was granted for reading only. Grant access to the folder again to let Wafer save your edits there."
        }
    }

    var recoveryOptions: [String] {
        ["Grant Access…", "Cancel"]
    }

    /// Runs on the main thread after the error's alert closes. The panel
    /// opens even if Wafer believed it could read the file, since the
    /// sandbox just refused it. The grant's completion reopens the file, or
    /// starts edit mode, so this works whether the panel runs modally or as
    /// a sheet; the result only says nothing was recovered before returning.
    func attemptRecovery(optionIndex recoveryOptionIndex: Int) -> Bool {
        guard recoveryOptionIndex == 0 else { return false }
        let fileURL = fileURL
        let purpose = purpose
        MainActor.assumeIsolated {
            FolderAccessFlow.requestAccess(to: fileURL, window: nil, access: purpose == .editing ? .readWrite : .readOnly) {
                let document = OpenDocumentRegistry.shared.document(for: fileURL)
                switch purpose {
                case .reading:
                    if let document {
                        document.reloadDocument(nil)
                    } else {
                        MarkdownDocumentOpener.open(urls: [fileURL])
                    }
                case .editing:
                    document?.beginEditing()
                }
            }
        }
        return false
    }

    /// Edit mode refuses a file it cannot write with `fileWriteNoPermission`.
    /// When the sandbox, not the file's own permissions, is the reason (it
    /// lies only in read-only grants), this error replaces it, offering a
    /// read-write grant.
    @MainActor
    static func explainingWriteRefusal(_ error: Error) -> Error? {
        let error = error as NSError
        let store = FolderAccessStore.shared
        guard store.isSandboxed, error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileWriteNoPermission.rawValue,
              let fileURL = error.userInfo[NSURLErrorKey] as? URL, fileURL.isFileURL,
              store.covers(fileURL), !store.allowsWriting(fileURL) else { return nil }
        return FolderAccessDeniedError(fileURL: fileURL, purpose: .editing)
    }

    /// A read refused for permission. The sandbox reports EPERM; a POSIX
    /// EACCES is an ordinary file permission that a grant cannot change.
    nonisolated static func isPermissionDenied(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var isCocoaPermissionError = false
        while let error = current {
            if error.domain == NSPOSIXErrorDomain {
                return error.code == Int(EPERM)
            }
            if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileReadNoPermission.rawValue {
                isCocoaPermissionError = true
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return isCocoaPermissionError
    }
}

/// A bar under the titlebar that explains a missing folder grant and offers
/// Grant Access…. It never blocks the window.
@MainActor
final class FolderAccessNoticeViewController: NSTitlebarAccessoryViewController, ThemeApplying {
    static let height: CGFloat = 36

    var onGrantAccess: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let grantButton = NSButton(title: "Grant Access…", target: nil, action: nil)
    private let dismissButton = NSButton()
    private let separator = NSView()

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
        fullScreenMinHeight = Self.height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var message: String {
        messageLabel.stringValue
    }

    override func loadView() {
        // Titlebar accessories size from the root view's frame.
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: Self.height))
        rootView.wantsLayer = true
        rootView.setAccessibilityElement(true)
        rootView.setAccessibilityRole(.group)
        rootView.setAccessibilityLabel("Folder access")

        iconView.image = NSImage(systemSymbolName: "folder.badge.questionmark", accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 1
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        grantButton.bezelStyle = .rounded
        grantButton.controlSize = .small
        grantButton.target = self
        grantButton.action = #selector(grantAccess(_:))
        dismissButton.bezelStyle = .inline
        dismissButton.isBordered = false
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismissButton.setAccessibilityLabel("Dismiss")
        dismissButton.target = self
        dismissButton.action = #selector(dismissNotice(_:))
        separator.wantsLayer = true

        let stackView = NSStackView(views: [iconView, messageLabel, grantButton, dismissButton])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.setCustomSpacing(12, after: messageLabel)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(stackView)
        rootView.addSubview(separator)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 14),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -10),
            stackView.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        view = rootView
        applyCurrentTheme()
    }

    /// `folderPath`, the full path of the folder offered, is the bar's tooltip.
    func show(message: String, folderPath: String? = nil) {
        loadViewIfNeeded()
        messageLabel.stringValue = message
        messageLabel.toolTip = folderPath
        grantButton.setAccessibilityHelp(folderPath.map { "\(message) \($0)" } ?? message)
        isHidden = false
    }

    func applyCurrentTheme() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = ReaderTheme.sidebarBackgroundColor.cgColor
        separator.layer?.backgroundColor = ReaderTheme.sidebarChromeBorderColor.cgColor
        messageLabel.textColor = ReaderTheme.sidebarPrimaryTextColor
        iconView.contentTintColor = ReaderTheme.sidebarSecondaryTextColor
        dismissButton.contentTintColor = ReaderTheme.sidebarSecondaryTextColor
        view.appearance = ReaderTheme.windowAppearance
    }

    #if DEBUG
    func triggerGrantAccessForTesting() {
        grantAccess(nil)
    }

    func triggerDismissForTesting() {
        dismissNotice(nil)
    }
    #endif

    @objc private func grantAccess(_ sender: Any?) {
        onGrantAccess?()
    }

    @objc private func dismissNotice(_ sender: Any?) {
        onDismiss?()
    }
}
