import XCTest
@testable import MonknotCore

final class ThemeConfigurationTests: XCTestCase {
    func testChromeSurfaceStyleEncodesAndDecodes() throws {
        var configuration = ThemeConfiguration(theme: AppTheme.codexLight)
        configuration.chromeSurfaceStyle = .liquidGlass

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(ThemeConfiguration.self, from: data)

        XCTAssertEqual(decoded.chromeSurfaceStyle, .liquidGlass)
    }

    func testLegacyTranslucentSidebarDecodesToChromeSurfaceStyle() throws {
        let json = """
        {
          "accent": "#339cff",
          "background": "#ffffff",
          "foreground": "#1a1c1f",
          "translucentSidebar": false,
          "quietSidebar": false,
          "uiFontSize": 16,
          "codeFontSize": 15,
          "contrast": 50
        }
        """

        let decoded = try JSONDecoder().decode(
            ThemeConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.chromeSurfaceStyle, .solid)
    }

    func testAppliedThemeSetsChromeSurfaceStyle() {
        let preset = AppTheme.codexLight
        var configuration = ThemeConfiguration(theme: preset)
        configuration.chromeSurfaceStyle = .translucent

        let applied = configuration.applied(to: preset)

        XCTAssertEqual(applied.chromeSurfaceStyle, .translucent)
        XCTAssertFalse(applied.opaqueWindows)
    }
}

/// Mirror of app-layer ThemeConfiguration for persistence tests.
private struct ThemeConfiguration: Codable, Equatable {
    var accent: String
    var background: String
    var foreground: String
    var chromeSurfaceStyle: MonknotChromeSurfaceStyle
    var quietSidebar: Bool
    var uiFontSize: Double
    var codeFontSize: Double
    var contrast: Double

    private enum CodingKeys: String, CodingKey {
        case accent
        case background
        case foreground
        case chromeSurfaceStyle
        case quietSidebar
        case uiFontSize
        case codeFontSize
        case contrast
        case translucentSidebar
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accent, forKey: .accent)
        try container.encode(background, forKey: .background)
        try container.encode(foreground, forKey: .foreground)
        try container.encode(chromeSurfaceStyle, forKey: .chromeSurfaceStyle)
        try container.encode(quietSidebar, forKey: .quietSidebar)
        try container.encode(uiFontSize, forKey: .uiFontSize)
        try container.encode(codeFontSize, forKey: .codeFontSize)
        try container.encode(contrast, forKey: .contrast)
    }

    init(theme: AppTheme) {
        accent = theme.accent
        background = theme.background
        foreground = theme.foreground
        chromeSurfaceStyle = theme.chromeSurfaceStyle
        quietSidebar = theme.quietSidebar
        uiFontSize = theme.uiFontSize
        codeFontSize = theme.codeFontSize
        contrast = theme.contrast
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accent = try container.decode(String.self, forKey: .accent)
        background = try container.decode(String.self, forKey: .background)
        foreground = try container.decode(String.self, forKey: .foreground)
        quietSidebar = try container.decodeIfPresent(Bool.self, forKey: .quietSidebar) ?? false
        uiFontSize = try container.decode(Double.self, forKey: .uiFontSize)
        codeFontSize = try container.decode(Double.self, forKey: .codeFontSize)
        contrast = try container.decode(Double.self, forKey: .contrast)
        if let style = try container.decodeIfPresent(MonknotChromeSurfaceStyle.self, forKey: .chromeSurfaceStyle) {
            chromeSurfaceStyle = style
        } else {
            let translucent = try container.decodeIfPresent(Bool.self, forKey: .translucentSidebar) ?? true
            chromeSurfaceStyle = MonknotChromeSurfaceStyle.fromLegacy(translucentSidebar: translucent)
        }
    }

    func applied(to theme: AppTheme) -> AppTheme {
        theme.replacing(
            background: background,
            foreground: foreground,
            accent: accent,
            chromeSurfaceStyle: chromeSurfaceStyle,
            quietSidebar: quietSidebar,
            uiFontSize: uiFontSize,
            codeFontSize: codeFontSize,
            contrast: contrast
        )
    }
}
