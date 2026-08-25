import Foundation
import SurfCore

/// The `amazon` domain: what the site lens asks Amazon.
///
/// Page world and on demand, for the same reasons `YouTubeBridge` is: the
/// cart's own controls are the site's, and a tab that never focuses Amazon
/// never parses a byte of this.
///
/// What is different, and worth saying plainly, is where the knowledge lives.
/// YouTube publishes a JSON payload and that bridge copies named keys out of
/// it. Amazon publishes nothing, so this reads the page as drawn — and
/// "which element is the price" is a judgement, which means the doctrine
/// needs restating rather than repeating. The Amazon version:
///
/// **The script may select and copy. It may not parse, classify, or decide.**
///
/// So there is no Amazon knowledge in this file at all. The selectors arrive
/// as a call argument from `AmazonSelectors`, and everything this returns is
/// a string. Nothing here decides what a price is, whether a card is an
/// advert, what a rating means, or which of two prices is the one you pay.
/// All of that is Swift, in `AmazonModel` and `AmazonReconcile`, under test.
///
/// Two details that look fussy and are not:
///
/// - Text is read by walking text nodes and skipping `<script>`, `<style>`
///   and `<noscript>`, not by `textContent`. Amazon puts an inline
///   Prime-signup script inside the delivery cell, and `textContent` returns
///   its source code as the delivery promise.
/// - It is never `innerText`. `innerText` returns nothing for an element
///   inside a `display:none` subtree, and Surf compiles EasyList's cosmetic
///   rules into exactly that — so `innerText` would go blank on whatever the
///   blocker happened to hide that week, which is the hardest kind of bug to
///   see.
enum AmazonBridge {

    /// Registers the domain. Idempotent through the agent's scratch state, so
    /// re-evaluating it on every load while the lens is up is a re-entry
    /// guard rather than a leak.
    static var installScript: String {
        """
        (function () {
          const agent = window['\(PageRuntime.handle)'];
          if (!agent || agent.state.amazonInstalled) { return; }
          agent.state.amazonInstalled = true;

          // ---- Machinery. No site knowledge below this line. --------------

          // Text as a reader sees it: every text node under the element,
          // minus the ones inside script, style and noscript.
          function text(node) {
            if (!node) { return ''; }
            const walker = document.createTreeWalker(
              node, NodeFilter.SHOW_TEXT, {
                acceptNode: function (t) {
                  for (let p = t.parentNode; p && p !== node.parentNode; p = p.parentNode) {
                    const tag = p.nodeName;
                    if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') {
                      return NodeFilter.FILTER_REJECT;
                    }
                  }
                  return NodeFilter.FILTER_ACCEPT;
                }
              }
            );
            let out = '';
            let hit;
            while ((hit = walker.nextNode())) { out += hit.nodeValue + ' '; }
            return out.replace(/\\s+/g, ' ').trim();
          }

          // An entry is "selector" or "selector@attribute", and a bare
          // "@attribute" reads the root's own attribute.
          function parts(entry) {
            const at = entry.indexOf('@');
            if (at < 0) { return { sel: entry, attr: null }; }
            return {
              sel: at === 0 ? null : entry.slice(0, at),
              attr: entry.slice(at + 1)
            };
          }

          function valueOf(node, attr) {
            if (!node) { return ''; }
            if (attr) { return (node.getAttribute(attr) || '').trim(); }
            return text(node);
          }

          // First candidate that yields anything. Tally is the canary: it
          // records which selector answered, so a field that goes quiet says
          // so in the log instead of rendering as blank.
          function one(root, list, tally, name) {
            if (!root || !list) { return ''; }
            for (const entry of list) {
              const p = parts(entry);
              let node;
              try { node = p.sel ? root.querySelector(p.sel) : root; }
              catch (e) { continue; }
              const value = valueOf(node, p.attr);
              if (value) {
                if (tally && name) { tally[name] = (tally[name] || 0) + 1; }
                return value;
              }
            }
            return '';
          }

          // Everything the first productive candidate matches.
          function many(root, list, tally, name) {
            if (!root || !list) { return []; }
            for (const entry of list) {
              const p = parts(entry);
              let nodes;
              try { nodes = p.sel ? root.querySelectorAll(p.sel) : [root]; }
              catch (e) { continue; }
              const out = [];
              for (const node of nodes) {
                const value = valueOf(node, p.attr);
                if (value) { out.push(value); }
              }
              if (out.length) {
                if (tally && name) { tally[name] = (tally[name] || 0) + out.length; }
                return out;
              }
            }
            return [];
          }

          function nodes(root, list) {
            if (!root || !list) { return []; }
            for (const entry of list) {
              let found;
              try { found = root.querySelectorAll(entry); }
              catch (e) { continue; }
              if (found.length) { return Array.prototype.slice.call(found); }
            }
            return [];
          }

          function has(root, list) {
            if (!root || !list) { return false; }
            for (const entry of list) {
              try { if (root.querySelector(entry)) { return true; } }
              catch (e) { continue; }
            }
            return false;
          }

          // ---- Reading ----------------------------------------------------

          function readNav(sel) {
            return {
              cartCount: one(document, sel.navCart),
              account: one(document, sel.navAccount)
            };
          }

          function readCards(sel, tally) {
            const out = [];
            let found;
            try { found = document.querySelectorAll(sel.card); }
            catch (e) { return out; }
            // Capped: a results page is sixteen or so organic products, and
            // whatever is past a hundred cards is shelves and carousels the
            // grid has no room for anyway.
            const limit = Math.min(found.length, 100);
            for (let i = 0; i < limit; i++) {
              const card = found[i];
              out.push({
                asin: (card.getAttribute('data-asin') || '').trim(),
                // The label's text, not a verdict. Whether this makes the
                // card an advert is Swift's call.
                sponsored: one(card, sel.sponsored),
                title: one(card, sel.cardTitle, tally, 'cardTitle'),
                image: one(card, sel.cardImage, tally, 'cardImage'),
                prices: many(card, sel.cardPrices, tally, 'cardPrices'),
                priceText: one(card, sel.cardPriceText, tally, 'cardPriceText'),
                rating: one(card, sel.cardRating, tally, 'cardRating'),
                reviews: one(card, sel.cardReviews, tally, 'cardReviews'),
                delivery: one(card, sel.cardDelivery, tally, 'cardDelivery'),
                badge: one(card, sel.cardBadge, tally, 'cardBadge')
              });
            }
            if (tally) { tally.card = found.length; }
            return out;
          }

          function readSpecs(sel, tally, which) {
            const out = [];
            const rows = nodes(document, which);
            for (const row of rows.slice(0, 40)) {
              const label = one(row, sel.specLabel);
              const value = one(row, sel.specValue);
              if (label || value) { out.push({ label: label, value: value }); }
            }
            if (tally) { tally.specRow = (tally.specRow || 0) + rows.length; }
            return out;
          }

          function readVariations(sel, tally) {
            const out = [];
            const rows = nodes(document, sel.variationRow);
            for (const row of rows.slice(0, 8)) {
              const options = [];
              const swatches = nodes(row, sel.variationOption);
              for (const swatch of swatches.slice(0, 60)) {
                options.push({
                  value: one(swatch, sel.variationOptionValue),
                  asin: one(swatch, sel.variationOptionASIN),
                  priceText: one(swatch, sel.variationOptionPrice),
                  // Amazon marks a combination it cannot sell; the class is
                  // reported, never interpreted here.
                  available: !/unavailable|swatch-disabled/i.test(
                    (swatch.className || '').toString()
                  )
                });
              }
              out.push({
                dimension: one(row, sel.variationID),
                label: one(row, sel.variationLabel),
                selected: one(row, sel.variationSelected),
                options: options
              });
            }
            if (tally) { tally.variationRow = rows.length; }
            return out;
          }

          function readReviews(sel, tally) {
            const out = [];
            const rows = nodes(document, sel.reviewRow);
            for (const row of rows.slice(0, 30)) {
              out.push({
                id: one(row, sel.reviewID),
                stars: one(row, sel.reviewStars),
                title: one(row, sel.reviewTitle),
                author: one(row, sel.reviewAuthor),
                date: one(row, sel.reviewDate),
                verified: has(row, sel.reviewVerified),
                body: one(row, sel.reviewBody),
                helpful: one(row, sel.reviewHelpful),
                variation: one(row, sel.reviewVariation)
              });
            }
            if (tally) { tally.reviewRow = rows.length; }
            return out;
          }

          // Amazon publishes the real photographs as JSON inside a script
          // tag; the markup's image strip is forty-pixel thumbnails. This
          // copies the blob out and reads none of it — parsing is Swift's,
          // in `AmazonGallery`.
          function galleryBlob() {
            const scripts = document.getElementsByTagName('script');
            for (let i = 0; i < scripts.length; i++) {
              const src = scripts[i].textContent || '';
              const at = src.indexOf("'colorImages'");
              if (at < 0) { continue; }
              const open = src.indexOf("parseJSON('", at);
              if (open < 0) { continue; }
              const start = open + 11;
              const end = src.indexOf("')", start);
              if (end < 0) { continue; }
              const blob = src.slice(start, end);
              // A sanity bound, not a parse: a runaway match should not send
              // half a megabyte of script across the bridge.
              return blob.length < 400000 ? blob : '';
            }
            return '';
          }

          function quantityMax(sel) {
            for (const entry of sel.productQuantity || []) {
              let node;
              try { node = document.querySelector(entry); }
              catch (e) { continue; }
              if (node && node.options && node.options.length) {
                return node.options.length;
              }
            }
            return 0;
          }

          function readProduct(sel, tally) {
            const title = one(document, sel.productTitle, tally, 'productTitle');
            // No title, no product page. Everything else is optional; this
            // is the one field whose absence means there is nothing here.
            if (!title) { return null; }
            const path = (location.pathname || '');
            return {
              // The id comes from the address, which is the only place it is
              // stated without ambiguity. Swift validates its shape.
              asin: path,
              title: title,
              byline: one(document, sel.productByline, tally, 'productByline'),
              prices: many(document, sel.productPrices, tally, 'productPrices'),
              priceText: one(document, sel.productPriceText),
              listPrice: one(document, sel.productListPrice),
              rating: one(document, sel.productRating, tally, 'productRating'),
              reviews: one(document, sel.productReviews),
              availability: one(document, sel.productAvailability),
              delivery: one(document, sel.productDelivery),
              seller: one(document, sel.productSeller),
              shipsFrom: one(document, sel.productShipsFrom),
              returns: one(document, sel.productReturns),
              // Presence, not text: the badge carries its own tooltip as a
              // child, so reading it returns a paragraph.
              choiceBadge: has(document, sel.productChoiceBadge),
              bought: one(document, sel.productBought),
              images: many(document, sel.productImages, tally, 'productImages'),
              bullets: many(document, sel.productBullets, tally, 'productBullets'),
              specs: readSpecs(sel, tally, sel.specRow),
              keySpecs: readSpecs(sel, tally, sel.keySpecRow),
              variations: readVariations(sel, tally),
              addToCart: has(document, sel.productAddToCart),
              gallery: galleryBlob(),
              quantityMax: quantityMax(sel)
            };
          }

          agent.define('amazon.page', (params) => {
            const sel = (params && params.selectors) || {};
            const tally = {};
            const cards = readCards(sel, tally);
            const product = readProduct(sel, tally);
            return {
              cards: cards,
              resultBar: one(document, sel.resultBar),
              noResults: one(document, sel.noResults),
              botCheck: has(document, sel.botCheck),
              signIn: has(document, sel.signIn),
              product: product,
              reviews: product ? readReviews(sel, tally) : [],
              histogram: product ? many(document, sel.histogramRow) : [],
              nav: readNav(sel),
              matches: tally
            };
          });

          // The cheap read, for confirming a write. A whole page read to
          // check one number would be absurd.
          agent.define('amazon.nav', (params) => {
            const sel = (params && params.selectors) || {};
            return readNav(sel);
          });

          // ---- The one thing that writes ----------------------------------
          //
          // It presses Amazon's own button. It does not build a request,
          // because that would mean owning Amazon's rotating session and
          // anti-forgery tokens, and getting one of them wrong means adding
          // the wrong thing to someone's cart.
          //
          // What it returns is only whether there was a button to press.
          // Whether anything actually reached the cart is observed
          // afterwards, from the page — a click resolves instantly and the
          // request behind it lands a second or two later.
          agent.define('amazon.addToCart', (params) => {
            const sel = (params && params.selectors) || {};
            const wanted = params && params.quantity;
            if (wanted && wanted > 1) {
              const box = document.querySelector('#quantity');
              if (box) {
                box.value = String(wanted);
                // Amazon listens for the event, not the property.
                box.dispatchEvent(new Event('change', { bubbles: true }));
              }
            }
            let button = null;
            for (const entry of sel.productAddToCart || []) {
              try { button = document.querySelector(entry); }
              catch (e) { continue; }
              if (button) { break; }
            }
            if (!button) { return false; }
            button.click();
            return true;
          });
        })();
        """
    }
}
