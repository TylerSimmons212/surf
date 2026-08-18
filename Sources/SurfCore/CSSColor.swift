import Foundation

/// A colour as it appears in a stylesheet, with its alpha kept alongside.
///
/// Alpha never takes part in the theme transform — it describes how much of
/// what's behind shows through, which is a compositing fact rather than a
/// colour choice, and a site that dims an overlay to 60% means that just as
/// much in dark mode. It's carried so the declaration can be written back out
/// intact.
public struct CSSColor: Equatable, Sendable {
    public var rgb: SRGB
    public var alpha: Double

    public init(rgb: SRGB, alpha: Double = 1) {
        self.rgb = rgb
        self.alpha = min(max(alpha, 0), 1)
    }
}

extension CSSColor {

    /// Parses the colour syntaxes that actually appear in stylesheets.
    ///
    /// Returns nil for anything it doesn't fully understand, and that is the
    /// important half of the contract: the caller leaves unrecognised text
    /// exactly as it found it. A colour we transform wrongly is a visible bug
    /// on someone's page, while a colour we decline to touch is merely a spot
    /// this feature hasn't reached yet. `currentColor`, `inherit`, and
    /// `color-mix()` deliberately fall into that second category — each refers
    /// to a value we don't have here, and guessing would be worse than passing.
    public init?(css text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        if value == "transparent" {
            self.init(rgb: .black, alpha: 0)
            return
        }
        if let hex = CSSColor.namedColors[value], let rgb = SRGB(hex: hex) {
            self.init(rgb: rgb, alpha: 1)
            return
        }
        if value.hasPrefix("#") {
            guard let rgb = SRGB(hex: value) else { return nil }
            // SRGB drops alpha; recover it from the 4- and 8-digit forms.
            self.init(rgb: rgb, alpha: CSSColor.hexAlpha(value))
            return
        }
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let function = String(value[value.startIndex..<open])
        let body = String(value[value.index(after: open)..<value.index(before: value.endIndex)])

        // Nested functions mean something like color-mix() or a var() we can't
        // resolve standing alone. Decline rather than mis-split on its commas.
        guard !body.contains("(") else { return nil }

        // Both the legacy comma form and the modern space form, with alpha
        // after a slash in either.
        let parts = body
            .replacingOccurrences(of: "/", with: " / ")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .map(String.init)

        var components: [String] = []
        var alphaText: String?
        var sawSlash = false
        for part in parts {
            if part == "/" { sawSlash = true; continue }
            if sawSlash { alphaText = part } else { components.append(part) }
        }
        // The legacy 4-argument forms put alpha last with no slash.
        if alphaText == nil, components.count == 4, function == "rgba" || function == "hsla"
            || function == "rgb" || function == "hsl" {
            alphaText = components.removeLast()
        }
        guard components.count == 3 else { return nil }

        let alpha = alphaText.flatMap(CSSColor.parseAlpha) ?? 1

        switch function {
        case "rgb", "rgba":
            guard let r = CSSColor.parseChannel(components[0]),
                  let g = CSSColor.parseChannel(components[1]),
                  let b = CSSColor.parseChannel(components[2])
            else { return nil }
            self.init(rgb: SRGB(r: r, g: g, b: b), alpha: alpha)

        case "hsl", "hsla":
            guard let h = CSSColor.parseAngle(components[0]),
                  let s = CSSColor.parsePercentage(components[1]),
                  let l = CSSColor.parsePercentage(components[2])
            else { return nil }
            self.init(rgb: CSSColor.fromHSL(h: h, s: s, l: l), alpha: alpha)

        case "oklch":
            guard let l = CSSColor.parseNumberOrPercentage(components[0], percentBase: 1),
                  let c = CSSColor.parseNumberOrPercentage(components[1], percentBase: 0.4),
                  let h = CSSColor.parseAngle(components[2])
            else { return nil }
            self.init(rgb: OKLCH(l: l, c: c, h: h).displayable, alpha: alpha)

        case "oklab":
            guard let l = CSSColor.parseNumberOrPercentage(components[0], percentBase: 1),
                  let a = CSSColor.parseNumberOrPercentage(components[1], percentBase: 0.4),
                  let b = CSSColor.parseNumberOrPercentage(components[2], percentBase: 0.4)
            else { return nil }
            let chroma = (a * a + b * b).squareRoot()
            let hue = chroma < 1e-9 ? 0 : atan2(b, a) * 180 / .pi
            self.init(rgb: OKLCH(l: l, c: chroma, h: hue).displayable, alpha: alpha)

        default:
            return nil
        }
    }

    /// Writes the colour back out.
    ///
    /// Hex when it's opaque, because that's what stylesheets mostly look like
    /// and it's the most compact thing to inject; the modern `rgb(… / …)` form
    /// when it isn't.
    public var css: String {
        guard alpha < 1 else { return rgb.hex }
        let c = rgb.clamped
        let channel = { (v: Double) in Int((v * 255).rounded()) }
        let a = (alpha * 1000).rounded() / 1000
        return "rgb(\(channel(c.r)) \(channel(c.g)) \(channel(c.b)) / \(a))"
    }

    // MARK: - Component parsing

    private static func hexAlpha(_ text: String) -> Double {
        var t = text
        if t.hasPrefix("#") { t.removeFirst() }
        if t.count == 4 {
            guard let v = UInt32(String(t.suffix(1)), radix: 16) else { return 1 }
            return Double(v * 17) / 255
        }
        if t.count == 8 {
            guard let v = UInt32(String(t.suffix(2)), radix: 16) else { return 1 }
            return Double(v) / 255
        }
        return 1
    }

    /// An rgb() channel: 0-255, or a percentage.
    private static func parseChannel(_ text: String) -> Double? {
        if text.hasSuffix("%") {
            return parsePercentage(text)
        }
        guard let v = Double(text) else { return nil }
        return min(max(v / 255, 0), 1)
    }

    private static func parsePercentage(_ text: String) -> Double? {
        guard text.hasSuffix("%"), let v = Double(text.dropLast()) else { return nil }
        return min(max(v / 100, 0), 1)
    }

    private static func parseNumberOrPercentage(_ text: String, percentBase: Double) -> Double? {
        if text.hasSuffix("%") {
            guard let v = Double(text.dropLast()) else { return nil }
            return v / 100 * percentBase
        }
        return Double(text)
    }

    private static func parseAlpha(_ text: String) -> Double? {
        if text.hasSuffix("%") { return parsePercentage(text) }
        guard let v = Double(text) else { return nil }
        return min(max(v, 0), 1)
    }

    /// Hue, in any of the units CSS allows for an angle.
    private static func parseAngle(_ text: String) -> Double? {
        if text == "none" { return 0 }
        for (suffix, factor) in [("deg", 1.0), ("grad", 0.9), ("rad", 180 / Double.pi), ("turn", 360.0)]
        where text.hasSuffix(suffix) {
            guard let v = Double(text.dropLast(suffix.count)) else { return nil }
            return v * factor
        }
        return Double(text)
    }

    private static func fromHSL(h: Double, s: Double, l: Double) -> SRGB {
        let hue = h.truncatingRemainder(dividingBy: 360) / 360
        let hue2 = hue < 0 ? hue + 1 : hue
        guard s > 0 else { return SRGB(r: l, g: l, b: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return SRGB(r: channel(hue2 + 1 / 3), g: channel(hue2), b: channel(hue2 - 1 / 3))
    }

    /// The CSS named colours. Sites use these constantly — `white`, `gray`,
    /// `rebeccapurple` — and a theme engine that skipped them would leave holes
    /// in otherwise transformed pages.
    static let namedColors: [String: String] = [
        "aliceblue": "f0f8ff",
        "antiquewhite": "faebd7",
        "aqua": "00ffff",
        "aquamarine": "7fffd4",
        "azure": "f0ffff",
        "beige": "f5f5dc",
        "bisque": "ffe4c4",
        "black": "000000",
        "blanchedalmond": "ffebcd",
        "blue": "0000ff",
        "blueviolet": "8a2be2",
        "brown": "a52a2a",
        "burlywood": "deb887",
        "cadetblue": "5f9ea0",
        "chartreuse": "7fff00",
        "chocolate": "d2691e",
        "coral": "ff7f50",
        "cornflowerblue": "6495ed",
        "cornsilk": "fff8dc",
        "crimson": "dc143c",
        "cyan": "00ffff",
        "darkblue": "00008b",
        "darkcyan": "008b8b",
        "darkgoldenrod": "b8860b",
        "darkgray": "a9a9a9",
        "darkgreen": "006400",
        "darkgrey": "a9a9a9",
        "darkkhaki": "bdb76b",
        "darkmagenta": "8b008b",
        "darkolivegreen": "556b2f",
        "darkorange": "ff8c00",
        "darkorchid": "9932cc",
        "darkred": "8b0000",
        "darksalmon": "e9967a",
        "darkseagreen": "8fbc8f",
        "darkslateblue": "483d8b",
        "darkslategray": "2f4f4f",
        "darkslategrey": "2f4f4f",
        "darkturquoise": "00ced1",
        "darkviolet": "9400d3",
        "deeppink": "ff1493",
        "deepskyblue": "00bfff",
        "dimgray": "696969",
        "dimgrey": "696969",
        "dodgerblue": "1e90ff",
        "firebrick": "b22222",
        "floralwhite": "fffaf0",
        "forestgreen": "228b22",
        "fuchsia": "ff00ff",
        "gainsboro": "dcdcdc",
        "ghostwhite": "f8f8ff",
        "gold": "ffd700",
        "goldenrod": "daa520",
        "gray": "808080",
        "green": "008000",
        "greenyellow": "adff2f",
        "grey": "808080",
        "honeydew": "f0fff0",
        "hotpink": "ff69b4",
        "indianred": "cd5c5c",
        "indigo": "4b0082",
        "ivory": "fffff0",
        "khaki": "f0e68c",
        "lavender": "e6e6fa",
        "lavenderblush": "fff0f5",
        "lawngreen": "7cfc00",
        "lemonchiffon": "fffacd",
        "lightblue": "add8e6",
        "lightcoral": "f08080",
        "lightcyan": "e0ffff",
        "lightgoldenrodyellow": "fafad2",
        "lightgray": "d3d3d3",
        "lightgreen": "90ee90",
        "lightgrey": "d3d3d3",
        "lightpink": "ffb6c1",
        "lightsalmon": "ffa07a",
        "lightseagreen": "20b2aa",
        "lightskyblue": "87cefa",
        "lightslategray": "778899",
        "lightslategrey": "778899",
        "lightsteelblue": "b0c4de",
        "lightyellow": "ffffe0",
        "lime": "00ff00",
        "limegreen": "32cd32",
        "linen": "faf0e6",
        "magenta": "ff00ff",
        "maroon": "800000",
        "mediumaquamarine": "66cdaa",
        "mediumblue": "0000cd",
        "mediumorchid": "ba55d3",
        "mediumpurple": "9370db",
        "mediumseagreen": "3cb371",
        "mediumslateblue": "7b68ee",
        "mediumspringgreen": "00fa9a",
        "mediumturquoise": "48d1cc",
        "mediumvioletred": "c71585",
        "midnightblue": "191970",
        "mintcream": "f5fffa",
        "mistyrose": "ffe4e1",
        "moccasin": "ffe4b5",
        "navajowhite": "ffdead",
        "navy": "000080",
        "oldlace": "fdf5e6",
        "olive": "808000",
        "olivedrab": "6b8e23",
        "orange": "ffa500",
        "orangered": "ff4500",
        "orchid": "da70d6",
        "palegoldenrod": "eee8aa",
        "palegreen": "98fb98",
        "paleturquoise": "afeeee",
        "palevioletred": "db7093",
        "papayawhip": "ffefd5",
        "peachpuff": "ffdab9",
        "peru": "cd853f",
        "pink": "ffc0cb",
        "plum": "dda0dd",
        "powderblue": "b0e0e6",
        "purple": "800080",
        "rebeccapurple": "663399",
        "red": "ff0000",
        "rosybrown": "bc8f8f",
        "royalblue": "4169e1",
        "saddlebrown": "8b4513",
        "salmon": "fa8072",
        "sandybrown": "f4a460",
        "seagreen": "2e8b57",
        "seashell": "fff5ee",
        "sienna": "a0522d",
        "silver": "c0c0c0",
        "skyblue": "87ceeb",
        "slateblue": "6a5acd",
        "slategray": "708090",
        "slategrey": "708090",
        "snow": "fffafa",
        "springgreen": "00ff7f",
        "steelblue": "4682b4",
        "tan": "d2b48c",
        "teal": "008080",
        "thistle": "d8bfd8",
        "tomato": "ff6347",
        "turquoise": "40e0d0",
        "violet": "ee82ee",
        "wheat": "f5deb3",
        "white": "ffffff",
        "whitesmoke": "f5f5f5",
        "yellow": "ffff00",
        "yellowgreen": "9acd32"
    ]
}
