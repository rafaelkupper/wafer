import AppKit
import XCTest
@testable import WaferApp
@testable import WaferCore

@MainActor
final class WebKitReaderViewControllerTests: XCTestCase {
    func testShowFindInterfaceRevealsFindBar() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }

        controller.showFindInterface(nil)

        XCTAssertTrue(controller.isFindBarVisibleForTesting)
    }

    func testFindBarChromeColorsMatchDarkPalette() throws {
        let controller = WebKitReaderViewController()
        defer { controller.invalidateForTesting() }
        controller.loadViewIfNeeded()

        let findBar = try XCTUnwrap(
            firstView(in: controller.view) { view in
                view.layer?.cornerRadius == 10 && view.layer?.borderWidth == 1
            }
        )

        assertLayerColor(findBar.layer?.backgroundColor, matches: ReaderThemePalette.dark.findBarBackground)
        assertLayerColor(findBar.layer?.borderColor, matches: ReaderThemePalette.dark.findBarBorder)
    }

    func testApplyCurrentThemeUpdatesFindBarChromeToLightPalette() throws {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let controller = WebKitReaderViewController()
        defer { controller.invalidateForTesting() }
        controller.loadViewIfNeeded()

        ReaderTheme.setCurrent(.light)
        controller.applyCurrentTheme()

        let findBar = try XCTUnwrap(
            firstView(in: controller.view) { view in
                view.layer?.cornerRadius == 10 && view.layer?.borderWidth == 1
            }
        )
        assertLayerColor(
            controller.view.layer?.backgroundColor,
            matches: ReaderThemeColor(hex: ReaderThemePalette.light.backgroundHex)
        )
        assertLayerColor(findBar.layer?.backgroundColor, matches: ReaderThemePalette.light.findBarBackground)
        assertLayerColor(findBar.layer?.borderColor, matches: ReaderThemePalette.light.findBarBorder)
    }

    func testFindCommandsRecordDirectionAndQuery() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }

        controller.setSuppressFindExecutionForTesting(true)
        controller.setFindQueryForTesting("Heading")
        controller.findNextMatch(nil)
        controller.findPreviousMatch(nil)

        XCTAssertEqual(controller.lastFindQueryForTesting, "Heading")
        XCTAssertEqual(controller.lastFindDirectionForTesting, "previous")
    }

    func testValidateUserInterfaceItemReflectsQueryAvailability() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }

        XCTAssertTrue(controller.validateUserInterfaceItem(makeMenuItem(action: #selector(WebKitReaderViewController.showFindInterface(_:)))))
        XCTAssertFalse(controller.validateUserInterfaceItem(makeMenuItem(action: #selector(WebKitReaderViewController.findNextMatch(_:)))))

        controller.setFindQueryForTesting("Heading")

        XCTAssertTrue(controller.validateUserInterfaceItem(makeMenuItem(action: #selector(WebKitReaderViewController.findNextMatch(_:)))))
    }

    func testIncrementalFindReportsMissingMatches() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }

        controller.setSuppressFindExecutionForTesting(true)
        controller.setSuppressedFindMatchResultForTesting(false)
        controller.setFindQueryForTesting("absent-text")
        controller.triggerFindQueryChangeForTesting()

        XCTAssertEqual(controller.lastFindMatchFoundForTesting, false)
        XCTAssertEqual(controller.findStatusTextForTesting, "No matches")
    }

    func testIncrementalFindFindsExistingText() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }

        controller.setSuppressFindExecutionForTesting(true)
        controller.setSuppressedFindMatchResultForTesting(true)
        controller.setFindQueryForTesting("Hello")
        controller.triggerFindQueryChangeForTesting()

        XCTAssertEqual(controller.lastFindMatchFoundForTesting, true)
        XCTAssertEqual(controller.findStatusTextForTesting, "")
    }

    func testDisplayLoadingShowsPlaceholderHTML() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }

        waitForNavigation(in: controller) {
            controller.displayLoading(for: "Preview.md")
        }

        let bodyText = evaluateString(
            "document.getElementById('write').innerText",
            in: controller
        ) as? String

        XCTAssertTrue(bodyText?.contains("Opening Preview.md...") == true)
    }

    func testApplyLoadsRenderedHTMLContent() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }

        let html = htmlDocument(body: "<h1>Rendered</h1><p>Body</p>")
        waitForNavigation(in: controller) {
            controller.apply(renderOutput: WebKitRenderOutput(html: html, baseURL: nil), initialScrollFraction: nil)
        }

        let heading = evaluateString(
            "document.querySelector('h1').textContent",
            in: controller
        ) as? String

        XCTAssertEqual(heading, "Rendered")
    }

    func testInjectedScrollReporterWorksUnderPageCSP() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }
        let html = cspScrollableHTML()
        XCTAssertTrue(html.contains("script-src 'none'"))

        waitForNavigation(in: controller) {
            controller.loadHTMLForTesting(html)
        }

        let scriptInstalled = evaluateReaderContentString(
            "Boolean(window.waferReaderScrollInstalled);",
            in: controller
        ) as? Bool
        XCTAssertEqual(scriptInstalled, true)

        let scrollExpectation = expectation(description: "scroll reporter still runs")
        controller.onScrollPositionChange = { fraction in
            if fraction > 0.2 {
                scrollExpectation.fulfill()
            }
        }

        let scrollY = evaluateReaderContentString(
            """
            (function() {
              window.scrollTo(0, document.documentElement.scrollHeight);
              window.dispatchEvent(new Event('scroll'));
              return window.scrollY;
            })();
            """,
            in: controller
        ) as? NSNumber
        XCTAssertGreaterThan(scrollY?.doubleValue ?? 0, 0)

        wait(for: [scrollExpectation], timeout: 5)
        XCTAssertGreaterThan(controller.currentScrollFraction, 0.2)
    }

    func testContentReadyMessageDelaysNavigationCompletionForAsyncRenderers() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }

        var completionCount = 0
        controller.onNavigationFinished = {
            completionCount += 1
        }

        controller.apply(
            renderOutput: WebKitRenderOutput(
                html: htmlDocument(body: "<p>Delayed renderer</p>"),
                baseURL: nil,
                waitsForContentReady: true
            ),
            initialScrollFraction: nil
        )

        XCTAssertTrue(controller.isAwaitingContentReadyForTesting)
        controller.markNavigationFinishedForTesting()
        XCTAssertEqual(completionCount, 0)

        controller.handleContentReadyForTesting()
        XCTAssertFalse(controller.isAwaitingContentReadyForTesting)
        XCTAssertEqual(completionCount, 1)

        controller.handleContentReadyForTesting()
        XCTAssertEqual(completionCount, 1)
    }

    func testExportReadinessRequiresRenderableCompletedContent() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }

        XCTAssertFalse(controller.isContentReadyForExport)
        XCTAssertNil(controller.webViewForExport)

        controller.displayLoading(for: "Loading.md")
        controller.markNavigationFinishedForTesting()
        XCTAssertFalse(controller.isContentReadyForExport)
        XCTAssertNil(controller.webViewForExport)

        controller.loadHTMLForTesting(htmlDocument(body: "<p>Ready</p>"))
        controller.markNavigationFinishedForTesting()
        XCTAssertTrue(controller.isContentReadyForExport)
        XCTAssertNotNil(controller.webViewForExport)
    }

    func testExportReadinessWaitsForAsyncContentReadySignal() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }

        controller.apply(
            renderOutput: WebKitRenderOutput(
                html: htmlDocument(body: "<p>Mermaid pending</p>"),
                baseURL: nil,
                waitsForContentReady: true
            ),
            initialScrollFraction: nil
        )

        controller.markNavigationFinishedForTesting()
        XCTAssertFalse(controller.isContentReadyForExport)
        XCTAssertNil(controller.webViewForExport)

        controller.handleContentReadyForTesting()
        XCTAssertTrue(controller.isContentReadyForExport)
        XCTAssertNotNil(controller.webViewForExport)
    }

    func testExportDOMSnapshotRequiresReadyContentAndReturnsOuterHTML() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }

        let notReady = expectation(description: "not ready snapshot fails")
        controller.exportDOMSnapshot { result in
            guard case .failure(ExportHTMLPreparationError.contentNotReady) = result else {
                XCTFail("Expected contentNotReady, got \(result)")
                return
            }
            notReady.fulfill()
        }
        wait(for: [notReady], timeout: 2)

        waitForNavigation(in: controller) {
            controller.loadHTMLForTesting(htmlDocument(body: "<main><p>Snapshot</p></main>"))
        }

        let ready = expectation(description: "ready snapshot succeeds")
        controller.exportDOMSnapshot { result in
            guard case let .success(html) = result else {
                XCTFail("Expected snapshot success, got \(result)")
                return
            }

            XCTAssertTrue(html.contains("<main><p>Snapshot</p></main>"))
            XCTAssertTrue(html.lowercased().hasPrefix("<html"))
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
    }

    func testMermaidDiagramRendersSVGInWebView() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }
        let output = renderMarkdown(
            """
            ```mermaid
            flowchart LR
              A[Start] --> B[Done]
            ```
            """
        )

        XCTAssertTrue(output.waitsForContentReady)
        waitForNavigation(in: controller, settleDelay: 0.2) {
            controller.apply(renderOutput: output, initialScrollFraction: nil)
        }

        let svgCount = evaluateString(
            "document.querySelectorAll('.md-mermaid-output svg').length",
            in: controller
        ) as? NSNumber
        let sourceDisplay = evaluateString(
            "getComputedStyle(document.querySelector('.md-mermaid-source')).display",
            in: controller
        ) as? String

        XCTAssertEqual(svgCount?.intValue, 1)
        XCTAssertEqual(sourceDisplay, "none")
    }

    func testMathFenceRendersKaTeXInWebView() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }
        let output = renderMarkdown(
            """
            ```math
            c = \\pm\\sqrt{a^2 + b^2}
            ```
            """
        )

        XCTAssertTrue(output.waitsForContentReady)
        waitForNavigation(in: controller, settleDelay: 0.2) {
            controller.apply(renderOutput: output, initialScrollFraction: nil)
        }

        let katexCount = evaluateString(
            "document.querySelectorAll('.md-math-output .katex').length",
            in: controller
        ) as? NSNumber
        let sourceDisplay = evaluateString(
            "getComputedStyle(document.querySelector('.md-math-source')).display",
            in: controller
        ) as? String
        let outputText = evaluateString(
            "document.querySelector('.md-math-output').textContent",
            in: controller
        ) as? String

        XCTAssertEqual(katexCount?.intValue, 1)
        XCTAssertEqual(sourceDisplay, "none")
        XCTAssertTrue(outputText?.contains("c") == true)

        let snapshotExpectation = expectation(description: "math export snapshot contains rendered KaTeX")
        controller.exportDOMSnapshot { result in
            guard case let .success(html) = result else {
                XCTFail("Expected snapshot success, got \(result)")
                snapshotExpectation.fulfill()
                return
            }

            XCTAssertTrue(html.contains("class=\"katex\""))
            do {
                let sanitized = try ExportSanitizer.sanitize(
                    domHTML: html,
                    policy: ExportSanitizer.ExportPolicy(inlineImage: { _ in nil })
                )
                XCTAssertTrue(sanitized.contains("class=\"katex\""))
                XCTAssertFalse(sanitized.lowercased().contains("<script"))
            } catch {
                XCTFail("Expected sanitized math export, got \(error)")
            }
            snapshotExpectation.fulfill()
        }
        wait(for: [snapshotExpectation], timeout: 5)
    }

    func testInvalidMathFenceShowsKaTeXErrorTextInWebView() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }
        let output = renderMarkdown(
            """
            ```math
            \\definitelynotacommand{
            ```
            """
        )

        XCTAssertTrue(output.waitsForContentReady)
        waitForNavigation(in: controller, settleDelay: 0.2) {
            controller.apply(renderOutput: output, initialScrollFraction: nil)
        }

        let errorCount = evaluateString(
            "document.querySelectorAll('.md-math-output .katex-error').length",
            in: controller
        ) as? NSNumber
        let errorText = evaluateString(
            "document.querySelector('.md-math-output').textContent",
            in: controller
        ) as? String
        let sourceDisplay = evaluateString(
            "getComputedStyle(document.querySelector('.md-math-source')).display",
            in: controller
        ) as? String

        XCTAssertEqual(errorCount?.intValue, 1)
        XCTAssertTrue(errorText?.contains("\\definitelynotacommand") == true)
        XCTAssertEqual(sourceDisplay, "none")
    }

    func testMermaidInspectorOpensOnlyFromExplicitControl() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }
        let output = renderMarkdown(
            """
            ```mermaid
            flowchart LR
              A[Start] --> B[Done]
            ```
            """
        )

        waitForNavigation(in: controller, settleDelay: 0.2) {
            controller.apply(renderOutput: output, initialScrollFraction: nil)
        }

        let inspectButtonHidden = evaluateString(
            "document.querySelector('.md-mermaid-open').hidden",
            in: controller
        ) as? Bool
        let diagramClickOpenedInspector = evaluateString(
            """
            (function() {
              document.querySelector('.md-mermaid-output svg').dispatchEvent(new MouseEvent('click', { bubbles: true }));
              return Boolean(document.querySelector('.md-diagram-inspector.is-open'));
            })();
            """,
            in: controller
        ) as? Bool
        let explicitOpenResult = evaluateString(
            """
            (function() {
              document.querySelector('.md-mermaid-open').click();
              return {
                isOpen: Boolean(document.querySelector('.md-diagram-inspector.is-open')),
                clonedSVGCount: document.querySelectorAll('.md-diagram-inspector-canvas svg').length,
                clonedSVGID: document.querySelector('.md-diagram-inspector-canvas svg').id,
                copyButtonCount: document.querySelectorAll('.md-diagram-inspector-toolbar [data-action="copy"]').length
              };
            })();
            """,
            in: controller
        ) as? [String: Any]
        let closeReturnedFocus = evaluateString(
            """
            (function() {
              document.querySelector('.md-diagram-inspector-toolbar [data-action="close"]').click();
              return document.activeElement.classList.contains('md-mermaid-open');
            })();
            """,
            in: controller
        ) as? Bool

        XCTAssertEqual(inspectButtonHidden, false)
        XCTAssertEqual(diagramClickOpenedInspector, false)
        XCTAssertEqual(explicitOpenResult?["isOpen"] as? Bool, true)
        XCTAssertEqual((explicitOpenResult?["clonedSVGCount"] as? NSNumber)?.intValue, 1)
        XCTAssertTrue((explicitOpenResult?["clonedSVGID"] as? String)?.hasPrefix("inspect-wafer-mermaid-1-") == true)
        XCTAssertEqual((explicitOpenResult?["copyButtonCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(closeReturnedFocus, true)
    }

    func testMermaidInspectorRestoresScrollPositionWhenClosed() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }
        let output = renderMarkdown(
            """
            \(longScrollableMarkdown(prefix: "Before"))

            ```mermaid
            flowchart LR
              A[Start] --> B[Done]
            ```

            \(longScrollableMarkdown(prefix: "After"))
            """
        )

        waitForNavigation(in: controller, settleDelay: 0.2) {
            controller.apply(renderOutput: output, initialScrollFraction: nil)
        }

        let scrollResult = evaluateString(
            """
            (function() {
              window.scrollTo(0, 420);
              var before = window.scrollY;
              document.querySelector('.md-mermaid-open').click();
              document.querySelector('.md-diagram-inspector-toolbar [data-action="close"]').click();
              return { before: before, after: window.scrollY };
            })();
            """,
            in: controller
        ) as? [String: Any]

        let before = (scrollResult?["before"] as? NSNumber)?.doubleValue ?? -1
        let after = (scrollResult?["after"] as? NSNumber)?.doubleValue ?? -1
        XCTAssertEqual(before, 420, accuracy: 1)
        XCTAssertEqual(
            after,
            before,
            accuracy: 1
        )
    }

    func testMermaidInspectorWheelInputPansZoomsAndDoesNotScrollDocument() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }
        let output = renderMarkdown(
            """
            \(longScrollableMarkdown(prefix: "Before"))

            ```mermaid
            flowchart LR
              A[Start] --> B[Done]
            ```

            \(longScrollableMarkdown(prefix: "After"))
            """
        )

        waitForNavigation(in: controller, settleDelay: 0.2) {
            controller.apply(renderOutput: output, initialScrollFraction: nil)
        }

        let wheelResult = evaluateString(
            """
            (function() {
              window.scrollTo(0, 420);
              var before = window.scrollY;
              document.querySelector('.md-mermaid-open').click();

              var viewport = document.querySelector('.md-diagram-inspector-viewport');
              var canvas = document.querySelector('.md-diagram-inspector-canvas');
              var panEvent = new WheelEvent('wheel', {
                deltaX: 12,
                deltaY: 18,
                bubbles: true,
                cancelable: true
              });
              var panCanceled = !viewport.dispatchEvent(panEvent);
              var afterPan = window.scrollY;
              var panTransform = canvas.style.transform;

              var scaleBeforeZoom = window.waferDiagramInspector.scale;
              var zoomEvent = new WheelEvent('wheel', {
                deltaY: -120,
                ctrlKey: true,
                clientX: 200,
                clientY: 200,
                bubbles: true,
                cancelable: true
              });
              var zoomCanceled = !viewport.dispatchEvent(zoomEvent);
              var scaleAfterZoom = window.waferDiagramInspector.scale;

              document.querySelector('.md-diagram-inspector-toolbar [data-action="close"]').click();
              return {
                before: before,
                afterPan: afterPan,
                panCanceled: panCanceled,
                panTransform: panTransform,
                zoomCanceled: zoomCanceled,
                scaleBeforeZoom: scaleBeforeZoom,
                scaleAfterZoom: scaleAfterZoom
              };
            })();
            """,
            in: controller
        ) as? [String: Any]

        let before = (wheelResult?["before"] as? NSNumber)?.doubleValue ?? -1
        let afterPan = (wheelResult?["afterPan"] as? NSNumber)?.doubleValue ?? -1
        let scaleBeforeZoom = (wheelResult?["scaleBeforeZoom"] as? NSNumber)?.doubleValue ?? -1
        let scaleAfterZoom = (wheelResult?["scaleAfterZoom"] as? NSNumber)?.doubleValue ?? -1

        XCTAssertEqual(before, 420, accuracy: 1)
        XCTAssertEqual(afterPan, before, accuracy: 1)
        XCTAssertEqual(wheelResult?["panCanceled"] as? Bool, true)
        XCTAssertTrue((wheelResult?["panTransform"] as? String)?.contains("translate(-12px, -18px)") == true)
        XCTAssertEqual(wheelResult?["zoomCanceled"] as? Bool, true)
        XCTAssertGreaterThan(scaleAfterZoom, scaleBeforeZoom)
    }

    func testInvalidMermaidDiagramShowsErrorAndSourceInWebView() {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }
        let output = renderMarkdown(
            """
            ```mermaid
            flowchart LR
              A -->
            ```
            """
        )

        waitForNavigation(in: controller, settleDelay: 0.2) {
            controller.apply(renderOutput: output, initialScrollFraction: nil)
        }

        let hasError = evaluateString(
            "document.querySelector('.md-mermaid-diagram').classList.contains('has-error')",
            in: controller
        ) as? Bool
        let errorText = evaluateString(
            "document.querySelector('.md-mermaid-error').textContent",
            in: controller
        ) as? String
        let sourceText = evaluateString(
            "document.querySelector('.md-mermaid-source code').textContent",
            in: controller
        ) as? String
        let inspectButtonHidden = evaluateString(
            "document.querySelector('.md-mermaid-open').hidden",
            in: controller
        ) as? Bool

        XCTAssertEqual(hasError, true)
        XCTAssertTrue(errorText?.contains("Unable to render Mermaid diagram") == true)
        XCTAssertTrue(sourceText?.contains("flowchart LR") == true)
        XCTAssertEqual(inspectButtonHidden, true)
    }

    func testApplySeedsCurrentScrollFractionFromInitialValue() {
        let controller = WebKitReaderViewController()
        defer { controller.invalidateForTesting() }

        controller.apply(
            renderOutput: WebKitRenderOutput(html: htmlDocument(body: longScrollableBody()), baseURL: nil),
            initialScrollFraction: 0.5
        )

        XCTAssertEqual(controller.currentScrollFraction, 0.5, accuracy: 0.0001)
    }

    func testScrollScriptUsesMutablePendingFlag() {
        XCTAssertTrue(WebKitReaderViewController.scrollScriptSourceForTesting.contains("var pending = false;"))
        XCTAssertFalse(WebKitReaderViewController.scrollScriptSourceForTesting.contains("let pending = false;"))
        XCTAssertTrue(WebKitReaderViewController.scrollScriptSourceForTesting.contains("waferActiveHeading"))
        XCTAssertTrue(WebKitReaderViewController.scrollScriptSourceForTesting.contains("document.querySelectorAll('#write h1[id], #write h2[id], #write h3[id], #write h4[id], #write h5[id], #write h6[id]')"))
        XCTAssertFalse(WebKitReaderViewController.scrollScriptSourceForTesting.contains(".md-anchor-alias"))
        XCTAssertTrue(WebKitReaderViewController.scrollScriptSourceForTesting.contains("window.scrollX !== 0"))
        XCTAssertTrue(WebKitReaderViewController.scrollScriptSourceForTesting.contains("event.deltaX"))
        XCTAssertTrue(WebKitReaderViewController.scrollScriptSourceForTesting.contains("function isHorizontallyScrollable"))
        XCTAssertTrue(WebKitReaderViewController.scrollScriptSourceForTesting.contains("event.target instanceof Element ? event.target : null"))
        XCTAssertTrue(WebKitReaderViewController.scrollScriptSourceForTesting.contains("while (node && node !== document.body)"))
        XCTAssertTrue(WebKitReaderViewController.scrollScriptSourceForTesting.contains("return overflowX === 'auto' || overflowX === 'scroll';"))
        XCTAssertTrue(WebKitReaderViewController.scrollScriptSourceForTesting.contains("event.preventDefault();"))
        XCTAssertTrue(WebKitReaderViewController.scrollScriptSourceForTesting.contains("passive: false"))
    }

    func testReportedScrollFractionUpdatesStateAndNotifiesObservers() {
        let controller = WebKitReaderViewController()
        defer { controller.invalidateForTesting() }

        let scrollExpectation = expectation(description: "scroll callback")
        controller.onScrollPositionChange = { fraction in
            if fraction == 0.85 {
                scrollExpectation.fulfill()
            }
        }

        controller.handleReportedScrollFraction(0.85)

        wait(for: [scrollExpectation], timeout: 5)
        XCTAssertEqual(controller.currentScrollFraction, 0.85, accuracy: 0.0001)
    }

    func testReportedActiveHeadingUpdatesStateAndNotifiesObservers() {
        let controller = WebKitReaderViewController()
        defer { controller.invalidateForTesting() }

        let headingExpectation = expectation(description: "heading callback")
        controller.onActiveHeadingChange = { headingID in
            if headingID == "section-two" {
                headingExpectation.fulfill()
            }
        }

        controller.handleReportedActiveHeading("section-two")

        wait(for: [headingExpectation], timeout: 5)
        XCTAssertEqual(controller.currentActiveHeadingID, "section-two")
    }

    func testScrollToHeadingBuildsAnchorScrollScript() {
        let script = WebKitReaderViewController.scrollToHeadingScript(for: #"deep"section"#)

        XCTAssertTrue(script.contains(#"document.getElementById("deep\"section")"#))
        XCTAssertTrue(script.contains("window.scrollTo"))
        XCTAssertTrue(script.contains("const offset = 28;"))
        XCTAssertFalse(script.contains("scrollIntoView"))
    }

    func testHandleActivatedLinkForwardsExternalMarkdownAndOtherFileURLs() {
        let controller = WebKitReaderViewController()
        defer { controller.invalidateForTesting() }

        let expectedURLs = [
            URL(string: "https://example.com")!,
            URL(fileURLWithPath: "/tmp/docs/Guide.md"),
            URL(fileURLWithPath: "/tmp/docs/notes.txt"),
        ]
        var forwardedURLs: [URL] = []
        controller.onOpenLink = { forwardedURLs.append($0) }

        let policies = expectedURLs.map { controller.handleActivatedLink($0) }

        XCTAssertEqual(policies, Array(repeating: .cancel, count: expectedURLs.count))
        XCTAssertEqual(forwardedURLs.count, expectedURLs.count)
        XCTAssertEqual(forwardedURLs[0].scheme, expectedURLs[0].scheme)
        XCTAssertEqual(forwardedURLs[0].host, expectedURLs[0].host)
        XCTAssertEqual(normalizedPath(forwardedURLs[0]), normalizedPath(expectedURLs[0]))
        XCTAssertEqual(forwardedURLs[1].standardizedFileURL, expectedURLs[1].standardizedFileURL)
        XCTAssertEqual(forwardedURLs[2].standardizedFileURL, expectedURLs[2].standardizedFileURL)
    }

    func testCommandClickRoutesToOpenLinkInNewTab() {
        let controller = WebKitReaderViewController()
        defer { controller.invalidateForTesting() }

        let url = URL(fileURLWithPath: "/tmp/docs/Guide.md")
        var plainOpens: [URL] = []
        var newTabOpens: [URL] = []
        controller.onOpenLink = { plainOpens.append($0) }
        controller.onOpenLinkInNewTab = { newTabOpens.append($0) }

        XCTAssertEqual(controller.handleActivatedLink(url, modifierFlags: [.command]), .cancel)
        XCTAssertTrue(plainOpens.isEmpty)
        XCTAssertEqual(newTabOpens.map(\.standardizedFileURL), [url.standardizedFileURL])

        XCTAssertEqual(controller.handleActivatedLink(url), .cancel)
        XCTAssertEqual(plainOpens.map(\.standardizedFileURL), [url.standardizedFileURL])
        XCTAssertEqual(newTabOpens.count, 1)
    }

    func testOpenLinkInNewTabFallsBackToPlainOpenWithoutHandler() {
        let controller = WebKitReaderViewController()
        defer { controller.invalidateForTesting() }

        var plainOpens: [URL] = []
        controller.onOpenLink = { plainOpens.append($0) }

        controller.handleOpenLinkInNewTab(URL(fileURLWithPath: "/tmp/docs/Guide.md"))
        XCTAssertEqual(plainOpens.count, 1)
    }

    func testReaderScriptReportsMiddleClickedLinksForNewTabOpening() {
        let script = WebKitReaderViewController.scrollScriptSourceForTesting

        XCTAssertTrue(script.contains("'auxclick'"))
        XCTAssertTrue(script.contains("event.button !== 1"))
        XCTAssertTrue(script.contains("closest('a[href]')"))
        XCTAssertTrue(script.contains("messageHandlers.waferOpenLinkInNewTab.postMessage"))
    }

    func testReaderScriptInstallsCopyButtonsOnFencedCodeBlocks() {
        let script = WebKitReaderViewController.scrollScriptSourceForTesting

        XCTAssertTrue(script.contains("installCopyButtons"))
        XCTAssertTrue(script.contains("'#write pre.md-fences'"))
        XCTAssertTrue(script.contains("md-copy-button"))
        XCTAssertTrue(script.contains("messageHandlers.waferCopyCode.postMessage"))
    }

    func testHandleCopyCodeWritesToPasteboard() {
        let controller = WebKitReaderViewController()
        defer { controller.invalidateForTesting() }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        controller.pasteboardForCopyCodeForTesting = pasteboard

        controller.handleCopyCode("let answer = 42\n")
        XCTAssertEqual(pasteboard.string(forType: .string), "let answer = 42\n")

        // A second copy replaces the previous contents.
        controller.handleCopyCode("second")
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
    }

    func testThemeUpdatePreservesDOMScrollAndCodeButtonsAreExcludedFromExport() throws {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }
        let document = MarkdownParser().parse(source: "# Theme\n\n```swift\nlet value = 42\n```\n\n" + String(repeating: "Paragraph.\n\n", count: 100), baseURL: nil)
        waitForNavigation(in: controller) {
            controller.apply(renderOutput: WebKitHTMLRenderer().render(document: document), initialScrollFraction: 0.4)
        }
        let before = try XCTUnwrap(evaluateDouble("window.scrollY", in: controller))
        _ = evaluateString("window.originalHeading = document.querySelector('h1'); 'set'", in: controller)
        waitForNavigation(in: controller) { controller.updateTheme(.light) }
        XCTAssertEqual(evaluateString("window.originalHeading === document.querySelector('h1')", in: controller) as? Bool, true)
        XCTAssertEqual(evaluateString("getComputedStyle(document.documentElement).getPropertyValue('--bg-color').trim()", in: controller) as? String, "#FFFFFF")
        XCTAssertEqual(try XCTUnwrap(evaluateDouble("window.scrollY", in: controller)), before, accuracy: 1)
        XCTAssertEqual(evaluateDouble("document.querySelectorAll('.md-copy-button[data-wafer-chrome]').length", in: controller), 1)
        let exported = expectation(description: "static export")
        controller.exportDOMSnapshot { result in
            do {
                let html = try result.get()
                let output = try DocumentExportController.prepareHTMLExport(domHTML: html, allowedRootDirectories: [], remoteAssets: [:], outputURL: URL(fileURLWithPath: "/tmp/output.html"))
                let sanitized = String(decoding: output.data, as: UTF8.self)
                XCTAssertFalse(sanitized.contains("class=\"md-copy-button\""))
                XCTAssertTrue(sanitized.contains("let"))
            } catch { XCTFail(String(describing: error)) }
            exported.fulfill()
        }
        wait(for: [exported], timeout: 5)
    }

    func testMermaidThemeUpdateReplacesOnlyDiagramAndRetainsSource() throws {
        let controller = WebKitReaderViewController()
        let window = hostInWindow(controller)
        defer { close(window, controller: controller) }
        let document = MarkdownParser().parse(source: "# Diagram\n\n```mermaid\ngraph TD\n A[Start] --> B[Finish]\n```", baseURL: nil)
        waitForNavigation(in: controller) {
            controller.apply(renderOutput: WebKitHTMLRenderer().render(document: document), initialScrollFraction: nil)
        }
        _ = evaluateString("window.oldHeading = document.querySelector('h1'); window.oldSVG = document.querySelector('.md-mermaid-output svg'); 'saved'", in: controller)
        waitForNavigation(in: controller) { controller.updateTheme(.light) }
        XCTAssertEqual(evaluateString("window.oldHeading === document.querySelector('h1')", in: controller) as? Bool, true)
        XCTAssertEqual(evaluateString("window.oldSVG !== document.querySelector('.md-mermaid-output svg')", in: controller) as? Bool, true)
        XCTAssertEqual(evaluateDouble("document.querySelectorAll('.md-mermaid-output svg').length", in: controller), 1)
        XCTAssertEqual(evaluateDouble("document.querySelectorAll('.md-mermaid-diagram.has-error').length", in: controller), 0)
        XCTAssertTrue((evaluateString("document.querySelector('.md-mermaid-source code').textContent", in: controller) as? String)?.contains("A[Start]") == true)
    }

    private func waitForNavigation(
        in controller: WebKitReaderViewController,
        settleDelay: TimeInterval = 0.05,
        action: () -> Void
    ) {
        let expectation = expectation(description: "navigation finished")
        controller.onNavigationFinished = {
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                expectation.fulfill()
            }
        }
        action()
        wait(for: [expectation], timeout: 5)
        controller.onNavigationFinished = nil
    }

    private func close(_ window: NSWindow, controller: WebKitReaderViewController) {
        controller.invalidateForTesting()
        window.contentViewController = nil
        window.orderOut(nil)
        window.close()
    }

    private func evaluateString(_ script: String, in controller: WebKitReaderViewController) -> Any? {
        let state = JavaScriptEvaluationState()
        let expectation = expectation(description: "evaluate js")
        controller.evaluateJavaScriptForTesting(script) { value, error in
            state.result = value
            state.receivedError = error
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertNil(state.receivedError)
        return state.result
    }

    private func evaluateReaderContentString(_ script: String, in controller: WebKitReaderViewController) -> Any? {
        let state = JavaScriptEvaluationState()
        let expectation = expectation(description: "evaluate reader js")
        controller.evaluateReaderContentJavaScriptForTesting(script) { value, error in
            state.result = value
            state.receivedError = error
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertNil(state.receivedError)
        return state.result
    }

    private func evaluateDouble(_ script: String, in controller: WebKitReaderViewController) -> Double? {
        let value = evaluateString(script, in: controller)
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return value as? Double
    }

    private func htmlDocument(body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            html, body { margin: 0; min-height: 100%; background: #383E44; color: #BCC3CA; }
            body { font: 16px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; }
            #write { max-width: 900px; margin: 0 auto; padding: 0 24px 24px; }
            p { margin: 0 0 16px; }
            img { display: block; max-width: 100%; }
          </style>
        </head>
        <body>
          <div id="write">\(body)</div>
        </body>
        </html>
        """
    }

    private func cspScrollableHTML() -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'none';">
          <style>
            html, body { margin: 0; min-height: 4200px; background: #383E44; color: #BCC3CA; }
            #write { min-height: 4200px; }
          </style>
        </head>
        <body>
          <div id="write"><h1 id="top">Top</h1><p>Scrollable body</p></div>
        </body>
        </html>
        """
    }

    private func renderMarkdown(_ source: String) -> WebKitRenderOutput {
        let document = MarkdownParser().parse(source: source, baseURL: nil)
        return WebKitHTMLRenderer().render(document: document)
    }

    private func longScrollableBody() -> String {
        (0..<200).map { "<p>Paragraph \($0) with enough content to produce a scrollable page in WebKit.</p>" }.joined()
    }

    private func longScrollableMarkdown(prefix: String) -> String {
        (0..<60).map { "\(prefix) paragraph \($0) with enough content to produce a scrollable page in WebKit." }.joined(separator: "\n\n")
    }

    private func normalizedPath(_ url: URL?) -> String {
        let path = url?.path ?? ""
        return path.isEmpty ? "/" : path
    }

    private func makeMenuItem(action: Selector) -> NSMenuItem {
        NSMenuItem(title: "Find", action: action, keyEquivalent: "")
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
        guard let rgb = color?.usingColorSpace(.deviceRGB) else {
            XCTFail("Missing layer color", file: file, line: line)
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

private final class JavaScriptEvaluationState: @unchecked Sendable {
    var result: Any?
    var receivedError: Error?
}
