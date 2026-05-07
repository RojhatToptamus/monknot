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
    public let opaqueWindows: Bool
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
        opaqueWindows: Bool = false,
        uiFontSize: Double = 16,
        codeFontSize: Double = 15,
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
        self.opaqueWindows = opaqueWindows
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
            opaqueWindows: opaqueWindows,
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
