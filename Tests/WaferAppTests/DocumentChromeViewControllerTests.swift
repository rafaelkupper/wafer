import AppKit
import XCTest
@testable import WaferApp

@MainActor
final class DocumentChromeViewControllerTests: XCTestCase {
    func testSidebarGeometryAndInterruptedTransitionsKeepOneLeadingConstraint() async throws {
        _ = NSApplication.shared
        let content = NSViewController()
        content.view = NSView()
        let chrome = DocumentChromeViewController(contentViewController: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = chrome
        defer { window.contentViewController = nil; window.close() }
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        chrome.reducedMotionOverride = false
        let frame = window.frame
        let width = chrome.view.bounds.width
        assertGeometry(chrome, leading: 0, width: width)
        chrome.toggleSidebar()
        XCTAssertTrue(chrome.isSidebarVisible)
        XCTAssertEqual(chrome.activeContentLeadingConstraintCountForTesting, 1)
        // Interrupt opening, then interrupt closing before either completion.
        chrome.toggleSidebar()
        XCTAssertFalse(chrome.isSidebarVisible)
        XCTAssertEqual(chrome.activeContentLeadingConstraintCountForTesting, 1)
        chrome.toggleSidebar()
        XCTAssertTrue(chrome.isSidebarVisible)
        window.displayIfNeeded()
        CATransaction.flush()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { !chrome.isSidebarTransitioningForTesting }
        }, object: nil)
        await fulfillment(of: [settled], timeout: 3)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, frame)
        assertGeometry(chrome, leading: DocumentSidebarViewController.sidebarWidth, width: width)
        XCTAssertEqual(chrome.sidebarFrameForTesting.minX, 0, accuracy: 0.5)
        XCTAssertEqual(chrome.sidebarFrameForTesting.width, DocumentSidebarViewController.sidebarWidth, accuracy: 0.5)
        XCTAssertEqual(chrome.sidebarWidthForTesting, DocumentSidebarViewController.sidebarWidth, accuracy: 0.5)
        XCTAssertEqual(chrome.sidebarAlphaForTesting, 1, accuracy: 0.01)
        chrome.toggleSidebar()
        XCTAssertEqual(chrome.activeContentLeadingConstraintCountForTesting, 1)
        window.displayIfNeeded()
        CATransaction.flush()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { !chrome.isSidebarTransitioningForTesting }
        }, object: nil)
        await fulfillment(of: [closed], timeout: 3)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, frame)
        assertGeometry(chrome, leading: 0, width: width)
        XCTAssertFalse(chrome.isSidebarAttachedForTesting)
        XCTAssertEqual(chrome.sidebarWidthForTesting, 0)
    }

    private func assertGeometry(_ chrome: DocumentChromeViewController, leading: CGFloat, width: CGFloat,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(chrome.activeContentLeadingConstraintCountForTesting, 1, file: file, line: line)
        XCTAssertEqual(chrome.contentFrameForTesting.minX, leading, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(chrome.contentFrameForTesting.maxX, width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(chrome.contentFrameForTesting.width, width - leading, accuracy: 0.5, file: file, line: line)
    }
}
