import AppKit
import Foundation
import WaferCore

/// What the folder panel asks for.
struct FolderAccessRequest: Equatable {
    /// Where the panel opens; choosing without selecting picks this folder.
    let suggestedFolder: URL
    let message: String
    var prompt = "Grant Access"
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

    /// True when Wafer can read `url` now. Otherwise asks for a folder that
    /// holds it, returns false, and calls `onGranted` once `url` is readable.
    @discardableResult
    static func ensureAccess(
        to url: URL, requestedBy documentURL: URL?, window: NSWindow?,
        onGranted: @escaping @MainActor () -> Void
    ) -> Bool {
        let store = FolderAccessStore.shared
        guard !store.covers(url) else { return true }
        if let documentURL {
            store.recordUnreadableFile(url, forDocumentAt: documentURL)
        }
        let folder = FileIdentity.normalized(url).deletingLastPathComponent()
        let request = FolderAccessRequest(suggestedFolder: folder, message: message(
            opening: url.lastPathComponent, folderName: folder.lastPathComponent
        ))
        chooseFolder(request, window) { chosen in
            guard let chosen else { return }
            refreshDocuments(store.grantAccess(to: chosen))
            if store.covers(url) { onGranted() }
        }
        return false
    }

    /// Grant Access… in a document window: offers the document's folder, or
    /// the closest folder that also holds the files it needs.
    static func requestAccess(
        forDocumentAt documentURL: URL, window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        let store = FolderAccessStore.shared
        let folder = store.suggestedFolder(forDocumentAt: documentURL)
        let request = FolderAccessRequest(suggestedFolder: folder, message: message(
            showing: documentURL.lastPathComponent, folderName: folder.lastPathComponent
        ))
        chooseFolder(request, window) { chosen in
            guard let chosen else {
                completion(false)
                return
            }
            refreshDocuments(store.grantAccess(to: chosen))
            completion(true)
        }
    }

    static func noticeMessage(folderName: String) -> String {
        "Allow Wafer to read the folder “\(folderName)” to show linked files and images."
    }

    static func message(showing documentName: String, folderName: String) -> String {
        "Wafer can read only the files and folders you choose. Grant access to “\(folderName)” to show the images and linked files in “\(documentName)”. Choosing a parent folder covers more of your documents."
    }

    static func message(opening fileName: String, folderName: String) -> String {
        "Wafer can read only the files and folders you choose. Grant access to “\(folderName)” to open “\(fileName)”. Choosing a parent folder covers more of your documents."
    }

    /// The default chooser: a folder-only open panel, as a sheet when a
    /// window is free for one.
    static func runOpenPanel(_ request: FolderAccessRequest, window: NSWindow?, completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = request.suggestedFolder
        panel.prompt = request.prompt
        panel.message = request.message
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

/// A read the App Sandbox refused. Presented errors offer Grant Access….
struct FolderAccessDeniedError: LocalizedError, CustomNSError, RecoverableError {
    let fileURL: URL

    static var errorDomain: String { "dev.wafer.folder-access" }
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] {
        [NSURLErrorKey: fileURL, NSFilePathErrorKey: fileURL.path]
    }

    var errorDescription: String? {
        "Wafer doesn't have permission to read “\(fileURL.lastPathComponent)”."
    }

    var recoverySuggestion: String? {
        "macOS lets Wafer read only the files and folders you choose. Grant access to the folder that contains it; choosing a parent folder covers more of your documents."
    }

    var recoveryOptions: [String] {
        ["Grant Access…", "Cancel"]
    }

    /// Runs on the main thread after the error's alert closes.
    func attemptRecovery(optionIndex recoveryOptionIndex: Int) -> Bool {
        guard recoveryOptionIndex == 0 else { return false }
        let fileURL = fileURL
        return MainActor.assumeIsolated {
            let reopen = {
                if let document = OpenDocumentRegistry.shared.document(for: fileURL) {
                    document.reloadDocument(nil)
                } else {
                    MarkdownDocumentOpener.open(urls: [fileURL])
                }
            }
            var granted = false
            // Without a window the panel is app-modal, so this returns after it.
            if FolderAccessFlow.ensureAccess(to: fileURL, requestedBy: nil, window: nil, onGranted: {
                granted = true
                reopen()
            }) {
                reopen()
                return true
            }
            return granted
        }
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
    static let height: CGFloat = 34

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

    func show(message: String) {
        loadViewIfNeeded()
        messageLabel.stringValue = message
        grantButton.setAccessibilityHelp(message)
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
