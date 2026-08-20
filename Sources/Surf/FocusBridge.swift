import Foundation
import SurfCore

/// The `focus` domain: what Focus Mode asks a page.
///
/// Two scripts with very different residency, and the split is the point. The
/// detector below is a few hundred bytes of counting and rides along in every
/// main frame, like `PageDomain`. The extractor is the expensive half — a
/// full content walk — and is *not* a user script: it is evaluated on demand
/// by `Tab.enterFocus()`, so only pages the user actually focuses pay for it.
///
/// Isolated world throughout. Focus only observes the document, and nothing
/// here needs the page's own globals — which also means nothing the page runs
/// can see or tamper with the extraction.
enum FocusBridge {

    /// The resident half: cheap signals, on request.
    ///
    /// No judgement here — no thresholds, no "is this an article". The script
    /// counts and Swift decides (`FocusClassification`), because thresholds
    /// get revised and a revision inside an injected string can't be tested.
    ///
    /// `textContent` rather than `innerText`, deliberately: `innerText`
    /// forces style and layout, and this runs on every page shortly after
    /// load. The overcount from hidden text is noise the classifier's
    /// thresholds already absorb.
    static var domainScript: String {
        """
        (function () {
          const agent = window['\(PageRuntime.handle)'];
          if (!agent || agent.state.focusInstalled) { return; }
          agent.state.focusInstalled = true;

          // Flattens every @type out of a JSON-LD tree: bare objects, arrays,
          // and @graph wrappers, which is how most sites actually ship it.
          function gatherTypes(node, out, depth) {
            if (!node || depth > 4 || out.length >= 32) { return; }
            if (Array.isArray(node)) {
              for (const item of node) { gatherTypes(item, out, depth + 1); }
              return;
            }
            if (typeof node !== 'object') { return; }
            const type = node['@type'];
            if (typeof type === 'string') { out.push(type); }
            else if (Array.isArray(type)) {
              for (const t of type) { if (typeof t === 'string') { out.push(t); } }
            }
            if (node['@graph']) { gatherTypes(node['@graph'], out, depth + 1); }
          }

          agent.define('focus.signals', () => {
            let words = 0;
            let paragraphs = 0;
            const ps = document.querySelectorAll('p');
            // Capped: a pathological page can hold tens of thousands of
            // paragraphs, and past a few hundred the verdict can't change.
            const limit = Math.min(ps.length, 400);
            for (let i = 0; i < limit; i++) {
              const count = (ps[i].textContent || '')
                .split(/\\s+/).filter(Boolean).length;
              if (count >= 8) { paragraphs += 1; }
              words += count;
            }

            const types = [];
            for (const s of document.querySelectorAll(
              'script[type="application/ld+json"]'
            )) {
              // Invalid JSON-LD is routine; a broken block just says nothing.
              try { gatherTypes(JSON.parse(s.textContent || 'null'), types, 0); }
              catch (e) { /* ignored */ }
            }

            const og = document.querySelector('meta[property="og:type"]');
            return {
              wordCount: words,
              paragraphCount: paragraphs,
              hasArticleElement:
                !!document.querySelector('article, [itemprop~="articleBody"]'),
              ogType: ((og && og.getAttribute('content')) || '')
                .trim().toLowerCase(),
              jsonLDTypes: types,
              videoCount: document.querySelectorAll('video').length
            };
          });
        })();
        """
    }

    /// The on-demand half: registers `focus.extract` and `focus.reveal` when
    /// first evaluated. Idempotent via the agent's scratch state, so calling
    /// it on every activation is a re-entry guard rather than a leak.
    ///
    /// A compact Readability: score the containers that hold real paragraph
    /// text, discount the ones that are mostly links, take the best one, and
    /// walk it into the flat block model every lens shares. Hand-rolled
    /// rather than vendored — Surf carries no dependencies, and the ~10% of
    /// layouts the full library wins on are exactly the ones Focus should
    /// decline gracefully anyway (`FocusArticle.isSubstantial`).
    static var extractorScript: String {
        """
        (function () {
          const agent = window['\(PageRuntime.handle)'];
          if (!agent || agent.state.focusExtractInstalled) { return; }
          agent.state.focusExtractInstalled = true;

          const GOOD = /article|body|content|entry|main|post|text|blog|story|prose/i;
          const BAD = /comment|share|related|sidebar|widget|nav|footer|header|menu|promo|social|byline|breadcrumb|banner|advert|-ad-|_ad_/i;

          function clean(text) {
            return (text || '')
              // Citation and maintenance markers: [2], [note 4],
              // [citation needed]. Not tappable in the reader, garbled by a
              // voice, and a cluster of them reads as a sentence of its own
              // to the tokenizer. Lowercase-only for bare letters ([a] is a
              // citation style, [I] is a quotation's inserted word) and the
              // named forms spelled out — a blanket strip of anything in
              // brackets would take "[He] said" with it.
              .replace(/\\[(?:\\d{1,3}|[a-z])\\]/g, '')
              .replace(
                /\\[(?:note \\d+|citation needed|clarification needed|by whom\\??|who\\??|when\\??|which\\??|dead link|update|sic)\\]/gi,
                ''
              )
              .replace(/\\s+/g, ' ')
              .trim();
          }

          function linkDensity(el) {
            const total = (el.textContent || '').length;
            if (!total) { return 1; }
            let linked = 0;
            for (const a of el.querySelectorAll('a')) {
              linked += (a.textContent || '').length;
            }
            return linked / total;
          }

          // The container most likely to be the article body.
          function bestCandidate() {
            const scores = new Map();

            function hint(el) {
              const label = ((el.className && String(el.className)) || '')
                + ' ' + (el.id || '');
              let score = el.tagName === 'ARTICLE' ? 20 : 0;
              if (GOOD.test(label)) { score += 25; }
              if (BAD.test(label)) { score -= 25; }
              return score;
            }

            function bump(el, points) {
              if (!el || el === document.body || el === document.documentElement) {
                return;
              }
              if (!scores.has(el)) { scores.set(el, hint(el)); }
              scores.set(el, scores.get(el) + points);
            }

            // Paragraph-ish text votes for its ancestors, with the vote
            // decaying by depth — the classic shape. Five levels rather than
            // two, because sites that nest sections inside sections (Parsoid
            // Wikipedia, most docs generators) put the real container three
            // or four elements above the prose, and a vote that stops at the
            // grandparent crowns the strongest chapter instead of the book.
            // dd and td vote too: reference pages carry their prose in
            // definition lists and tables, and a page like that scored on
            // paragraphs alone crowns its intro and misses the reference.
            for (const p of document.querySelectorAll('p, pre, blockquote, dd, td')) {
              const text = clean(p.textContent);
              if (text.length < 25) { continue; }
              const points = 1
                + Math.min(3, Math.floor(text.length / 100))
                + (text.split(',').length - 1) * 0.5;
              let ancestor = p.parentElement;
              for (let level = 0; ancestor && level < 5; level++) {
                const divisor = level === 0 ? 1 : level === 1 ? 2 : level * 3;
                bump(ancestor, points / divisor);
                ancestor = ancestor.parentElement;
              }
            }

            // A high scorer that is mostly links is an index page's list of
            // teasers, not a body. Memoised: the ranking below asks
            // repeatedly, and linkDensity walks the element's text each time.
            const cache = new Map();
            const effective = (el) => {
              if (!cache.has(el)) {
                cache.set(el, scores.get(el) * (1 - linkDensity(el)));
              }
              return cache.get(el);
            };

            let best = null;
            let bestScore = -Infinity;
            for (const el of scores.keys()) {
              const scaled = effective(el);
              if (scaled > bestScore) { bestScore = scaled; best = el; }
            }
            if (!best) {
              return document.querySelector('article') || document.body;
            }

            // A page that wraps each section in its own element — Wikipedia,
            // docs sites — gives its strongest *section* the top score, and
            // stopping there extracts a chapter and calls it the book. The
            // tell is other strong candidates that are neither ancestors nor
            // descendants of the winner: real sibling sections. When they
            // exist, the article is the deepest ancestor that unites most of
            // them — and when they don't (one solid body, junk elsewhere),
            // nothing here moves, which is what keeps a sidebar or a comments
            // thread from being climbed into.
            const others = [...scores.keys()]
              .filter((el) =>
                el !== best && !el.contains(best) && !best.contains(el)
                && effective(el) >= Math.max(10, bestScore * 0.15))
              .sort((a, b) => effective(b) - effective(a))
              .slice(0, 4);

            if (others.length) {
              const need = Math.min(3, others.length);
              let candidate = best;
              for (let step = 0; step < 5; step++) {
                const contained =
                  others.filter((el) => candidate.contains(el)).length;
                if (contained >= need) { best = candidate; break; }
                const parent = candidate.parentElement;
                if (!parent || parent === document.body
                    || parent === document.documentElement) { break; }
                candidate = parent;
              }
            }
            return best;
          }

          function meta(selector) {
            const el = document.querySelector(selector);
            return clean(el && el.getAttribute('content'));
          }

          function byline() {
            const declared = meta('meta[name="author" i]');
            if (declared) { return declared.slice(0, 120); }
            const el = document.querySelector(
              '[rel="author"], [itemprop~="author"], .byline'
            );
            return clean(el && el.textContent).slice(0, 120);
          }

          function imageSource(img) {
            const src = img.currentSrc || img.src || '';
            // data: URIs are placeholders more often than pictures, and either
            // way they can be megabytes the payload shouldn't carry.
            return /^https?:/.test(src) ? src : '';
          }

          function ownLabel(el) {
            return ((el.className && String(el.className)) || '')
              + ' ' + (el.id || '');
          }

          agent.define('focus.extract', () => {
            const root = bestCandidate();
            const title = meta('meta[property="og:title"]') || clean(document.title);
            const blocks = [];
            const elements = [];
            // Containers already emitted whole, so their insides don't come
            // out again as separate blocks — a quote's paragraphs, a
            // figure's img.
            const consumed = [];

            function insideConsumed(el) {
              for (const c of consumed) {
                if (c !== el && c.contains(el)) { return true; }
              }
              return false;
            }

            function push(block, el) {
              blocks.push(block);
              elements.push(el);
            }

            const nodes = root.querySelectorAll(
              'h1, h2, h3, h4, h5, h6, p, pre, blockquote, ul, ol, dl, figure, img'
            );
            for (const el of nodes) {
              if (blocks.length >= 600) { break; }
              if (insideConsumed(el)) { continue; }
              // Junk names its own furniture: a share row, a byline strip, a
              // related-links list living *inside* the body still shouldn't
              // read as the body.
              if (BAD.test(ownLabel(el))) { continue; }
              const tag = el.tagName;

              if (tag === 'P') {
                const text = clean(el.textContent);
                // Mostly-links "paragraphs" are share rows and crumb trails.
                if (!text || linkDensity(el) > 0.6) { continue; }
                push({ type: 'paragraph', text: text }, el);

              } else if (tag[0] === 'H' && tag.length === 2) {
                const text = clean(el.textContent);
                if (!text) { continue; }
                // The lead heading is almost always the title the header
                // already sets — showing both opens every article twice.
                if (blocks.length < 2
                    && text.toLowerCase() === title.toLowerCase()) { continue; }
                push({ type: 'heading', text: text, level: +tag[1] }, el);

              } else if (tag === 'PRE') {
                consumed.push(el);
                // Not cleaned: a code block's whitespace is its indentation.
                const text = (el.textContent || '').replace(/\\s+$/, '');
                if (!text.trim()) { continue; }
                push({ type: 'code', text: text }, el);

              } else if (tag === 'BLOCKQUOTE') {
                consumed.push(el);
                const text = clean(el.textContent);
                if (!text) { continue; }
                push({ type: 'quote', text: text }, el);

              } else if (tag === 'DL') {
                consumed.push(el);
                // Terms and their definitions read as an unordered list of
                // "term — definition" until a reference lens exists.
                const items = [];
                let term = '';
                for (const child of el.children) {
                  if (child.tagName === 'DT') {
                    term = clean(child.textContent);
                  } else if (child.tagName === 'DD') {
                    const text = clean(child.textContent);
                    if (!text && !term) { continue; }
                    items.push(term ? term + ' — ' + text : text);
                    term = '';
                  }
                }
                if (term) { items.push(term); }
                if (!items.length) { continue; }
                push({ type: 'list', items: items, ordered: false }, el);

              } else if (tag === 'UL' || tag === 'OL') {
                consumed.push(el);
                // A list that is mostly links is navigation wearing bullets.
                if (linkDensity(el) > 0.6) { continue; }
                const items = [];
                for (const li of el.querySelectorAll(':scope > li')) {
                  const text = clean(li.textContent);
                  if (text) { items.push(text); }
                }
                if (!items.length) { continue; }
                push({ type: 'list', items: items, ordered: tag === 'OL' }, el);

              } else if (tag === 'FIGURE') {
                consumed.push(el);
                const img = el.querySelector('img');
                const src = img ? imageSource(img) : '';
                if (!src) { continue; }
                const cap = el.querySelector('figcaption');
                push({
                  type: 'image', src: src,
                  caption: clean(cap ? cap.textContent : (img.alt || ''))
                }, el);

              } else if (tag === 'IMG') {
                const src = imageSource(el);
                if (!src) { continue; }
                // Skip the trackers and ornaments; a loaded picture knows its
                // size, an unloaded one gets the benefit of the doubt.
                if (el.naturalWidth > 0 && el.naturalWidth < 120) { continue; }
                push({ type: 'image', src: src, caption: clean(el.alt) }, el);
              }
            }

            // Kept for `focus.reveal`: the reader scrolls by block index, and
            // these are what an index scrolls the page back to. On the agent's
            // scratch state, so the page sees no new global.
            agent.state.focusBlockElements = elements;

            let hero = meta('meta[property="og:image"]');
            // The lead image usually *is* og:image; showing it twice would
            // open every article with a stutter.
            for (const block of blocks.slice(0, 3)) {
              if (block.type === 'image' && block.src === hero) { hero = ''; break; }
            }

            // The page's structured data, raw. Parsing happens in Swift
            // (`FocusRecipe`), where the mess real sites ship — @graph
            // wrappers, entity-encoded strings, five spellings of
            // "instructions" — can be unit-tested instead of debugged live.
            // Capped: some pages carry megabytes of product JSON-LD, and a
            // recipe that doesn't fit in the first few scripts isn't one.
            const jsonLD = [];
            for (const s of document.querySelectorAll(
              'script[type="application/ld+json"]'
            )) {
              if (jsonLD.length >= 10) { break; }
              const raw = s.textContent || '';
              if (raw.length > 0 && raw.length <= 400000) { jsonLD.push(raw); }
            }

            // Which element won the scoring — one line in the debug log that
            // explains every extraction that looks wrong.
            let path = [];
            for (let el = root; el && el !== document.body && path.length < 4;
                 el = el.parentElement) {
              path.unshift(el.tagName.toLowerCase()
                + (el.id ? '#' + el.id : '')
                + (el.className ? '.' + String(el.className).split(/\\s+/)[0] : ''));
            }

            return {
              title: title,
              byline: byline(),
              siteName: meta('meta[property="og:site_name"]') || location.hostname,
              heroImage: hero,
              rootPath: path.join(' > '),
              jsonLD: jsonLD,
              blocks: blocks
            };
          });

          // Puts the page back where the reader was: leaving Focus lands on
          // the same passage, not at whatever scroll position the page kept.
          agent.define('focus.reveal', ({ index }) => {
            const elements = agent.state.focusBlockElements;
            const el = elements && elements[index];
            if (!el || !el.isConnected) { return null; }
            el.scrollIntoView({ block: 'start' });
            return true;
          });
        })();
        """
    }
}
