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
    // Measuring through our own holding colour would only measure the holding
    // colour — the page would look dark, be declared already dark, and be left
    // alone in a scheme it never had. So the preflight is switched off for the
    // duration of the read.
    //
    // Safe because nothing paints in the middle of a script turn: the browser
    // renders between turns, not during one, so the page is never shown without
    // it. `getComputedStyle` still forces the recalc we need, synchronously.
    const preflight = document.getElementById('__glass_preflight');
    const preflightSheet = preflight ? preflight.sheet : null;
    if (preflightSheet) { preflightSheet.disabled = true; }

    try {

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

      // A property we have already overridden now reports *our* colour.
      // Reading it back would transform it a second time and undo the work, so
      // anything already marked is skipped rather than re-measured.
      if (!element.hasAttribute('data-glass-bg')) {
        note(style.backgroundColor, 'background', area, interactive, large, '');
      }
      if (!element.hasAttribute('data-glass-fg')) {
        note(style.color, 'text', area, interactive, large, backdrop);
      }
      if (!element.hasAttribute('data-glass-bd')) {
        note(style.borderTopColor, 'border', area, interactive, large, backdrop);
        note(style.borderBottomColor, 'border', area, interactive, large, backdrop);
        note(style.borderLeftColor, 'border', area, interactive, large, backdrop);
        note(style.borderRightColor, 'border', area, interactive, large, backdrop);
      }
      if (!element.hasAttribute('data-glass-ol')) {
        note(style.outlineColor, 'outline', area, interactive, large, backdrop);
      }

      // Gradients only. A url() is an image, and images are never recoloured.
      const image = style.backgroundImage;
      if (!element.hasAttribute('data-glass-gr')
          && image && image !== 'none' && image.indexOf('gradient(') !== -1) {
        note(image, 'gradient', area, interactive, large);
      }
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

    return JSON.stringify({
      ground: ground || '', themed: themed, colors: Array.from(found.values())
    });

    } finally {
      if (preflightSheet) { preflightSheet.disabled = false; }
    }
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
    // Off for the read, and then removed for good once the real theme is in
    // place — the lookups below are keyed on the site's own colours, not on the
    // ones we are holding over the top of them.
    const preflight = document.getElementById('__glass_preflight');
    if (preflight && preflight.sheet) { preflight.sheet.disabled = true; }

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
    }`;

    function paint(element, property, attribute, variable, replacement) {
      if (!replacement) return;
      element.style.setProperty(variable, replacement);
      element.setAttribute(attribute, '');
    }

    const elements = document.querySelectorAll('*');
    const limit = Math.min(elements.length, \(elementBudget));
    for (let i = 0; i < limit; i++) {
      const element = elements[i];
      const style = getComputedStyle(element);

      paint(element, 'background', 'data-glass-bg', '--glass-bg',
            plan['background|' + style.backgroundColor]);
      paint(element, 'text', 'data-glass-fg', '--glass-fg',
            plan['text|' + style.color]);
      paint(element, 'border', 'data-glass-bd', '--glass-bd',
            plan['border|' + style.borderTopColor]);
      paint(element, 'outline', 'data-glass-ol', '--glass-ol',
            plan['outline|' + style.outlineColor]);

      const image = style.backgroundImage;
      if (image && image !== 'none' && image.indexOf('gradient(') !== -1) {
        paint(element, 'gradient', 'data-glass-gr', '--glass-gr',
              plan['gradient|' + image]);
      }
    }

    // Last, so there is never a frame between the holding colour coming off and
    // the real one going on.
    document.getElementById('__glass_preflight')?.remove();
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
    document.getElementById('__glass_theme')?.remove();
    document.getElementById('__glass_preflight')?.remove();
    const attributes = ['data-glass-bg', 'data-glass-fg', 'data-glass-bd',
                        'data-glass-ol', 'data-glass-gr'];
    const variables = ['--glass-bg', '--glass-fg', '--glass-bd',
                       '--glass-ol', '--glass-gr'];
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

    struct Survey: Decodable {
        var ground: String
        /// True once this page has been themed. The ground reading is then our
        /// own paint, and can't be used to judge what the site does.
        var themed: Bool
        var colors: [Reading]
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
