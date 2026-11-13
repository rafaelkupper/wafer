(function() {
  var configuration = JSON.parse(document.currentScript.dataset.waferRenderer);
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
    overlay.setAttribute(configuration.chromeAttributeName, configuration.chromeAttributeValue);
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
  window.waferApplyMermaidTheme(configuration.theme, configuration.variables).finally(settleThenFinish);
})();
