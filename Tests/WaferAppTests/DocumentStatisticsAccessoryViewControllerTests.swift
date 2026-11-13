import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class DocumentStatisticsAccessoryViewControllerTests: XCTestCase {
    func testAccessoryStartsHiddenAndShowsWordCountByDefault() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let notificationCenter = NotificationCenter()
        let store = DocumentStatisticPreferenceStore(defaults: defaults, notificationCenter: notificationCenter)
        let controller = DocumentStatisticsAccessoryViewController(
            preferenceStore: store,
            notificationCenter: notificationCenter
        )

        controller.loadViewIfNeeded()
        XCTAssertNil(controller.displayedTextForTesting)

        controller.apply(statistics: DocumentStatistics(words: 870, minutes: 5, lines: 306, characters: 6708))

        XCTAssertEqual(controller.displayedTextForTesting, "870 Words")
        XCTAssertGreaterThan(controller.preferredWidthForTesting, 100)
    }

    func testStatisticsAppearAndDisappearInNarrowTitlebar() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 360),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let controller = DocumentStatisticsAccessoryViewController()
        window.addTitlebarAccessoryViewController(controller)
        window.layoutIfNeeded()
        let hiddenWidth = controller.preferredWidthForTesting
        XCTAssertNil(controller.displayedTextForTesting)
        XCTAssertTrue(controller.view.translatesAutoresizingMaskIntoConstraints)
        XCTAssertGreaterThan(controller.view.frame.width, 0)

        for _ in 0..<3 {
            controller.apply(statistics: DocumentStatistics(words: 870, minutes: 5, lines: 306, characters: 6708))
            window.layoutIfNeeded()
            XCTAssertEqual(controller.displayedTextForTesting, "870 Words")
            XCTAssertGreaterThan(controller.preferredWidthForTesting, hiddenWidth)
            XCTAssertFalse(controller.view.hasAmbiguousLayout)
            controller.apply(statistics: nil)
            window.layoutIfNeeded()
            XCTAssertNil(controller.displayedTextForTesting)
            XCTAssertEqual(controller.preferredWidthForTesting, hiddenWidth)
        }
    }

    func testSelectingDifferentMetricUpdatesDisplayImmediately() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let notificationCenter = NotificationCenter()
        let store = DocumentStatisticPreferenceStore(defaults: defaults, notificationCenter: notificationCenter)
        let controller = DocumentStatisticsAccessoryViewController(
            preferenceStore: store,
            notificationCenter: notificationCenter
        )
        controller.loadViewIfNeeded()
        controller.apply(statistics: DocumentStatistics(words: 870, minutes: 5, lines: 306, characters: 6708))

        let item = NSMenuItem(title: "Lines", action: nil, keyEquivalent: "")
        item.representedObject = DocumentStatisticKind.lines.rawValue
        controller.selectKind(item)

        XCTAssertEqual(store.selectedKind, .lines)
        XCTAssertEqual(controller.displayedTextForTesting, "306 Lines")
    }

    func testChangingMetricBroadcastUpdatesMultipleOpenWindows() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let notificationCenter = NotificationCenter()
        let store = DocumentStatisticPreferenceStore(defaults: defaults, notificationCenter: notificationCenter)
        let first = DocumentStatisticsAccessoryViewController(
            preferenceStore: store,
            notificationCenter: notificationCenter
        )
        let second = DocumentStatisticsAccessoryViewController(
            preferenceStore: store,
            notificationCenter: notificationCenter
        )
        first.loadViewIfNeeded()
        second.loadViewIfNeeded()

        let stats = DocumentStatistics(words: 870, minutes: 5, lines: 306, characters: 6708)
        first.apply(statistics: stats)
        second.apply(statistics: stats)

        store.selectedKind = .characters

        let expected = stats.displayText(for: .characters)
        XCTAssertEqual(first.displayedTextForTesting, expected)
        XCTAssertEqual(second.displayedTextForTesting, expected)
    }

    func testCopyButtonShowsCheckmarkOnlyAfterSuccessfulCopy() {
        let controller = DocumentStatisticsAccessoryViewController()
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.copyButtonSymbolForTesting, "doc.on.doc")

        var copyResult = false
        var activationCount = 0
        controller.onCopyDocument = {
            activationCount += 1
            return copyResult
        }

        controller.triggerCopyDocumentForTesting()
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(controller.copyButtonSymbolForTesting, "doc.on.doc")

        copyResult = true
        controller.triggerCopyDocumentForTesting()
        XCTAssertEqual(activationCount, 2)
        XCTAssertEqual(controller.copyButtonSymbolForTesting, "checkmark")
    }

    func testCopyFileButtonIsIndependentOfCopyTextButton() {
        let controller = DocumentStatisticsAccessoryViewController()
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.copyFileButtonSymbolForTesting, "doc")

        var textCopies = 0
        var fileCopies = 0
        controller.onCopyDocument = {
            textCopies += 1
            return true
        }
        controller.onCopyFile = {
            fileCopies += 1
            return true
        }

        controller.triggerCopyFileForTesting()

        XCTAssertEqual(fileCopies, 1)
        XCTAssertEqual(textCopies, 0)
        XCTAssertEqual(controller.copyFileButtonSymbolForTesting, "checkmark")
        XCTAssertEqual(controller.copyButtonSymbolForTesting, "doc.on.doc")
    }

    func testSidebarToggleCallbackCanBeTriggered() {
        let controller = DocumentStatisticsAccessoryViewController()
        controller.loadViewIfNeeded()

        var activationCount = 0
        controller.onToggleSidebar = {
            activationCount += 1
        }

        controller.triggerSidebarToggleForTesting()

        XCTAssertEqual(activationCount, 1)
    }

    func testStatisticsChromeLayerColorsMatchDarkPalette() throws {
        let controller = DocumentStatisticsAccessoryViewController()
        controller.loadViewIfNeeded()
        controller.apply(statistics: DocumentStatistics(words: 870, minutes: 5, lines: 306, characters: 6708))

        let pillView = try XCTUnwrap(
            firstView(in: controller.view) { view in
                view.layer?.cornerRadius == 7 && view.layer?.borderWidth == 1
            }
        )
        assertLayerColor(
            pillView.layer?.backgroundColor,
            matches: ReaderThemePalette.dark.statisticsPillRestingBackground
        )
        let pillLabel = try XCTUnwrap(firstView(in: pillView) { $0 is NSTextField } as? NSTextField)
        assertAppKitColor(pillLabel.textColor, matches: ReaderThemePalette.dark.statisticsLabel)
        let pillImageView = try XCTUnwrap(firstView(in: pillView) { $0 is NSImageView } as? NSImageView)
        assertAppKitColor(pillImageView.contentTintColor, matches: ReaderThemePalette.dark.statisticsIcon)

        let hoverEvent = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseEntered,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        )
        pillView.mouseEntered(with: hoverEvent)
        assertLayerColor(
            pillView.layer?.backgroundColor,
            matches: ReaderThemePalette.dark.statisticsPillHoverBackground
        )
        assertLayerColor(
            pillView.layer?.borderColor,
            matches: ReaderThemePalette.dark.statisticsPillHoverBorder
        )

        let iconButton = try XCTUnwrap(
            firstView(in: controller.view) { view in
                (view as? TitlebarAccessoryIconButtonView)?.symbolName == "sidebar.left"
            }
        )
        assertLayerColor(
            iconButton.layer?.backgroundColor,
            matches: ReaderThemePalette.dark.statisticsIconButtonRestingBackground
        )
        let iconImageView = try XCTUnwrap(firstView(in: iconButton) { $0 is NSImageView } as? NSImageView)
        assertAppKitColor(iconImageView.contentTintColor, matches: ReaderThemePalette.dark.statisticsIconButton)

        iconButton.mouseEntered(with: hoverEvent)
        assertLayerColor(
            iconButton.layer?.backgroundColor,
            matches: ReaderThemePalette.dark.statisticsIconButtonHoverBackground
        )
        assertLayerColor(
            iconButton.layer?.borderColor,
            matches: ReaderThemePalette.dark.statisticsIconButtonHoverBorder
        )

        let exitEvent = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseExited,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        )
        iconButton.mouseExited(with: exitEvent)
        controller.setSidebarActive(true)
        assertLayerColor(
            iconButton.layer?.backgroundColor,
            matches: ReaderThemePalette.dark.statisticsIconButtonActiveBackground
        )
        assertLayerColor(
            iconButton.layer?.borderColor,
            matches: ReaderThemePalette.dark.statisticsIconButtonHoverBorder
        )
    }

    func testStatisticsChromeAppliesLightPalette() throws {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let controller = DocumentStatisticsAccessoryViewController()
        controller.loadViewIfNeeded()
        controller.apply(statistics: DocumentStatistics(words: 870, minutes: 5, lines: 306, characters: 6708))

        ReaderTheme.setCurrent(.light)
        controller.applyCurrentTheme()

        let pillView = try XCTUnwrap(
            firstView(in: controller.view) { view in
                view.layer?.cornerRadius == 7 && view.layer?.borderWidth == 1
            }
        )
        assertLayerColor(
            pillView.layer?.backgroundColor,
            matches: ReaderThemePalette.light.statisticsPillRestingBackground
        )
        let pillLabel = try XCTUnwrap(firstView(in: pillView) { $0 is NSTextField } as? NSTextField)
        assertAppKitColor(pillLabel.textColor, matches: ReaderThemePalette.light.statisticsLabel)
        let pillImageView = try XCTUnwrap(firstView(in: pillView) { $0 is NSImageView } as? NSImageView)
        assertAppKitColor(pillImageView.contentTintColor, matches: ReaderThemePalette.light.statisticsIcon)

        let iconButton = try XCTUnwrap(
            firstView(in: controller.view) { view in
                (view as? TitlebarAccessoryIconButtonView)?.symbolName == "sidebar.left"
            }
        )
        assertLayerColor(
            iconButton.layer?.backgroundColor,
            matches: ReaderThemePalette.light.statisticsIconButtonRestingBackground
        )
        let iconImageView = try XCTUnwrap(firstView(in: iconButton) { $0 is NSImageView } as? NSImageView)
        assertAppKitColor(iconImageView.contentTintColor, matches: ReaderThemePalette.light.statisticsIconButton)
    }

    private func firstView(in rootView: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        if predicate(rootView) {
            return rootView
        }

        for subview in rootView.subviews {
            if let match = firstView(in: subview, matching: predicate) {
                return match
            }
        }

        return nil
    }

    private func assertLayerColor(
        _ cgColor: CGColor?,
        matches token: ReaderThemeColor,
        accuracy: CGFloat = 0.003,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let color = cgColor.flatMap(NSColor.init(cgColor:))
        assertAppKitColor(color, matches: token, accuracy: accuracy, file: file, line: line)
    }

    private func assertAppKitColor(
        _ color: NSColor?,
        matches token: ReaderThemeColor,
        accuracy: CGFloat = 0.003,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let rgb = color?.usingColorSpace(.deviceRGB) else {
            XCTFail("Missing color", file: file, line: line)
            return
        }
        let expected = components(for: token.hex, alpha: token.alpha)

        XCTAssertEqual(rgb.redComponent, expected.red, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rgb.greenComponent, expected.green, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rgb.blueComponent, expected.blue, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rgb.alphaComponent, expected.alpha, accuracy: accuracy, file: file, line: line)
    }

    private func components(for hex: String, alpha: Double) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let digits = String(hex.dropFirst())
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        return (
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
