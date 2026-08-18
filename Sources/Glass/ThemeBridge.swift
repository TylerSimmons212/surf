import Foundation
import GlassCore
import WebKit

/// The scripts that let a page be measured and then restyled.
///
/// Everything here is deliberately thin. The decisions — what a colour is
/// doing, what it becomes, whether the result can be read — all live in
/// `GlassCore`, where they can be tested without a web view. This side only
/// gathers evidence and writes back an answer it was handed.
///
/// All of it runs in an isolated content world. The page keeps its own
/// `window`, and nothing we define can collide with, or be reached by, the
/// site's own scripts.
enum ThemeBridge {

    /// The channel the page uses to say it has changed under us.
    static let handlerName = "glassTheme"


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
      return JSON.stringify({ ground: '', themed: false, ready: false, colors: [] });
    }

    \(traversal)

    // Every sheet of ours, wherever it ended up — the document, an iframe, or
    // adopted by a shadow root. Switched off around the read, because measuring
    // through our own paint would only measure our own paint.
    function ourStyleSheets() {
      const sheets = [];
      function add(sheet) { if (sheet && sheets.indexOf(sheet) === -1) { sheets.push(sheet); } }
      const preflight = document.getElementById('__glass_preflight');
      add(preflight && preflight.sheet);
      (window.__glassSheets || []).forEach(add);
      return sheets;
    }

    const ourSheets = ourStyleSheets();
    ourSheets.forEach(function (sheet) { sheet.disabled = true; });

    try {

    const viewport = Math.max(1, innerWidth * innerHeight);
    const found = new Map();

    // Sampling marks, to find the colourless ones that would vanish.
    //
    // 64x64 rather than something smaller: a wordmark's strokes are thin, and
    // reduced much further they survive only as part-transparent smudges, which
    // is not enough to tell ink from colour. getImageData throws for a
    // cross-origin image loaded without CORS — that refusal is the whole
    // answer, since an image we can't inspect is one we leave alone.
    if (!window.__glassSeenImages) { window.__glassSeenImages = new Set(); }
    const sampled = [];
    const canvas = document.createElement('canvas');
    canvas.width = 64;
    canvas.height = 64;
    const context = canvas.getContext('2d', { willReadFrequently: true });

    function sampleImage(element, backdrop) {
      if (sampled.length >= 16) { return; }
      const source = element.currentSrc || element.src;
      if (!source || window.__glassSeenImages.has(source)) { return; }
      if (!element.complete || !element.naturalWidth) { return; }

      const box = element.getBoundingClientRect();
      // Too small to matter, or far too large to be a mark rather than a
      // picture — and a picture is opaque and was never at risk.
      if (box.width < 8 || box.height < 8) { return; }
      if (box.width > 512 || box.height > 512) { return; }

      window.__glassSeenImages.add(source);
      try {
        context.clearRect(0, 0, 64, 64);
        context.drawImage(element, 0, 0, 64, 64);
        const data = context.getImageData(0, 0, 64, 64).data;
        let binary = '';
        for (let j = 0; j < data.length; j++) { binary += String.fromCharCode(data[j]); }
        sampled.push({ key: source, pixels: btoa(binary), backdrop: backdrop || '' });
      } catch (error) { /* tainted: left alone */ }
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

    eachElement(document, \(elementBudget), function (element) {
      const style = styleOf(element);
      if (style.display === 'none' || style.visibility === 'hidden') { return; }

      const box = element.getBoundingClientRect();
      const area = Math.max(0, box.width * box.height) / viewport;
      const interactive = !!element.closest(
        'a, button, [role="button"], input, select, textarea, summary'
      );
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

      if (element.localName === 'img') { sampleImage(element, backdrop); }
    });

    // What the page is actually sitting on, which decides whether it needs us
    // at all. Walked up from the body because a transparent body shows the
    // html element's paint, and that's what the eye sees.
    let ground = getComputedStyle(document.body || document.documentElement).backgroundColor;
    if (!opaque(ground)) {
      ground = getComputedStyle(document.documentElement).backgroundColor;
    }

    // Whether this page already carries a theme. When it does, the ground is
    // ours rather than the site's, and can't be read as evidence about it.
    const themed = !!document.getElementById('__glass_theme');

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
    if (window.__glassObserver) { window.__glassObserver.disconnect(); }

    \(traversal)

    const RULES = `
    @media screen {
      :root { color-scheme: ${scheme}; }
      html { background-color: ${ground} !important; }
      [data-glass-bg] { background-color: var(--glass-bg) !important; }
      [data-glass-fg] { color: var(--glass-fg) !important; }
      [data-glass-bd] { border-color: var(--glass-bd) !important; }
      [data-glass-ol] { outline-color: var(--glass-ol) !important; }
      [data-glass-gr] { background-image: var(--glass-gr) !important; }
      [data-glass-fl] { fill: var(--glass-fl) !important; }
      [data-glass-st] { stroke: var(--glass-st) !important; }
      /* Only ever on a mark carrying no colour, so there is no hue to shift.
         A filter touches the pixels already being drawn and leaves
         transparency transparent — no box appears around the artwork. */
      img[data-glass-invert] { filter: invert(1) brightness(0.92) !important; }
      /* A mark that does carry colour flips its lightness while holding its
         hue. Plain inversion takes the complement, which is what turns a blue
         badge orange and a green logotype pink. */
      img[data-glass-invert-hue] {
        filter: url(#glass-hue-invert) brightness(0.92) !important;
      }
    }`;

    window.__glassSheets = [];
    function register(sheet) {
      if (sheet && window.__glassSheets.indexOf(sheet) === -1) {
        window.__glassSheets.push(sheet);
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
      if (target.getElementById('__glass_filters')) { return; }
      const NS = 'http://www.w3.org/2000/svg';
      const holder = target.createElementNS(NS, 'svg');
      holder.id = '__glass_filters';
      holder.setAttribute('width', '0');
      holder.setAttribute('height', '0');
      holder.setAttribute('aria-hidden', 'true');
      holder.style.position = 'absolute';
      const filter = target.createElementNS(NS, 'filter');
      filter.id = 'glass-hue-invert';
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
      let element = target.getElementById('__glass_theme');
      if (!element) {
        element = target.createElement('style');
        element.id = '__glass_theme';
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
      if (!window.__glassShadowSheet) {
        try { window.__glassShadowSheet = new CSSStyleSheet(); }
        catch (error) { window.__glassShadowSheet = null; }
      }
      const sheet = window.__glassShadowSheet;
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

    const preflight = document.getElementById('__glass_preflight');
    if (preflight && preflight.sheet) { preflight.sheet.disabled = true; }

    function paint(element, attribute, variable, replacement) {
      if (!replacement) { return; }
      element.style.setProperty(variable, replacement);
      element.setAttribute(attribute, '');
    }

    try {
      eachElement(document, \(elementBudget), function (element) {
        const style = styleOf(element);

        const maskImage = style.maskImage || style.webkitMaskImage;
        const masked = !!maskImage && maskImage !== 'none';
        // Same property and the same variable — the ink is delivered through
        // background-color either way; only the decision differs.
        paint(element, 'data-glass-bg', '--glass-bg',
              plan[(masked ? 'maskink|' : 'background|') + style.backgroundColor]);
        paint(element, 'data-glass-fg', '--glass-fg',
              plan['text|' + style.color]);
        paint(element, 'data-glass-bd', '--glass-bd',
              plan['border|' + style.borderTopColor]);
        paint(element, 'data-glass-ol', '--glass-ol',
              plan['outline|' + style.outlineColor]);

        if (element instanceof SVGElement) {
          paint(element, 'data-glass-fl', '--glass-fl', plan['fill|' + style.fill]);
          paint(element, 'data-glass-st', '--glass-st', plan['stroke|' + style.stroke]);
        }

        const image = style.backgroundImage;
        if (image && image !== 'none' && image.indexOf('gradient(') !== -1) {
          paint(element, 'data-glass-gr', '--glass-gr', plan['gradient|' + image]);
        }

        if (element.localName === 'img') {
          const source = element.currentSrc || element.src;
          if (inverts[source]) {
            element.setAttribute('data-glass-invert', '');
          } else if (hueInverts[source]) {
            // A filter referenced by url(#id) resolves against the document, so
            // it is only offered where that reference can be trusted: not from
            // inside a shadow tree, whose fragments resolve in their own scope,
            // and not on a page carrying a <base>, which would send the lookup
            // to another URL entirely. Where it can't be trusted the mark is
            // left as it is, which is the safe half of the trade.
            const owner = element.ownerDocument;
            const inShadow = !!(element.getRootNode() && element.getRootNode().host);
            if (!inShadow && owner.getElementById('glass-hue-invert')
                && !owner.querySelector('base')) {
              element.setAttribute('data-glass-invert-hue', '');
            }
          }
        }
      }, function (root) {
        // A tree discovered on the way: give it the rules, or nothing marked
        // inside it will mean anything.
        if (root.host) { styleShadow(root); }
        else if (root.documentElement) { styleDocument(root); }
      });
    } finally {
      (window.__glassSheets || []).forEach(function (sheet) { sheet.disabled = false; });
    }

    // Last, so there is never a frame between the holding colour coming off and
    // the real one going on.
    document.getElementById('__glass_preflight')?.remove();

    // Then watch for the page changing underneath us — a section revealed on
    // scroll, a lazily loaded list, a subtree re-rendered with our properties
    // torn off. Coalesced into one report, because a list that adds fifty rows
    // fires fifty times and they all want the same answer.
    if (!window.__glassObserver) {
      window.__glassObserver = new MutationObserver(function () {
        if (window.__glassPending) { return; }
        window.__glassPending = setTimeout(function () {
          window.__glassPending = null;
          window.webkit.messageHandlers.\(handlerName).postMessage('changed');
        }, 250);
      });
    }
    window.__glassObserver.observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['class', 'style']
    });
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
          if (document.getElementById('__glass_preflight')) { return; }
          const style = document.createElement('style');
          style.id = '__glass_preflight';
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
    document.getElementById('__glass_preflight')?.remove();
    return true;
    """

    static let revertScript = """
    window.__glassObserver?.disconnect();
    window.__glassObserver = null;
    window.__glassSheets = [];
    window.__glassSeenImages = null;
    document.getElementById('__glass_theme')?.remove();
    document.getElementById('__glass_preflight')?.remove();
    document.getElementById('__glass_filters')?.remove();
    const attributes = ['data-glass-bg', 'data-glass-fg', 'data-glass-bd',
                        'data-glass-ol', 'data-glass-gr',
                        'data-glass-fl', 'data-glass-st', 'data-glass-invert',
                        'data-glass-invert-hue'];
    const variables = ['--glass-bg', '--glass-fg', '--glass-bd',
                       '--glass-ol', '--glass-gr',
                       '--glass-fl', '--glass-st'];
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
    struct Reading: Decodable {
        var value: String
        var property: String
        var area: Double
        var interactive: Bool
        var large: Bool
        /// The colour this one is painted on top of, where there is one.
        var on: String?
    }

    /// One image, reduced to something the analysis can read.
    struct ImageReading: Decodable {
        var key: String
        /// Base64 of a 64x64 RGBA reduction.
        var pixels: String
        /// The site's own colour behind it, resolved through the plan to find
        /// what it will actually be sitting on once the theme lands.
        var backdrop: String
    }

    struct Survey: Decodable {
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

    /// Turns the page's report into the observations `GlassCore` reasons about.
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
