// Execute the actual injected reader script with a controlled layout and scheduler.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const script = fs.readFileSync(path.join(__dirname, '../../../Sources/WaferApp/Resources/Scripts/reader-scroll.js'), 'utf8');
function fixture(frameFirst) {
  const timers = [], frames = [], messages = [], events = new Map();
  let queries = 0, rectangles = 0, resize;
  const context = {
    window: { scrollX: 0, scrollY: 0, innerHeight: 700, scrollTo() {},
      addEventListener(name, callback) { events.set(name, callback); },
      webkit: { messageHandlers: new Proxy({}, { get: (_, name) => ({ postMessage: value => messages.push([name, value]) }) }) } },
    document: { scrollingElement: { scrollHeight: 400000 },
      querySelectorAll(selector) {
        if (!selector.startsWith('#write h1')) return [];
        queries++;
        return Array.from({length: 10000}, (_, index) => ({ id: 'heading-' + index,
          getClientRects: () => [1], getBoundingClientRect() { rectangles++; return {top: index * 40 - context.window.scrollY}; }
        }));
      }, getElementById: () => ({}), addEventListener() {} },
    ResizeObserver: class { constructor(callback) { resize = callback; } observe() {} },
    MutationObserver: class { observe() {} },
    requestAnimationFrame: callback => frames.push(callback),
    setTimeout: callback => timers.push(callback),
  };
  function flush() {
    const first = frameFirst ? frames : timers, second = frameFirst ? timers : frames;
    first.splice(0).forEach(fn => fn()); second.splice(0).forEach(fn => fn());
  }
  vm.runInNewContext(script, context);
  flush();
  assert.equal(messages.length, 2, 'one report despite both timer and frame callbacks');
  for (let index = 1; index <= 100; index++) {
    context.window.scrollY = index * 40;
    events.get('scroll')(); flush();
  }
  assert.equal(messages.length, 202);
  assert.equal(queries, 1);
  assert.equal(rectangles, 10000, 'scroll events never measure headings again');
  assert.equal(messages.at(-1)[1], 'heading-100');
  resize(); flush();
  assert.equal(queries, 2, 'layout changes invalidate the heading cache');
  console.log(`${frameFirst ? 'frame-first' : 'timer-first'}: 101 reports, 1 heading query, 10000 rectangle reads before layout invalidation; passed`);
}
fixture(false);
fixture(true);
