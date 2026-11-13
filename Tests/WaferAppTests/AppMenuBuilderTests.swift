import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class AppMenuBuilderTests: XCTestCase {
    func testMainMenuIncludesEditMenuWithStandardEditingAndFindCommands() throws {
        let appDelegate = AppDelegate(openURLs: { _ in })
        let windowMenu = NSMenu(title: "Window")

        let menu = AppMenuBuilder.makeMainMenu(windowsMenu: windowMenu, appDelegate: appDelegate)

        XCTAssertEqual(menu.items.count, 6)
        XCTAssertEqual(menu.items[0].submenu?.title, "Wafer")
        XCTAssertEqual(menu.items[1].submenu?.title, "File")
        XCTAssertEqual(menu.items[2].submenu?.title, "Edit")
        XCTAssertEqual(menu.items[3].submenu?.title, "Go")
        XCTAssertEqual(menu.items[4].submenu?.title, "Theme")
        XCTAssertTrue(menu.items[5].submenu === windowMenu)

        let goMenu = try XCTUnwrap(menu.items[3].submenu)
        XCTAssertEqual(goMenu.items.map(\.title), ["Back", "Forward"])
        XCTAssertEqual(goMenu.items[0].action, #selector(MarkdownReaderDocument.goBackInHistory(_:)))
        XCTAssertEqual(goMenu.items[0].keyEquivalent, "[")
        XCTAssertEqual(goMenu.items[0].keyEquivalentModifierMask, [.command])
        XCTAssertNil(goMenu.items[0].target)
        XCTAssertEqual(goMenu.items[1].action, #selector(MarkdownReaderDocument.goForwardInHistory(_:)))
        XCTAssertEqual(goMenu.items[1].keyEquivalent, "]")
        XCTAssertEqual(goMenu.items[1].keyEquivalentModifierMask, [.command])
        XCTAssertNil(goMenu.items[1].target)

        let appMenu = try XCTUnwrap(menu.items[0].submenu)
        XCTAssertEqual(
            appMenu.items.map(\.title),
            ["Check for Updates…", "Automatically Check for Updates", "", "Quit Wafer"]
        )
        XCTAssertEqual(appMenu.items[0].action, #selector(UpdateController.checkForUpdates(_:)))
        XCTAssertTrue(appMenu.items[0].target === UpdateController.shared)
        XCTAssertEqual(appMenu.items[1].action, #selector(UpdateController.toggleAutomaticallyChecksForUpdates(_:)))
        XCTAssertTrue(appMenu.items[1].target === UpdateController.shared)

        let themeMenu = try XCTUnwrap(menu.items[4].submenu)
        XCTAssertTrue(themeMenu.delegate is AppearanceMenuController)
        XCTAssertEqual(
            themeMenu.items.map(\.title),
            ["System", "Light", "Dark", "", "Reload Themes", "Reveal Themes Folder in Finder"]
        )
        XCTAssertTrue(themeMenu.items[0...2].allSatisfy { $0.target is AppearanceMenuController })
        XCTAssertTrue(themeMenu.items[3].isSeparatorItem)
        XCTAssertEqual(themeMenu.items[4].action, #selector(AppearanceMenuController.reloadThemes(_:)))
        XCTAssertTrue(themeMenu.items[4].target is AppearanceMenuController)
        XCTAssertEqual(themeMenu.items[5].action, #selector(AppearanceMenuController.revealThemesFolder(_:)))
        XCTAssertTrue(themeMenu.items[5].target is AppearanceMenuController)

        let editMenu = try XCTUnwrap(menu.items[2].submenu)
        XCTAssertEqual(
            editMenu.items.map(\.title),
            ["Undo", "Redo", "", "Cut", "Copy", "Paste", "Select All", "", "Edit Markdown", "",
             "Find…", "Find Next", "Find Previous", "", "Search Library…"]
        )

        XCTAssertEqual(editMenu.items[0].action, #selector(MarkdownSourceTextView.undo(_:)))
        XCTAssertEqual(editMenu.items[0].keyEquivalent, "z")
        XCTAssertEqual(editMenu.items[1].action, #selector(MarkdownSourceTextView.redo(_:)))
        XCTAssertEqual(editMenu.items[1].keyEquivalentModifierMask, [.command, .shift])
        let editMarkdownItem = editMenu.items[8]
        XCTAssertEqual(editMarkdownItem.action, #selector(MarkdownReaderDocument.toggleEditing(_:)))
        XCTAssertNil(editMarkdownItem.target)
        XCTAssertEqual(editMarkdownItem.keyEquivalent, "e")
        XCTAssertEqual(editMarkdownItem.keyEquivalentModifierMask, [.command])

        let cutItem = editMenu.items[3]
        XCTAssertEqual(cutItem.action, #selector(NSText.cut(_:)))
        XCTAssertNil(cutItem.target)
        XCTAssertEqual(cutItem.keyEquivalent, "x")

        let copyItem = editMenu.items[4]
        XCTAssertEqual(copyItem.action, #selector(NSText.copy(_:)))
        XCTAssertNil(copyItem.target)
        XCTAssertEqual(copyItem.keyEquivalent, "c")

        let pasteItem = editMenu.items[5]
        XCTAssertEqual(pasteItem.action, #selector(NSText.paste(_:)))
        XCTAssertNil(pasteItem.target)
        XCTAssertEqual(pasteItem.keyEquivalent, "v")

        let selectAllItem = editMenu.items[6]
        XCTAssertEqual(selectAllItem.action, #selector(NSText.selectAll(_:)))
        XCTAssertNil(selectAllItem.target)
        XCTAssertEqual(selectAllItem.keyEquivalent, "a")
        XCTAssertTrue(editMenu.items[7].isSeparatorItem)

        let findItem = editMenu.items[10]
        XCTAssertEqual(findItem.action, #selector(WebKitReaderViewController.showFindInterface(_:)))
        XCTAssertNil(findItem.target)
        XCTAssertEqual(findItem.keyEquivalent, "f")
        XCTAssertEqual(findItem.keyEquivalentModifierMask, [.command])

        let nextItem = editMenu.items[11]
        XCTAssertEqual(nextItem.action, #selector(WebKitReaderViewController.findNextMatch(_:)))
        XCTAssertEqual(nextItem.keyEquivalent, "g")
        XCTAssertEqual(nextItem.keyEquivalentModifierMask, [.command])

        let previousItem = editMenu.items[12]
        XCTAssertEqual(previousItem.action, #selector(WebKitReaderViewController.findPreviousMatch(_:)))
        XCTAssertEqual(previousItem.keyEquivalent, "G")
        XCTAssertEqual(previousItem.keyEquivalentModifierMask, [.command, .shift])

        XCTAssertTrue(editMenu.items[13].isSeparatorItem)
        let searchLibraryItem = editMenu.items[14]
        XCTAssertEqual(searchLibraryItem.action, #selector(DocumentWindowController.focusLibrarySearch(_:)))
        XCTAssertNil(searchLibraryItem.target)
        XCTAssertEqual(searchLibraryItem.keyEquivalent, "F")
        XCTAssertEqual(searchLibraryItem.keyEquivalentModifierMask, [.command, .shift])
    }

    func testFileMenuIncludesRetainedOpenRecentSubmenu() throws {
        let appDelegate = AppDelegate(openURLs: { _ in })
        let menu = AppMenuBuilder.makeMainMenu(windowsMenu: NSMenu(title: "Window"), appDelegate: appDelegate)

        let fileMenu = try XCTUnwrap(menu.items[1].submenu)
        XCTAssertEqual(
            fileMenu.items.map(\.title),
            [
                "Open...",
                "Open Recent",
                "Reload",
                "Save",
                "Revert Edits",
                "Automatically Reload",
                "Load Remote Images",
                "Close",
                "",
                "Open Folder...",
                "Close Library",
                "Retry Library",
                "Quick Open...",
                "",
                "Print…",
                "Export as PDF…",
                "Export as HTML…",
            ]
        )

        let openRecentSubmenu = try XCTUnwrap(fileMenu.items[1].submenu)
        XCTAssertEqual(openRecentSubmenu.title, "Open Recent")
        XCTAssertNotNil(openRecentSubmenu.delegate)

        let reloadItem = fileMenu.items[2]
        XCTAssertEqual(reloadItem.action, #selector(MarkdownReaderDocument.reloadDocument(_:)))
        XCTAssertNil(reloadItem.target)
        XCTAssertEqual(reloadItem.keyEquivalent, "r")
        XCTAssertEqual(reloadItem.keyEquivalentModifierMask, [.command])

        let saveItem = fileMenu.items[3]
        XCTAssertEqual(saveItem.action, #selector(MarkdownReaderDocument.saveEdits(_:)))
        XCTAssertNil(saveItem.target)
        XCTAssertEqual(saveItem.keyEquivalent, "s")
        XCTAssertEqual(fileMenu.items[4].action, #selector(MarkdownReaderDocument.revertEdits(_:)))

        let autoReloadItem = fileMenu.items[5]
        XCTAssertEqual(autoReloadItem.action, #selector(ReaderBehaviorMenuController.toggleAutomaticallyReload(_:)))
        XCTAssertTrue(autoReloadItem.target is ReaderBehaviorMenuController)
        XCTAssertEqual(autoReloadItem.keyEquivalent, "")

        XCTAssertTrue((autoReloadItem.target as? ReaderBehaviorMenuController)?.validateMenuItem(autoReloadItem) == true)

        let loadRemoteImagesItem = fileMenu.items[6]
        XCTAssertEqual(loadRemoteImagesItem.action, #selector(ReaderBehaviorMenuController.toggleLoadRemoteImages(_:)))
        XCTAssertTrue(loadRemoteImagesItem.target is ReaderBehaviorMenuController)
        XCTAssertEqual(loadRemoteImagesItem.keyEquivalent, "")
        XCTAssertTrue((loadRemoteImagesItem.target as? ReaderBehaviorMenuController)?.validateMenuItem(loadRemoteImagesItem) == true)

        XCTAssertTrue(fileMenu.items[8].isSeparatorItem)
        let openFolderItem = fileMenu.items[9]
        XCTAssertEqual(openFolderItem.action, #selector(LibraryMenuController.openFolder(_:)))
        XCTAssertTrue(openFolderItem.target is LibraryMenuController)
        XCTAssertEqual(openFolderItem.keyEquivalent, "o")
        XCTAssertEqual(openFolderItem.keyEquivalentModifierMask, [.command, .option])

        let closeLibraryItem = fileMenu.items[10]
        XCTAssertEqual(closeLibraryItem.action, #selector(LibraryMenuController.closeLibrary(_:)))
        XCTAssertTrue(closeLibraryItem.target is LibraryMenuController)

        let retryLibraryItem = fileMenu.items[11]
        XCTAssertEqual(retryLibraryItem.action, #selector(LibraryMenuController.retryLibrary(_:)))
        XCTAssertTrue(retryLibraryItem.target is LibraryMenuController)

        let quickOpenItem = fileMenu.items[12]
        XCTAssertEqual(quickOpenItem.action, #selector(QuickOpenPanelController.showQuickOpen(_:)))
        XCTAssertTrue(quickOpenItem.target is QuickOpenPanelController)
        XCTAssertEqual(quickOpenItem.keyEquivalent, "O")
        XCTAssertEqual(quickOpenItem.keyEquivalentModifierMask, [.command, .shift])

        XCTAssertTrue(fileMenu.items[13].isSeparatorItem)

        let printItem = fileMenu.items[14]
        XCTAssertEqual(printItem.action, #selector(DocumentWindowController.printDocument(_:)))
        XCTAssertNil(printItem.target)
        XCTAssertEqual(printItem.keyEquivalent, "p")
        XCTAssertEqual(printItem.keyEquivalentModifierMask, [.command])

        let exportPDFItem = fileMenu.items[15]
        XCTAssertEqual(exportPDFItem.action, #selector(DocumentWindowController.exportPDF(_:)))
        XCTAssertNil(exportPDFItem.target)
        XCTAssertEqual(exportPDFItem.keyEquivalent, "")

        let exportHTMLItem = fileMenu.items[16]
        XCTAssertEqual(exportHTMLItem.action, #selector(DocumentWindowController.exportHTML(_:)))
        XCTAssertNil(exportHTMLItem.target)
        XCTAssertEqual(exportHTMLItem.keyEquivalent, "")
    }

    func testLibraryMenuControllerValidationAndCloseActionReflectLibraryState() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let firstURL = tempDirectory.url.appendingPathComponent("A.md")
        let secondURL = tempDirectory.url.appendingPathComponent("B.md")
        let scannedFiles = [
            libraryFile(url: firstURL, title: "A"),
            libraryFile(url: secondURL, title: "B"),
        ]
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            scanner: { _ in LibraryScanner.Result(files: scannedFiles, truncated: false) },
            monitorFactory: { rootURL, onChange in FakeMenuDirectoryMonitor(rootURL: rootURL, onChange: onChange) }
        )
        let menuController = LibraryMenuController(libraryController: controller)
        let closeItem = NSMenuItem(
            title: "Close Library",
            action: #selector(LibraryMenuController.closeLibrary(_:)),
            keyEquivalent: ""
        )

        XCTAssertFalse(menuController.validateMenuItem(closeItem))

        try controller.openLibrary(at: tempDirectory.url)
        XCTAssertTrue(menuController.validateMenuItem(closeItem))

        menuController.closeLibrary(closeItem)

        XCTAssertFalse(controller.hasLibrary)
        XCTAssertFalse(menuController.validateMenuItem(closeItem))

        var openedDocumentURLs: [URL] = []
        let openingMenuController = LibraryMenuController(
            libraryController: controller,
            openInitialDocument: { files in
                LibraryInitialDocumentOpener.openFirstDocumentIfNoMarkdownWindow(
                    files: files,
                    hasVisibleMarkdownWindow: { false },
                    openDocument: { openedDocumentURLs.append($0) },
                    presentError: { XCTFail("Unexpected error: \($0)") }
                )
            }
        )

        openingMenuController.openLibrary(at: tempDirectory.url)
        waitUntil(timeout: 2) {
            !controller.isScanning
        }

        XCTAssertTrue(controller.hasLibrary)
        XCTAssertEqual(openedDocumentURLs, [firstURL])
    }

    func testOpenRecentSubmenuPopulatesRecentDocumentsAndClearMenu() throws {
        NSDocumentController.shared.clearRecentDocuments(nil)
        defer { NSDocumentController.shared.clearRecentDocuments(nil) }
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let recentURL = try tempDirectory.createTextFile(named: "Recent.md", contents: "# Recent")
        NSDocumentController.shared.noteNewRecentDocumentURL(recentURL)
        let appDelegate = AppDelegate(openURLs: { _ in })
        let menu = AppMenuBuilder.makeMainMenu(windowsMenu: NSMenu(title: "Window"), appDelegate: appDelegate)
        let fileMenu = try XCTUnwrap(menu.items[1].submenu)
        let openRecentSubmenu = try XCTUnwrap(fileMenu.items[1].submenu)

        openRecentSubmenu.delegate?.menuNeedsUpdate?(openRecentSubmenu)

        XCTAssertEqual(openRecentSubmenu.items.first?.title, "Recent.md")
        XCTAssertEqual(
            (openRecentSubmenu.items.first?.representedObject as? URL)?.standardizedFileURL.resolvingSymlinksInPath(),
            recentURL.standardizedFileURL.resolvingSymlinksInPath()
        )
        let clearItem = try XCTUnwrap(openRecentSubmenu.items.last)
        XCTAssertEqual(clearItem.title, "Clear Menu")
        XCTAssertEqual(clearItem.action, #selector(NSDocumentController.clearRecentDocuments(_:)))
        XCTAssertTrue(clearItem.target === NSDocumentController.shared)
    }

    func testAutomaticallyReloadMenuItemReflectsAndTogglesPreference() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ReaderBehaviorPreferenceStore(defaults: defaults)
        let controller = ReaderBehaviorMenuController(preferenceStore: store)
        let item = NSMenuItem(
            title: "Automatically Reload",
            action: #selector(ReaderBehaviorMenuController.toggleAutomaticallyReload(_:)),
            keyEquivalent: ""
        )

        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)

        controller.toggleAutomaticallyReload(item)

        XCTAssertFalse(store.automaticallyReloadsDocuments)
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
    }

    func testLoadRemoteImagesMenuItemReflectsAndTogglesPreference() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ReaderBehaviorPreferenceStore(defaults: defaults)
        let controller = ReaderBehaviorMenuController(preferenceStore: store)
        let item = NSMenuItem(
            title: "Load Remote Images",
            action: #selector(ReaderBehaviorMenuController.toggleLoadRemoteImages(_:)),
            keyEquivalent: ""
        )

        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)

        controller.toggleLoadRemoteImages(item)

        XCTAssertFalse(store.loadsRemoteImages)
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
    }

    func testAppearanceMenuItemReflectsAndChangesSelection() throws {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AppearancePreferenceStore(defaults: defaults, systemIsDark: { false })
        let controller = AppearanceMenuController(preferenceStore: store)
        let systemItem = appearanceMenuItem(title: "System", selection: .system)
        let darkItem = appearanceMenuItem(title: "Dark", selection: .dark)

        XCTAssertTrue(controller.validateMenuItem(systemItem))
        XCTAssertEqual(systemItem.state, .on)
        XCTAssertTrue(controller.validateMenuItem(darkItem))
        XCTAssertEqual(darkItem.state, .off)

        controller.selectAppearance(darkItem)

        XCTAssertEqual(store.appearanceSelection, .dark)
        XCTAssertEqual(ReaderTheme.current, .dark)
        XCTAssertTrue(controller.validateMenuItem(systemItem))
        XCTAssertEqual(systemItem.state, .off)
        XCTAssertTrue(controller.validateMenuItem(darkItem))
        XCTAssertEqual(darkItem.state, .on)
    }

    func testAppearanceMenuDelegateListsCustomThemes() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let themesURL = tempDirectory.url.appendingPathComponent("Themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try themeData(named: "Ocean").write(to: themesURL.appendingPathComponent("Ocean.json"))
        let library = ThemeLibrary(themesDirectoryURL: themesURL, bundledThemesDirectoryURL: nil, revealHandler: { _ in })
        let controller = AppearanceMenuController(themeLibrary: library)
        let menu = NSMenu(title: "Appearance")

        controller.menuNeedsUpdate(menu)

        XCTAssertFalse(menu.items.contains { $0.title == "Example" }, "the Example template must not be listed")
        let customItem = try XCTUnwrap(menu.items.first { $0.title == "Ocean" })
        XCTAssertEqual(customItem.action, #selector(AppearanceMenuController.selectAppearance(_:)))
        XCTAssertTrue(customItem.target === controller)
        XCTAssertEqual(customItem.representedObject as? String, "custom:Ocean")
        XCTAssertTrue(menu.items.contains { $0.title == "Reload Themes" })
        XCTAssertTrue(menu.items.contains { $0.title == "Reveal Themes Folder in Finder" })
    }

    func testCustomAppearanceMenuItemPersistsAndAppliesTheme() throws {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let themesURL = tempDirectory.url.appendingPathComponent("Themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try themeData(named: "Ocean").write(to: themesURL.appendingPathComponent("Ocean.json"))
        let library = ThemeLibrary(themesDirectoryURL: themesURL, bundledThemesDirectoryURL: nil, revealHandler: { _ in })
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AppearancePreferenceStore(
            defaults: defaults,
            themeLibrary: library,
            missingCustomThemeNotifier: { XCTFail("Listed theme should resolve: \($0)") },
            systemIsDark: { false }
        )
        let controller = AppearanceMenuController(preferenceStore: store, themeLibrary: library)
        let menu = NSMenu(title: "Appearance")
        controller.menuNeedsUpdate(menu)
        let customItem = try XCTUnwrap(menu.items.first { $0.title == "Ocean" })

        controller.selectAppearance(customItem)

        XCTAssertEqual(store.appearanceSelection, .custom("Ocean"))
        XCTAssertEqual(ReaderTheme.current.name, "Ocean")
        XCTAssertTrue(controller.validateMenuItem(customItem))
        XCTAssertEqual(customItem.state, .on)
    }

    func testReloadThemesRescansMenuAndRevealUsesThemeLibrary() throws {
        let tempDirectory = try TemporaryTestDirectory()
        defer { tempDirectory.remove() }
        let themesURL = tempDirectory.url.appendingPathComponent("Themes", isDirectory: true)
        var revealedURL: URL?
        let library = ThemeLibrary(
            themesDirectoryURL: themesURL,
            bundledThemesDirectoryURL: nil,
            revealHandler: { revealedURL = $0 }
        )
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AppearancePreferenceStore(defaults: defaults, themeLibrary: library, systemIsDark: { false })
        let controller = AppearanceMenuController(preferenceStore: store, themeLibrary: library)
        let menu = NSMenu(title: "Appearance")
        controller.populate(menu: menu, reloadThemes: false)
        XCTAssertFalse(menu.items.contains { $0.title == "Ocean" })
        try FileManager.default.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try themeData(named: "Ocean").write(to: themesURL.appendingPathComponent("Ocean.json"))
        let reloadItem = try XCTUnwrap(menu.items.first { $0.title == "Reload Themes" })

        controller.reloadThemes(reloadItem)

        XCTAssertTrue(menu.items.contains { $0.title == "Ocean" })

        let revealItem = try XCTUnwrap(menu.items.first { $0.title == "Reveal Themes Folder in Finder" })
        controller.revealThemesFolder(revealItem)

        XCTAssertEqual(revealedURL, themesURL)
    }

    private func appearanceMenuItem(title: String, selection: AppearanceSelection) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(AppearanceMenuController.selectAppearance(_:)),
            keyEquivalent: ""
        )
        item.representedObject = selection.rawValue
        return item
    }

    private func libraryFile(url: URL, title: String) -> LibraryFile {
        LibraryFile(
            fileURL: url,
            relativePathComponents: [url.lastPathComponent],
            displayTitle: title,
            outlineItems: [],
            plainText: "",
            searchableText: "",
            contentFingerprint: LibraryFileFingerprint(
                modificationDate: Date(timeIntervalSince1970: 0),
                fileSize: 0
            )
        )
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class FakeMenuDirectoryMonitor: DirectoryMonitoring {
    init(rootURL: URL, onChange: @escaping () -> Void) {}

    func start() {}

    func stop() {}
}
