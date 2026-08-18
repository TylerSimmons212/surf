#!/bin/bash
# Checks the half of the page agent's contract that Swift can't.
#
# A method has two declarations in two languages: a case in
# `PageProtocol.Method`, and an `agent.define` in a domain script. The compiler
# sees only the first, so a name that exists on one side and not the other is a
# feature that quietly stops working — in one content world, months later.
#
# So the real scripts are dumped and installed into a real JavaScript engine,
# and asked whether they answer to everything the enum claims.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/js-check"

command -v node >/dev/null || { echo "check-js: needs node on PATH" >&2; exit 1; }

swift build --package-path "$ROOT"
BIN="$(swift build --package-path "$ROOT" --show-bin-path)/Glass"

rm -rf "$OUT"
GLASS_DUMP_SCRIPTS="$OUT" "$BIN"

# Every script has to parse before any of it can be asked anything.
for f in "$OUT"/*.js; do node --check "$f"; done

cat > "$OUT/check.mjs" <<'JS'
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const dir = process.argv[2];
const read = (f) => readFileSync(`${dir}/${f}`, 'utf8');
const handle = read('runtime-isolated.js').match(/const HANDLE = '([^']+)'/)[1];

// Enough of a document for the domains to install against. No method body
// runs here — only the `define` calls that register them.
function context() {
  const noop = () => {};
  const el = { sheet: null, remove: noop, appendChild: noop, dataset: {}, style: {} };
  const window = {
    document: {
      readyState: 'complete', addEventListener: noop, getElementById: () => null,
      querySelectorAll: () => [], createElement: () => el, documentElement: el,
      body: el, elementFromPoint: () => null, title: '',
    },
    setInterval: noop, setTimeout: noop, navigator: {}, innerWidth: 1000,
    location: { hostname: 'example.com' }, getSelection: () => null,
    getComputedStyle: () => ({ backgroundColor: 'rgba(0,0,0,0)' }),
    webkit: { messageHandlers: {} },
    Object, JSON, Array, Math, String, Number, isFinite,
    HTMLMediaElement: class {}, MutationObserver: class {},
  };
  window.window = window;
  return vm.createContext(window);
}

const worlds = {
  isolated: ['runtime-isolated.js', 'theme.js', 'page.js'],
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

for (const { name, world } of JSON.parse(read('methods.json'))) {
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
  for (const f of ['runtime-isolated.js', 'theme.js', 'page.js']) {
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

if (bad) { console.error(`check-js: ${bad} problem(s)`); process.exit(1); }
console.log('check-js: Swift and JavaScript agree on every method');
JS

node "$OUT/check.mjs" "$OUT"
