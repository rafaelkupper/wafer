import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class LinkTargetOpenerTests: XCTestCase {
    private var directory: TemporaryTestDirectory!
    private var opened: [URL] = []
    private var revealed: [URL] = []
    private var asked: [URL] = []
    private var openedMarkdown: [URL] = []
    private var decision = LinkTargetOpener.FileDecision.cancel

    override func setUp() async throws {
        directory = try TemporaryTestDirectory()
        opened = []
        revealed = []
        asked = []
        openedMarkdown = []
        decision = .cancel
    }

    override func tearDown() async throws {
        directory.remove()
    }

    private func makeOpener() -> LinkTargetOpener {
        LinkTargetOpener(
            openURL: { [unowned self] in self.opened.append($0) },
            revealInFinder: { [unowned self] in self.revealed.append($0) },
            confirmOpeningFile: { [unowned self] in
                self.asked.append($0)
                return self.decision
            },
            openMarkdownFile: { [unowned self] in self.openedMarkdown.append($0) }
        )
    }

    private func makeFile(_ name: String, executable: Bool = false) throws -> URL {
        let url = try directory.createTextFile(named: name, contents: "#!/bin/sh\necho hi\n")
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = directory.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testOnlyWebAndMailLinksOpenExternally() throws {
        let opener = makeOpener()
        let allowed = ["https://example.com/a", "http://example.com", "HTTPS://EXAMPLE.COM/b", "mailto:someone@example.com"]
        let refused = [
            "javascript:alert(1)", "ftp://example.com/file", "vnc://host", "smb://server/share", "tel:123",
            "x-apple.systempreferences:com.apple.preference.security", "custom-app://run?x=1", "file:///Applications/Calculator.app",
        ]

        for string in allowed + refused {
            opener.handle(.external(try XCTUnwrap(URL(string: string))))
        }

        XCTAssertEqual(opened.map(\.absoluteString), allowed)
        XCTAssertEqual(asked, [])
    }

    func testKnownPassiveFilesOpenWithoutAsking() throws {
        let opener = makeOpener()
        let targets = [
            try makeFile("notes.txt"), try makeFile("image.png"), try makeFile("paper.pdf"),
            try makeFile("letter.docx"), try makeFile("table.xlsx"), try makeFile("slides.pptx"),
            try makeFile("song.mp3"), try makeFile("movie.mp4"), try makeFile("note.rtf"),
        ]

        for url in targets {
            opener.handle(.otherFile(url))
        }

        XCTAssertEqual(opened, targets)
        XCTAssertEqual(asked, [])
    }

    func testFilesThatCanRunCodeAskFirst() throws {
        let opener = makeOpener()
        let tool = try makeFile("tool", executable: true)
        let link = directory.url.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        let targets = [
            tool,
            link,
            try makeFile("data.json", executable: true),
            try makeFile("run.command"),
            try makeFile("settings.terminal"),
            try makeFile("script.sh"),
            try makeFile("installer.pkg"),
            try makeFile("site.webloc"),
            try makeFile("target.fileloc"),
            try makeFolder("Calculator.app"),
            try makeFolder("Clean Up.workflow"),
            try makeFolder("Helper.plugin"),
            directory.url.appendingPathComponent("Missing.app"),
        ]

        for url in targets {
            opener.handle(.otherFile(url))
        }

        XCTAssertEqual(asked, targets)
        XCTAssertEqual(opened, [], "nothing opens while the user cancels")
        XCTAssertEqual(revealed, [])
    }

    func testUnknownFilesDirectoriesAndPackagesAskFirst() throws {
        let opener = makeOpener()
        let targets = try [
            "page.html", "disk.dmg", "action.shortcut", "action.wflow",
            "profile.mobileconfig", "launch.jnlp", "notebook.ipynb", "unknown.wafer-unknown",
            "tool-without-extension", "script.py", "script.js", "macro.docm",
        ].map { try makeFile($0) } + [
            makeFolder("Plain folder"), makeFolder("Doc.rtfd"),
            makeFolder("Code.playground"), makeFolder("Project.xcodeproj"),
            makeFolder("Fake.png"),
        ]
        for url in targets { opener.handle(.otherFile(url)) }
        XCTAssertEqual(asked, targets)
        XCTAssertTrue(opened.isEmpty)
    }

    func testScriptCapableImageAndMarkupFilesRequireConfirmation() throws {
        let opener = makeOpener()
        let targets = try ["image.svg", "image.svgz", "data.xml", "page.xhtml", "page.html", "page.webarchive"]
            .map { try makeFile($0) }
        let disguised = directory.url.appendingPathComponent("image.png")
        try FileManager.default.createSymbolicLink(at: disguised, withDestinationURL: targets[0])
        for target in targets + [disguised] { opener.handle(.otherFile(target)) }
        XCTAssertEqual(asked, targets + [disguised])
        XCTAssertTrue(opened.isEmpty)
    }

    func testConfirmationChoosesBetweenOpeningRevealingAndNothing() throws {
        let opener = makeOpener()
        let tool = try makeFile("tool", executable: true)

        decision = .open
        opener.handle(.otherFile(tool))
        decision = .reveal
        opener.handle(.otherFile(tool))
        decision = .cancel
        opener.handle(.otherFile(tool))

        XCTAssertEqual(asked, [tool, tool, tool])
        XCTAssertEqual(opened, [tool])
        XCTAssertEqual(revealed, [tool])
    }

    func testFilesOutsideTheGrantedFoldersAskForAccessBeforeOpening() throws {
        let image = try makeFile("photo.png")
        _ = installSandboxedFolderAccess()
        let opener = makeOpener()

        FolderAccessFlow.chooseFolder = { _, _, completion in completion(nil) }
        opener.handle(.otherFile(image))
        XCTAssertEqual(opened, [])

        var requests: [FolderAccessRequest] = []
        FolderAccessFlow.chooseFolder = { request, _, completion in
            requests.append(request)
            completion(request.suggestedFolder)
        }
        opener.handle(.otherFile(image))

        XCTAssertEqual(requests.map(\.suggestedFolder.path), [directory.url.path])
        XCTAssertEqual(opened, [image])
        XCTAssertEqual(asked, [])
    }

    func testMarkdownAndUnresolvedTargets() throws {
        let opener = makeOpener()
        let note = try makeFile("Note.md")

        opener.handle(.markdownFile(note))
        opener.handle(.unresolved("nowhere"))

        XCTAssertEqual(openedMarkdown, [note])
        XCTAssertEqual(opened, [])
    }

    func testDocumentLinksGoThroughTheOpener() throws {
        let reader = RecordingReaderViewController()
        let document = MarkdownReaderDocument(
            librarySnapshotProvider: emptyTestLibrarySnapshot,
            scrollStateStore: makeTestScrollStateStore(),
            renderScheduler: { _, _, _, _, _ in DispatchWorkItem {} },
            linkTargetHandler: { [unowned self] in self.makeOpener().handle($0) },
            readerControllerFactory: { reader },
            fileMonitorFactory: { _, _ in LinkTestFileMonitor() }
        )
        document.fileURL = try makeFile("Links.md")
        try document.read(from: Data("# Links".utf8), ofType: "dev.wafer.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let tool = try makeFile("tool", executable: true)

        reader.onOpenLink?(tool)
        reader.onOpenLink?(try XCTUnwrap(URL(string: "javascript:alert(1)")))
        reader.onOpenLink?(try XCTUnwrap(URL(string: "https://example.com")))

        XCTAssertEqual(asked, [tool])
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com"])
    }
}

@MainActor
private final class LinkTestFileMonitor: FileChangeMonitoring {
    func start() {}
    func stop() {}
}
