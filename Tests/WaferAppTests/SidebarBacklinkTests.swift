import AppKit
import Foundation
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class SidebarBacklinkTests: XCTestCase {
    private func makeLibrary(
        files: [(name: String, contents: String)]
    ) throws -> (controller: LibraryController, center: NotificationCenter, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            try Data(file.contents.utf8).write(to: root.appendingPathComponent(file.name))
        }

        let center = NotificationCenter()
        let controller = LibraryController(
            preferenceStore: LibraryPreferenceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            notificationCenter: center,
            monitorFactory: { _, _ in StubDirectoryMonitor() }
        )
        return (controller, center, root)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        condition: @escaping @MainActor () -> Bool
    ) {
        let done = expectation(description: description)
        Task { @MainActor in
            while !condition() {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: timeout)
    }

    private func openAndWait(_ controller: LibraryController, center: NotificationCenter, root: URL) throws {
        try controller.openLibrary(at: root)
        waitUntil("library loaded") {
            !controller.isScanning && !controller.files.isEmpty
        }
    }

    func testControllerExposesBacklinksAndRefreshesOnRescan() throws {
        let (controller, center, root) = try makeLibrary(files: [
            ("Hub.md", "# Hub\n\nSee [[Target]]."),
            ("Target.md", "# Target"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        try openAndWait(controller, center: center, root: root)
        let targetURL = root.appendingPathComponent("Target.md")
        XCTAssertEqual(controller.backlinks(for: targetURL).map(\.sourceTitle), ["Hub"])

        // Adding a second linking file and rescanning updates the index.
        try Data("# Second\n\n[[Target]] again.".utf8).write(to: root.appendingPathComponent("Second.md"))
        controller.refreshLibrary()
        waitUntil("rescan finished") {
            !controller.isScanning && controller.files.count == 3
        }

        XCTAssertEqual(
            controller.backlinks(for: targetURL).map(\.sourceTitle).sorted(),
            ["Hub", "Second"]
        )
        controller.closeLibrary()
        XCTAssertTrue(controller.backlinks(for: targetURL).isEmpty)
    }

    func testOutlineViewShowsLinkedFromSectionAndNavigates() throws {
        let (controller, center, root) = try makeLibrary(files: [
            ("Hub.md", "# Hub\n\nSee [[Target]] for setup."),
            ("Target.md", "# Target\n\n## Section"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        try openAndWait(controller, center: center, root: root)

        let sidebar = DocumentSidebarViewController(
            libraryController: controller,
            notificationCenter: center
        )
        sidebar.loadViewIfNeeded()
        sidebar.setMode(.outline)

        var activations: [(URL, String?)] = []
        sidebar.onSelectDocumentWithAnchor = { url, anchorID in
            activations.append((url, anchorID))
        }

        let targetURL = root.appendingPathComponent("Target.md")
        sidebar.apply(
            sidebarEntries: [
                DocumentSidebarEntry(
                    fileURL: targetURL,
                    displayTitle: "Target",
                    previewText: "",
                    isCurrent: true,
                    isAvailable: true
                ),
            ],
            outlineItems: [DocumentOutlineItem(title: "Section", level: 2, anchorID: "section")]
        )

        XCTAssertTrue(sidebar.hasBacklinkSectionForTesting)
        XCTAssertEqual(sidebar.backlinkTitlesForTesting, ["Hub"])

        sidebar.triggerBacklinkActivationForTesting(at: 0)
        XCTAssertEqual(activations.count, 1)
        XCTAssertEqual(
            FileIdentity.normalized(activations[0].0),
            FileIdentity.normalized(root.appendingPathComponent("Hub.md"))
        )

        // A document with no backlinks shows no section.
        sidebar.apply(
            sidebarEntries: [
                DocumentSidebarEntry(
                    fileURL: root.appendingPathComponent("Hub.md"),
                    displayTitle: "Hub",
                    previewText: "",
                    isCurrent: true,
                    isAvailable: true
                ),
            ],
            outlineItems: []
        )
        XCTAssertFalse(sidebar.hasBacklinkSectionForTesting)

        controller.closeLibrary()
    }

    func testMiddleClickActivatesBacklinkRow() throws {
        let backlink = Backlink(
            sourceFileURL: URL(fileURLWithPath: "/vault/Hub.md"),
            sourceTitle: "Hub",
            contextSnippet: "context"
        )
        let row = SidebarBacklinkRowView(backlink: backlink)
        var activations = 0
        row.onActivate = { activations += 1 }

        func otherMouseEvent(buttonNumber: UInt32) -> NSEvent {
            let cgEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .otherMouseUp,
                mouseCursorPosition: .zero,
                mouseButton: CGMouseButton(rawValue: buttonNumber)!
            )!
            return NSEvent(cgEvent: cgEvent)!
        }

        row.otherMouseUp(with: otherMouseEvent(buttonNumber: 2))
        XCTAssertEqual(activations, 1)
        row.otherMouseUp(with: otherMouseEvent(buttonNumber: 3))
        XCTAssertEqual(activations, 1, "history buttons must not activate rows")
    }
}

@MainActor
private final class StubDirectoryMonitor: DirectoryMonitoring {
    func start() {}
    func stop() {}
}
