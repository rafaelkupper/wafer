(function() {
  if (window.waferReaderScrollInstalled) {
    return;
  }
  window.waferReaderScrollInstalled = true;

  function clampHorizontalScroll() {
    if (window.scrollX !== 0) {
      window.scrollTo(0, window.scrollY);
    }
  }

  function currentFraction() {
    const root = document.scrollingElement || document.documentElement;
    const maxOffset = Math.max(root.scrollHeight - window.innerHeight, 0);
    if (maxOffset <= 0) {
      return 0;
    }
    return Math.max(0, Math.min(1, window.scrollY / maxOffset));
  }

  var pending = false;
  var pendingClamp = false;
  function report() {
    if (!pending) { return; }
    pending = false;
    clampHorizontalScroll();
    window.webkit.messageHandlers.waferScroll.postMessage(currentFraction());
    window.webkit.messageHandlers.waferActiveHeading.postMessage(currentHeadingID());
  }

  function performClamp() {
    if (!pendingClamp) { return; }
    pendingClamp = false;
    clampHorizontalScroll();
  }

  var headingOffsets = [];
  var headingsDirty = true;
  function invalidateHeadings() {
    headingsDirty = true;
    scheduleReport();
  }
  function currentHeadingID() {
    if (headingsDirty) {
      headingOffsets = Array.from(document.querySelectorAll('#write h1[id], #write h2[id], #write h3[id], #write h4[id], #write h5[id], #write h6[id]'))
        .filter(function(heading) { return heading.getClientRects().length > 0; })
        .map(function(heading) { return { id: heading.id, top: window.scrollY + heading.getBoundingClientRect().top }; });
      headingsDirty = false;
    }
    if (!headingOffsets.length) { return null; }
    const threshold = window.scrollY + 32;
    let low = 0, high = headingOffsets.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (headingOffsets[middle].top <= threshold) { low = middle + 1; }
      else { high = middle; }
    }
    return headingOffsets[Math.max(0, low - 1)].id;
  }
  const writeRoot = document.getElementById('write');
  if (writeRoot) {
    new ResizeObserver(invalidateHeadings).observe(writeRoot);
    new MutationObserver(invalidateHeadings).observe(writeRoot, { childList: true, subtree: true, attributes: true, characterData: true });
  }
  document.addEventListener('load', invalidateHeadings, true);
  document.addEventListener('toggle', invalidateHeadings, true);
  if (document.fonts) { document.fonts.ready.then(invalidateHeadings); }

  function scheduleReport() {
    if (pending) {
      return;
    }
    pending = true;
    if (typeof requestAnimationFrame === 'function') {
      requestAnimationFrame(report);
    }
    setTimeout(function() {
      if (pending) {
        report();
      }
    }, 0);
  }

  function scheduleClamp() {
    if (pendingClamp) {
      return;
    }
    pendingClamp = true;
    if (typeof requestAnimationFrame === 'function') {
      requestAnimationFrame(performClamp);
    }
    setTimeout(function() {
      if (pendingClamp) {
        performClamp();
      }
    }, 0);
  }

  function isHorizontallyScrollable(element) {
    if (!element || element === document.body || element === document.documentElement) {
      return false;
    }
    if (element.scrollWidth > element.clientWidth + 1) {
      var overflowX = window.getComputedStyle(element).overflowX;
      return overflowX === 'auto' || overflowX === 'scroll';
    }
    return false;
  }

  window.addEventListener('scroll', function() {
    scheduleClamp();
    scheduleReport();
  }, { passive: true });
  window.addEventListener('load', function() {
    scheduleClamp();
    scheduleReport();
  }, { once: true });
  window.addEventListener('resize', function() {
    invalidateHeadings();
    scheduleClamp();
    scheduleReport();
  });
  // GitHub-style copy button on fenced code blocks; copying goes
  // through the native pasteboard so no clipboard permission applies.
  function installCopyButtons() {
    var fences = document.querySelectorAll('#write pre.md-fences');
    for (var i = 0; i < fences.length; i++) {
      (function(fence) {
        if (fence.querySelector('.md-copy-button')) {
          return;
        }
        var button = document.createElement('button');
        button.className = 'md-copy-button';
        button.setAttribute('data-wafer-chrome', 'true');
        button.type = 'button';
        button.textContent = 'Copy';
        button.setAttribute('aria-label', 'Copy code block');
        button.addEventListener('click', function(event) {
          event.preventDefault();
          var codeNode = fence.querySelector('code');
          var text = codeNode ? codeNode.innerText : '';
          window.webkit.messageHandlers.waferCopyCode.postMessage(text);
          button.textContent = 'Copied';
          button.classList.add('is-copied');
          setTimeout(function() {
            button.textContent = 'Copy';
            button.classList.remove('is-copied');
          }, 1400);
        });
        fence.appendChild(button);
      })(fences[i]);
    }
  }
  installCopyButtons();
  // Edit mode patches #write in place; give new code blocks buttons too.
  if (writeRoot) {
    var copyButtonsPending = false;
    new MutationObserver(function() {
      if (copyButtonsPending) { return; }
      copyButtonsPending = true;
      setTimeout(function() { copyButtonsPending = false; installCopyButtons(); }, 0);
    }).observe(writeRoot, { childList: true });
  }

  // Middle-clicks never reach the navigation policy delegate, so
  // report them from the page for open-in-new-tab handling.
  document.addEventListener('auxclick', function(event) {
    if (event.button !== 1) {
      return;
    }
    var anchor = event.target instanceof Element ? event.target.closest('a[href]') : null;
    if (!anchor) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    window.webkit.messageHandlers.waferOpenLinkInNewTab.postMessage(anchor.href);
  }, true);

  window.addEventListener('wheel', function(event) {
    if (Math.abs(event.deltaX) > 0) {
      var node = event.target instanceof Element ? event.target : null;
      while (node && node !== document.body) {
        if (isHorizontallyScrollable(node)) {
          return;
        }
        node = node.parentElement;
      }
      event.preventDefault();
      scheduleClamp();
    }
  }, { passive: false });

  scheduleClamp();
  scheduleReport();
})();
