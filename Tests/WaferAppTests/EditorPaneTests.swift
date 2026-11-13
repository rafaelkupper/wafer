import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class EditorPaneExpansionTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 2000, height: 1000)

    func testPaneOpensToTheLeftAndDoublesTheContentWidth() {
        let plan = EditorPaneExpansion.plan(
            windowFrame: NSRect(x: 1000, y: 100, width: 600, height: 700),
            contentWidth: 600,
            visibleFrame: screen,
            canResize: true
        )

        XCTAssertEqual(plan.frame, NSRect(x: 400, y: 100, width: 1200, height: 700))
        XCTAssertEqual(plan.growth, 600)
        XCTAssertEqual(plan.rightShift, 0, "the right edge, and so the reader, stays put")
        XCTAssertEqual(plan.editorWidth, 600)
    }

    func testSidebarWidthIsNotDoubled() {
        let plan = EditorPaneExpansion.plan(
            windowFrame: NSRect(x: 1000, y: 100, width: 860, height: 700),
            contentWidth: 600,
            visibleFrame: screen,
            canResize: true
        )

        XCTAssertEqual(plan.frame.width, 1460)
        XCTAssertEqual(plan.editorWidth, 600)
    }

    func testWindowMovesRightOnlyWhenTheLeftRunsOut() {
        let plan = EditorPaneExpansion.plan(
            windowFrame: NSRect(x: 500, y: 100, width: 600, height: 700),
            contentWidth: 600,
            visibleFrame: screen,
            canResize: true
        )

        XCTAssertEqual(plan.frame, NSRect(x: 0, y: 100, width: 1200, height: 700))
        XCTAssertEqual(plan.rightShift, 100)
        XCTAssertEqual(plan.editorWidth, 600)
    }

    func testScreenTooNarrowToDoubleSharesWhatThereIs() {
        let plan = EditorPaneExpansion.plan(
            windowFrame: NSRect(x: 181, y: 0, width: 1150, height: 800),
            contentWidth: 1150,
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 900),
            canResize: true
        )

        XCTAssertEqual(plan.frame, NSRect(x: 0, y: 0, width: 1512, height: 800))
        XCTAssertEqual(plan.growth, 362)
        XCTAssertEqual(plan.editorWidth, 756)
    }

    func testFullScreenSplitsInPlace() {
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let plan = EditorPaneExpansion.plan(windowFrame: frame, contentWidth: 1512, visibleFrame: frame, canResize: false)

        XCTAssertEqual(plan.frame, frame)
        XCTAssertEqual(plan.growth, 0)
        XCTAssertEqual(plan.editorWidth, 756)
    }

    func testEveryFrameOfTheTransitionKeepsTheReaderWidthAndRightEdge() {
        let start = NSRect(x: 1000, y: 100, width: 601, height: 700)
        let plan = EditorPaneExpansion.plan(windowFrame: start, contentWidth: 601, visibleFrame: screen, canResize: true)

        for step in 0...1_000 {
            let progress = DisplayLinkedAnimation.eased(CGFloat(step) / 1_000)
            let frame = EditorPaneExpansion.frame(from: start, to: plan.frame, progress: progress)
            let revealed = (plan.editorWidth * progress).rounded()
            XCTAssertEqual(frame.maxX, start.maxX)
            XCTAssertEqual(frame.width - revealed, 601, "reader width at progress \(progress)")
            XCTAssertEqual(frame.width, frame.width.rounded())
        }
        XCTAssertEqual(DisplayLinkedAnimation.eased(0), 0)
        XCTAssertEqual(DisplayLinkedAnimation.eased(1), 1)
    }
}

@MainActor
final class EditorPaneWindowTests: XCTestCase {
    private func makeWindowController() throws -> (DocumentWindowController, NSRect) {
        let controller = DocumentWindowController(
            contentViewController: NSViewController(),
            appearancePreferenceStore: AppearancePreferenceStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!,
                missingCustomThemeNotifier: { _ in },
                systemIsDark: { true }
            )
        )
        let window = try XCTUnwrap(controller.window)
        let visible = try XCTUnwrap((window.screen ?? NSScreen.main)?.visibleFrame)
        try XCTSkipIf(visible.width < 1_300, "needs room to double a 600-point window")
        // Against the right edge of the screen, with room on the left.
        let frame = NSRect(x: visible.maxX - 620, y: visible.minY + 40, width: 600, height: 500)
        window.setFrame(frame, display: false)
        controller.showWindow(nil)
        window.layoutIfNeeded()
        return (controller, frame)
    }

    private func makePane() -> NSViewController {
        let pane = NSViewController()
        pane.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        return pane
    }

    func testOpeningThePaneWidensTheWindowLeftAndClosingRestoresIt() throws {
        let (controller, frame) = try makeWindowController()
        defer { controller.close() }
        controller.setReducedMotionForTesting(true)
        let window = try XCTUnwrap(controller.window)
        let pane = makePane()
        XCTAssertEqual(controller.hostedContentWidthForTesting, 600)

        controller.setEditorPane(pane, animated: true)

        XCTAssertFalse(controller.isEditorPaneAnimatingForTesting, "reduced motion applies the change at once")
        XCTAssertEqual(window.frame, NSRect(x: frame.minX - 600, y: frame.minY, width: 1_200, height: 500))
        XCTAssertEqual(controller.hostedContentWidthForTesting, 600)
        XCTAssertEqual(controller.editorPaneWidthForTesting, 600)
        XCTAssertEqual(pane.view.frame.width, 600)
        XCTAssertTrue(pane.view.window === window)

        controller.setEditorPane(nil, animated: true)

        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(controller.hostedContentWidthForTesting, 600)
        XCTAssertEqual(controller.editorPaneWidthForTesting, 0)
        XCTAssertNil(pane.view.superview)
        XCTAssertNil(controller.editorPaneControllerForTesting)
    }

    func testAnimatedPaneNeverResizesTheReaderOrMovesItsEdge() throws {
        let (controller, frame) = try makeWindowController()
        defer { controller.close() }
        controller.setReducedMotionForTesting(false)
        let window = try XCTUnwrap(controller.window)
        let pane = makePane()

        for opening in [true, false] {
            controller.setEditorPane(opening ? pane : nil, animated: true)
            XCTAssertTrue(controller.isEditorPaneAnimatingForTesting)
            XCTAssertEqual(pane.view.frame.width, 600, "the editor is laid out at its final width throughout")
            var widths: Set<CGFloat> = []
            var frames = 0
            let deadline = Date(timeIntervalSinceNow: 3)
            while controller.isEditorPaneAnimatingForTesting, Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
                widths.insert(controller.hostedContentWidthForTesting)
                XCTAssertEqual(window.frame.maxX, frame.maxX)
                frames += 1
            }
            XCTAssertFalse(controller.isEditorPaneAnimatingForTesting)
            XCTAssertEqual(widths, [600], "\(opening ? "opening" : "closing") sampled \(frames) times")
            XCTAssertEqual(window.frame.width, opening ? 1_200 : 600)
        }
        XCTAssertEqual(window.frame, frame)
    }

    func testTogglingDuringTheAnimationFinishesItFirst() throws {
        let (controller, frame) = try makeWindowController()
        defer { controller.close() }
        controller.setReducedMotionForTesting(false)
        let window = try XCTUnwrap(controller.window)
        let pane = makePane()

        controller.setEditorPane(pane, animated: true)
        XCTAssertTrue(controller.isEditorPaneAnimatingForTesting)
        controller.setEditorPane(nil, animated: false)

        XCTAssertFalse(controller.isEditorPaneAnimatingForTesting)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(controller.hostedContentWidthForTesting, 600)
        XCTAssertNil(pane.view.superview)
    }

    func testDividerCanBeDraggedWithinPaneMinimums() {
        let split = DocumentContentSplitView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 400))
        let main = NSView()
        let editor = NSView()
        split.embedMainView(main)
        XCTAssertEqual(main.frame.width, 1_000)

        split.installEditor(editor)
        XCTAssertEqual(split.editorWidth, 500)
        XCTAssertEqual(split.mainWidth, 500)
        XCTAssertEqual(main.frame.width, 500)

        XCTAssertEqual(DocumentContentSplitView.editorWidth(forFraction: 0.05, totalWidth: 1_000), 240)
        XCTAssertEqual(DocumentContentSplitView.editorWidth(forFraction: 0.95, totalWidth: 1_000), 760)
        XCTAssertEqual(DocumentContentSplitView.editorWidth(forFraction: 0.5, totalWidth: 300), 150)

        // The share is kept when the window is resized.
        split.setFrameSize(NSSize(width: 1_400, height: 400))
        split.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.editorWidth, 700)

        split.removeEditor()
        XCTAssertEqual(split.mainWidth, 1_400)
    }
}
