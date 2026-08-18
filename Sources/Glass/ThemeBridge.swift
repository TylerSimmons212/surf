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
    // Nothing useful to measure yet, and a page mid-parse reports a palette of
    // three colours that isn't the site's. Reported rather than guessed at, so
    // the caller can leave the holding colour up and come back.
    if (document.readyState === 'loading') {
      return JSON.stringify({ ground: '', themed: false, ready: false, colors: [] });
    }

    // Measuring through our own paint would only measure our own paint, so both
    // the holding colour and the theme itself are switched off for the read.
    //
    // This is what makes a page re-readable. Once a colour is overridden,
    // getComputedStyle returns the value *we* wrote, and the author's is no
    // longer observable — so a second look would either transform our own
    // output again or have to skip everything it had already touched. Skipping
    // is what a reveal-on-scroll page punishes: an element whose colour changes
    // underneath us has already been marked, so it would keep the answer for a
    // colour it no longer has.
    //
    // Safe because nothing paints in the middle of a script turn: the browser
    // renders between turns, not during one, so the page is never shown
    // unstyled. getComputedStyle still forces the recalc, synchronously.
    const ourSheets = ['__glass_preflight', '__glass_theme']
      .map(function (id) { const el = document.getElementById(id); return el && el.sheet; })
      .filter(Boolean);
    ourSheets.forEach(function (sheet) { sheet.disabled = true; });

    let payload = null;
    let deferred = [];

    try {

    // Sample any image that might be a logo.
    //
    // Pixels are never altered — this only asks whether the artwork would
    // survive on a dark page, and the answer, when it is no, is a plate painted
    // behind it. A 16x16 reduction is plenty for "is this broadly dark ink on
    // nothing", and keeps the message small.
    //
    // getImageData throws for a cross-origin image loaded without CORS, which
    // is most images on most sites. That is left as a refusal rather than
    // worked around: an image we cannot inspect is one we leave exactly alone,
    // which is the safe outcome anyway.
    if (!window.__glassSeenImages) { window.__glassSeenImages = new Set(); }
    const sampled = [];
    const backgroundGrounds = [];

    function firstURL(value) {
      if (!value) { return ''; }
      const start = value.indexOf('url(');
      if (start === -1) { return ''; }
      let inner = value.slice(start + 4);
      const end = inner.indexOf(')');
      if (end === -1) { return ''; }
      inner = inner.slice(0, end).trim();
      const quote = inner.charAt(0);
      if (quote === '"' || quote === "'") { inner = inner.slice(1, -1); }
      // A data: URI is already in hand and costs nothing; anything else is a
      // fetch we only want to make once.
      return inner;
    }

    function pixelsOf(image) {
      try {
        context.clearRect(0, 0, 16, 16);
        context.drawImage(image, 0, 0, 16, 16);
        const data = context.getImageData(0, 0, 16, 16).data;
        let binary = '';
        for (let j = 0; j < data.length; j++) { binary += String.fromCharCode(data[j]); }
        return btoa(binary);
      } catch (error) {
        return null;  // tainted: left alone, which is the safe outcome
      }
    }
    const canvas = document.createElement('canvas');
    canvas.width = 16;
    canvas.height = 16;
    const context = canvas.getContext('2d', { willReadFrequently: true });

    const viewport = Math.max(1, innerWidth * innerHeight);
    const found = new Map();

    function opaque(value) {
      return !!value && value !== 'transparent' && value.indexOf('rgba(0, 0, 0, 0)') !== 0;
    }

    // What each element's content actually sits on.
    //
    // Text is legible against the thing behind *it*, not against the page: a
    // label on a brand-coloured button is judged on that button. Filled in as
    // the walk goes, which is O(n) rather than O(n·depth) because
    // querySelectorAll returns document order, so a parent is always resolved
    // before its children ask for it.
    const backdrops = new Map();
    function backdropFor(element, own) {
      if (opaque(own)) { backdrops.set(element, own); return own; }
      const parent = element.parentElement;
      const inherited = parent ? (backdrops.get(parent) || '') : '';
      backdrops.set(element, inherited);
      return inherited;
    }

    function note(value, property, area, interactive, large, on) {
      if (!opaque(value)) return;
      const key = property + '|' + value;
      const existing = found.get(key);
      if (existing) {
        // The largest sighting wins, and carries its backdrop with it.
        if (area > existing.area) { existing.area = area; existing.on = on || ''; }
        existing.interactive = existing.interactive || interactive;
        existing.large = existing.large || large;
      } else {
        found.set(key, { value, property, area, interactive, large, on: on || '' });
      }
    }

    const elements = document.querySelectorAll('*');
    const limit = Math.min(elements.length, \(elementBudget));
    for (let i = 0; i < limit; i++) {
      const element = elements[i];
      const style = getComputedStyle(element);
      if (style.display === 'none' || style.visibility === 'hidden') continue;

      const box = element.getBoundingClientRect();
      const area = Math.max(0, box.width * box.height) / viewport;
      const interactive = !!element.closest(
        'a, button, [role="button"], input, select, textarea, summary'
      );
      const fontSize = parseFloat(style.fontSize) || 16;
      const weight = parseInt(style.fontWeight, 10) || 400;
      // WCAG's large-text threshold, in the px it converts to.
      const large = fontSize >= 24 || (fontSize >= 18.5 && weight >= 700);

      const backdrop = backdropFor(element, style.backgroundColor);

      note(style.backgroundColor, 'background', area, interactive, large, '');
      note(style.color, 'text', area, interactive, large, backdrop);

      // Only where a border is actually drawn.
      //
      // An element without one still reports a border colour, because the
      // initial value is currentColor — so every element on the page claims a
      // border in its own text colour. That is not merely noise: html and body
      // cover the whole viewport, so their phantom black border wins the
      // aggregation on area, and the real hairline's backdrop is never seen.
      // Emphasis is measured against that backdrop, so losing it costs the
      // border its weight.
      function noteEdge(width, style_, color) {
        if (style_ === 'none' || style_ === 'hidden') { return; }
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

      // SVG paint, which is how most sites now ship their icons. This is DOM
      // rather than pixels, so it is recoloured like anything else and gets the
      // same role treatment: a neutral mark inverts as text does, a chromatic
      // one is brand and keeps its hue. Only real colours — `none`, and a
      // url(#gradient) reference, are not ours to touch.
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

      // A background image is artwork too, and can be backed the same way —
      // background-color paints behind background-image, so the plate lands
      // under it without the artwork being touched. Deferred to after the
      // measurement, because reading one means loading it.
      const backgroundURL = firstURL(style.backgroundImage);
      if (backgroundURL && !window.__glassSeenImages.has(backgroundURL)
          && backgroundGrounds.length < 8) {
        window.__glassSeenImages.add(backgroundURL);
        backgroundGrounds.push({ url: backgroundURL, backdrop: backdrop });
      }

      // Gradients only. A url() is an image, and images are never recoloured.
      const image = style.backgroundImage;
      if (image && image !== 'none' && image.indexOf('gradient(') !== -1) {
        note(image, 'gradient', area, interactive, large, backdrop);
      }
    }

    const images = document.querySelectorAll('img');

    for (let i = 0; i < Math.min(images.length, 40) && sampled.length < 16; i++) {
      const image = images[i];
      const source = image.currentSrc || image.src;
      if (!source || window.__glassSeenImages.has(source)) { continue; }
      if (!image.complete || !image.naturalWidth) { continue; }

      const box = image.getBoundingClientRect();
      // Too small to matter, or far too large to be a mark rather than a
      // picture — and a picture is opaque and was never at risk.
      if (box.width < 8 || box.height < 8) { continue; }
      if (box.width > 512 || box.height > 512) { continue; }

      window.__glassSeenImages.add(source);
      const pixels = pixelsOf(image);
      if (!pixels) { continue; }
      sampled.push({ key: source, pixels: pixels, backdrop: backdrops.get(image) || '' });
    }

    // What the page is actually sitting on, which decides whether it needs us
    // at all. Walked up from the body because a transparent body shows the
    // html element's paint, and that's what the eye sees.
    let ground = getComputedStyle(document.body || document.documentElement).backgroundColor;
    if (!ground || ground.indexOf('rgba(0, 0, 0, 0)') === 0) {
      ground = getComputedStyle(document.documentElement).backgroundColor;
    }

    // Whether this page already carries a theme. When it does, the ground is
    // ours rather than the site's, so the caller must not read it as evidence
    // that the site was always dark — it simply sweeps whatever is new.
    const themed = !!document.getElementById('__glass_theme');

    payload = {
      ground: ground || '', themed: themed, ready: true,
      colors: Array.from(found.values()), images: sampled
    };
    deferred = backgroundGrounds;

    } finally {
      ourSheets.forEach(function (sheet) { sheet.disabled = false; });
    }

    // Only now is it safe to wait for anything. An await yields to the event
    // loop, and a frame painted while our styles were switched off would show
    // the page stripped bare — so every measurement above had to be
    // synchronous, and loading an image never can be.
    for (const pending of deferred) {
      const pixels = await new Promise(function (resolve) {
        const image = new Image();
        let settled = false;
        function finish(value) { if (!settled) { settled = true; resolve(value); } }
        image.onload = function () { finish(pixelsOf(image)); };
        image.onerror = function () { finish(null); };
        // A background that never arrives must not hold the sweep open.
        setTimeout(function () { finish(null); }, 1200);
        // Deliberately no crossOrigin: asking for CORS would make a second,
        // uncached request of every background on the page, and an image we
        // can't read is one we leave alone anyway.
        image.src = pending.url;
      });
      if (pixels) {
        payload.images.push({ key: pending.url, pixels: pixels, backdrop: pending.backdrop });
      }
    }

    return JSON.stringify(payload);
    """

    /// Writes the plan onto the page.
    ///
    /// Each element gets a custom property and a marker attribute, and one
    /// injected stylesheet turns those into declarations. The indirection is
    /// worth it: the author's own rules are never overwritten, so the original
    /// value survives, removing the theme is a matter of dropping attributes,
    /// and a page that re-renders can be swept again without anything having
    /// been destroyed in the meantime.
    ///
    /// The whole sheet is `@media screen`. WebKit forces light appearance while
    /// printing, and an unscoped dark theme would put black pages through
    /// someone's printer.
    static let applyScript = """
    // Stop watching while we write. Our own attribute and property changes are
    // page mutations like any other, and an observer left running would report
    // them straight back and sweep forever.
    if (window.__glassObserver) { window.__glassObserver.disconnect(); }

    const sheetID = '__glass_theme';
    let sheet = document.getElementById(sheetID);
    if (!sheet) {
      sheet = document.createElement('style');
      sheet.id = sheetID;
      document.documentElement.appendChild(sheet);
    }

    sheet.textContent = `
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
      /* Behind the artwork, never over it. The image itself is untouched; its
         transparent areas simply show this instead of the dark page. Last, so
         it wins over a background colour on the same element — the plate was
         computed to make that particular artwork readable. */
      [data-glass-plate] { background-color: var(--glass-plate) !important; }
    }`;

    // Read the site's colours, not ours — the plan is keyed on what the author
    // wrote, and with our sheet live every lookup would be of our own output.
    const ourSheets = ['__glass_preflight', '__glass_theme']
      .map(function (id) { const el = document.getElementById(id); return el && el.sheet; })
      .filter(Boolean);
    ourSheets.forEach(function (each) { each.disabled = true; });

    function firstURL(value) {
      if (!value) { return ''; }
      const start = value.indexOf('url(');
      if (start === -1) { return ''; }
      let inner = value.slice(start + 4);
      const end = inner.indexOf(')');
      if (end === -1) { return ''; }
      inner = inner.slice(0, end).trim();
      const quote = inner.charAt(0);
      if (quote === '"' || quote === "'") { inner = inner.slice(1, -1); }
      return inner;
    }

    function paint(element, attribute, variable, replacement) {
      if (!replacement) { return; }
      element.style.setProperty(variable, replacement);
      element.setAttribute(attribute, '');
    }

    try {
      const elements = document.querySelectorAll('*');
      const limit = Math.min(elements.length, \(elementBudget));
      for (let i = 0; i < limit; i++) {
        const element = elements[i];
        const style = getComputedStyle(element);

        paint(element, 'data-glass-bg', '--glass-bg',
              plan['background|' + style.backgroundColor]);
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
        if (image && image !== 'none') {
          if (image.indexOf('gradient(') !== -1) {
            paint(element, 'data-glass-gr', '--glass-gr', plan['gradient|' + image]);
          }
          // A background image gets its plate on the element carrying it,
          // where background-color already paints underneath the artwork.
          const backgroundURL = firstURL(image);
          if (backgroundURL) {
            paint(element, 'data-glass-plate', '--glass-plate', plates[backgroundURL]);
          }
        }
      }
    } finally {
      ourSheets.forEach(function (each) { each.disabled = false; });
    }

    const images = document.querySelectorAll('img');
    for (let i = 0; i < Math.min(images.length, 64); i++) {
      const image = images[i];
      const plate = plates[image.currentSrc || image.src];
      if (plate) {
        image.style.setProperty('--glass-plate', plate);
        image.setAttribute('data-glass-plate', '');
      }
    }

    // Last, so there is never a frame between the holding colour coming off and
    // the real one going on.
    document.getElementById('__glass_preflight')?.remove();

    // Then watch for the page changing underneath us — a section revealed on
    // scroll, a lazily loaded list, a header that turns opaque, a framework
    // re-rendering a subtree and taking our properties with it. Coalesced into
    // one report, because a page that loads fifty rows fires fifty times and
    // they all want the same single answer.
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
      // Colour follows class far more often than it follows an inline style,
      // and watching every attribute on a large page is a lot of noise for the
      // two that matter.
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
    window.__glassSeenImages = null;
    document.getElementById('__glass_theme')?.remove();
    document.getElementById('__glass_preflight')?.remove();
    const attributes = ['data-glass-bg', 'data-glass-fg', 'data-glass-bd',
                        'data-glass-ol', 'data-glass-gr', 'data-glass-plate',
                        'data-glass-fl', 'data-glass-st'];
    const variables = ['--glass-bg', '--glass-fg', '--glass-bd',
                       '--glass-ol', '--glass-gr', '--glass-plate',
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
        /// Base64 of a 16x16 RGBA reduction.
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
        default: return nil
        }
    }
}
