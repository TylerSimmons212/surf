import Foundation
import SurfCore
import WebKit

/// The scripts that let a page be measured and then restyled.
///
/// Everything here is deliberately thin. The decisions — what a colour is
/// doing, what it becomes, whether the result can be read — all live in
/// `SurfCore`, where they can be tested without a web view. This side only
/// gathers evidence and writes back an answer it was handed.
///
/// All of it runs in an isolated content world. The page keeps its own
/// `window`, and nothing we define can collide with, or be reached by, the
/// site's own scripts.
enum ThemeBridge {

    /// The isolated-world domain: every theme method the agent answers to.
    ///
    /// The scripts below are unchanged in substance — they are the same
    /// measuring and painting passes, registered as named methods instead of
    /// being posted as fresh source for each call. `collect` still hands back
    /// a JSON string, so it is parsed here and the agent's own envelope
    /// carries the result; that keeps the walk itself untouched.
    static var domainScript: String {
        """
        (function () {
          const agent = window['\(PageRuntime.handle)'];
          if (!agent) { return; }

          agent.define('theme.collect', () => JSON.parse((() => {
        \(collectScript)
          })()));

          agent.define('theme.apply', ({ plan, inverts, hueInverts, ground, scheme }) => {
        \(applyScript)
          });

          agent.define('theme.revert', () => {
        \(revertScript)
          });

          agent.define('theme.dismissPreflight', () => {
        \(dismissPreflightScript)
          });
        })();
        """
    }


    /// Walking and styling the page, shared by the survey and the apply pass so
    /// the two can never disagree about what counts as part of it.
    ///
    /// `querySelectorAll` stops at two boundaries. A shadow root is a separate
    /// tree, and a same-origin iframe is a separate document — between them
    /// they hold most of the web's design-system components and embedded
    /// widgets, and every one of them was staying light on a dark page.
    ///
    /// Shadow DOM needs more than reaching, though: style encapsulation runs
    /// both ways, so the sheet injected into the document never applies inside
    /// a shadow tree. Marking those elements would have changed nothing at all.
    /// They are reached *and* given the rules, through one constructed
    /// stylesheet adopted by every root, which also means one object to switch
    /// off when measuring rather than a search for scattered copies.
    static let traversal = """
    function parentOf(element) {
      if (element.parentElement) { return element.parentElement; }
      const root = element.getRootNode();
      // Out through a shadow boundary to the host that owns it...
      if (root && root.host) { return root.host; }
      // ...or out of a frame to the element that embeds it.
      if (root && root.defaultView && root.defaultView.frameElement) {
        return root.defaultView.frameElement;
      }
      return null;
    }

    function eachElement(start, budget, visit, onRoot) {
      const roots = [start];
      let seen = 0;
      while (roots.length && seen < budget) {
        const root = roots.shift();
        if (onRoot && root !== start) { onRoot(root); }
        let list;
        try { list = root.querySelectorAll('*'); } catch (error) { continue; }
        for (let i = 0; i < list.length && seen < budget; i++) {
          const element = list[i];
          seen++;
          visit(element, root);
          if (element.shadowRoot) { roots.push(element.shadowRoot); }
          if (element.localName === 'iframe') {
            let document_ = null;
            // A cross-origin frame throws here, or hands back nothing. Either
            // way it is not ours to touch, and refusing is the whole answer.
            try { document_ = element.contentDocument; } catch (error) { document_ = null; }
            if (document_ && document_.documentElement) { roots.push(document_); }
          }
        }
      }
      return seen;
    }

    function viewOf(element) {
      const document_ = element.ownerDocument;
      return (document_ && document_.defaultView) || window;
    }

    function styleOf(element) { return viewOf(element).getComputedStyle(element); }
    """

    /// How many elements are examined. A long article can run to tens of
    /// thousands of nodes and the colours stop being new long before that;
    /// this is a ceiling on the cost, not a sample of the page.
    static let elementBudget = 4000

    /// Reads what the page has actually painted.
    ///
    /// Returns the distinct colours with the context that makes them
    /// classifiable — which property carried them, how much of the viewport
    /// they cover, whether they sit on something clickable. Aggregated here
    /// rather than in Swift so the message stays a few dozen entries instead of
    /// one per element.
    ///
    /// The area recorded is the largest sighting rather than the total, because
    /// the question it answers is "what is the biggest thing this colour
    /// paints" — a masthead, or a badge repeated forty times.
    static let collectScript = """
    if (document.readyState === 'loading') {
      // `images` is not optional on the Swift side, so leaving it out made
      // this reply undecodable — and the `ready` guard waiting on it dead
      // code. The old call site swallowed the decode failure and returned,
      // which looked identical from the outside and hid it.
      return JSON.stringify({
        ground: '', themed: false, ready: false, colors: [], images: []
      });
    }

    \(traversal)

    // Every sheet of ours, wherever it ended up — the document, an iframe, or
    // adopted by a shadow root. Switched off around the read, because measuring
    // through our own paint would only measure our own paint.
    function ourStyleSheets() {
      const sheets = [];
      function add(sheet) { if (sheet && sheets.indexOf(sheet) === -1) { sheets.push(sheet); } }
      const preflight = document.getElementById('__surf_preflight');
      add(preflight && preflight.sheet);
      (window.__surfSheets || []).forEach(add);
      return sheets;
    }

    const ourSheets = ourStyleSheets();
    ourSheets.forEach(function (sheet) { sheet.disabled = true; });

    try {

    const viewport = Math.max(1, innerWidth * innerHeight);

    // Scope: the whole document, or only the subtrees the observer saw change.
    //
    // The mutation records used to be thrown away, so every re-sweep paid for
    // the whole document again. The observer now remembers which elements
    // changed; a re-sweep walks only those subtrees and merges what it finds
    // into the last survey, which reads identically on the Swift side.
    // Anything that makes the scoped walk untrustworthy — too many roots, a
    // change at the document root, an observer that was paused while the page
    // moved — falls back to the full walk.
    const cache = window.__surfColorCache;
    let sweepRoots = null;
    if (cache && !window.__surfMutationOverflow
        && window.__surfMutationRoots && window.__surfMutationRoots.size) {
      let candidates = Array.from(window.__surfMutationRoots).filter(function (node) {
        return node && node.nodeType === 1 && node.isConnected;
      });
      const structural = candidates.some(function (node) {
        return node === document.documentElement || node === document.body;
      });
      if (candidates.length && candidates.length <= 40 && !structural) {
        // An ancestor's walk covers its descendants; keep only the outermost.
        candidates = candidates.filter(function (node) {
          return !candidates.some(function (other) {
            return other !== node && other.contains(node);
          });
        });
        sweepRoots = candidates;
      }
    }
    // Consumed either way: whatever happens after this read is the next
    // sweep's news, not this one's.
    window.__surfMutationRoots = new Set();
    window.__surfMutationOverflow = false;
    // Remembered so the apply pass that follows can paint the same subtrees
    // rather than re-walking a document that mostly didn't change.
    window.__surfLastSweepRoots = sweepRoots;

    const found = new Map();
    if (sweepRoots) {
      // Start from the last survey so the merged report stays a full account
      // of the page. Copied entry by entry, because `note` mutates in place.
      cache.forEach(function (entry, key) {
        found.set(key, {
          value: entry.value, property: entry.property, area: entry.area,
          interactive: entry.interactive, large: entry.large, on: entry.on
        });
      });
    }

    // Sampling marks, to find the colourless ones that would vanish.
    //
    // 64x64 rather than something smaller: a wordmark's strokes are thin, and
    // reduced much further they survive only as part-transparent smudges, which
    // is not enough to tell ink from colour. getImageData throws for a
    // cross-origin image loaded without CORS — that refusal is the whole
    // answer, since an image we can't inspect is one we leave alone.
    //
    // Candidates are only noted during the walk; the canvas work runs after
    // it, clear of the layout reads, and only when something new turned up —
    // a re-sweep of a page whose images were all seen before pays nothing.
    if (!window.__surfSeenImages) { window.__surfSeenImages = new Set(); }
    const imageCandidates = [];

    function considerImage(element, backdrop, box) {
      if (imageCandidates.length >= 16) { return; }
      const source = element.currentSrc || element.src;
      if (!source || window.__surfSeenImages.has(source)) { return; }
      if (!element.complete || !element.naturalWidth) { return; }
      // Too small to matter, or far too large to be a mark rather than a
      // picture — and a picture is opaque and was never at risk.
      if (box.width < 8 || box.height < 8) { return; }
      if (box.width > 512 || box.height > 512) { return; }
      window.__surfSeenImages.add(source);
      imageCandidates.push({ element: element, source: source, backdrop: backdrop || '' });
    }

    function sampleCandidates() {
      const sampled = [];
      if (!imageCandidates.length) { return sampled; }
      const canvas = document.createElement('canvas');
      canvas.width = 64;
      canvas.height = 64;
      const context = canvas.getContext('2d', { willReadFrequently: true });
      for (const candidate of imageCandidates) {
        try {
          context.clearRect(0, 0, 64, 64);
          context.drawImage(candidate.element, 0, 0, 64, 64);
          const data = context.getImageData(0, 0, 64, 64).data;
          // In slices: a few apply calls per image rather than 16,384 string
          // concatenations of one character each.
          let binary = '';
          for (let j = 0; j < data.length; j += 8192) {
            binary += String.fromCharCode.apply(null, data.subarray(j, j + 8192));
          }
          sampled.push({
            key: candidate.source, pixels: btoa(binary),
            backdrop: candidate.backdrop
          });
        } catch (error) { /* tainted: left alone */ }
      }
      return sampled;
    }

    function opaque(value) {
      return !!value && value !== 'transparent' && value.indexOf('rgba(0, 0, 0, 0)') !== 0;
    }

    // What each element's content sits on. Filled in as the walk goes, which is
    // O(n) rather than O(n·depth) because a parent is always resolved before a
    // child asks for it — including across a shadow or frame boundary, which
    // parentOf follows.
    const backdrops = new Map();
    function backdropFor(element, own) {
      if (opaque(own)) { backdrops.set(element, own); return own; }
      const parent = parentOf(element);
      const inherited = parent ? (backdrops.get(parent) || '') : '';
      backdrops.set(element, inherited);
      return inherited;
    }

    // Whether an element sits on something clickable. The old walk asked
    // `closest()` for every element — a selector match against the whole
    // ancestor chain, per element. The answer is inherited down the walk
    // instead, resolved once per element, exactly like the backdrop.
    const INTERACTIVE = 'a, button, [role="button"], input, select, textarea, summary';
    const interactives = new Map();
    function interactiveFor(element) {
      let own = false;
      try { own = element.matches(INTERACTIVE); } catch (error) { own = false; }
      if (own) { interactives.set(element, true); return true; }
      const parent = parentOf(element);
      const inherited = parent ? (interactives.get(parent) || false) : false;
      interactives.set(element, inherited);
      return inherited;
    }

    // A scoped walk starts mid-tree, where the maps above have no ancestors
    // to answer from. Prime them with the chain above the root, outermost
    // first, so inheritance works the same as in a full walk.
    function primeAncestors(element) {
      const chain = [];
      for (let node = parentOf(element); node; node = parentOf(node)) {
        if (backdrops.has(node)) { break; }
        chain.push(node);
      }
      for (let i = chain.length - 1; i >= 0; i--) {
        const node = chain[i];
        backdropFor(node, styleOf(node).backgroundColor);
        interactiveFor(node);
      }
    }

    function note(value, property, area, interactive, large, on) {
      if (!opaque(value)) { return; }
      const key = property + '|' + value;
      const existing = found.get(key);
      if (existing) {
        if (area > existing.area) { existing.area = area; existing.on = on || ''; }
        existing.interactive = existing.interactive || interactive;
        existing.large = existing.large || large;
      } else {
        found.set(key, { value, property, area, interactive, large, on: on || '' });
      }
    }

    function visit(element) {
      const style = styleOf(element);
      if (style.display === 'none' || style.visibility === 'hidden') { return; }

      const box = element.getBoundingClientRect();
      const area = Math.max(0, box.width * box.height) / viewport;
      const interactive = interactiveFor(element);
      const fontSize = parseFloat(style.fontSize) || 16;
      const weight = parseInt(style.fontWeight, 10) || 400;
      const large = fontSize >= 24 || (fontSize >= 18.5 && weight >= 700);

      const backdrop = backdropFor(element, style.backgroundColor);

      // A mask turns a background colour into ink: the sprite is cut to shape
      // and the background is what you see. Recorded apart from real surfaces
      // so it is judged as a glyph, and so a colour used both ways on one page
      // can't collapse into a single answer.
      const maskImage = style.maskImage || style.webkitMaskImage;
      const masked = !!maskImage && maskImage !== 'none';
      note(style.backgroundColor, masked ? 'maskink' : 'background',
           area, interactive, large, backdrop);

      note(style.color, 'text', area, interactive, large, backdrop);

      // Only where a border is actually drawn. An element without one still
      // reports a colour, because the initial value is currentColor — and html
      // and body cover the viewport, so their phantom border would win the
      // aggregation on area and carry no backdrop with it.
      function noteEdge(width, edgeStyle, color) {
        if (edgeStyle === 'none' || edgeStyle === 'hidden') { return; }
        if (!(parseFloat(width) > 0)) { return; }
        note(color, 'border', area, interactive, large, backdrop);
      }
      noteEdge(style.borderTopWidth, style.borderTopStyle, style.borderTopColor);
      noteEdge(style.borderBottomWidth, style.borderBottomStyle, style.borderBottomColor);
      noteEdge(style.borderLeftWidth, style.borderLeftStyle, style.borderLeftColor);
      noteEdge(style.borderRightWidth, style.borderRightStyle, style.borderRightColor);

      if (style.outlineStyle !== 'none' && parseFloat(style.outlineWidth) > 0) {
        note(style.outlineColor, 'outline', area, interactive, large, backdrop);
      }

      // SVG paint, which is how most sites ship their icons. DOM rather than
      // pixels, so it is remapped like any other colour and by the same rules.
      if (element instanceof SVGElement) {
        const fill = style.fill;
        if (fill && fill !== 'none' && fill.indexOf('url(') !== 0) {
          note(fill, 'fill', area, interactive, large, backdrop);
        }
        const stroke = style.stroke;
        if (stroke && stroke !== 'none' && stroke.indexOf('url(') !== 0) {
          note(stroke, 'stroke', area, interactive, large, backdrop);
        }
      }

      const image = style.backgroundImage;
      if (image && image !== 'none' && image.indexOf('gradient(') !== -1) {
        note(image, 'gradient', area, interactive, large, backdrop);
      }

      if (element.localName === 'img') { considerImage(element, backdrop, box); }
    }

    if (sweepRoots) {
      let remaining = \(elementBudget);
      for (const root of sweepRoots) {
        if (remaining <= 0) { break; }
        primeAncestors(root);
        // The root itself changed too — querySelectorAll never includes it.
        visit(root);
        remaining -= 1;
        remaining -= eachElement(root, Math.max(0, remaining), visit);
      }
    } else {
      eachElement(document, \(elementBudget), visit);
    }

    const sampled = sampleCandidates();

    // What the page is actually sitting on, which decides whether it needs us
    // at all. Walked up from the body because a transparent body shows the
    // html element's paint, and that's what the eye sees.
    let ground = getComputedStyle(document.body || document.documentElement).backgroundColor;
    if (!opaque(ground)) {
      ground = getComputedStyle(document.documentElement).backgroundColor;
    }

    // Whether this page already carries a theme. When it does, the ground is
    // ours rather than the site's, and can't be read as evidence about it.
    const themed = !!document.getElementById('__surf_theme');

    // Kept for the next scoped sweep to merge into.
    window.__surfColorCache = found;

    return JSON.stringify({
      ground: ground || '', themed: themed, ready: true,
      colors: Array.from(found.values()), images: sampled
    });

    } finally {
      ourSheets.forEach(function (sheet) { sheet.disabled = false; });
    }
    """

    /// Writes the plan onto the page.
    ///
    /// Each element gets a custom property and a marker attribute, and one
    /// stylesheet per tree turns those into declarations. The indirection is
    /// worth it: the author's own rules are never overwritten, so the original
    /// value survives, removing the theme is a matter of dropping attributes,
    /// and a page that re-renders can be swept again without anything having
    /// been destroyed in the meantime.
    ///
    /// The rules are `@media screen`. WebKit forces light appearance while
    /// printing, and an unscoped dark theme would put black pages through
    /// someone's printer.
    static let applyScript = """
    if (window.__surfObserver) { window.__surfObserver.disconnect(); }

    \(traversal)

    const RULES = `
    @media screen {
      :root { color-scheme: ${scheme}; }
      html { background-color: ${ground} !important; }
      [data-surf-bg] { background-color: var(--surf-bg) !important; }
      [data-surf-fg] { color: var(--surf-fg) !important; }
      [data-surf-bd] { border-color: var(--surf-bd) !important; }
      [data-surf-ol] { outline-color: var(--surf-ol) !important; }
      [data-surf-gr] { background-image: var(--surf-gr) !important; }
      [data-surf-fl] { fill: var(--surf-fl) !important; }
      [data-surf-st] { stroke: var(--surf-st) !important; }
      /* Only ever on a mark carrying no colour, so there is no hue to shift.
         A filter touches the pixels already being drawn and leaves
         transparency transparent — no box appears around the artwork. */
      img[data-surf-invert] { filter: invert(1) brightness(0.92) !important; }
      /* A mark that does carry colour flips its lightness while holding its
         hue. Plain inversion takes the complement, which is what turns a blue
         badge orange and a green logotype pink. */
      img[data-surf-invert-hue] {
        filter: url(#surf-hue-invert) brightness(0.92) !important;
      }
    }`;

    window.__surfSheets = [];
    function register(sheet) {
      if (sheet && window.__surfSheets.indexOf(sheet) === -1) {
        window.__surfSheets.push(sheet);
        // Created mid-read, so it starts switched off with all the others and
        // is turned on at the end along with them.
        sheet.disabled = true;
      }
    }

    // The hue-preserving inversion, as a real colour matrix.
    //
    // `invert(1) hue-rotate(180deg)` is the usual shorthand for this and is a
    // linear approximation that drifts — light blue reliably comes out brown.
    // This is the exact form: each row sums to about -1 with a +1 offset, so
    // lightness flips while hue stays put. sRGB interpolation is explicit
    // because the default is linearRGB, which would give a different answer.
    function ensureFilters(target) {
      if (target.getElementById('__surf_filters')) { return; }
      const NS = 'http://www.w3.org/2000/svg';
      const holder = target.createElementNS(NS, 'svg');
      holder.id = '__surf_filters';
      holder.setAttribute('width', '0');
      holder.setAttribute('height', '0');
      holder.setAttribute('aria-hidden', 'true');
      holder.style.position = 'absolute';
      const filter = target.createElementNS(NS, 'filter');
      filter.id = 'surf-hue-invert';
      filter.setAttribute('color-interpolation-filters', 'sRGB');
      const matrix = target.createElementNS(NS, 'feColorMatrix');
      matrix.setAttribute('type', 'matrix');
      matrix.setAttribute('values',
        '0.333 -0.667 -0.667 0 1 ' +
        '-0.667 0.333 -0.667 0 1 ' +
        '-0.667 -0.667 0.333 0 1 ' +
        '0 0 0 1 0');
      filter.appendChild(matrix);
      holder.appendChild(filter);
      target.documentElement.appendChild(holder);
    }

    function styleDocument(target) {
      let element = target.getElementById('__surf_theme');
      if (!element) {
        element = target.createElement('style');
        element.id = '__surf_theme';
        target.documentElement.appendChild(element);
      }
      element.textContent = RULES;
      register(element.sheet);
      ensureFilters(target);
    }

    // A shadow root is styled by adoption rather than injection: encapsulation
    // means a sheet in the document never reaches inside one, so marking those
    // elements without this would change precisely nothing. One constructed
    // sheet is shared by every root, which also leaves one object to switch off
    // when measuring instead of a search for scattered copies.
    function styleShadow(root) {
      if (!window.__surfShadowSheet) {
        try { window.__surfShadowSheet = new CSSStyleSheet(); }
        catch (error) { window.__surfShadowSheet = null; }
      }
      const sheet = window.__surfShadowSheet;
      if (!sheet) { return; }
      try {
        sheet.replaceSync(RULES);
        if (root.adoptedStyleSheets.indexOf(sheet) === -1) {
          root.adoptedStyleSheets = root.adoptedStyleSheets.concat([sheet]);
        }
        register(sheet);
      } catch (error) { /* a root that won't take it is left as it is */ }
    }

    styleDocument(document);

    const preflight = document.getElementById('__surf_preflight');
    if (preflight && preflight.sheet) { preflight.sheet.disabled = true; }

    function paint(element, attribute, variable, replacement) {
      if (!replacement) { return; }
      element.style.setProperty(variable, replacement);
      element.setAttribute(attribute, '');
    }

    try {
      // Read phase: every computed style is taken before anything at all is
      // written back, so the walk forces at most one style flush rather than
      // interleaving reads with the writes that dirty them.
      const jobs = [];
      const discoveredRoots = [];
      function read(element) {
        const style = styleOf(element);
        const maskImage = style.maskImage || style.webkitMaskImage;
        const job = {
          element: element,
          masked: !!maskImage && maskImage !== 'none',
          background: style.backgroundColor,
          color: style.color,
          border: style.borderTopColor,
          outline: style.outlineColor
        };
        if (element instanceof SVGElement) {
          job.fill = style.fill;
          job.stroke = style.stroke;
        }
        const image = style.backgroundImage;
        if (image && image !== 'none' && image.indexOf('gradient(') !== -1) {
          job.gradient = image;
        }
        jobs.push(job);
      }
      function onRoot(root) { discoveredRoots.push(root); }

      // The subtrees the sweep just measured, or the whole document when it
      // measured all of it. Painting only what was collected keeps a mutation
      // burst from re-walking four thousand untouched elements.
      const scoped = window.__surfLastSweepRoots;
      if (scoped && scoped.length) {
        let remaining = \(elementBudget);
        for (const root of scoped) {
          if (remaining <= 0) { break; }
          if (!root.isConnected) { continue; }
          read(root);
          remaining -= 1;
          remaining -= eachElement(root, Math.max(0, remaining), read, onRoot);
        }
      } else {
        eachElement(document, \(elementBudget), read, onRoot);
      }

      // Write phase. Sheets first — a tree discovered on the way needs the
      // rules, or nothing marked inside it will mean anything.
      for (const root of discoveredRoots) {
        if (root.host) { styleShadow(root); }
        else if (root.documentElement) { styleDocument(root); }
      }

      for (const job of jobs) {
        const element = job.element;
        // Same property and the same variable — the ink is delivered through
        // background-color either way; only the decision differs.
        paint(element, 'data-surf-bg', '--surf-bg',
              plan[(job.masked ? 'maskink|' : 'background|') + job.background]);
        paint(element, 'data-surf-fg', '--surf-fg', plan['text|' + job.color]);
        paint(element, 'data-surf-bd', '--surf-bd', plan['border|' + job.border]);
        paint(element, 'data-surf-ol', '--surf-ol', plan['outline|' + job.outline]);

        if (job.fill !== undefined) {
          paint(element, 'data-surf-fl', '--surf-fl', plan['fill|' + job.fill]);
          paint(element, 'data-surf-st', '--surf-st', plan['stroke|' + job.stroke]);
        }
        if (job.gradient) {
          paint(element, 'data-surf-gr', '--surf-gr', plan['gradient|' + job.gradient]);
        }

        if (element.localName === 'img') {
          const source = element.currentSrc || element.src;
          if (inverts[source]) {
            element.setAttribute('data-surf-invert', '');
          } else if (hueInverts[source]) {
            // A filter referenced by url(#id) resolves against the document, so
            // it is only offered where that reference can be trusted: not from
            // inside a shadow tree, whose fragments resolve in their own scope,
            // and not on a page carrying a <base>, which would send the lookup
            // to another URL entirely. Where it can't be trusted the mark is
            // left as it is, which is the safe half of the trade.
            const owner = element.ownerDocument;
            const inShadow = !!(element.getRootNode() && element.getRootNode().host);
            if (!inShadow && owner.getElementById('surf-hue-invert')
                && !owner.querySelector('base')) {
              element.setAttribute('data-surf-invert-hue', '');
            }
          }
        }
      }
    } finally {
      (window.__surfSheets || []).forEach(function (sheet) { sheet.disabled = false; });
    }

    // Last, so there is never a frame between the holding colour coming off and
    // the real one going on.
    document.getElementById('__surf_preflight')?.remove();

    // Then watch for the page changing underneath us — a section revealed on
    // scroll, a lazily loaded list, a subtree re-rendered with our properties
    // torn off. Coalesced into one report, because a list that adds fifty rows
    // fires fifty times and they all want the same answer.
    if (!window.__surfObserver) {
      window.__surfObserver = new MutationObserver(function (records) {
        // Remember where, not just that: the records are what let the next
        // sweep walk the changed subtrees instead of the whole document.
        // Past a point the bookkeeping stops paying for itself, and anything
        // that isn't a plain element means the document itself moved — both
        // fall back to a full sweep.
        let roots = window.__surfMutationRoots;
        if (!roots) { roots = window.__surfMutationRoots = new Set(); }
        for (let i = 0; i < records.length; i++) {
          const target = records[i].target;
          if (target && target.nodeType === 1) { roots.add(target); }
          else { window.__surfMutationOverflow = true; }
          if (roots.size > 40) { window.__surfMutationOverflow = true; break; }
        }
        if (window.__surfPending) { return; }
        window.__surfPending = setTimeout(function () {
          window.__surfPending = null;
          agent.emit('theme', 'mutated');
        }, 250);
      });
    }
    window.__surfObserver.observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['class', 'style']
    });
    return true;
    """

    /// Stops the page reporting mutations, for a tab that has gone off screen.
    ///
    /// Disconnecting rather than ignoring the reports on our side: the point is
    /// to stop the page doing the work and stop the messages crossing the
    /// bridge, not to throw the answers away after paying for them. Any pending
    /// coalescing timer goes too, so a report can't land after the disconnect.
    static let pauseObserverScript = """
    window.__surfObserver?.disconnect();
    if (window.__surfPending) {
      clearTimeout(window.__surfPending);
      window.__surfPending = null;
    }
    // Remembered so resuming knows whether it was ever watching to begin with.
    window.__surfObserverPaused = true;
    // Whatever changes while nobody is watching goes unrecorded, so the sweep
    // that catches the tab up cannot trust the mutation log — it walks the
    // whole document once instead.
    window.__surfMutationOverflow = true;
    return true;
    """

    /// Puts the observer back when the tab is looked at again.
    ///
    /// A no-op if the page was never themed — there is nothing to watch for
    /// yet, and `applyScript` will start the observer itself when it runs.
    static let resumeObserverScript = """
    if (window.__surfObserver && window.__surfObserverPaused) {
      window.__surfObserverPaused = false;
      window.__surfObserver.observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['class', 'style']
      });
    }
    return true;
    """

    // MARK: - Preflight

    /// The ground colour painted before a page has said anything about itself.
    ///
    /// Also handed to `underPageBackgroundColor`, which is what the web view
    /// shows while a navigation is in flight — that surface is white by default
    /// and is the flash you see *between* pages, before any of this runs.
    static func preflightGround(for target: ColorSchemeTarget) -> SRGB {
        OKLCH(l: Perceptual.bounds(for: target).surface, c: 0, h: 0).displayable
    }

    /// Painted at document start, before the page's own styles arrive.
    ///
    /// Without this the sequence is: white page paints, user sees it, theme
    /// lands a moment later. No amount of speed fixes that — the flash is a
    /// frame the page was always going to draw, so the only cure is to have an
    /// answer in place before it draws one.
    ///
    /// It works by removing colour rather than imposing it. Backgrounds are
    /// forced transparent so everything shows the one dark ground beneath, and
    /// text is forced to inherit so it picks up the one light colour set on the
    /// body. The alternative — stamping a dark background onto every element —
    /// turns transparent overlays into opaque blocks and hides whatever they
    /// were floating over.
    ///
    /// Media is exempt throughout. An image is never recoloured, and that holds
    /// in the first frame as much as in the last.
    static func preflightScript(for target: ColorSchemeTarget) -> String {
        let bounds = Perceptual.bounds(for: target)
        let ground = preflightGround(for: target).hex
        let foreground = OKLCH(l: bounds.foreground, c: 0, h: 0).displayable.hex
        let border = OKLCH(l: target == .dark ? 0.32 : 0.78, c: 0, h: 0).displayable.hex

        return """
        (function () {
          if (document.getElementById('__surf_preflight')) { return; }
          const style = document.createElement('style');
          style.id = '__surf_preflight';
          style.textContent = '@media screen {' +
            'html, body {' +
              'background-color: \(ground) !important;' +
              'color: \(foreground) !important;' +
            '}' +
            'body :not(iframe):not(img):not(video):not(canvas):not(svg):not(svg *) {' +
              'background-color: transparent !important;' +
              'color: inherit !important;' +
              'border-color: \(border) !important;' +
            '}' +
          '}';
          // documentElement is the only thing guaranteed to exist this early;
          // head is often still being parsed.
          document.documentElement.appendChild(style);
        })();
        """
    }

    /// Removes everything the theme added, leaving the page as authored.
    static let dismissPreflightScript = """
    document.getElementById('__surf_preflight')?.remove();
    return true;
    """

    static let revertScript = """
    window.__surfObserver?.disconnect();
    window.__surfObserver = null;
    window.__surfSheets = [];
    window.__surfSeenImages = null;
    window.__surfColorCache = null;
    window.__surfMutationRoots = null;
    window.__surfMutationOverflow = false;
    window.__surfLastSweepRoots = null;
    document.getElementById('__surf_theme')?.remove();
    document.getElementById('__surf_preflight')?.remove();
    document.getElementById('__surf_filters')?.remove();
    const attributes = ['data-surf-bg', 'data-surf-fg', 'data-surf-bd',
                        'data-surf-ol', 'data-surf-gr',
                        'data-surf-fl', 'data-surf-st', 'data-surf-invert',
                        'data-surf-invert-hue'];
    const variables = ['--surf-bg', '--surf-fg', '--surf-bd',
                       '--surf-ol', '--surf-gr',
                       '--surf-fl', '--surf-st'];
    for (const attribute of attributes) {
      for (const element of document.querySelectorAll('[' + attribute + ']')) {
        element.removeAttribute(attribute);
      }
    }
    for (const element of document.querySelectorAll('[style]')) {
      for (const variable of variables) { element.style.removeProperty(variable); }
    }
    return true;
    """

    /// One colour the page reported, before any decision has been made about it.
    struct Reading: Decodable, Sendable {
        var value: String
        var property: String
        var area: Double
        var interactive: Bool
        var large: Bool
        /// The colour this one is painted on top of, where there is one.
        var on: String?
    }

    /// One image, reduced to something the analysis can read.
    struct ImageReading: Decodable, Sendable {
        var key: String
        /// Base64 of a 64x64 RGBA reduction.
        var pixels: String
        /// The site's own colour behind it, resolved through the plan to find
        /// what it will actually be sitting on once the theme lands.
        var backdrop: String
    }

    struct Survey: Decodable, Sendable {
        var ground: String
        /// True once this page has been themed. The ground reading is then our
        /// own paint, and can't be used to judge what the site does.
        var themed: Bool
        /// False while the document is still parsing, when nothing it reports
        /// is representative of the finished page.
        var ready: Bool
        var colors: [Reading]
        var images: [ImageReading]
    }

    // MARK: - Synthesis

    /// Everything one sweep decided, computed away from the main actor.
    ///
    /// The survey behind a busy page runs to thousands of colour observations
    /// and a handful of base64 pixel buffers, and decoding it, judging every
    /// image pixel by pixel and building the plan were all being paid for on
    /// the main actor — per mutation burst, on the tab being looked at. All of
    /// it is pure value work on `Sendable` types, so it happens on a detached
    /// task now and only the answer crosses back.
    enum SweepOutcome: Sendable {
        /// The reply didn't decode into a survey — a page with no runtime, or
        /// nothing to say. Matches the old silent early return.
        case unavailable
        /// The document is still parsing; nothing it reports is
        /// representative yet.
        case parsing
        /// Nothing painted yet to decide from — wait rather than guess.
        case unpainted
        /// The site already draws the scheme the user asked for.
        case satisfied
        /// A survey arrived, but nothing in it needs changing.
        case unchanged
        /// A plan, ready to be sent to the page as it stands.
        case apply(
            replacements: [String: String],
            inverts: [String: String],
            hueInverts: [String: String],
            ground: CSSColor
        )
    }

    /// The whole judgement, from raw reply envelope to finished plan.
    ///
    /// Deliberately nonisolated and free of AppKit: it takes value types in
    /// and hands a value type back, so a caller can run it wherever is cheap.
    static func synthesize(
        envelope: String,
        target: ColorSchemeTarget,
        establishedGround: CSSColor?
    ) -> SweepOutcome {
        guard let survey = try? PageProtocol.decode(
            envelope, as: Survey.self,
            method: PageProtocol.Method.themeCollect.rawValue
        ) else { return .unavailable }

        // Measured, not asked. A site that already paints in the scheme the
        // user wants needs nothing from us, and restyling it would swap its
        // designers' work for an approximation of it. Declared signals —
        // a meta tag, a media query — say what a site claims; this says what
        // it did, and cross-origin stylesheets can't hide it.
        debugLog("""
            theme: target=\(target.rawValue) ground=\(survey.ground) \
            themed=\(survey.themed) colours=\(survey.colors.count)
            """)

        guard survey.ready else { return .parsing }

        let observations = observations(from: survey)

        // What the decision gets made on.
        //
        // `survey.ground` is the declared background of body or html, and is
        // very often transparent — plenty of sites never set one and simply
        // show the browser's canvas. Read literally, `rgba(0, 0, 0, 0)` parses
        // as black and satisfies "already dark", which would leave every such
        // site in light mode forever. But treating transparent as *light* is
        // just as wrong: a page caught mid-load hasn't painted its background
        // yet, and GitHub — which has a perfectly good dark mode — was being
        // restyled on the strength of a background that simply hadn't arrived.
        //
        // Neither reading of "undeclared" is safe, so the declared value is
        // abandoned and the largest thing the page actually paints is used
        // instead. That is what the eye takes for the background, and a page
        // with nothing painted yet has none — which is the signal to wait
        // rather than to guess.
        guard let decisionGround = SchemeDecision.decisionGround(
            declared: survey.ground, observations: observations
        ) else { return .unpainted }

        if !survey.themed,
           SchemeDecision.alreadySatisfies(target, ground: decisionGround) {
            let lightness = String((OKLCH(decisionGround.rgb).l * 100).rounded() / 100)
            debugLog("theme: site already \(target.rawValue) (L=\(lightness)) — left alone")
            return .satisfied
        }

        var plan = ThemePlan.build(
            from: observations,
            target: target,
            establishedGround: survey.themed ? establishedGround : nil
        )

        // Gradients are values rather than single colours, so they take their
        // own path — stops move together, or the light comes from the wrong
        // side afterwards.
        for reading in survey.colors where reading.property == "gradient" {
            let transformed = CSSGradient.transformValue(reading.value, to: target)
            guard transformed != reading.value else { continue }
            plan.replacements["gradient|" + reading.value] = transformed
        }

        // Artwork is not recoloured, with one exception narrow enough to be
        // safe: a mark carrying no colour at all, which would otherwise vanish.
        // A black wordmark becomes a white one — what its designers drew for
        // their own dark mode — and there is no hue to lose by flipping it.
        var inverts: [String: String] = [:]
        var hueInverts: [String: String] = [:]
        for reading in survey.images {
            guard let data = Data(base64Encoded: reading.pixels),
                  let verdict = ImageAnalysis.verdict(rgba: [UInt8](data))
            else { continue }

            // What it will be sitting on once the theme lands, not what it
            // sits on now: the surface behind it is about to move too.
            let surface: SRGB = {
                if let themed = plan.replacements["background|" + reading.backdrop]
                    .flatMap(CSSColor.init(css:)) {
                    return themed.rgb
                }
                if let backdrop = CSSColor(css: reading.backdrop), backdrop.alpha > 0.5 {
                    return backdrop.rgb
                }
                return plan.pageBackground.rgb
            }()

            if ImageAnalysis.shouldInvert(verdict, on: surface) {
                inverts[reading.key] = "1"
            } else if ImageAnalysis.shouldInvertPreservingHue(verdict, on: surface) {
                hueInverts[reading.key] = "1"
            }
        }

        if !inverts.isEmpty || !hueInverts.isEmpty {
            debugLog("""
                theme: inverting \(inverts.count) colourless and \
                \(hueInverts.count) coloured mark(s)
                """)
        }

        guard !plan.isEmpty || !inverts.isEmpty || !hueInverts.isEmpty else {
            return .unchanged
        }

        return .apply(
            replacements: plan.replacements,
            inverts: inverts,
            hueInverts: hueInverts,
            ground: plan.pageBackground
        )
    }

    /// Turns the page's report into the observations `SurfCore` reasons about.
    ///
    /// Colours the parser can't fully understand are dropped rather than
    /// guessed at, which means they're left exactly as the site drew them.
    static func observations(from survey: Survey) -> [ColorObservation] {
        survey.colors.compactMap { reading in
            guard let property = ColorProperty(bridgeName: reading.property) else { return nil }
            guard let color = CSSColor(css: reading.value) else { return nil }
            return ColorObservation(
                color: color,
                property: property,
                areaFraction: reading.area,
                isInteractive: reading.interactive,
                isLargeText: reading.large,
                // Keyed by the page's own spelling, which is what it will look
                // the replacement up with.
                source: reading.value,
                backdrop: reading.on.flatMap { CSSColor(css: $0) }
            )
        }
    }
}

extension ColorProperty {
    /// The names the injected script uses, kept separate from the raw values so
    /// renaming one can't silently change the other.
    init?(bridgeName: String) {
        switch bridgeName {
        case "background": self = .background
        case "text": self = .text
        case "border": self = .border
        case "outline": self = .outline
        case "fill": self = .fill
        case "stroke": self = .stroke
        case "maskink": self = .maskedInk
        default: return nil
        }
    }
}
