import Foundation

public struct AppThemeSemanticColors: Codable, Equatable, Sendable {
    public let diffAdded: String
    public let diffRemoved: String
    public let skill: String

    public init(diffAdded: String, diffRemoved: String, skill: String) {
        self.diffAdded = diffAdded
        self.diffRemoved = diffRemoved
        self.skill = skill
    }
}

public struct AppTheme: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let codeThemeID: String
    public let background: String
    public let foreground: String
    public let cursor: String
    public let selectionBackground: String
    public let selectionForeground: String
    public let palette: [String]
    public let semanticColors: AppThemeSemanticColors
    public let uiFontName: String?
    public let codeFontName: String?
    public let quietSidebar: Bool
    public let uiFontSize: Double
    public let codeFontSize: Double
    public let contrast: Double

    public init(
        id: String,
        name: String,
        codeThemeID: String? = nil,
        background: String,
        foreground: String,
        cursor: String,
        selectionBackground: String,
        selectionForeground: String,
        palette: [String],
        semanticColors: AppThemeSemanticColors = AppThemeSemanticColors(
            diffAdded: "#00A240",
            diffRemoved: "#E02E2A",
            skill: "#924FF7"
        ),
        uiFontName: String? = nil,
        codeFontName: String? = nil,
        quietSidebar: Bool = false,
        uiFontSize: Double = 16,
        codeFontSize: Double = 13,
        contrast: Double = 50
    ) {
        self.id = id
        self.name = name
        self.codeThemeID = codeThemeID ?? id
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
        self.semanticColors = semanticColors
        self.uiFontName = uiFontName
        self.codeFontName = codeFontName
        self.quietSidebar = quietSidebar
        self.uiFontSize = uiFontSize
        self.codeFontSize = codeFontSize
        self.contrast = contrast
    }

    public var accent: String {
        palette[safe: 4] ?? "#339CFF"
    }

    public var secondaryAccent: String {
        palette[safe: 5] ?? accent
    }

    public var codeKeyword: String {
        palette[safe: 5] ?? accent
    }

    public var codeString: String {
        palette[safe: 2] ?? "#71D36F"
    }

    public var codeNumber: String {
        palette[safe: 6] ?? "#64D2FF"
    }

    public var codeBuiltin: String {
        palette[safe: 3] ?? "#FF9F40"
    }

    public var codeComment: String {
        palette[safe: 8] ?? "#8D939F"
    }

    public static func == (lhs: AppTheme, rhs: AppTheme) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.codeThemeID == rhs.codeThemeID
            && lhs.background == rhs.background
            && lhs.foreground == rhs.foreground
            && lhs.cursor == rhs.cursor
            && lhs.selectionBackground == rhs.selectionBackground
            && lhs.selectionForeground == rhs.selectionForeground
            && lhs.palette == rhs.palette
            && lhs.semanticColors == rhs.semanticColors
            && lhs.uiFontName == rhs.uiFontName
            && lhs.codeFontName == rhs.codeFontName
            && lhs.quietSidebar == rhs.quietSidebar
            && lhs.uiFontSize == rhs.uiFontSize
            && lhs.codeFontSize == rhs.codeFontSize
            && lhs.contrast == rhs.contrast
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case codeThemeID
        case background
        case foreground
        case cursor
        case selectionBackground
        case selectionForeground
        case palette
        case semanticColors
        case uiFontName
        case codeFontName
        case quietSidebar
        case uiFontSize
        case codeFontSize
        case contrast
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        codeThemeID = try container.decode(String.self, forKey: .codeThemeID)
        background = try container.decode(String.self, forKey: .background)
        foreground = try container.decode(String.self, forKey: .foreground)
        cursor = try container.decode(String.self, forKey: .cursor)
        selectionBackground = try container.decode(String.self, forKey: .selectionBackground)
        selectionForeground = try container.decode(String.self, forKey: .selectionForeground)
        palette = try container.decode([String].self, forKey: .palette)
        semanticColors = try container.decode(AppThemeSemanticColors.self, forKey: .semanticColors)
        uiFontName = try container.decodeIfPresent(String.self, forKey: .uiFontName)
        codeFontName = try container.decodeIfPresent(String.self, forKey: .codeFontName)
        quietSidebar = try container.decodeIfPresent(Bool.self, forKey: .quietSidebar) ?? false
        uiFontSize = try container.decodeIfPresent(Double.self, forKey: .uiFontSize) ?? 16
        codeFontSize = try container.decodeIfPresent(Double.self, forKey: .codeFontSize) ?? 13
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 50
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(codeThemeID, forKey: .codeThemeID)
        try container.encode(background, forKey: .background)
        try container.encode(foreground, forKey: .foreground)
        try container.encode(cursor, forKey: .cursor)
        try container.encode(selectionBackground, forKey: .selectionBackground)
        try container.encode(selectionForeground, forKey: .selectionForeground)
        try container.encode(palette, forKey: .palette)
        try container.encode(semanticColors, forKey: .semanticColors)
        try container.encodeIfPresent(uiFontName, forKey: .uiFontName)
        try container.encodeIfPresent(codeFontName, forKey: .codeFontName)
        try container.encode(quietSidebar, forKey: .quietSidebar)
        try container.encode(uiFontSize, forKey: .uiFontSize)
        try container.encode(codeFontSize, forKey: .codeFontSize)
        try container.encode(contrast, forKey: .contrast)
    }

    public var isDark: Bool {
        guard let rgb = RGBHex(background) else {
            return true
        }

        return rgb.relativeLuminance < 0.45
    }

    public var onAccentForegroundHex: String {
        guard let accent = RGBHex(accent),
              let light = RGBHex("#FFFFFF"),
              let dark = RGBHex("#101010") else {
            return "#FFFFFF"
        }

        return light.contrastRatio(with: accent) >= dark.contrastRatio(with: accent)
            ? "#FFFFFF"
            : "#101010"
    }

    public func replacing(
        background: String? = nil,
        foreground: String? = nil,
        accent: String? = nil,
        quietSidebar: Bool? = nil,
        uiFontSize: Double? = nil,
        codeFontSize: Double? = nil,
        contrast: Double? = nil
    ) -> AppTheme {
        var palette = self.palette
        if let accent {
            if palette.indices.contains(4) {
                palette[4] = accent
            } else {
                while palette.count < 4 {
                    palette.append(self.foreground)
                }
                palette.append(accent)
            }
        }

        let nextBackground = background ?? self.background

        return AppTheme(
            id: id,
            name: name,
            codeThemeID: codeThemeID,
            background: nextBackground,
            foreground: foreground ?? self.foreground,
            cursor: accent ?? cursor,
            selectionBackground: Self.selectionBackground(
                accent: accent ?? self.accent,
                background: nextBackground,
                isDark: Self.isDarkBackground(nextBackground)
            ),
            selectionForeground: foreground ?? selectionForeground,
            palette: palette,
            semanticColors: semanticColors,
            uiFontName: uiFontName,
            codeFontName: codeFontName,
            quietSidebar: quietSidebar ?? self.quietSidebar,
            uiFontSize: uiFontSize ?? self.uiFontSize,
            codeFontSize: codeFontSize ?? self.codeFontSize,
            contrast: contrast ?? self.contrast
        )
    }

    private static func selectionBackground(accent: String, background: String, isDark: Bool) -> String {
        guard let accentRGB = RGBHex(accent), let backgroundRGB = RGBHex(background) else {
            return accent
        }

        let amount = isDark ? 0.28 : 0.20
        let red = accentRGB.red * amount + backgroundRGB.red * (1 - amount)
        let green = accentRGB.green * amount + backgroundRGB.green * (1 - amount)
        let blue = accentRGB.blue * amount + backgroundRGB.blue * (1 - amount)

        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    private static func isDarkBackground(_ background: String) -> Bool {
        RGBHex(background)?.relativeLuminance ?? 0 < 0.45
    }
}

public struct RGBHex: Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init?(_ hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }

        guard value.count == 6, let intValue = Int(value, radix: 16) else {
            return nil
        }

        self.red = Double((intValue >> 16) & 0xFF) / 255.0
        self.green = Double((intValue >> 8) & 0xFF) / 255.0
        self.blue = Double(intValue & 0xFF) / 255.0
    }

    public var relativeLuminance: Double {
        0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrastRatio(with other: RGBHex) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func linear(_ component: Double) -> Double {
        if component <= 0.03928 {
            return component / 12.92
        }

        return pow((component + 0.055) / 1.055, 2.4)
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Layered surface hierarchy

public extension AppTheme {
    /// Linearly blends `baseHex` toward `targetHex` by `amount` (0...1) and
    /// returns a `#RRGGBB` string. Returns `baseHex` unchanged if either input
    /// cannot be parsed.
    static func blendHex(_ baseHex: String, toward targetHex: String, amount: Double) -> String {
        guard let base = RGBHex(baseHex), let target = RGBHex(targetHex) else {
            return baseHex
        }

        let clamped = max(0, min(1, amount))
        let red = base.red + (target.red - base.red) * clamped
        let green = base.green + (target.green - base.green) * clamped
        let blue = base.blue + (target.blue - base.blue) * clamped

        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    /// A surface tone derived from `background`, nudged toward the `foreground`
    /// ink. In dark themes this reads as a gently raised panel; in light themes
    /// it reads as a recessed gray. Used to build calm, theme-driven surface
    /// hierarchy instead of relying on heavy borders.
    func recessedSurfaceHex(amount: Double) -> String {
        AppTheme.blendHex(background, toward: foreground, amount: amount)
    }

    /// The window's frame around the cards: titlebar, sidebar and the gaps between cards (design.md
    /// §10.0). It sits below the canvas in both modes, so the document card reads as lifted out of
    /// it: a step toward the ink in light themes, a step toward black in dark ones. The step is large
    /// enough to see on tinted canvases such as Catppuccin Latte, where a 3 % step disappeared.
    var chromeSurfaceHex: String {
        isDark
            ? AppTheme.blendHex(background, toward: "#000000", amount: 0.28)
            : recessedSurfaceHex(amount: 0.055)
    }

    /// The terminal sits on a card beside the document's, on the same canvas (design.md §10.0).
}

// MARK: - Fills and floating surfaces (design.md §1.2, §2.1)

/// The chrome and Preview's page read these, so a native menu and a menu on the page cannot drift.
public extension AppTheme {
    /// `hover`: the one hover fill for every row, tab, cell and button.
    var hoverInkOpacity: Double {
        isDark ? 0.06 : 0.055
    }

    /// `press`: replaces the hover fill while a control is held down.
    var pressInkOpacity: Double {
        isDark ? 0.11 : 0.10
    }

    /// `selected`: a selected sidebar or Settings row, the active terminal session, and the highlighted
    /// row of every menu, native or on Preview's page.
    var selectedInkOpacity: Double {
        isDark ? 0.10 : 0.09
    }

    /// `accsoft`: the 3 pt ring around a focused field.
    var accentSoftOpacity: Double {
        isDark ? 0.18 : 0.14
    }

    /// The fill of a floating surface — a menu, popover or the format bar (`surf2`).
    var floatingSurfaceHex: String {
        recessedSurfaceHex(amount: isDark ? 0.11 : 0.05)
    }

    /// A floating surface's shadow hue: black in dark themes; in light ones the ink with 10 % of the
    /// accent, so the shadow takes the theme's temperature instead of going muddy.
    var floatingShadowHex: String {
        isDark ? "#000000" : AppTheme.blendHex(foreground, toward: accent, amount: 0.10)
    }

    /// A floating surface's inset ring: white at 14 % in dark themes, the shadow hue at 8 % in light ones.
    var floatingRingHex: String {
        isDark ? "#FFFFFF" : floatingShadowHex
    }

    var floatingRingOpacity: Double {
        isDark ? 0.14 : 0.08
    }
}

// MARK: - The ink ladder (design.md §1.2)

public extension AppTheme {
    /// `ink2`, every label at rest: the theme ink at the lowest opacity, from 72 %, that still reads
    /// 4.5:1 on both the chrome and the canvas. Catppuccin Latte's soft ink needs 84 %; a dark ink on
    /// white keeps 72 %. One value for the sidebar, tabs, menus and Settings alike.
    var labelInkOpacity: Double {
        inkLadder.label
    }

    /// `ink3`, every glyph at rest and all secondary text: from 50 %, until it reads 3:1.
    var glyphInkOpacity: Double {
        inkLadder.glyph
    }

    /// The theme's `contrast` (0–100, 40 by default) scales the ladder's floors (design.md §14): at 40
    /// they are 72 % and 50 %, at 100 a fifth higher, at 0 a sixth lower, and the contrast rule still
    /// raises them wherever the ink would not read.
    var inkLadderContrastFactor: Double {
        0.85 + min(100, max(0, contrast)) / 100 * 0.375
    }

    /// `ink4`, disabled controls and placeholders.
    static let disabledInkOpacity = 0.30

    /// The smallest opacity at or above `base`, in hundredths, at which `ink` blended over each of
    /// `surfaces` reaches `ratio`:1 against it; 1 when even the full ink cannot.
    static func inkOpacity(ink: String, over surfaces: [String], ratio: Double, base: Double) -> Double {
        guard RGBHex(ink) != nil else { return 1 }
        let parsedSurfaces = surfaces.compactMap { hex in RGBHex(hex).map { (hex, $0) } }
        var step = Int((base * 100).rounded())
        while step < 100 {
            let opacity = Double(step) / 100
            let reads = parsedSurfaces.allSatisfy { hex, surface in
                guard let blended = RGBHex(blendHex(hex, toward: ink, amount: opacity)) else { return false }
                return blended.contrastRatio(with: surface) >= ratio
            }
            if reads { return opacity }
            step += 1
        }
        return 1
    }

    private var inkLadder: InkLadder {
        let factor = inkLadderContrastFactor
        let key = "\(foreground)|\(background)|\(isDark)|\(factor)"
        if let cached = InkLadder.cache.value(for: key) { return cached }
        let surfaces = [chromeSurfaceHex, background]
        let ladder = InkLadder(
            label: Self.inkOpacity(ink: foreground, over: surfaces, ratio: 4.5, base: min(0.95, 0.72 * factor)),
            glyph: Self.inkOpacity(ink: foreground, over: surfaces, ratio: 3.0, base: min(0.80, 0.50 * factor))
        )
        InkLadder.cache.store(ladder, for: key)
        return ladder
    }
}

private struct InkLadder: Sendable {
    let label: Double
    let glyph: Double

    /// Themes are few and their ladders tiny; views ask for them on every render.
    static let cache = InkLadderCache()
}

private final class InkLadderCache: @unchecked Sendable {
    private let lock = NSLock()
    private var ladders: [String: InkLadder] = [:]

    func value(for key: String) -> InkLadder? {
        lock.lock()
        defer { lock.unlock() }
        return ladders[key]
    }

    func store(_ ladder: InkLadder, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if ladders.count > 64 { ladders.removeAll() }
        ladders[key] = ladder
    }
}
