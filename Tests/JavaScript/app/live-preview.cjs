// Run the shipped installer with a small controlled DOM, without npm dependencies.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../../Sources/WaferApp/Resources/Scripts/reader-live-preview.js'), 'utf8');

class Block {
  constructor(tag, attrs, text) {
    this.nodeType = 1; this.tagName = tag.toUpperCase(); this.attrs = attrs;
    this.textContent = text; this.parentNode = null;
  }
  get outerHTML() { return `<${this.tagName.toLowerCase()}${Object.entries(this.attrs).map(([k,v]) => ` ${k}="${v}"`).join('')}>${this.textContent}</${this.tagName.toLowerCase()}>`; }
  get nextSibling() { return this.parentNode?.childNodes[this.parentNode.childNodes.indexOf(this) + 1] || null; }
  getAttribute(key) { return this.attrs[key] ?? null; }
  hasAttribute(key) { return key in this.attrs; }
  setAttribute(key, value) { this.attrs[key] = value; }
  removeAttribute(key) { delete this.attrs[key]; }
  matches(selector) { return (this.attrs.class || '').split(' ').includes(selector.slice(1)); }
  querySelectorAll() { return []; }
  getElementsByTagName() { return []; }
  remove() { const parent = this.parentNode; if (parent) parent.childNodes.splice(parent.childNodes.indexOf(this), 1); this.parentNode = null; }
  replaceWith(other) { const parent = this.parentNode; parent.insertBefore(other, this); this.remove(); }
}
function parse(html) {
  return [...html.matchAll(/<(\w+)([^>]*)>(.*?)<\/\1>/gs)].map(([, tag, attrs, text]) =>
    new Block(tag, Object.fromEntries([...attrs.matchAll(/([\w-]+)="([^"]*)"/g)].map(([, k, v]) => [k, v])), text));
}
function fixture(html = '<p data-source-line="1">A</p><p data-source-line="10">B</p>') {
  const container = { childNodes: parse(html), insertBefore(node, anchor) {
    node.remove(); const index = anchor ? this.childNodes.indexOf(anchor) : this.childNodes.length;
    this.childNodes.splice(index, 0, node); node.parentNode = this;
  }};
  container.childNodes.forEach(node => { node.parentNode = container; });
  const events = new Map();
  const annotations = [
    { line: 1, top: 20, height: 100 }, { line: 20, top: 350, height: 150 },
    { line: 50, top: 1100, height: 500 }, { line: 90, top: 2100, height: 400 }
  ];
  let measurements = 0;
  const context = {
    window: { scrollY: 0, innerHeight: 500, scrollTo(x, y) { this.scrollY = y; },
      addEventListener(name, fn) { events.set(name, fn); } },
    document: { scrollingElement: { scrollHeight: 3000 },
      getElementById: () => container,
      createElement: () => ({ set innerHTML(value) { this.content = { childNodes: parse(value) }; } }),
      addEventListener(name, fn) { events.set(name, fn); },
      querySelectorAll: () => annotations.map(item => ({
        getAttribute: () => String(item.line), getClientRects: () => [1],
        getBoundingClientRect() { measurements++; return { top: item.top - context.window.scrollY, height: item.height }; }
      })) },
    performance: { now: () => 0 },
    MutationObserver: class { constructor(callback) { events.set('mutation', callback); } observe() {} },
  };
  vm.runInNewContext(source, context);
  return { live: context.window.waferLive, container, context, events, annotations, measurements: () => measurements };
}
const a = '<p data-source-line="1">A</p>', b = '<p data-source-line="10">B</p>';
{
  const f = fixture(); const [oldA, oldB] = f.container.childNodes;
  assert.equal(f.live.patch(a + b, null, null), 'reload');
  assert.equal(f.live.patch(a + '<p data-source-line="5">C</p>' + b, a + b, null), 'patched:1');
  assert.equal(f.container.childNodes[0], oldA); assert.equal(f.container.childNodes[2], oldB);
  assert.equal(f.live.patch('<p data-source-line="2">B</p><p data-source-line="7">C</p><p data-source-line="11">A</p>', null, null), 'patched:0');
  assert.equal(f.container.childNodes[0], oldB); assert.equal(oldB.getAttribute('data-source-line'), '2');
  assert.equal(f.container.childNodes[2], oldA); assert.equal(oldA.getAttribute('data-source-line'), '11');
  assert.equal(f.live.patch('<p>B</p><p>C</p><p>A</p>', null, null), 'patched:0');
  assert.equal(oldA.hasAttribute('data-source-line'), false);
  assert.equal(f.live.patch('<p data-source-line="1">B</p><p data-source-line="2">C</p><p data-source-line="3">A</p>', null, null), 'patched:0');
  assert.equal(oldA.getAttribute('data-source-line'), '3');
}
{
  const f = fixture(); const original = [...f.container.childNodes];
  assert.equal(f.live.patch('<figure class="md-mermaid-diagram">diagram</figure>', a + b, null), 'reload');
  assert.deepEqual(f.container.childNodes, original, 'missing renderer leaves DOM untouched');
  f.context.window.waferRenderMermaidFigures = () => Promise.resolve();
  assert.equal(f.live.patch('<figure class="md-mermaid-diagram">diagram</figure>', a + b, null), 'patched:1');
}
{
  const f = fixture(); const positions = [1, 81, 12, 100]; // top, bottom, visible, total
  let previous = -Infinity;
  for (let line = 1; line <= 81; line += 0.25) {
    assert.equal(f.live.scrollToLine(line, ...positions), true);
    const y = f.context.window.scrollY;
    assert.ok(y >= previous - 1, 'mapping stays monotonic'); previous = y;
    // scrollTo only changes offsets by >= 1 px, so allow its intentional deadband.
    const adopted = f.live.lineAtTop(...positions);
    assert.ok(Math.abs(adopted - line) < 0.3, `round trip at ${line}: ${adopted}`);
  }
  f.live.scrollToLine(1, ...positions); assert.equal(f.context.window.scrollY, 0);
  f.live.scrollToLine(81, ...positions); assert.equal(f.context.window.scrollY, 2500);
  assert.equal(f.measurements(), 4, 'mapping reuses cached geometry');
  f.annotations[1].top = 500; f.events.get('resize')();
  assert.equal(f.measurements(), 8, 'resize invalidates geometry');
  f.annotations[1].line = 25; f.events.get('mutation')();
  assert.equal(f.measurements(), 12, 'page-world patches invalidate isolated scroll geometry');
  assert.equal(f.live.scrollToLine(1, 1, 1, 10, 5), false, 'non-scrolling editor has no mapping');
}
console.log('live-preview: patch reuse, edits, line attributes, renderer fallback, scroll endpoints, monotonicity, inverse and cache passed');
