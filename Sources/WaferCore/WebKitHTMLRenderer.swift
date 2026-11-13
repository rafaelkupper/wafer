import CoreGraphics
import Foundation
import Markdown

public enum RenderTarget: Sendable {
    case reader
    case preview
}

public final class WebKitHTMLRenderer {
    private let assetResolver: AssetResolver
    private let palette: ReaderThemePalette
    private let target: RenderTarget
    private let wikiLinkIndex: WikiLinkIndex?
    private let annotatesSourceLines: Bool
    private let codeSyntaxHighlighter = CodeSyntaxHighlighter()

    /// `annotatesSourceLines` adds `data-source-line` attributes to blocks for
    /// the edit-mode live preview and returns the body HTML separately so the
    /// reader can patch it in place. Reading, export, and Quick Look leave it off.
    public init(
        assetResolver: AssetResolver = AssetResolver(),
        palette: ReaderThemePalette = .dark,
        target: RenderTarget = .reader,
        wikiLinkIndex: WikiLinkIndex? = nil,
        annotatesSourceLines: Bool = false
    ) {
        self.assetResolver = assetResolver
        self.palette = palette
        self.target = target
        // Quick Look previews always render the unresolved styling.
        self.wikiLinkIndex = target == .reader ? wikiLinkIndex : nil
        self.annotatesSourceLines = annotatesSourceLines && target == .reader
    }

    public func render(document: MarkdownDocument) -> WebKitRenderOutput {
        return render(document: document, metadata: metadata(for: document))
    }

    public func metadata(for document: MarkdownDocument) -> DocumentRenderMetadata {
        DocumentRenderMetadata(
            statistics: target == .reader ? RenderedTextDocumentStatistics.statistics(from: document) : .zero,
            sidebarEntries: target == .reader ? DocumentSidebarDataBuilder.sidebarEntries(
                from: document, assetResolver: assetResolver, loadLinkedFiles: false) : [],
            outlineItems: DocumentSidebarDataBuilder.outlineItems(from: document)
        )
    }

    public func render(document: MarkdownDocument, metadata: DocumentRenderMetadata) -> WebKitRenderOutput {
        let statistics = metadata.statistics
        let sidebarEntries = metadata.sidebarEntries
        let outlineItems = metadata.outlineItems
        var visitor = WebKitHTMLRenderVisitor(
            baseURL: document.baseURL,
            assetResolver: assetResolver,
            codeSyntaxHighlighter: codeSyntaxHighlighter,
            footnotes: document.footnotes,
            reservedHeadingAnchorIDs: Set(outlineItems.map(\.anchorID)),
            target: target,
            wikiLinkIndex: wikiLinkIndex,
            sourceLineMap: annotatesSourceLines ? document.sourceLineMap : nil
        )
        var frontMatterHTML = visitor.renderFrontMatter(document.frontMatter)
        if annotatesSourceLines, !frontMatterHTML.isEmpty {
            frontMatterHTML = WebKitHTMLRenderVisitor.addingSourceLine(1, toFirstElementIn: frontMatterHTML)
        }
        let renderedBody = visitor.visit(document.ast)
        let body = frontMatterHTML + renderedBody + visitor.renderFootnotesSection()
        let cspMetaTag: String
        let katexStyleSheet: String
        let rendererScripts: String
        if target == .reader {
            let scriptNonce = Self.scriptNonce()
            let hasScriptedRenderers = visitor.hasMermaidDiagrams || visitor.hasMathDisplays
            let csp = Self.contentSecurityPolicy(
                allowsPageScripts: hasScriptedRenderers,
                scriptNonce: scriptNonce
            )
            cspMetaTag = "  <meta http-equiv=\"Content-Security-Policy\" content=\"\(csp.escapedHTMLAttribute)\">"
            katexStyleSheet = visitor.hasMathDisplays
                ? "\n\(Self.katexStyleSheet())"
                : ""
            rendererScripts = hasScriptedRenderers
                ? Self.rendererScripts(
                    nonce: scriptNonce,
                    palette: palette,
                    includesMermaid: visitor.hasMermaidDiagrams,
                    includesMath: visitor.hasMathDisplays
                )
                : ""
        } else {
            cspMetaTag = ""
            katexStyleSheet = ""
            rendererScripts = ""
        }
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
        \(cspMetaTag)
          <style>
          \(ReaderTheme.styleSheet(for: palette))\(katexStyleSheet)
          </style>
        </head>
        <body>
          <div id="write">
          \(body)
          </div>
          \(rendererScripts)
        </body>
        </html>
        """

        return WebKitRenderOutput(
            html: html,
            baseURL: document.baseURL?.deletingLastPathComponent(),
            statistics: statistics,
            sidebarEntries: sidebarEntries,
            outlineItems: outlineItems,
            waitsForContentReady: target == .reader && (visitor.hasMermaidDiagrams || visitor.hasMathDisplays),
            previewAttachments: visitor.previewAttachments,
            hasWikiLinks: visitor.hasWikiLinks,
            bodyHTML: target == .reader ? body : nil,
            hasMermaidDiagrams: visitor.hasMermaidDiagrams,
            hasMathDisplays: visitor.hasMathDisplays
        )
    }

    private static func scriptNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func contentSecurityPolicy(allowsPageScripts: Bool, scriptNonce: String) -> String {
        let scriptSource = allowsPageScripts ? "'nonce-\(scriptNonce)'" : "'none'"
        return [
            "default-src 'none'",
            "img-src wafer-local: wafer-remote:",
            "style-src 'unsafe-inline' wafer-local:",
            "font-src wafer-local:",
            "connect-src 'none'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            "script-src \(scriptSource)",
        ].joined(separator: "; ") + ";"
    }

    private static func rendererScripts(
        nonce: String,
        palette: ReaderThemePalette,
        includesMermaid: Bool,
        includesMath: Bool
    ) -> String {
        let externalScripts = [
            includesMermaid ? scriptTag(resourceName: "mermaid.min.js", nonce: nonce) : nil,
            includesMath ? scriptTag(resourceName: "katex/katex.min.js", nonce: nonce) : nil,
        ]
            .compactMap { $0 }
            .joined(separator: "\n")

        return """
        \(externalScripts)
        <script nonce="\(nonce.escapedHTMLAttribute)">
        \(asyncRendererCoordinatorScript())
        \(includesMermaid ? mermaidBootstrapScript(for: palette) : "")
        \(includesMath ? katexBootstrapScript() : "")
        </script>
        """
    }

    private static func scriptTag(resourceName: String, nonce: String) -> String {
        guard let scriptURL = ReaderTheme.resourceURL(named: resourceName) else {
            return ""
        }

        let source = WebKitHTMLRenderVisitor.webViewAssetURLString(for: scriptURL)
        return "<script src=\"\(source.escapedHTMLAttribute)\" nonce=\"\(nonce.escapedHTMLAttribute)\"></script>"
    }

    private static func asyncRendererCoordinatorScript() -> String {
        """
    window.waferAsyncRenderer = (function() {
      var pending = 0;
      var didNotify = false;

      function notifyContentReady() {
        if (
          window.webkit &&
          window.webkit.messageHandlers &&
          window.webkit.messageHandlers.waferContentReady
        ) {
          window.webkit.messageHandlers.waferContentReady.postMessage(document.querySelector('meta[name="wafer-navigation"]')?.content || "");
        }
      }

      function settleThenNotify() {
        if (pending > 0) {
          return;
        }
        function notifyOnce() {
          if (didNotify) {
            return;
          }
          didNotify = true;
          notifyContentReady();
        }

        setTimeout(notifyOnce, 0);
        if (typeof requestAnimationFrame === 'function') {
          requestAnimationFrame(function() {
            requestAnimationFrame(notifyOnce);
          });
        }
      }

      return {
        beginTask: function() {
          pending += 1;
          var didFinish = false;
          return function() {
            if (didFinish) {
              return;
            }
            didFinish = true;
            pending = Math.max(pending - 1, 0);
            settleThenNotify();
          };
        }
      };
    })();
    """
    }

    private static func mermaidBootstrapScript(for palette: ReaderThemePalette) -> String {
        """
    (function() {
      var finishMermaidRender = window.waferAsyncRenderer.beginTask();

      function settleThenFinish() {
        var didNotify = false;
        function finishOnce() {
          if (didNotify) {
            return;
          }
          didNotify = true;
          finishMermaidRender();
        }

        setTimeout(finishOnce, 0);
        if (typeof requestAnimationFrame === 'function') {
          requestAnimationFrame(function() {
            requestAnimationFrame(finishOnce);
          });
        }
      }

      function messageFor(error) {
        if (!error) {
          return 'Unknown Mermaid render error.';
        }
        if (typeof error === 'string') {
          return error;
        }
        return error.str || error.message || String(error);
      }

      function showError(figure, message) {
        figure.classList.add('has-error');
        figure.classList.remove('is-rendered');

        var inspectButton = figure.querySelector('.md-mermaid-open');
        if (inspectButton) {
          inspectButton.hidden = true;
        }

        var output = figure.querySelector('.md-mermaid-output');
        if (output) {
          output.replaceChildren();
        }

        var error = figure.querySelector('.md-mermaid-error');
        if (error) {
          error.hidden = false;
          error.textContent = 'Unable to render Mermaid diagram: ' + message;
        }
      }

      function replaceAllText(text, oldValue, newValue) {
        return text.split(oldValue).join(newValue);
      }

      function cloneSVGForInspector(sourceSVG, figure) {
        var clone = sourceSVG.cloneNode(true);
        var diagramID = figure.getAttribute('data-wafer-mermaid-id') || 'diagram';
        var prefix = 'inspect-' + diagramID + '-';
        var idMap = [];
        var idElements = clone.hasAttribute('id') ? [clone] : [];

        idElements = idElements.concat(Array.prototype.slice.call(clone.querySelectorAll('[id]')));
        idElements.forEach(function(element) {
          var oldID = element.getAttribute('id');
          var newID = prefix + oldID;
          idMap.push([oldID, newID]);
          element.setAttribute('id', newID);
        });

        var elements = [clone].concat(Array.prototype.slice.call(clone.querySelectorAll('*')));
        elements.forEach(function(element) {
          Array.prototype.slice.call(element.attributes || []).forEach(function(attribute) {
            var value = attribute.value;
            idMap.forEach(function(pair) {
              value = replaceAllText(value, 'url(#' + pair[0] + ')', 'url(#' + pair[1] + ')');
              value = replaceAllText(value, '#' + pair[0], '#' + pair[1]);
            });
            if (value !== attribute.value) {
              element.setAttribute(attribute.name, value);
            }
          });
        });

        Array.prototype.slice.call(clone.querySelectorAll('style')).forEach(function(styleElement) {
          var text = styleElement.textContent || '';
          idMap.forEach(function(pair) {
            text = replaceAllText(text, '#' + pair[0], '#' + pair[1]);
          });
          styleElement.textContent = text;
        });

        return clone;
      }

      function svgNaturalSize(svg) {
        var viewBox = svg.viewBox && svg.viewBox.baseVal;
        if (viewBox && viewBox.width > 0 && viewBox.height > 0) {
          return { width: viewBox.width, height: viewBox.height };
        }

        var rect = svg.getBoundingClientRect();
        return {
          width: Math.max(rect.width, 1),
          height: Math.max(rect.height, 1)
        };
      }

      function clamp(value, minimum, maximum) {
        return Math.min(Math.max(value, minimum), maximum);
      }

      function ensureDiagramInspector() {
        if (window.waferDiagramInspector) {
          return window.waferDiagramInspector;
        }

        var overlay = document.createElement('div');
        overlay.className = 'md-diagram-inspector';
        overlay.hidden = true;
        overlay.setAttribute('\(ExportSanitizer.chromeAttributeName)', '\(ExportSanitizer.chromeAttributeValue)');
        overlay.setAttribute('role', 'dialog');
        overlay.setAttribute('aria-modal', 'true');
        overlay.setAttribute('aria-label', 'Diagram inspector');
        overlay.innerHTML = [
          '<div class="md-diagram-inspector-surface">',
          '  <div class="md-diagram-inspector-toolbar">',
          '    <button type="button" data-action="zoom-out" aria-label="Zoom out">-</button>',
          '    <button type="button" data-action="zoom-in" aria-label="Zoom in">+</button>',
          '    <button type="button" data-action="fit">Fit</button>',
          '    <button type="button" data-action="reset">Reset</button>',
          '    <button type="button" data-action="copy">Copy SVG</button>',
          '    <span class="md-diagram-inspector-status" aria-live="polite"></span>',
          '    <button type="button" data-action="close" aria-label="Close diagram inspector">Close</button>',
          '  </div>',
          '  <div class="md-diagram-inspector-viewport" tabindex="0">',
          '    <div class="md-diagram-inspector-canvas"></div>',
          '  </div>',
          '</div>'
        ].join('');

        document.body.appendChild(overlay);

        var inspector = {
          overlay: overlay,
          viewport: overlay.querySelector('.md-diagram-inspector-viewport'),
          canvas: overlay.querySelector('.md-diagram-inspector-canvas'),
          status: overlay.querySelector('.md-diagram-inspector-status'),
          trigger: null,
          sourceSVGMarkup: '',
          lastScroll: null,
          naturalWidth: 1,
          naturalHeight: 1,
          scale: 1,
          translateX: 0,
          translateY: 0,
          isDragging: false,
          lastPointerX: 0,
          lastPointerY: 0
        };

        function setStatus(message) {
          inspector.status.textContent = message || '';
        }

        function applyTransform() {
          inspector.canvas.style.transform = 'translate(' + inspector.translateX + 'px, ' + inspector.translateY + 'px) scale(' + inspector.scale + ')';
        }

        function centerAtCurrentScale() {
          inspector.translateX = (inspector.viewport.clientWidth - inspector.naturalWidth * inspector.scale) / 2;
          inspector.translateY = (inspector.viewport.clientHeight - inspector.naturalHeight * inspector.scale) / 2;
          applyTransform();
        }

        function fitToView() {
          var availableWidth = Math.max(inspector.viewport.clientWidth - 48, 1);
          var availableHeight = Math.max(inspector.viewport.clientHeight - 48, 1);
          var fitScale = Math.min(
            availableWidth / inspector.naturalWidth,
            availableHeight / inspector.naturalHeight
          );
          inspector.scale = clamp(Math.min(fitScale, 1), 0.1, 6);
          centerAtCurrentScale();
        }

        function resetView() {
          inspector.scale = 1;
          centerAtCurrentScale();
        }

        function zoomAt(nextScale, viewportX, viewportY) {
          nextScale = clamp(nextScale, 0.1, 6);
          var contentX = (viewportX - inspector.translateX) / inspector.scale;
          var contentY = (viewportY - inspector.translateY) / inspector.scale;

          inspector.scale = nextScale;
          inspector.translateX = viewportX - contentX * nextScale;
          inspector.translateY = viewportY - contentY * nextScale;
          applyTransform();
        }

        function zoomBy(multiplier) {
          zoomAt(
            inspector.scale * multiplier,
            inspector.viewport.clientWidth / 2,
            inspector.viewport.clientHeight / 2
          );
        }

        function viewportPointFor(event) {
          var rect = inspector.viewport.getBoundingClientRect();
          return {
            x: event.clientX - rect.left,
            y: event.clientY - rect.top
          };
        }

        function wheelDelta(value, mode, viewportSize) {
          if (mode === 1) {
            return value * 16;
          }
          if (mode === 2) {
            return value * viewportSize;
          }
          return value;
        }

        function shouldZoomForWheel(event, deltaX, deltaY) {
          if (event.ctrlKey || event.metaKey || event.altKey) {
            return true;
          }
          if (event.deltaMode !== 0) {
            return true;
          }
          return Math.abs(deltaY) > 40 && Math.abs(deltaX) < Math.abs(deltaY) * 0.3;
        }

        function handleWheel(event) {
          event.preventDefault();
          event.stopPropagation();

          if (!inspector.viewport.contains(event.target)) {
            return;
          }

          var deltaX = wheelDelta(event.deltaX, event.deltaMode, inspector.viewport.clientWidth);
          var deltaY = wheelDelta(event.deltaY, event.deltaMode, inspector.viewport.clientHeight);

          if (shouldZoomForWheel(event, deltaX, deltaY)) {
            var point = viewportPointFor(event);
            zoomAt(inspector.scale * Math.exp(-deltaY * 0.002), point.x, point.y);
            return;
          }

          inspector.translateX -= deltaX;
          inspector.translateY -= deltaY;
          applyTransform();
        }

        function handleGestureStart(event) {
          event.preventDefault();
          event.stopPropagation();
          inspector.gestureStartScale = inspector.scale;
        }

        function handleGestureChange(event) {
          event.preventDefault();
          event.stopPropagation();
          var point = viewportPointFor(event);
          zoomAt(inspector.gestureStartScale * event.scale, point.x, point.y);
        }

        function fallbackCopyText(text) {
          var textarea = document.createElement('textarea');
          textarea.value = text;
          textarea.setAttribute('readonly', '');
          textarea.style.position = 'fixed';
          textarea.style.left = '-9999px';
          document.body.appendChild(textarea);
          textarea.select();
          try {
            return document.execCommand('copy');
          } finally {
            textarea.remove();
          }
        }

        function copySVG() {
          var text = inspector.sourceSVGMarkup;
          if (!text) {
            setStatus('Nothing to copy');
            return;
          }

          if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
            navigator.clipboard.writeText(text).then(function() {
              setStatus('Copied SVG');
            }).catch(function() {
              setStatus(fallbackCopyText(text) ? 'Copied SVG' : 'Copy unavailable');
            });
            return;
          }

          setStatus(fallbackCopyText(text) ? 'Copied SVG' : 'Copy unavailable');
        }

        function closeInspector() {
          if (overlay.hidden) {
            return;
          }

          var trigger = inspector.trigger;
          var lastScroll = inspector.lastScroll;
          overlay.hidden = true;
          overlay.classList.remove('is-open');
          document.body.classList.remove('md-diagram-inspector-open');
          inspector.canvas.replaceChildren();
          inspector.trigger = null;
          inspector.sourceSVGMarkup = '';
          setStatus('');

          if (lastScroll) {
            window.scrollTo(lastScroll.x, lastScroll.y);
          }
          if (trigger && typeof trigger.focus === 'function') {
            trigger.focus({ preventScroll: true });
          }
        }

        overlay.addEventListener('click', function(event) {
          if (event.target === overlay) {
            closeInspector();
          }
        });

        overlay.querySelector('[data-action="zoom-out"]').addEventListener('click', function() {
          zoomBy(0.82);
        });
        overlay.querySelector('[data-action="zoom-in"]').addEventListener('click', function() {
          zoomBy(1.22);
        });
        overlay.querySelector('[data-action="fit"]').addEventListener('click', fitToView);
        overlay.querySelector('[data-action="reset"]').addEventListener('click', resetView);
        overlay.querySelector('[data-action="copy"]').addEventListener('click', copySVG);
        overlay.querySelector('[data-action="close"]').addEventListener('click', closeInspector);
        overlay.addEventListener('wheel', handleWheel, { passive: false });
        inspector.viewport.addEventListener('gesturestart', handleGestureStart, { passive: false });
        inspector.viewport.addEventListener('gesturechange', handleGestureChange, { passive: false });

        inspector.viewport.addEventListener('mousedown', function(event) {
          if (event.button !== 0) {
            return;
          }
          inspector.isDragging = true;
          inspector.lastPointerX = event.clientX;
          inspector.lastPointerY = event.clientY;
          inspector.viewport.classList.add('is-dragging');
          event.preventDefault();
        });

        document.addEventListener('mousemove', function(event) {
          if (!inspector.isDragging) {
            return;
          }
          inspector.translateX += event.clientX - inspector.lastPointerX;
          inspector.translateY += event.clientY - inspector.lastPointerY;
          inspector.lastPointerX = event.clientX;
          inspector.lastPointerY = event.clientY;
          applyTransform();
        });

        document.addEventListener('mouseup', function() {
          inspector.isDragging = false;
          inspector.viewport.classList.remove('is-dragging');
        });

        document.addEventListener('wheel', function(event) {
          if (overlay.hidden) {
            return;
          }
          event.preventDefault();
        }, { capture: true, passive: false });

        document.addEventListener('keydown', function(event) {
          if (overlay.hidden || event.key !== 'Escape') {
            return;
          }
          event.preventDefault();
          closeInspector();
        });

        inspector.open = function(figure, trigger) {
          var sourceSVG = figure.querySelector('.md-mermaid-output svg');
          if (!sourceSVG) {
            return;
          }

          var size = svgNaturalSize(sourceSVG);
          var clonedSVG = cloneSVGForInspector(sourceSVG, figure);
          clonedSVG.style.width = size.width + 'px';
          clonedSVG.style.height = size.height + 'px';
          clonedSVG.style.maxWidth = 'none';
          clonedSVG.style.maxHeight = 'none';

          inspector.canvas.replaceChildren(clonedSVG);
          inspector.trigger = trigger;
          inspector.sourceSVGMarkup = sourceSVG.outerHTML;
          inspector.lastScroll = { x: window.scrollX, y: window.scrollY };
          inspector.naturalWidth = size.width;
          inspector.naturalHeight = size.height;
          inspector.scale = 1;
          inspector.translateX = 0;
          inspector.translateY = 0;
          setStatus('');

          overlay.hidden = false;
          overlay.classList.add('is-open');
          document.body.classList.add('md-diagram-inspector-open');

          requestAnimationFrame(function() {
            if (overlay.hidden) {
              return;
            }
            fitToView();
            inspector.viewport.focus({ preventScroll: true });
          });
        };

        inspector.close = closeInspector;
        window.waferDiagramInspector = inspector;
        return inspector;
      }

      function prepareInspectButton(figure) {
        var inspectButton = figure.querySelector('.md-mermaid-open');
        if (!inspectButton) {
          return;
        }

        inspectButton.addEventListener('click', function(event) {
          event.preventDefault();
          event.stopPropagation();
          ensureDiagramInspector().open(figure, inspectButton);
        });
      }

      var figures = Array.prototype.slice.call(document.querySelectorAll('.md-mermaid-diagram'));
      if (figures.length === 0) {
        settleThenFinish();
        return;
      }

      figures.forEach(prepareInspectButton);

      if (!window.mermaid) {
        figures.forEach(function(figure) {
          showError(figure, 'The bundled Mermaid renderer is unavailable.');
        });
        settleThenFinish();
        return;
      }

      var requestedTheme = null;
      var pendingFigures = [];
      var rendering = null;
      async function renderFigure(figure, index) {
        try {
          var source = figure.querySelector('.md-mermaid-source code');
          var output = figure.querySelector('.md-mermaid-output');
          if (!source || !output) { throw new Error('The diagram container is missing required markup.'); }
          var diagramID = figure.getAttribute('data-wafer-mermaid-id') || ('wafer-mermaid-' + (index + 1));
          var result = await window.mermaid.render(diagramID + '-svg', source.textContent || '');
          output.innerHTML = result.svg;
          if (typeof result.bindFunctions === 'function') { result.bindFunctions(output); }
          var error = figure.querySelector('.md-mermaid-error');
          if (error) { error.hidden = true; error.textContent = ''; }
          figure.classList.add('is-rendered');
          figure.classList.remove('has-error');
          var inspectButton = figure.querySelector('.md-mermaid-open');
          if (inspectButton) { inspectButton.hidden = false; }
        } catch (error) { showError(figure, messageFor(error)); }
      }
      async function renderFigures() {
        while (requestedTheme || pendingFigures.length) {
          if (requestedTheme) {
            var configuration = requestedTheme;
            requestedTheme = null;
            pendingFigures = [];
            // Re-query so figures added or removed by the edit-mode preview are included.
            figures = Array.prototype.slice.call(document.querySelectorAll('.md-mermaid-diagram'));
            try {
              window.mermaid.initialize({
                startOnLoad: false, suppressErrorRendering: true, securityLevel: 'strict',
                theme: configuration.theme, themeVariables: configuration.variables
              });
              for (var index = 0; index < figures.length; index++) {
                await renderFigure(figures[index], index);
              }
            } catch (error) {
              figures.forEach(function(figure) { showError(figure, messageFor(error)); });
            }
            continue;
          }
          var batch = pendingFigures;
          pendingFigures = [];
          for (var position = 0; position < batch.length; position++) {
            if (batch[position].isConnected) {
              await renderFigure(batch[position], position);
            }
          }
        }
      }
      window.waferApplyMermaidTheme = function(theme, variables) {
        requestedTheme = { theme: theme, variables: variables };
        if (!rendering) {
          rendering = renderFigures().finally(function() { rendering = null; });
        }
        return rendering;
      };
      // Edit-mode preview: render figures inserted by an in-place body patch.
      window.waferRenderMermaidFigures = function(newFigures) {
        newFigures.forEach(prepareInspectButton);
        pendingFigures = pendingFigures.concat(newFigures);
        if (!rendering) {
          rendering = renderFigures().finally(function() { rendering = null; });
        }
        return rendering;
      };
      window.waferApplyMermaidTheme('\(palette.mermaid.theme.escapedJavaScriptString)', {
        \(mermaidThemeVariablesJavaScript(for: palette))
      }).finally(settleThenFinish);
    })();
    """
    }

    private static func katexBootstrapScript() -> String {
        """
    (function() {
      var finishMathRender = window.waferAsyncRenderer.beginTask();

      function messageFor(error) {
        if (!error) {
          return 'Unknown KaTeX render error.';
        }
        if (typeof error === 'string') {
          return error;
        }
        return error.message || String(error);
      }

      function showError(block, message) {
        block.classList.add('has-error');
        block.classList.remove('is-rendered');

        var output = block.querySelector('.md-math-output');
        if (output) {
          output.replaceChildren();
        }

        var error = block.querySelector('.md-math-error');
        if (error) {
          error.hidden = false;
          error.textContent = 'Unable to render math: ' + message;
        }
      }

      var blocks = Array.prototype.slice.call(document.querySelectorAll('.md-math-display'));
      if (blocks.length === 0) {
        finishMathRender();
        return;
      }

      if (!window.katex || typeof window.katex.render !== 'function') {
        blocks.forEach(function(block) {
          showError(block, 'The bundled KaTeX renderer is unavailable.');
        });
        finishMathRender();
        return;
      }

      var errorColor = window.getComputedStyle(document.documentElement)
        .getPropertyValue('--mermaid-error-text-color')
        .trim() || '#cc0000';

      function renderBlock(block) {
        var source = block.querySelector('.md-math-source code');
        var output = block.querySelector('.md-math-output');
        if (!source || !output) {
          showError(block, 'The math container is missing required markup.');
          return;
        }

        try {
          window.katex.render(source.textContent || '', output, {
            displayMode: true,
            throwOnError: false,
            errorColor: errorColor
          });

          var error = block.querySelector('.md-math-error');
          if (error) {
            error.hidden = true;
            error.textContent = '';
          }
          block.classList.add('is-rendered');
          block.classList.remove('has-error');
        } catch (error) {
          showError(block, messageFor(error));
        }
      }

      blocks.forEach(renderBlock);
      // Edit-mode preview: render math blocks inserted by an in-place body patch.
      window.waferRenderMathBlocks = function(newBlocks) {
        newBlocks.forEach(renderBlock);
      };

      finishMathRender();
    })();
    """
    }

    private static func katexStyleSheet() -> String {
        guard
            let styleSheetURL = ReaderTheme.resourceURL(named: "katex/katex.min.css"),
            let styleSheet = try? String(contentsOf: styleSheetURL, encoding: .utf8)
        else {
            return ""
        }

        return styleSheet.replacingKaTeXFontURLs(relativeTo: styleSheetURL)
    }

    private static func mermaidThemeVariablesJavaScript(for palette: ReaderThemePalette) -> String {
        (palette.mermaid.themeVariables + [("fontFamily", palette.mermaid.fontFamily)])
            .map { "            \($0.key): '\($0.value.escapedJavaScriptString)'" }
            .joined(separator: ",\n")
    }
}

private struct WebKitHTMLRenderVisitor: MarkupVisitor {
    typealias Result = String

    let baseURL: URL?
    let assetResolver: AssetResolver
    let codeSyntaxHighlighter: CodeSyntaxHighlighter
    let target: RenderTarget
    let wikiLinkIndex: WikiLinkIndex?
    private(set) var hasWikiLinks = false
    private let footnoteDefinitionsByLabel: [String: FootnoteDefinition]
    private let previewAttachmentStore = PreviewAttachmentStore()
    private var headingSlugger: HeadingAnchorSlugger
    private var inTableHead = false
    private var currentTableColumn = 0
    private var currentTableColumnAlignments: [Table.ColumnAlignment?] = []
    private var mermaidDiagramCount = 0
    private var mathDisplayCount = 0
    private var isInsideLink = false
    private var isRenderingFootnoteDefinition = false
    private let sourceLineMap: [Int]?
    private var footnoteNumbersByLabel: [String: Int] = [:]
    private var renderedFootnotes: [FootnoteDefinition] = []
    private var referencedFootnoteNumbers = Set<Int>()

    var hasMermaidDiagrams: Bool {
        mermaidDiagramCount > 0
    }

    var hasMathDisplays: Bool {
        mathDisplayCount > 0
    }

    var previewAttachments: [String: URL] {
        previewAttachmentStore.attachments
    }

    init(
        baseURL: URL?,
        assetResolver: AssetResolver,
        codeSyntaxHighlighter: CodeSyntaxHighlighter,
        footnotes: [FootnoteDefinition],
        reservedHeadingAnchorIDs: Set<String>,
        target: RenderTarget,
        wikiLinkIndex: WikiLinkIndex? = nil,
        sourceLineMap: [Int]? = nil
    ) {
        self.sourceLineMap = sourceLineMap
        self.baseURL = baseURL
        self.assetResolver = assetResolver
        self.codeSyntaxHighlighter = codeSyntaxHighlighter
        self.footnoteDefinitionsByLabel = MarkdownFootnoteSupport.definitionMap(from: footnotes)
        self.headingSlugger = HeadingAnchorSlugger(reservedPrimaryIDs: reservedHeadingAnchorIDs)
        self.target = target
        self.wikiLinkIndex = wikiLinkIndex
    }

    private var readAccessDirectoryURL: URL? {
        guard let baseURL else {
            return nil
        }

        guard baseURL.isFileURL else {
            return baseURL
        }

        return baseURL.hasDirectoryPath ? baseURL : baseURL.deletingLastPathComponent()
    }

    private var htmlSanitizer: HTMLSanitizer {
        HTMLSanitizer(policy: HTMLSanitizerPolicy(
            resolveImageSource: { rawSource in
                htmlImageSource(for: rawSource)
            },
            resolveLinkHref: { rawHref in
                htmlLinkHref(for: rawHref)
            },
            allowsSourceElements: target == .reader
        ))
    }

    mutating func visit(_ markup: Markup) -> String {
        markup.accept(&self)
    }

    func renderFrontMatter(_ frontMatter: String?) -> String {
        guard let frontMatter else {
            return ""
        }

        let rows = frontMatterTableRows(from: frontMatter)
        return """
        <details class="md-front-matter">
        <summary>Document metadata</summary>
        <table>
        <tbody>\(rows)</tbody>
        </table>
        </details>
        """
    }

    mutating func renderFootnotesSection() -> String {
        guard !renderedFootnotes.isEmpty else {
            return ""
        }

        let previousIsRenderingFootnoteDefinition = isRenderingFootnoteDefinition
        isRenderingFootnoteDefinition = true
        defer {
            isRenderingFootnoteDefinition = previousIsRenderingFootnoteDefinition
        }

        let items = renderedFootnotes.enumerated().map { index, definition in
            let number = index + 1
            let ast = Document(parsing: definition.content, options: [.parseBlockDirectives, .parseSymbolLinks])
            let content = visit(ast)
            let backref = "<a class=\"md-footnote-backref\" href=\"\(sameDocumentFragmentHref(for: "fnref-\(number)").escapedHTMLAttribute)\" aria-label=\"Back to footnote reference\">↩</a>"
            return """
            <li id="fn-\(number)">
            \(footnoteBodyHTML(content: content, backref: backref))
            </li>
            """
        }.joined()

        return """
        <section class="md-footnotes" aria-label="Footnotes">
        <hr />
        <ol>
        \(items)
        </ol>
        </section>
        """
    }

    mutating func defaultVisit(_ markup: Markup) -> String {
        if markup is BlockMarkup {
            return "<p class=\"fallback-block\">\(markup.format().escapedHTML)</p>"
        }

        return descend(markup)
    }

    mutating func visitDocument(_ document: Document) -> String {
        guard sourceLineMap != nil, !isRenderingFootnoteDefinition else {
            return descend(document)
        }

        return document.children.map { child in
            annotatingSourceLine(of: child, in: visit(child))
        }.joined()
    }

    /// Edit-mode source line for a block in the main document, never for
    /// footnote definitions (they are parsed separately).
    private func sourceLine(of markup: Markup) -> Int? {
        guard
            let sourceLineMap,
            !isRenderingFootnoteDefinition,
            let astLine = markup.range?.lowerBound.line,
            astLine >= 1, astLine <= sourceLineMap.count
        else {
            return nil
        }

        return sourceLineMap[astLine - 1]
    }

    private func annotatingSourceLine(of markup: Markup, in html: String) -> String {
        guard let line = sourceLine(of: markup) else {
            return html
        }

        return Self.addingSourceLine(line, toFirstElementIn: html)
    }

    private func sourceLineAttribute(for markup: Markup) -> String {
        sourceLine(of: markup).map { " data-source-line=\"\($0)\"" } ?? ""
    }

    /// Inserts `data-source-line` into the first start tag when the HTML
    /// begins with an element; text, comments, and closing tags are left alone.
    static func addingSourceLine(_ line: Int, toFirstElementIn html: String) -> String {
        guard let open = html.firstIndex(where: { !$0.isWhitespace }), html[open] == "<" else {
            return html
        }

        let nameStart = html.index(after: open)
        guard nameStart < html.endIndex, html[nameStart].isLetter else {
            return html
        }

        guard let nameEnd = html[nameStart...].firstIndex(where: { $0.isWhitespace || $0 == ">" || $0 == "/" }) else {
            return html
        }

        var annotated = html
        annotated.insert(contentsOf: " data-source-line=\"\(line)\"", at: nameEnd)
        return annotated
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(descend(paragraph))</p>"
    }

    mutating func visitText(_ text: Text) -> String {
        guard !isInsideLink else {
            return text.string.escapedHTML
        }

        let textWithFootnotes = htmlByRenderingFootnoteReferences(in: text.string)
        if let textWithFootnotes {
            return textWithFootnotes
        }

        return htmlByRenderingInlineText(text.string)
    }

    private mutating func htmlByRenderingFootnoteReferences(in text: String) -> String? {
        guard !isRenderingFootnoteDefinition else {
            return nil
        }

        let references = MarkdownFootnoteSupport.references(in: text)
        let knownLabels = Set(footnoteDefinitionsByLabel.keys)
        guard references.contains(where: { knownLabels.contains($0.normalizedLabel) }) else {
            return nil
        }

        var output = ""
        var cursor = text.startIndex
        for reference in references {
            output += htmlByRenderingInlineText(String(text[cursor..<reference.range.lowerBound]))
            if let referenceHTML = footnoteReferenceHTML(for: reference.normalizedLabel) {
                output += referenceHTML
            } else {
                output += htmlByRenderingInlineText(String(text[reference.range]))
            }
            cursor = reference.range.upperBound
        }
        output += htmlByRenderingInlineText(String(text[cursor...]))
        return output
    }

    private mutating func footnoteReferenceHTML(for normalizedLabel: String) -> String? {
        guard let definition = footnoteDefinitionsByLabel[normalizedLabel] else {
            return nil
        }

        let number: Int
        if let existingNumber = footnoteNumbersByLabel[normalizedLabel] {
            number = existingNumber
        } else {
            number = renderedFootnotes.count + 1
            footnoteNumbersByLabel[normalizedLabel] = number
            renderedFootnotes.append(definition)
        }

        let idAttribute = referencedFootnoteNumbers.insert(number).inserted ? #" id="fnref-\#(number)""# : ""
        let href = sameDocumentFragmentHref(for: "fn-\(number)").escapedHTMLAttribute
        return "<sup class=\"md-footnote-ref\"><a href=\"\(href)\"\(idAttribute) aria-label=\"Footnote \(number)\">\(number)</a></sup>"
    }

    private mutating func htmlByRenderingInlineText(_ text: String) -> String {
        let wikiSpans = WikiLinkSyntax.spans(in: text)
        guard !wikiSpans.isEmpty else {
            return htmlByRenderingPlainInlineText(text)
        }

        hasWikiLinks = true
        var output = ""
        var cursor = text.startIndex
        for span in wikiSpans {
            output += htmlByRenderingPlainInlineText(String(text[cursor..<span.range.lowerBound]))
            output += wikiLinkHTML(for: span)
            cursor = span.range.upperBound
        }
        output += htmlByRenderingPlainInlineText(String(text[cursor...]))
        return output
    }

    private mutating func wikiLinkHTML(for span: WikiLinkSyntax.Span) -> String {
        if span.isEmbed, span.targetIsImage {
            return imageHTML(source: span.target, altText: span.displayText)
        }

        let headingAnchorID = span.heading.map { heading in
            var slugger = HeadingAnchorSlugger()
            return slugger.slug(for: heading)
        }

        // Same-document heading form: [[#Heading]].
        if span.target.isEmpty, let headingAnchorID {
            let href = sameDocumentFragmentHref(for: headingAnchorID)
            return "<a class=\"md-wikilink\" href=\"\(href.escapedHTMLAttribute)\">\(span.displayText.escapedHTML)</a>"
        }

        if
            !span.isEmbed,
            let resolvedURL = wikiLinkIndex?.resolve(span.target),
            let wikiURL = WikiLinkURL.url(for: resolvedURL, anchorID: headingAnchorID)
        {
            return "<a class=\"md-wikilink\" href=\"\(wikiURL.absoluteString.escapedHTMLAttribute)\">\(span.displayText.escapedHTML)</a>"
        }

        return "<span class=\"md-wikilink-unresolved\">\(span.displayText.escapedHTML)</span>"
    }

    private func htmlByRenderingPlainInlineText(_ text: String) -> String {
        let segments = Autolinker.segments(in: text)
        guard segments.count > 1 || segments.first != .plain(text) else {
            return MarkdownInlineCompatibility.htmlByRenderingTextDecorations(in: text)
        }

        return segments.map { segment in
            switch segment {
            case let .plain(text):
                return MarkdownInlineCompatibility.htmlByRenderingTextDecorations(in: text)
            case let .link(text, href):
                return anchorHTML(href: resolvedLinkHref(for: href), bodyHTML: text.escapedHTML)
            }
        }.joined()
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br />"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(descend(strong))</strong>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(descend(emphasis))</em>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(descend(strikethrough))</del>"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let title = MarkdownSemanticSupport
            .strippedHTMLText(from: heading.plainText)
            .strippingKnownFootnoteReferences(knownLabels: Set(footnoteDefinitionsByLabel.keys))
            .collapsingWhitespace
        let idAttribute: String
        let aliasHTML: String
        if title.isEmpty {
            idAttribute = ""
            aliasHTML = ""
        } else {
            let slugs = headingSlugger.slugs(for: title)
            idAttribute = " id=\"\(slugs.primary.escapedHTMLAttribute)\""
            if let gitHubAlias = slugs.gitHubAlias {
                aliasHTML = "<a id=\"\(gitHubAlias.escapedHTMLAttribute)\" class=\"md-anchor-alias\" aria-hidden=\"true\"></a>"
            } else {
                aliasHTML = ""
            }
        }
        return "<h\(heading.level)\(idAttribute)>\(aliasHTML)\(descend(heading))</h\(heading.level)>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(inlineCode.code.escapedHTML)</code>"
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) -> String {
        let destination = symbolLink.destination ?? ""
        return "<code class=\"md-symbol-link\">\(destination.escapedHTML)</code>"
    }

    mutating func visitInlineAttributes(_ attributes: InlineAttributes) -> String {
        let content = descend(attributes)
        guard let className = MarkdownSemanticSupport.inlineAttributeClassName(from: attributes) else {
            return content
        }

        return "<span class=\"\(className.escapedHTMLAttribute)\">\(content)</span>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let normalizedLanguage = codeBlock.language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let code = codeBlock.code.trimmingCharacters(in: .newlines)
        if target == .reader, isMermaidLanguage(normalizedLanguage) {
            return renderMermaidDiagram(source: code)
        }
        if target == .reader, isMathLanguage(normalizedLanguage) {
            return renderMathDisplay(source: code)
        }

        let languageClass = normalizedLanguage.isEmpty ? "" : " language-\(normalizedLanguage.escapedHTMLAttribute)"

        let highlighted = codeSyntaxHighlighter.highlightedHTML(
            code: code,
            language: codeBlock.language
        )
        let languageAttribute = normalizedLanguage.isEmpty ? "" : " lang=\"\(normalizedLanguage.escapedHTMLAttribute)\""
        return "<pre class=\"md-fences\"\(languageAttribute)><code class=\"cm-s-inner\(languageClass)\">\(highlighted)</code></pre>"
    }

    mutating func visitLink(_ link: Link) -> String {
        let previousIsInsideLink = isInsideLink
        isInsideLink = true
        let bodyHTML = descend(link)
        isInsideLink = previousIsInsideLink
        return anchorHTML(href: resolvedLinkHref(for: link.destination ?? ""), bodyHTML: bodyHTML)
    }

    mutating func visitImage(_ image: Image) -> String {
        imageHTML(source: image.source, altText: image.plainText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private mutating func imageHTML(source: String?, altText: String) -> String {
        guard
            let source,
            let url = assetResolver.imageURL(for: source, relativeTo: baseURL)
        else {
            return "<p class=\"fallback-block\">[Missing image]</p>"
        }

        if assetResolver.isRemoteImageURL(url) {
            if target == .preview {
                return remoteImagePlaceholder(altText: altText)
            }
            let sourceURL = Self.webViewRemoteImageURLString(for: url)
            return "<img src=\"\(sourceURL.escapedHTMLAttribute)\" alt=\"\(altText.escapedHTMLAttribute)\" loading=\"lazy\" />"
        }

        if target == .preview {
            guard let sourceURL = previewAttachmentStore.cidSource(
                for: url,
                allowedRootDirectory: readAccessDirectoryURL
            ) else {
                return "<p class=\"fallback-block\">[Missing image]</p>"
            }
            return "<img src=\"\(sourceURL.escapedHTMLAttribute)\" alt=\"\(altText.escapedHTMLAttribute)\" />"
        }

        let sourceURL = Self.webViewAssetURLString(for: url)
        return "<img src=\"\(sourceURL.escapedHTMLAttribute)\" alt=\"\(altText.escapedHTMLAttribute)\" />"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        if let alert = MarkdownSemanticSupport.gitHubAlert(for: blockQuote) {
            return calloutHTML(
                for: alert.definition,
                bodyHTML: renderGitHubAlertBody(for: blockQuote, alert: alert)
            )
        }

        return "<blockquote>\(descend(blockQuote))</blockquote>"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        let containsTasks = unorderedList.children.contains { child in
            guard let listItem = child as? ListItem else {
                return false
            }
            return taskListState(for: listItem) != nil
        }

        let classAttribute = containsTasks ? " class=\"task-list\"" : ""
        return "<ul\(classAttribute)>\(descend(unorderedList))</ul>"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        let startAttribute = orderedList.startIndex == 1 ? "" : " start=\"\(orderedList.startIndex)\""
        return "<ol\(startAttribute)>\(descend(orderedList))</ol>"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        let content = flattenLeadingParagraphIfPresent(descend(listItem))

        let lineAttribute = sourceLineAttribute(for: listItem)
        if let taskState = taskListState(for: listItem) {
            let checkedAttribute = taskState ? " checked" : ""
            return "<li class=\"md-task-list-item\"\(lineAttribute)><input type=\"checkbox\" disabled\(checkedAttribute) />\(content)</li>"
        }

        return "<li\(lineAttribute)>\(content)</li>"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr />"
    }

    mutating func visitTable(_ table: Table) -> String {
        guard !table.isEmpty, table.maxColumnCount > 0 else {
            return "<p class=\"fallback-block\">\(table.format().escapedHTML)</p>"
        }

        let rows = tableTextRows(for: table)
        let columnWidths = tableColumnWidthPercentages(for: rows, columnCount: table.maxColumnCount)
        let columns = columnWidths.map { width in
            "<col style=\"width: \(width)%\">"
        }.joined()

        let previousAlignments = currentTableColumnAlignments
        let previousColumn = currentTableColumn
        let previousInHead = inTableHead

        currentTableColumnAlignments = normalizedTableColumnAlignments(for: table)
        currentTableColumn = 0
        inTableHead = false
        let content = descend(table)

        currentTableColumnAlignments = previousAlignments
        currentTableColumn = previousColumn
        inTableHead = previousInHead

        return """
        <table>
          <colgroup>\(columns)</colgroup>
          \(content)
        </table>
        """
    }

    mutating func visitTableHead(_ tableHead: Table.Head) -> String {
        let previousInHead = inTableHead
        let previousColumn = currentTableColumn
        inTableHead = true
        currentTableColumn = 0
        let content = descend(tableHead)
        inTableHead = previousInHead
        currentTableColumn = previousColumn
        return "<thead><tr>\(content)</tr></thead>"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) -> String {
        guard !tableBody.isEmpty else {
            return ""
        }

        return "<tbody>\(descend(tableBody))</tbody>"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) -> String {
        let previousColumn = currentTableColumn
        currentTableColumn = 0
        let content = descend(tableRow)
        currentTableColumn = previousColumn
        return "<tr\(sourceLineAttribute(for: tableRow))>\(content)</tr>"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) -> String {
        guard tableCell.colspan > 0, tableCell.rowspan > 0 else {
            currentTableColumn += 1
            return ""
        }

        let element = inTableHead ? "th" : "td"
        let colspan = max(Int(tableCell.colspan), 1)
        let rowspan = max(Int(tableCell.rowspan), 1)
        let columnIndex = currentTableColumn
        currentTableColumn += colspan

        var attributes = ""
        if columnIndex < currentTableColumnAlignments.count,
           let alignment = currentTableColumnAlignments[columnIndex] {
            attributes += " align=\"\(htmlAlignmentValue(for: alignment))\""
        }
        if rowspan > 1 {
            attributes += " rowspan=\"\(rowspan)\""
        }
        if colspan > 1 {
            attributes += " colspan=\"\(colspan)\""
        }

        return "<\(element)\(attributes)>\(descend(tableCell))</\(element)>"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        let source = html.format()
        let sanitized = htmlSanitizer.sanitize(source)
        let trimmedSanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSanitized.isEmpty else {
            return ""
        }
        if sanitized.contains("<") {
            return sanitized
        }

        return "<p class=\"fallback-block\">\(trimmedSanitized)</p>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        let source = inlineHTML.format()
        let sanitized = htmlSanitizer.sanitize(source)
        if !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sanitized
        }

        return MarkdownSemanticSupport.strippedHTMLText(from: source).escapedHTML
    }

    mutating func visitBlockDirective(_ blockDirective: BlockDirective) -> String {
        if let callout = MarkdownSemanticSupport.calloutDefinition(for: blockDirective) {
            let body = descend(blockDirective)
            return calloutHTML(for: callout, bodyHTML: body)
        }

        return "<p class=\"fallback-block\">\(blockDirective.format().escapedHTML)</p>"
    }

    private mutating func descend(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    private mutating func renderGitHubAlertBody(for blockQuote: BlockQuote, alert: MarkdownGitHubAlert) -> String {
        let blockChildren = Array(blockQuote.children)
        guard let firstParagraph = blockChildren.first as? Paragraph else {
            return ""
        }

        let paragraphChildren = Array(firstParagraph.children)
        let firstParagraphBody = paragraphChildren
            .dropFirst(alert.firstParagraphInlineDropCount)
            .map { visit($0) }
            .joined()
        var bodyParts: [String] = []
        if !firstParagraphBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bodyParts.append("<p>\(firstParagraphBody)</p>")
        }
        bodyParts.append(contentsOf: blockChildren.dropFirst().map { visit($0) })
        return bodyParts.joined()
    }

    private func calloutHTML(for callout: MarkdownCalloutDefinition, bodyHTML: String) -> String {
        let body = bodyHTML.isEmpty ? "" : "<div class=\"md-callout-body\">\(bodyHTML)</div>"
        return """
        <aside class="md-callout \(callout.kind.cssClassName)">
        <div class="md-callout-label">\(callout.label.escapedHTML)</div>\(body)
        </aside>
        """
    }

    private func frontMatterTableRows(from frontMatter: String) -> String {
        frontMatter
            .components(separatedBy: .newlines)
            .map { line in
                if let separator = frontMatterKeyValueSeparator(in: line) {
                    let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                    let valueStart = line.index(after: separator)
                    let value = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
                    return "<tr><th>\(key.escapedHTML)</th><td>\(value.escapedHTML)</td></tr>"
                }

                return "<tr><td colspan=\"2\"><code>\(line.escapedHTML)</code></td></tr>"
            }
            .joined()
    }

    private func frontMatterKeyValueSeparator(in line: String) -> String.Index? {
        guard line.first?.isWhitespace != true, let separator = line.firstIndex(of: ":") else {
            return nil
        }

        let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : separator
    }

    private func tableColumnWidthPercentages(for rows: [[String]], columnCount: Int) -> [CGFloat] {
        guard columnCount > 0 else {
            return []
        }

        var weights = Array(repeating: CGFloat(1), count: columnCount)
        for row in rows {
            for columnIndex in 0..<columnCount {
                let text = columnIndex < row.count ? row[columnIndex] : ""
                let characterCount = text.count
                let longestWordCount = text
                    .split(whereSeparator: \.isWhitespace)
                    .map(\.count)
                    .max() ?? 0
                let weight = CGFloat(min(max(characterCount + (longestWordCount / 2), 8), 36))
                weights[columnIndex] = max(weights[columnIndex], weight)
            }
        }

        if let widestColumnIndex = weights.indices.max(by: { weights[$0] < weights[$1] }) {
            weights[widestColumnIndex] *= 1.15
        }

        let minimums = Array(repeating: CGFloat(12), count: columnCount)
        let totalMinimum = minimums.reduce(0, +)
        guard totalMinimum < 100 else {
            return Array(repeating: 100 / CGFloat(columnCount), count: columnCount)
        }

        let normalizedWeights = zip(weights, minimums).map { max($0 - $1, 1) }
        let normalizedWeightTotal = normalizedWeights.reduce(0, +)
        let distributableWidth = 100 - totalMinimum

        return zip(minimums, normalizedWeights).map { minimum, weight in
            minimum + (distributableWidth * weight / normalizedWeightTotal)
        }
    }

    private func tableTextRows(for table: Table) -> [[String]] {
        var rows = [tableTextRow(for: table.head, columnCount: table.maxColumnCount)]
        rows.append(contentsOf: table.body.rows.map { tableTextRow(for: $0, columnCount: table.maxColumnCount) })
        return rows
    }

    private func tableTextRow(for row: some Markup, columnCount: Int) -> [String] {
        let cells = row.children.compactMap { $0 as? Table.Cell }
        var texts: [String] = []

        for cell in cells {
            if cell.colspan == 0 || cell.rowspan == 0 {
                texts.append("")
                continue
            }

            let colspan = max(Int(cell.colspan), 1)
            texts.append(cell.plainText.collapsingWhitespace)
            if colspan > 1 {
                texts.append(contentsOf: repeatElement("", count: colspan - 1))
            }
        }

        if texts.count < columnCount {
            texts.append(contentsOf: repeatElement("", count: columnCount - texts.count))
        } else if texts.count > columnCount {
            texts = Array(texts.prefix(columnCount))
        }

        return texts
    }

    private func normalizedTableColumnAlignments(for table: Table) -> [Table.ColumnAlignment?] {
        var alignments = table.columnAlignments
        if alignments.count < table.maxColumnCount {
            alignments.append(contentsOf: repeatElement(nil, count: table.maxColumnCount - alignments.count))
        } else if alignments.count > table.maxColumnCount {
            alignments = Array(alignments.prefix(table.maxColumnCount))
        }
        return alignments
    }

    private func htmlAlignmentValue(for alignment: Table.ColumnAlignment) -> String {
        switch alignment {
        case .left:
            return "left"
        case .center:
            return "center"
        case .right:
            return "right"
        }
    }

    private func isMermaidLanguage(_ language: String) -> Bool {
        switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mermaid", "mmd":
            return true
        default:
            return false
        }
    }

    private func isMathLanguage(_ language: String) -> Bool {
        language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "math"
    }

    private mutating func renderMermaidDiagram(source: String) -> String {
        mermaidDiagramCount += 1
        let diagramID = "wafer-mermaid-\(mermaidDiagramCount)"
        return """
        <figure class="md-mermaid-diagram" data-wafer-mermaid-id="\(diagramID)">
          <button type="button" class="md-mermaid-open" \(ExportSanitizer.chromeAttributeName)="\(ExportSanitizer.chromeAttributeValue)" aria-label="Open Mermaid diagram inspector" hidden>Open</button>
          <div class="md-mermaid-output" aria-label="Mermaid diagram"></div>
          <p class="md-mermaid-error" hidden></p>
          <pre class="md-mermaid-source" lang="mermaid"><code>\(source.escapedHTML)</code></pre>
        </figure>
        """
    }

    private mutating func renderMathDisplay(source: String) -> String {
        mathDisplayCount += 1
        let mathID = "wafer-math-\(mathDisplayCount)"
        return """
        <figure class="md-math-display" data-wafer-math-id="\(mathID)">
          <div class="md-math-output" aria-label="Rendered math"></div>
          <p class="md-math-error" hidden></p>
          <pre class="md-math-source" lang="math"><code>\(source.escapedHTML)</code></pre>
        </figure>
        """
    }

    private func taskListState(for listItem: ListItem) -> Bool? {
        switch listItem.checkbox {
        case .checked?:
            true
        case .unchecked?:
            false
        case nil:
            nil
        }
    }

    private func flattenLeadingParagraphIfPresent(_ html: String) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<p>"), let closingRange = trimmed.range(of: "</p>") else {
            return html
        }

        let paragraphStart = trimmed.index(trimmed.startIndex, offsetBy: 3)
        let firstParagraph = String(trimmed[paragraphStart..<closingRange.lowerBound])
        let remainder = trimmed[closingRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? firstParagraph : firstParagraph + remainder
    }

    private func resolvedHTMLURLString(for url: URL?) -> String? {
        guard let url else {
            return nil
        }

        guard url.isFileURL else {
            return url.absoluteString
        }

        guard
            let readAccessDirectoryURL,
            readAccessDirectoryURL.isFileURL,
            let relativePath = relativePath(from: readAccessDirectoryURL, to: url)
        else {
            return url.absoluteString
        }

        return relativePath
    }

    private func relativePath(from directoryURL: URL, to fileURL: URL) -> String? {
        let standardizedDirectoryURL = directoryURL.standardizedFileURL
        let standardizedFileURL = fileURL.standardizedFileURLPreservingFragment()

        let directoryPath = standardizedDirectoryURL.path
        let filePath = standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"

        guard filePath.hasPrefix(prefix) else {
            return nil
        }

        let relativePath = String(filePath.dropFirst(prefix.count))
        let encodedPath = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { component in
                String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
            }
            .joined(separator: "/")

        if let fragment = standardizedFileURL.fragment {
            let encodedFragment = fragment.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? fragment
            return encodedPath + "#" + encodedFragment
        }

        return encodedPath
    }

    private func resolvedLinkHref(for destination: String) -> String {
        resolvedHTMLURLString(
            for: assetResolver.resolve(destination: destination, relativeTo: baseURL)
        ) ?? destination
    }

    private func footnoteBodyHTML(content: String, backref: String) -> String {
        // Match GitHub: the back-reference sits inline at the end of the
        // definition's last paragraph. Appending it after the closing block
        // tag wraps it onto its own orphan line. It is joined WITHOUT a space
        // so there is no line-break opportunity before the arrow (the visual
        // gap comes from the .md-footnote-backref margin) — a full-width last
        // line wraps the arrow together with the final word, never alone.
        guard
            let closingRange = content.range(of: "</p>", options: .backwards),
            content[closingRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "\(content)\(backref)"
        }

        return content.replacingCharacters(in: closingRange, with: "\(backref)</p>")
    }

    private func sameDocumentFragmentHref(for fragment: String) -> String {
        // The reader page loads with the document's DIRECTORY as its base URL,
        // so a plain "#fragment" click resolves to the folder URL and opens it
        // in Finder instead of scrolling. Resolve fragments to
        // "File.md#fragment" like every markdown anchor. Quick Look previews
        // have no file base URL (and baseURL-less renders cannot resolve), so
        // both keep the plain fragment for native in-page scrolling.
        guard target == .reader, baseURL != nil else {
            return "#\(fragment)"
        }

        return resolvedLinkHref(for: "#\(fragment)")
    }

    private func anchorHTML(href: String, bodyHTML: String) -> String {
        "<a href=\"\(href.escapedHTMLAttribute)\">\(bodyHTML)</a>"
    }

    private func htmlImageSource(for rawSource: String) -> String? {
        guard let url = assetResolver.imageURL(for: rawSource, relativeTo: baseURL) else {
            return nil
        }

        if assetResolver.isRemoteImageURL(url) {
            guard target == .reader else {
                return nil
            }
            return Self.webViewRemoteImageURLString(for: url)
        }

        if target == .preview {
            return previewAttachmentStore.cidSource(
                for: url,
                allowedRootDirectory: readAccessDirectoryURL
            )
        }

        return Self.webViewAssetURLString(for: url)
    }

    private func remoteImagePlaceholder(altText: String) -> String {
        let suffix = altText.isEmpty ? "" : ": \(altText)"
        return "<span class=\"md-image-placeholder\">[Remote image omitted\(suffix.escapedHTML)]</span>"
    }

    private func htmlLinkHref(for rawHref: String) -> String? {
        guard let url = assetResolver.resolve(destination: rawHref, relativeTo: baseURL) else {
            return nil
        }

        if url.isFileURL {
            return resolvedHTMLURLString(for: url)
        }

        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            return url.absoluteString
        default:
            return nil
        }
    }

    static func webViewAssetURLString(for fileURL: URL) -> String {
        var components = URLComponents()
        components.scheme = "wafer-local"
        components.host = "asset"
        components.queryItems = [
            URLQueryItem(name: "path", value: fileURL.standardizedFileURL.path),
        ]
        return components.url?.absoluteString ?? fileURL.absoluteString
    }

    static func webViewRemoteImageURLString(for remoteURL: URL) -> String {
        var components = URLComponents()
        components.scheme = "wafer-remote"
        components.host = "image"
        components.queryItems = [
            URLQueryItem(name: "url", value: remoteURL.absoluteString),
        ]
        return components.url?.absoluteString ?? remoteURL.absoluteString
    }
}

private extension String {
    func replacingKaTeXFontURLs(relativeTo styleSheetURL: URL) -> String {
        let pattern = #"url\((['"]?)(fonts/[^)'"]+)\1\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return self
        }

        var result = self
        let matches = regex.matches(in: self, range: NSRange(startIndex..<endIndex, in: self))
        for match in matches.reversed() where match.numberOfRanges >= 3 {
            guard
                let fullRange = Range(match.range(at: 0), in: result),
                let fontRange = Range(match.range(at: 2), in: result)
            else {
                continue
            }

            let fontPath = String(result[fontRange])
            let fontURL = ReaderTheme.resourceURL(named: "katex/\(fontPath)")
                ?? ReaderTheme.resourceURL(named: fontPath)
                ?? styleSheetURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(fontPath)
            let assetURL = WebKitHTMLRenderVisitor.webViewAssetURLString(for: fontURL)
            result.replaceSubrange(fullRange, with: "url('\(assetURL.escapedCSSString)')")
        }
        return result
    }

    var escapedCSSString: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\a ")
            .replacingOccurrences(of: "\r", with: "\\d ")
    }
}

private final class PreviewAttachmentStore {
    private(set) var attachments: [String: URL] = [:]

    func cidSource(for fileURL: URL, allowedRootDirectory: URL?) -> String? {
        guard
            fileURL.isFileURL,
            let allowedRootDirectory,
            allowedRootDirectory.isFileURL
        else {
            return nil
        }

        let resolvedFileURL = URL(fileURLWithPath: fileURL.path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedRootURL = URL(fileURLWithPath: allowedRootDirectory.path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false

        guard
            Self.isAllowed(fileURL: resolvedFileURL, in: resolvedRootURL),
            FileManager.default.fileExists(atPath: resolvedFileURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return nil
        }

        if let existing = attachments.first(where: { $0.value == resolvedFileURL }) {
            return "cid:\(existing.key)"
        }

        let key = "preview-asset-\(attachments.count + 1)"
        attachments[key] = resolvedFileURL
        return "cid:\(key)"
    }

    private static func isAllowed(fileURL: URL, in rootDirectory: URL) -> Bool {
        let filePath = fileURL.path
        let rootPath = rootDirectory.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath == rootPath || filePath.hasPrefix(rootPrefix)
    }
}
