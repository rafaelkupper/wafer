import AppKit
import WaferCore

@MainActor
enum AppMenuBuilder {
    private static let recentDocumentsController = RecentDocumentsMenuController()
    private static let readerBehaviorMenuController = ReaderBehaviorMenuController()
    private static let appearanceMenuController = AppearanceMenuController()
    private static let libraryMenuController = LibraryMenuController()
    private static let quickOpenPanelController = QuickOpenPanelController()

    static func makeMainMenu(windowsMenu: NSMenu, appDelegate: AppDelegate) -> NSMenu {
        let mainMenu = NSMenu(title: "MainMenu")

        let appItem = NSMenuItem()
        let fileItem = NSMenuItem()
        let editItem = NSMenuItem()
        let goItem = NSMenuItem()
        let themeItem = NSMenuItem()
        let windowItem = NSMenuItem()

        mainMenu.addItem(appItem)
        mainMenu.addItem(fileItem)
        mainMenu.addItem(editItem)
        mainMenu.addItem(goItem)
        mainMenu.addItem(themeItem)
        mainMenu.addItem(windowItem)

        appItem.submenu = appMenu()
        fileItem.submenu = fileMenu(appDelegate: appDelegate)
        editItem.submenu = editMenu()
        goItem.submenu = goMenu()
        themeItem.submenu = themeMenu()
        windowItem.submenu = windowsMenu
        appendTabItems(to: windowsMenu)

        return mainMenu
    }

    // Tabs (v1.2)
    private static func appendTabItems(to windowsMenu: NSMenu) {
        windowsMenu.addItem(.separator())

        let previousTabItem = NSMenuItem(
            title: "Show Previous Tab",
            action: #selector(DocumentHostWindowController.showPreviousTab(_:)),
            keyEquivalent: "["
        )
        previousTabItem.keyEquivalentModifierMask = [.command, .shift]
        previousTabItem.target = nil
        windowsMenu.addItem(previousTabItem)

        let nextTabItem = NSMenuItem(
            title: "Show Next Tab",
            action: #selector(DocumentHostWindowController.showNextTab(_:)),
            keyEquivalent: "]"
        )
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        nextTabItem.target = nil
        windowsMenu.addItem(nextTabItem)

        let moveLeftItem = NSMenuItem(
            title: "Move Tab Left",
            action: #selector(DocumentHostWindowController.moveActiveTabLeft(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
        moveLeftItem.keyEquivalentModifierMask = [.command, .control]
        moveLeftItem.target = nil
        windowsMenu.addItem(moveLeftItem)

        let moveRightItem = NSMenuItem(
            title: "Move Tab Right",
            action: #selector(DocumentHostWindowController.moveActiveTabRight(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        )
        moveRightItem.keyEquivalentModifierMask = [.command, .control]
        moveRightItem.target = nil
        windowsMenu.addItem(moveRightItem)
    }
    // End Tabs (v1.2)

    // Go (v1.2)
    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")

        let backItem = NSMenuItem(
            title: "Back",
            action: #selector(MarkdownReaderDocument.goBackInHistory(_:)),
            keyEquivalent: "["
        )
        backItem.target = nil
        menu.addItem(backItem)

        let forwardItem = NSMenuItem(
            title: "Forward",
            action: #selector(MarkdownReaderDocument.goForwardInHistory(_:)),
            keyEquivalent: "]"
        )
        forwardItem.target = nil
        menu.addItem(forwardItem)

        return menu
    }
    // End Go (v1.2)

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Wafer")

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(UpdateController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = UpdateController.shared
        menu.addItem(checkForUpdatesItem)

        let automaticUpdateChecksItem = NSMenuItem(
            title: "Automatically Check for Updates",
            action: #selector(UpdateController.toggleAutomaticallyChecksForUpdates(_:)),
            keyEquivalent: ""
        )
        automaticUpdateChecksItem.target = UpdateController.shared
        menu.addItem(automaticUpdateChecksItem)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Wafer",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    private static func themeMenu() -> NSMenu {
        let menu = NSMenu(title: "Theme")
        menu.delegate = appearanceMenuController
        appearanceMenuController.populate(menu: menu, reloadThemes: false)
        return menu
    }

    private static func fileMenu(appDelegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")

        let openItem = NSMenuItem(
            title: "Open...",
            action: #selector(AppDelegate.openDocument(_:)),
            keyEquivalent: "o"
        )
        openItem.target = appDelegate
        menu.addItem(openItem)

        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.delegate = recentDocumentsController
        openRecentItem.submenu = openRecentMenu
        menu.addItem(openRecentItem)

        let reloadItem = NSMenuItem(
            title: "Reload",
            action: #selector(MarkdownReaderDocument.reloadDocument(_:)),
            keyEquivalent: "r"
        )
        reloadItem.target = nil
        menu.addItem(reloadItem)

        // Edit mode (v1.5): saves happen automatically; Save flushes now.
        let saveItem = NSMenuItem(
            title: "Save",
            action: #selector(MarkdownReaderDocument.saveEdits(_:)),
            keyEquivalent: "s"
        )
        saveItem.target = nil
        menu.addItem(saveItem)

        let revertEditsItem = NSMenuItem(
            title: "Revert Edits",
            action: #selector(MarkdownReaderDocument.revertEdits(_:)),
            keyEquivalent: ""
        )
        revertEditsItem.target = nil
        menu.addItem(revertEditsItem)

        let automaticallyReloadItem = NSMenuItem(
            title: "Automatically Reload",
            action: #selector(ReaderBehaviorMenuController.toggleAutomaticallyReload(_:)),
            keyEquivalent: ""
        )
        automaticallyReloadItem.target = readerBehaviorMenuController
        menu.addItem(automaticallyReloadItem)

        let loadRemoteImagesItem = NSMenuItem(
            title: "Load Remote Images",
            action: #selector(ReaderBehaviorMenuController.toggleLoadRemoteImages(_:)),
            keyEquivalent: ""
        )
        loadRemoteImagesItem.target = readerBehaviorMenuController
        menu.addItem(loadRemoteImagesItem)

        let closeItem = NSMenuItem(
            title: "Close",
            action: #selector(DocumentHostWindowController.closeActiveTab(_:)),
            keyEquivalent: "w"
        )
        closeItem.target = nil
        menu.addItem(closeItem)

        // Library (v0.7)
        menu.addItem(.separator())
        let openFolderItem = NSMenuItem(
            title: "Open Folder...",
            action: #selector(LibraryMenuController.openFolder(_:)),
            keyEquivalent: "o"
        )
        openFolderItem.target = libraryMenuController
        openFolderItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(openFolderItem)

        let closeLibraryItem = NSMenuItem(
            title: "Close Library",
            action: #selector(LibraryMenuController.closeLibrary(_:)),
            keyEquivalent: ""
        )
        closeLibraryItem.target = libraryMenuController
        menu.addItem(closeLibraryItem)

        let retryLibraryItem = NSMenuItem(
            title: "Retry Library", action: #selector(LibraryMenuController.retryLibrary(_:)), keyEquivalent: ""
        )
        retryLibraryItem.target = libraryMenuController
        menu.addItem(retryLibraryItem)

        let quickOpenItem = NSMenuItem(
            title: "Quick Open...",
            action: #selector(QuickOpenPanelController.showQuickOpen(_:)),
            keyEquivalent: "O"
        )
        quickOpenItem.target = quickOpenPanelController
        quickOpenItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(quickOpenItem)
        // End Library (v0.7)

        // Export (v0.8)
        menu.addItem(.separator())
        let printItem = NSMenuItem(
            title: "Print…",
            action: #selector(DocumentWindowController.printDocument(_:)),
            keyEquivalent: "p"
        )
        printItem.target = nil
        menu.addItem(printItem)

        let exportPDFItem = NSMenuItem(
            title: "Export as PDF…",
            action: #selector(DocumentWindowController.exportPDF(_:)),
            keyEquivalent: ""
        )
        exportPDFItem.target = nil
        menu.addItem(exportPDFItem)

        let exportHTMLItem = NSMenuItem(
            title: "Export as HTML…",
            action: #selector(DocumentWindowController.exportHTML(_:)),
            keyEquivalent: ""
        )
        exportHTMLItem.target = nil
        menu.addItem(exportHTMLItem)

        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(editMenuItem(title: "Undo", action: #selector(MarkdownSourceTextView.undo(_:)), keyEquivalent: "z"))
        let redoItem = editMenuItem(title: "Redo", action: #selector(MarkdownSourceTextView.redo(_:)), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redoItem)
        menu.addItem(.separator())
        menu.addItem(editMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(editMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(editMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(editMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        menu.addItem(.separator())
        menu.addItem(editMenuItem(
            title: "Edit Markdown",
            action: #selector(MarkdownReaderDocument.toggleEditing(_:)),
            keyEquivalent: "e"
        ))
        menu.addItem(.separator())
        menu.addItem(findMenuItem(
            title: "Find…",
            keyEquivalent: "f",
            modifiers: [.command],
            action: #selector(WebKitReaderViewController.showFindInterface(_:))
        ))
        menu.addItem(findMenuItem(
            title: "Find Next",
            keyEquivalent: "g",
            modifiers: [.command],
            action: #selector(WebKitReaderViewController.findNextMatch(_:))
        ))
        menu.addItem(findMenuItem(
            title: "Find Previous",
            keyEquivalent: "G",
            modifiers: [.command, .shift],
            action: #selector(WebKitReaderViewController.findPreviousMatch(_:))
        ))

        // Library Search (v0.7)
        menu.addItem(.separator())
        menu.addItem(findMenuItem(
            title: "Search Library…",
            keyEquivalent: "F",
            modifiers: [.command, .shift],
            action: #selector(DocumentWindowController.focusLibrarySearch(_:))
        ))
        // End Library Search (v0.7)
        return menu
    }

    private static func editMenuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = nil
        return item
    }

    private static func findMenuItem(
        title: String,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.target = nil
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

@MainActor
final class LibraryMenuController: NSObject, NSMenuItemValidation {
    typealias InitialDocumentOpenHandler = @MainActor ([LibraryFile]) -> Void

    private let libraryController: LibraryController
    private let openInitialDocument: InitialDocumentOpenHandler

    init(
        libraryController: LibraryController = .shared,
        openInitialDocument: @escaping InitialDocumentOpenHandler = {
            LibraryInitialDocumentOpener.openFirstDocumentIfNoMarkdownWindow(files: $0)
        }
    ) {
        self.libraryController = libraryController
        self.openInitialDocument = openInitialDocument
        super.init()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closeLibrary(_:)):
            return libraryController.hasLibrary
        case #selector(retryLibrary(_:)):
            return libraryController.hasLibrary && !libraryController.isScanning
        default:
            return true
        }
    }

    @objc func openFolder(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.urls.first else {
            return
        }

        openLibrary(at: url)
    }

    func openLibrary(at url: URL) {
        do {
            try libraryController.openLibrary(at: url) { [openInitialDocument] files in
                openInitialDocument(files)
            }
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc func closeLibrary(_ sender: NSMenuItem) {
        libraryController.closeLibrary()
    }

    @objc func retryLibrary(_ sender: NSMenuItem) {
        libraryController.refreshLibrary()
    }
}

@MainActor
final class AppearanceMenuController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let preferenceStore: AppearancePreferenceStore
    private let themeLibrary: ThemeLibrary

    init(
        preferenceStore: AppearancePreferenceStore = .shared,
        themeLibrary: ThemeLibrary = .shared
    ) {
        self.preferenceStore = preferenceStore
        self.themeLibrary = themeLibrary
        super.init()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu: menu, reloadThemes: true)
    }

    func populate(menu: NSMenu, reloadThemes: Bool) {
        if reloadThemes {
            themeLibrary.loadThemes()
        }

        menu.removeAllItems()
        for selection in AppearanceSelection.builtInMenuSelections {
            menu.addItem(appearanceItem(for: selection))
        }

        let customPalettes = themeLibrary.palettes
        if !customPalettes.isEmpty {
            menu.addItem(.separator())
            for palette in customPalettes {
                menu.addItem(appearanceItem(for: .custom(palette.name)))
            }
        }

        menu.addItem(.separator())
        let reloadItem = NSMenuItem(
            title: "Reload Themes",
            action: #selector(reloadThemes(_:)),
            keyEquivalent: ""
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

        let revealItem = NSMenuItem(
            title: "Reveal Themes Folder in Finder",
            action: #selector(revealThemesFolder(_:)),
            keyEquivalent: ""
        )
        revealItem.target = self
        menu.addItem(revealItem)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard
            menuItem.action == #selector(selectAppearance(_:)),
            let selection = representedSelection(for: menuItem)
        else {
            return true
        }

        menuItem.state = selection == preferenceStore.appearanceSelection ? .on : .off
        return true
    }

    @objc func selectAppearance(_ sender: NSMenuItem) {
        guard let selection = representedSelection(for: sender) else {
            return
        }

        preferenceStore.appearanceSelection = selection
        sender.state = .on
    }

    @objc func reloadThemes(_ sender: NSMenuItem) {
        themeLibrary.loadThemes()
        preferenceStore.applyResolvedPalette()
        if let menu = sender.menu {
            populate(menu: menu, reloadThemes: false)
        }
    }

    @objc func revealThemesFolder(_ sender: NSMenuItem) {
        themeLibrary.revealThemesFolder()
    }

    private func appearanceItem(for selection: AppearanceSelection) -> NSMenuItem {
        let item = NSMenuItem(
            title: selection.menuTitle,
            action: #selector(selectAppearance(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = selection.rawValue
        return item
    }

    private func representedSelection(for item: NSMenuItem) -> AppearanceSelection? {
        guard let rawValue = item.representedObject as? String else {
            return nil
        }

        return AppearanceSelection(rawValue: rawValue)
    }
}

@MainActor
final class ReaderBehaviorMenuController: NSObject, NSMenuItemValidation {
    private let preferenceStore: ReaderBehaviorPreferenceStore

    init(preferenceStore: ReaderBehaviorPreferenceStore = .shared) {
        self.preferenceStore = preferenceStore
        super.init()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleAutomaticallyReload(_:)):
            menuItem.state = preferenceStore.automaticallyReloadsDocuments ? .on : .off
            return true
        case #selector(toggleLoadRemoteImages(_:)):
            menuItem.state = preferenceStore.loadsRemoteImages ? .on : .off
            return true
        default:
            return true
        }
    }

    @objc func toggleAutomaticallyReload(_ sender: NSMenuItem) {
        preferenceStore.automaticallyReloadsDocuments.toggle()
        sender.state = preferenceStore.automaticallyReloadsDocuments ? .on : .off
    }

    @objc func toggleLoadRemoteImages(_ sender: NSMenuItem) {
        preferenceStore.loadsRemoteImages.toggle()
        sender.state = preferenceStore.loadsRemoteImages ? .on : .off
    }
}

@MainActor
final class RecentDocumentsMenuController: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let clear = NSMenuItem(
            title: "Clear Menu",
            action: #selector(NSDocumentController.clearRecentDocuments(_:)),
            keyEquivalent: ""
        )
        clear.target = NSDocumentController.shared
        menu.addItem(clear)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else {
            return
        }

        MarkdownDocumentOpener.open(urls: [url])
    }
}
