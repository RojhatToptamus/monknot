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

    /// The single distinct tool-panel tier (sidebar). Subtly offset from the
    /// content canvas so the sidebar reads apart without heavy borders: lighter
    /// in dark themes, a hair darker in light themes. Magnitudes are tuned to
    /// the reference design, where the sidebar offset is small in light and a
    /// touch stronger in dark so it remains perceptible against a dark canvas.
    var sidebarSurfaceHex: String {
        recessedSurfaceHex(amount: isDark ? 0.075 : 0.028)
    }

    /// The terminal mirrors the left sidebar as a right-edge tool panel.
    var terminalSurfaceHex: String {
        sidebarSurfaceHex
    }
}
