if (!window.waferLive) {
  window.waferLive = (function() {
    var lineAttribute = /\sdata-source-line="\d+"/g;
    var state = null;
    // Scroll sync: cached annotated blocks, the synced editor position,
    // the offset of our own last scroll (so its event is not taken for
    // the user's), and when the user last scrolled the preview.
    var targets = null;
    var sync = null;
    var active = false;
    var expectedY = null;
    var lastPreviewScroll = -Infinity;

    function isSignificant(node) {
      return node.nodeType === 1 || (node.nodeType === 3 && node.textContent.trim() !== '');
    }
    function significantChildren(parent) {
      return Array.prototype.filter.call(parent.childNodes, isSignificant);
    }
    function rawHTML(node) {
      return node.nodeType === 1 ? node.outerHTML : '#text:' + node.textContent;
    }
    function keyOf(raw) {
      return raw.replace(lineAttribute, '');
    }
    function parse(html) {
      var template = document.createElement('template');
      template.innerHTML = html;
      return significantChildren(template.content);
    }
    function annotated(node) {
      if (node.nodeType !== 1) { return []; }
      var list = node.hasAttribute('data-source-line') ? [node] : [];
      return list.concat(Array.prototype.slice.call(node.querySelectorAll('[data-source-line]')));
    }
    function setLine(element, value) {
      if (value === null) { element.removeAttribute('data-source-line'); }
      else { element.setAttribute('data-source-line', value); }
    }
    function syncLineAttributes(oldNode, newNode) {
      if (oldNode.nodeType !== 1 || newNode.nodeType !== 1) { return oldNode.nodeType === newNode.nodeType; }
      var from = annotated(newNode);
      var to = annotated(oldNode);
      if (from.length === to.length) {
        for (var index = 0; index < from.length; index++) {
          to[index].setAttribute('data-source-line', from[index].getAttribute('data-source-line'));
        }
        return true;
      }
      // The annotated set changed (entering or leaving edit mode on the
      // same content): pair elements by tag and position instead.
      var tags = {};
      from.concat(to).forEach(function(element) {
        if (element !== newNode && element !== oldNode) { tags[element.tagName] = true; }
      });
      var pairs = [[oldNode, newNode]];
      for (var tag in tags) {
        var oldList = oldNode.getElementsByTagName(tag);
        var newList = newNode.getElementsByTagName(tag);
        if (oldList.length !== newList.length) { return false; }
        for (var position = 0; position < oldList.length; position++) {
          pairs.push([oldList[position], newList[position]]);
        }
      }
      pairs.forEach(function(pair) { setLine(pair[0], pair[1].getAttribute('data-source-line')); });
      return true;
    }
    function collect(nodes, selector) {
      var found = [];
      nodes.forEach(function(node) {
        if (node.nodeType !== 1) { return; }
        if (node.matches(selector)) { found.push(node); }
        found = found.concat(Array.prototype.slice.call(node.querySelectorAll(selector)));
      });
      return found;
    }

    function patch(html, previous, position) {
      var container = document.getElementById('write');
      if (!container) { return 'reload'; }
      var current = significantChildren(container);
      if (!state) {
        if (previous === null || previous === undefined) { return 'reload'; }
        var previousRaws = parse(previous).map(rawHTML);
        if (previousRaws.length !== current.length) { return 'reload'; }
        state = { raws: previousRaws, keys: previousRaws.map(keyOf) };
      }
      if (state.keys.length !== current.length) { state = null; return 'reload'; }

      var nextNodes = parse(html);
      var nextRaws = nextNodes.map(rawHTML);
      var nextKeys = nextRaws.map(keyOf);
      var oldKeys = state.keys;
      var prefix = 0;
      while (prefix < oldKeys.length && prefix < nextKeys.length && oldKeys[prefix] === nextKeys[prefix]) {
        prefix++;
      }
      var suffix = 0;
      while (
        suffix < oldKeys.length - prefix && suffix < nextKeys.length - prefix &&
        oldKeys[oldKeys.length - 1 - suffix] === nextKeys[nextKeys.length - 1 - suffix]
      ) {
        suffix++;
      }

      // Inside the changed middle, reuse any old block whose key still
      // appears (edits at several places, moved blocks); build the plan
      // first so nothing is mutated if a renderer is missing.
      var middleEnd = current.length - suffix;
      var pool = {};
      for (var oldIndex = prefix; oldIndex < middleEnd; oldIndex++) {
        (pool[oldKeys[oldIndex]] = pool[oldKeys[oldIndex]] || []).push(oldIndex);
      }
      var plan = [];
      var reused = {};
      for (var newIndex = prefix; newIndex < nextNodes.length - suffix; newIndex++) {
        var candidates = pool[nextKeys[newIndex]];
        if (candidates && candidates.length) {
          var match = candidates.shift();
          reused[match] = true;
          plan.push({ oldIndex: match, newIndex: newIndex });
        } else {
          plan.push({ oldIndex: -1, newIndex: newIndex });
        }
      }
      var insertedNodes = plan.filter(function(step) { return step.oldIndex < 0; })
        .map(function(step) { return nextNodes[step.newIndex]; });
      var figures = collect(insertedNodes, '.md-mermaid-diagram');
      var mathBlocks = collect(insertedNodes, '.md-math-display');
      if (figures.length && typeof window.waferRenderMermaidFigures !== 'function') { return 'reload'; }
      if (mathBlocks.length && typeof window.waferRenderMathBlocks !== 'function') { return 'reload'; }

      var anchor = suffix > 0 ? current[middleEnd] : null;
      for (var removeIndex = prefix; removeIndex < middleEnd; removeIndex++) {
        if (!reused[removeIndex]) { current[removeIndex].remove(); }
      }

      function refreshKept(oldIndex, newIndex) {
        if (state.raws[oldIndex] === nextRaws[newIndex]) { return; }
        if (!syncLineAttributes(current[oldIndex], nextNodes[newIndex])) {
          current[oldIndex].replaceWith(nextNodes[newIndex]);
          figures = figures.concat(collect([nextNodes[newIndex]], '.md-mermaid-diagram'));
          mathBlocks = mathBlocks.concat(collect([nextNodes[newIndex]], '.md-math-display'));
        }
      }
      plan.forEach(function(step) {
        var node = step.oldIndex < 0 ? nextNodes[step.newIndex] : current[step.oldIndex];
        if (node.nextSibling !== anchor || node.parentNode !== container) {
          container.insertBefore(node, anchor);
        }
        if (step.oldIndex >= 0) { refreshKept(step.oldIndex, step.newIndex); }
      });
      for (var keptIndex = 0; keptIndex < prefix; keptIndex++) {
        refreshKept(keptIndex, keptIndex);
      }
      for (var tail = 0; tail < suffix; tail++) {
        refreshKept(current.length - 1 - tail, nextNodes.length - 1 - tail);
      }

      state = { raws: nextRaws, keys: nextKeys };
      targets = null;
      if (mathBlocks.length) { window.waferRenderMathBlocks(mathBlocks); }
      if (figures.length) {
        Promise.resolve(window.waferRenderMermaidFigures(figures)).then(resync, resync);
      }
      // The edit that caused this patch is the editor's: it leads.
      if (position && active) { sync = position; lastPreviewScroll = -Infinity; }
      apply();
      return 'patched:' + insertedNodes.length;
    }

    function scrollLimit() {
      var root = document.scrollingElement || document.documentElement;
      return Math.max(root.scrollHeight - window.innerHeight, 0);
    }
    // Annotated blocks as { line, top, height }, sorted by line with
    // non-decreasing tops so the mapping below stays monotonic.
    function collectTargets() {
      var list = [];
      var scrollY = window.scrollY;
      Array.prototype.forEach.call(document.querySelectorAll('#write [data-source-line]'), function(element) {
        var line = parseInt(element.getAttribute('data-source-line'), 10);
        if (isNaN(line) || element.getClientRects().length === 0) { return; }
        var rect = element.getBoundingClientRect();
        list.push({ line: line, top: rect.top + scrollY, height: rect.height });
      });
      list.sort(function(a, b) { return a.line - b.line; });
      for (var index = 1; index < list.length; index++) {
        if (list[index].top < list[index - 1].top) { list[index].top = list[index - 1].top; }
      }
      return list;
    }
    // Document offset of a fractional source line, interpolated between
    // the annotated blocks around it.
    function rawOffset(line, totalLines) {
      var low = 0;
      var high = targets.length;
      while (low < high) {
        var middle = (low + high) >> 1;
        if (targets[middle].line <= line) { low = middle + 1; } else { high = middle; }
      }
      if (low === 0) {
        var first = targets[0];
        return first.line > 1 ? first.top * Math.max(0, line - 1) / (first.line - 1) : 0;
      }
      var previous = targets[low - 1];
      if (low < targets.length) {
        var next = targets[low];
        return previous.top + (next.top - previous.top) * (line - previous.line) / (next.line - previous.line);
      }
      var span = Math.max(1, (totalLines || previous.line) - previous.line + 1);
      return previous.top + previous.height * Math.min(1, (line - previous.line) / span);
    }
    function smooth(value) {
      var t = Math.min(1, Math.max(0, value));
      return t * t * (3 - 2 * t);
    }
    // Editor line <-> preview offset for one editor geometry. The editor
    // scrolls from topLine to bottomLine; those map to 0 and the preview's
    // scroll limit, and the correction this needs fades over `ramp` lines
    // at each end. Null when there is nothing to map (no annotated
    // blocks, or an editor that cannot scroll).
    function mapping(position) {
      if (!targets) { targets = collectTargets(); }
      var span = position.bottomLine - position.topLine;
      if (!targets.length || !(span > 0.001)) { return null; }
      var limit = scrollLimit();
      function clamped(line) {
        return Math.min(Math.max(rawOffset(line, position.totalLines), 0), limit);
      }
      var startExcess = clamped(position.topLine);
      var endGap = limit - clamped(position.bottomLine);
      var ramp = Math.max(Math.min(position.visibleLines > 0 ? position.visibleLines : span, span / 2), 0.001);
      function offsetFor(line) {
        if (line <= position.topLine) { return 0; }
        if (line >= position.bottomLine) { return limit; }
        var offset = clamped(line)
          - startExcess * (1 - smooth((line - position.topLine) / ramp))
          + endGap * smooth((line - position.bottomLine + ramp) / ramp);
        return Math.min(Math.max(offset, 0), limit);
      }
      function lineFor(offset) {
        var low = position.topLine;
        var high = position.bottomLine;
        if (offset <= 0) { return low; }
        for (var step = 0; step < 40; step++) {
          var middle = (low + high) / 2;
          if (offsetFor(middle) < offset) { low = middle; } else { high = middle; }
        }
        return high;
      }
      return { offsetFor: offsetFor, lineFor: lineFor };
    }

    function makePosition(line, topLine, bottomLine, visibleLines, totalLines) {
      return { line: line, topLine: topLine, bottomLine: bottomLine, visibleLines: visibleLines, totalLines: totalLines };
    }
    // Moves the preview to the synced line.
    function apply() {
      if (!active || !sync) { return false; }
      var map = mapping(sync);
      if (!map) { return false; }
      var offset = map.offsetFor(sync.line);
      // Remembered even when already there: if the page then clamps its
      // offset to this value, that scroll is not the user's either.
      expectedY = offset;
      if (Math.abs(window.scrollY - offset) >= 1) { window.scrollTo(0, offset); }
      return true;
    }
    // Takes the preview's current offset as the synced line.
    function adopt(report) {
      if (!active || !sync) { return null; }
      var map = mapping(sync);
      if (!map) { return null; }
      sync.line = map.lineFor(window.scrollY);
      if (report) {
        var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.waferLiveScroll;
        if (handler) { handler.postMessage(sync.line); }
      }
      return sync.line;
    }
    function previewLeads() {
      return performance.now() - lastPreviewScroll < 250;
    }
    function scrollToLine(line, topLine, bottomLine, visibleLines, totalLines) {
      active = true;
      sync = makePosition(line, topLine, bottomLine, visibleLines, totalLines);
      lastPreviewScroll = -Infinity;
      return apply();
    }
    function updateMetrics(topLine, bottomLine, visibleLines, totalLines) {
      if (!sync) { return false; }
      sync = makePosition(sync.line, topLine, bottomLine, visibleLines, totalLines);
      return true;
    }
    function lineAtTop(topLine, bottomLine, visibleLines, totalLines) {
      active = true;
      sync = makePosition(topLine, topLine, bottomLine, visibleLines, totalLines);
      return adopt(false);
    }
    function setActive(flag) {
      active = flag;
      if (!flag) { sync = null; expectedY = null; }
    }
    // Layout changed (async diagram, image, resize): keep whichever pane
    // the user is driving where it is and realign the other.
    function resync() {
      targets = null;
      if (previewLeads()) { adopt(true); } else { apply(); }
    }
    function handleScroll() {
      if (!active || !sync) { return; }
      if (expectedY !== null && Math.abs(window.scrollY - expectedY) < 1.5) { return; }
      expectedY = null;
      lastPreviewScroll = performance.now();
      adopt(true);
    }

    var write = document.getElementById('write');
    if (write && typeof ResizeObserver === 'function') {
      new ResizeObserver(resync).observe(write);
    }
    document.addEventListener('load', resync, true);
    document.addEventListener('toggle', resync, true);
    window.addEventListener('resize', resync);
    window.addEventListener('scroll', handleScroll, { passive: true });

    return {
      patch: patch,
      scrollToLine: scrollToLine,
      updateMetrics: updateMetrics,
      lineAtTop: lineAtTop,
      setActive: setActive,
      hasState: function() { return state !== null; }
    };
  })();
}
