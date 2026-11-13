// Run the shipped bootstrap scripts against a controlled DOM and scheduler.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const resources = path.join(__dirname, '../../../Sources/WaferCore/Resources');

function block(sourceText) {
  const classes = new Set();
  const output = { innerHTML: '', replaceChildren() { this.innerHTML = ''; } };
  const error = { hidden: true, textContent: '' };
  const button = { hidden: true, addEventListener() {} };
  return {
    isConnected: true,
    classList: { add: name => classes.add(name), remove: name => classes.delete(name), contains: name => classes.has(name) },
    getAttribute: () => 'diagram-1',
    querySelector(selector) {
      if (selector.endsWith(' code')) return { textContent: sourceText };
      if (selector.endsWith('-output')) return output;
      if (selector.endsWith('-error')) return error;
      if (selector.endsWith('-open')) return button;
      return null;
    }, output, error, button,
  };
}

function fixture({ diagrams = [], math = [], mermaid, katex } = {}) {
  const timers = [], frames = [], messages = [];
  const configuration = { theme: 'base', variables: { primaryColor: "'</script>" }, chromeAttributeName: 'data-wafer-chrome', chromeAttributeValue: 'true' };
  const window = {
    mermaid, katex,
    webkit: { messageHandlers: { waferContentReady: { postMessage: message => messages.push(message) } } },
    getComputedStyle: () => ({ getPropertyValue: () => '#cc0000' }),
  };
  const document = {
    currentScript: { dataset: { waferRenderer: JSON.stringify(configuration) } },
    documentElement: {},
    querySelector: () => ({ content: 'navigation-1' }),
    querySelectorAll: selector => selector === '.md-mermaid-diagram' ? diagrams : selector === '.md-math-display' ? math : [],
  };
  const context = vm.createContext({ window, document, setTimeout: fn => timers.push(fn), requestAnimationFrame: fn => frames.push(fn) });
  const run = name => vm.runInContext(fs.readFileSync(path.join(resources, name + '.js'), 'utf8'), context, { filename: name });
  function flush() {
    for (let i = 0; i < 10 && (timers.length || frames.length); i++) {
      timers.splice(0).forEach(fn => fn());
      frames.splice(0).forEach(fn => fn());
    }
  }
  run('async-renderer');
  return { window, messages, run, flush, configuration };
}

test('coordinator waits for all renderers and ignores duplicate completion', () => {
  const f = fixture();
  const first = f.window.waferAsyncRenderer.beginTask();
  const second = f.window.waferAsyncRenderer.beginTask();
  first(); first(); f.flush();
  assert.equal(f.messages.length, 0);
  second(); f.flush();
  assert.deepEqual(f.messages, ['navigation-1']);
});

test('Mermaid uses JSON theme data, strict mode, and renders incremental figures', async () => {
  const diagram = block('graph TD; A-->B');
  const calls = [];
  const f = fixture({ diagrams: [diagram], mermaid: {
    initialize: config => calls.push(config),
    render: async (id, source) => ({ svg: `<svg>${source}</svg>` }),
  } });
  f.run('mermaid-bootstrap');
  await new Promise(setImmediate); f.flush();
  assert.equal(calls[0].securityLevel, 'strict');
  assert.equal(calls[0].themeVariables.primaryColor, "'</script>");
  assert.equal(diagram.output.innerHTML, '<svg>graph TD; A-->B</svg>');
  assert.equal(diagram.button.hidden, false);
  assert.deepEqual(f.messages, ['navigation-1']);
  const added = block('graph TD; B-->C');
  await f.window.waferRenderMermaidFigures([added]);
  assert.equal(added.output.innerHTML, '<svg>graph TD; B-->C</svg>');
  await f.window.waferApplyMermaidTheme('dark', { primaryColor: '#123456' });
  assert.equal(calls.at(-1).theme, 'dark');
});

test('KaTeX renders source as data and supports incremental math', () => {
  const math = block('x^2 <script>');
  const calls = [];
  const f = fixture({ math: [math], katex: { render: (source, output, options) => calls.push({ source, options }) } });
  f.run('katex-bootstrap'); f.flush();
  assert.equal(calls[0].source, 'x^2 <script>');
  assert.equal(calls[0].options.displayMode, true);
  assert.equal(calls[0].options.throwOnError, false);
  assert.equal(math.classList.contains('is-rendered'), true);
  f.window.waferRenderMathBlocks([block('y^2')]);
  assert.equal(calls[1].source, 'y^2');
  assert.deepEqual(f.messages, ['navigation-1']);
});

test('missing libraries show errors and release readiness', () => {
  const diagram = block('bad'), math = block('bad');
  const f = fixture({ diagrams: [diagram], math: [math] });
  f.run('mermaid-bootstrap'); f.run('katex-bootstrap'); f.flush();
  assert.match(diagram.error.textContent, /unavailable/);
  assert.match(math.error.textContent, /unavailable/);
  assert.equal(diagram.error.hidden, false);
  assert.equal(math.error.hidden, false);
  assert.deepEqual(f.messages, ['navigation-1']);
});
