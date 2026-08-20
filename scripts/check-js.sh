#!/bin/bash
# Checks the half of the injected contracts that Swift can't.
#
# A method has two declarations in two languages — a case in an enum, and a
# registration in a script — and the compiler sees only the first. A name that
# exists on one side and not the other is a feature that quietly stops working,
# in one content world, months later.
#
# Two contracts are checked, because there are two: `PageProtocol.Method`
# against the always-resident page agent, and `DevToolsMethod` against the
# three scripts dev tools installs while it is attached.
#
# So the real scripts are dumped and installed into a real JavaScript engine,
# and asked whether they answer to everything the enums claim.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/js-check"

command -v node >/dev/null || { echo "check-js: needs node on PATH" >&2; exit 1; }

swift build --package-path "$ROOT"
BIN="$(swift build --package-path "$ROOT" --show-bin-path)/Surf"

rm -rf "$OUT"
SURF_DUMP_SCRIPTS="$OUT" "$BIN"

# Every script has to parse before any of it can be asked anything.
for f in "$OUT"/*.js; do node --check "$f"; done

cat > "$OUT/check.mjs" <<'JS'
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const dir = process.argv[2];
const read = (f) => readFileSync(`${dir}/${f}`, 'utf8');
const pageAgent = JSON.parse(read('methods.json'));
const handle = pageAgent.handle;

// Enough of a document for the domains to install against. No method body
// runs here — only the `define` calls that register them.
function context() {
  const noop = () => {};
  const el = { sheet: null, remove: noop, appendChild: noop, dataset: {}, style: {} };
  const window = {
    document: {
      readyState: 'complete', addEventListener: noop, getElementById: () => null,
      querySelectorAll: () => [], querySelector: () => null,
      createElement: () => el, documentElement: el,
      body: el, elementFromPoint: () => null, title: '',
    },
    setInterval: noop, clearInterval: noop, setTimeout: noop, navigator: {},
    innerWidth: 1000, location: { hostname: 'example.com' },
    getSelection: () => null, addEventListener: noop, removeEventListener: noop,
    postMessage: noop, performance: { now: () => 0 },
    getComputedStyle: () => ({ backgroundColor: 'rgba(0,0,0,0)' }),
    webkit: { messageHandlers: {} },
    Object, JSON, Array, Math, String, Number, isFinite,
    HTMLMediaElement: class {}, MutationObserver: class {},
  };
  window.window = window;
  // The media domain asks whether it is the top frame, and answers frame
  // offsets differently if it isn't. Stubbed as the top one.
  window.top = window;
  window.parent = window;
  return vm.createContext(window);
}

const worlds = {
  // focus-extract.js is not resident — Tab.enterFocus() evaluates it on
  // demand — but it registers focus.extract and focus.reveal against the
  // same agent, so it installs here like everything else, beside capture.js,
  // main's lazy domain with the same arrangement.
  isolated: ['runtime-isolated.js', 'theme.js', 'page.js', 'capture.js',
             'focus.js', 'focus-extract.js'],
  page: ['runtime-page.js', 'media.js', 'find.js'],
};

const agents = {};
for (const [world, files] of Object.entries(worlds)) {
  const ctx = context();
  for (const f of files) vm.runInContext(read(f), ctx, { filename: f });
  if (!ctx[handle]) throw new Error(`${world} world: the agent never installed`);
  agents[world] = ctx[handle];
}

let bad = 0;
const fail = (message) => { console.error(`  ${message}`); bad++; };

for (const { name, world } of pageAgent.methods) {
  const reply = JSON.parse(await agents[world].dispatch(name, {}));
  if (reply.ok === false && /no such method/.test(reply.error || '')) {
    fail(`${name} is declared in Swift but never registered in the ${world} world`);
  }
}

// The reply a page still parsing gives back has to satisfy the same type as a
// finished one. It didn't, once: `images` was missing, so the survey couldn't
// be decoded at all and the Swift-side "still parsing" branch was unreachable.
// Nothing said so, because the call site swallowed the decode failure.
// Keys mirror `ThemeBridge.Survey`.
{
  const ctx = context();
  ctx.document.readyState = 'loading';
  for (const f of ['runtime-isolated.js', 'theme.js', 'page.js', 'capture.js']) {
    vm.runInContext(read(f), ctx, { filename: f });
  }
  const reply = JSON.parse(await ctx[handle].dispatch('theme.collect', {}));
  for (const key of ['ground', 'themed', 'ready', 'colors', 'images']) {
    if (!(key in (reply.value || {}))) {
      fail(`theme.collect omits "${key}" while the document is still parsing`);
    }
  }
}

// A method must not answer from the world it doesn't belong to.
if (JSON.parse(await agents.page.dispatch('theme.collect', {})).ok !== false) {
  fail('a theme method answered in the page world');
}

// And an unknown name has to come back as a reported failure rather than as
// silence, or the Swift side can't tell it from a page with nothing to say.
if (JSON.parse(await agents.isolated.dispatch('theme.nope', {})).ok !== false) {
  fail('an unknown method did not report a failure');
}

// ---- Dev tools -----------------------------------------------------------
//
// Four times the surface, and the half where routing has already gone wrong:
// `DevToolsTarget` carries a note about evaluation being sent to the wrong
// world and failing as "unknown method", which reads like a missing feature
// rather than a misroute. Nothing catches that today.
//
// The dispatch sources are the real ones, dumped from Swift rather than
// re-described here, so this exercises the same path `DevToolsBridge` does —
// including the `if (!globalThis.X) return null` guard.

// A far larger stub than the page agent needs: these scripts wrap `fetch`,
// install observers and walk the DOM as they install. Kept separate from
// `context()` so growing it can't disturb a check that already works.
function devToolsContext() {
  const noop = () => {};
  const el = {
    style: { setProperty: noop, removeProperty: noop, getPropertyValue: () => '' },
    dataset: {}, attributes: [], childNodes: [], children: [],
    getAttribute: () => null, setAttribute: noop, removeAttribute: noop,
    appendChild: noop, remove: noop, addEventListener: noop, removeEventListener: noop,
    getBoundingClientRect: () => ({ x: 0, y: 0, width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0 }),
    getElementsByTagName: () => [], querySelectorAll: () => [], querySelector: () => null,
    matches: () => false, contains: () => false, nodeType: 1, tagName: 'DIV', localName: 'div',
  };
  const document = {
    ...el, documentElement: el, body: el, head: el, readyState: 'complete',
    createElement: () => ({ ...el }), createTextNode: () => ({ ...el }),
    getElementById: () => null, styleSheets: [], adoptedStyleSheets: [],
    title: '', cookie: '', createTreeWalker: () => ({ nextNode: () => null }),
  };
  const g = {
    document,
    location: { href: 'https://example.com/', hostname: 'example.com', origin: 'https://example.com' },
    navigator: { userAgent: 'stub', storage: {} },
    performance: { now: () => 0, getEntries: () => [], getEntriesByType: () => [], timeOrigin: 0, mark: noop, measure: noop },
    console: { log: noop, warn: noop, error: noop, info: noop, debug: noop },
    setTimeout: noop, clearTimeout: noop, setInterval: noop, clearInterval: noop,
    requestAnimationFrame: noop, cancelAnimationFrame: noop,
    addEventListener: noop, removeEventListener: noop,
    getComputedStyle: () => ({ getPropertyValue: () => '', length: 0 }),
    MutationObserver: class { observe() {} disconnect() {} takeRecords() { return []; } },
    PerformanceObserver: class { observe() {} disconnect() {} },
    ResizeObserver: class { observe() {} disconnect() {} },
    IntersectionObserver: class { observe() {} disconnect() {} },
    XMLHttpRequest: class { open() {} send() {} setRequestHeader() {} addEventListener() {} },
    fetch: () => Promise.resolve({}),
    Request: class {}, Response: class {},
    Headers: class { forEach() {} entries() { return []; } },
    CSSStyleSheet: class { replaceSync() {} get cssRules() { return []; } },
    Element: class {}, Node: class {}, HTMLElement: class {}, Text: class {}, ShadowRoot: class {},
    CSS: { escape: (s) => s, supports: () => false },
    localStorage: { length: 0, key: () => null, getItem: () => null, setItem: noop, removeItem: noop, clear: noop },
    sessionStorage: { length: 0, key: () => null, getItem: () => null, setItem: noop, removeItem: noop, clear: noop },
    indexedDB: { databases: () => Promise.resolve([]) },
    caches: { keys: () => Promise.resolve([]) },
    webkit: { messageHandlers: new Proxy({}, { get: () => ({ postMessage: noop }) }) },
    innerWidth: 1200, innerHeight: 800, devicePixelRatio: 2,
  };
  g.window = g; g.globalThis = g; g.self = g;
  return vm.createContext(g);
}

const devTools = JSON.parse(read('devtools.json'));
const dispatchers = {};

for (const [target, file] of Object.entries(devTools.scripts)) {
  const ctx = devToolsContext();
  try {
    vm.runInContext(read(file), ctx, { filename: file });
  } catch (error) {
    fail(`${file} threw while installing the ${target} target — ${error.message}`);
    continue;
  }
  dispatchers[target] = vm.runInContext(
    `(async (method, params) => { ${devTools.dispatch[target]} })`,
    ctx, { filename: `dispatch-${target}.js` }
  );
}

// `null` is the dispatcher's own "I am not here" — distinct from a registered
// method that answered, and from one that isn't registered at all.
const answers = async (target, name) => {
  const dispatch = dispatchers[target];
  if (!dispatch) { return false; }
  const raw = await dispatch(name, {});
  if (raw === null) { return false; }
  let reply;
  try { reply = JSON.parse(raw); } catch { return true; }
  // One runtime, so one spelling. Every injected script reports an
  // unregistered name the same way now.
  return !(typeof reply?.error === 'string' && /no such method/.test(reply.error));
};

for (const { name, target } of devTools.methods) {
  if (!(await answers(target, name))) {
    fail(`${name} is declared in Swift but the ${target} script never registers it`);
  }
  // The documented failure: right name, wrong dispatcher. Silence from the
  // other two is what makes the routing table meaningful.
  for (const other of Object.keys(dispatchers)) {
    if (other === target) { continue; }
    if (await answers(other, name)) {
      fail(`${name} is routed to ${target} but the ${other} script also answers it`);
    }
  }
}

// The envelope itself, on the three cheapest read-only methods. Registration
// says a name is known; this says a caller can actually read the answer —
// which is the half that changed when dev tools stopped returning its payload
// bare and started returning it under `ok`/`value`.
for (const [target, method] of [
  ['agent', 'Runtime.ping'], ['page', 'Console.drain'], ['network', 'Network.drain'],
]) {
  const raw = await dispatchers[target]?.(method, {});
  let reply;
  try { reply = JSON.parse(raw); } catch { reply = null; }
  if (reply?.ok !== true) {
    fail(`${method} did not answer with ok:true — got ${JSON.stringify(reply)}`);
  } else if (reply.value === undefined) {
    fail(`${method} answered ok but carried no value key`);
  }
}

// Rule handles must be held strongly.
//
// A source check rather than a behavioural one, which is weaker than this
// file's other tests and deliberate: reproducing it needs a live CSSOM, and
// the bug it guards is worth catching cheaply. Rule ids were once held as
// WeakRefs on the theory that the stylesheet keeps its wrappers alive. It
// does not — the collector took every id minted while reading the Styles
// pane, so editing anything you had just looked at failed with "no rule"
// and the panel drew the edit as though it had landed.
{
  const source = Object.values(devTools.scripts).map(read).join('\n');
  const handles = source.slice(
    Math.max(0, source.indexOf('const ruleRefs')),
    source.indexOf('function applyStyleText')
  );
  if (/WeakRef/.test(handles)) {
    fail('rule handles are held weakly again — an id will not survive to be edited');
  }
}

if (bad) { console.error(`check-js: ${bad} problem(s)`); process.exit(1); }
console.log(
  `check-js: Swift and JavaScript agree — ` +
  `${pageAgent.methods.length} page-agent methods, ` +
  `${devTools.methods.length} dev tools methods`
);
JS

node "$OUT/check.mjs" "$OUT"

# ---- Size budgets ----------------------------------------------------------
#
# Every byte here is parsed and evaluated at documentStart on real pages —
# most of it in every frame — so growth is a per-page-load performance cost,
# not a download cost. Ceilings are current size plus headroom; raising one
# should be a deliberate act with a reason, not a side effect of a feature.
BUDGET_FAIL=0
check_size() {
    local file="$1" budget="$2"
    local size
    size=$(wc -c < "$OUT/$file" | tr -d ' ')
    if [ "$size" -gt "$budget" ]; then
        echo "check-js: $file is ${size} bytes — over its ${budget}-byte budget." >&2
        BUDGET_FAIL=1
    fi
}
# Injected into every frame of every page.
check_size theme.js              34000
check_size block.js              14000
# Raised from 12000 when theater mode landed, and again to 16000 when it
# learned to survive hostile players (14451 at the time): stylesheet-based
# staging, ancestor neutralisation, and lights-out all have to run where the
# element lives, which is here.
check_size media.js              16000
check_size runtime-isolated.js    3000
check_size runtime-page.js        3000
check_size page.js                3000
# Injected on first use of the screenshot pick, never at page load — this
# budget bounds feature creep, not per-page cost.
check_size capture.js             6000
check_size find.js                2000
# Main frame only.
check_size console.js            40000
check_size network.js            33000
check_size preflight.js           2000
check_size focus.js               3000
# Not resident at all — evaluated once, on the pages the user focuses — so
# like devtools.js this budgets feature growth rather than per-page cost.
check_size focus-extract.js      16000
# Only while dev tools are attached — never on ordinary pages, so this one
# budgets feature growth rather than per-page cost. Raised from 70000 when
# the elements-pane work landed (74683 bytes at the time).
check_size devtools.js           90000
if [ "$BUDGET_FAIL" -ne 0 ]; then
    echo "check-js: injected-script size budget exceeded — trim the script or raise the budget deliberately." >&2
    exit 1
fi
