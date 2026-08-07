import Foundation

public enum MonknotThemeVariant: String, Codable, Sendable {
    case light
    case dark
}

public struct MonknotThemePreset: Identifiable, Codable, Equatable, Sendable {
    public static let sourceVersion = "monknot-theme-v4"

    public let id: String
    public let codeThemeID: String
    public let variant: MonknotThemeVariant
    public let theme: AppTheme

    public init(id: String, codeThemeID: String, variant: MonknotThemeVariant, theme: AppTheme) {
        self.id = id
        self.codeThemeID = codeThemeID
        self.variant = variant
        self.theme = theme
    }
}

public enum MonknotThemeCatalog {
    public static let sourceVersion = MonknotThemePreset.sourceVersion

    // Palette provenance and Monknot's semantic-role mappings are recorded in
    // LICENSE_AUDIT.md.
    public static let lightPresets: [MonknotThemePreset] = [
        preset(id: "parchment-light", name: "Parchment", codeThemeID: "parchment", variant: .light, accent: "#876a26", contrast: 40, ink: "#241b12", surface: "#f7f4ed", diffAdded: "#277c4c", diffRemoved: "#a52f27", skill: "#9b36ab"),
        preset(id: "brasspants-light", name: "Brasspants", codeThemeID: "brasspants-light", variant: .light, accent: "#8a6410", contrast: 40, ink: "#181f28", surface: "#f7f9fb", diffAdded: "#1f7d5c", diffRemoved: "#bf3a34", skill: "#2f5fbd"),
        preset(id: "catppuccin-latte", name: "Catppuccin Latte", codeThemeID: "catppuccin-latte", variant: .light, accent: "#8839ef", contrast: 45, ink: "#4c4f69", surface: "#eff1f5", diffAdded: "#40a02b", diffRemoved: "#d20f39", skill: "#8839ef"),
        preset(id: "harbor-light", name: "Harbor", codeThemeID: "harbor", variant: .light, accent: "#0a52a3", contrast: 40, ink: "#1c1e22", surface: "#fdfdfe", diffAdded: "#277c4c", diffRemoved: "#a52f27", skill: "#7436ab"),
        preset(id: "codechimp-light", name: "Codechimp", codeThemeID: "codechimp-light", variant: .light, accent: "#12805a", contrast: 40, ink: "#1a2027", surface: "#fbfcfd", diffAdded: "#12805a", diffRemoved: "#c33b36", skill: "#4457c9"),
        preset(id: "everforest-light", name: "Everforest", codeThemeID: "everforest", variant: .light, accent: "#93b259", contrast: 45, ink: "#5c6a72", surface: "#fdf6e3", diffAdded: "#8da101", diffRemoved: "#f85552", skill: "#df69ba"),
        preset(id: "forge-light", name: "Forge", codeThemeID: "forge", variant: .light, accent: "#13499a", contrast: 40, ink: "#191f29", surface: "#f9fafb", diffAdded: "#277c4c", diffRemoved: "#a52f27", skill: "#7036ab"),
        preset(id: "greaseball-light", name: "Greaseball", codeThemeID: "greaseball-light", variant: .light, accent: "#a35a17", contrast: 40, ink: "#221d14", surface: "#faf6ef", diffAdded: "#2f8f3f", diffRemoved: "#c2352b", skill: "#8d4fc4"),
        preset(id: "axis-light", name: "Axis", codeThemeID: "axis", variant: .light, accent: "#321f8e", contrast: 40, ink: "#1d1c26", surface: "#f6f6f9", diffAdded: "#277c4c", diffRemoved: "#a52f27", skill: "#9336ab"),
        preset(id: "paper-light", name: "Paper", codeThemeID: "paper", variant: .light, accent: "#2f597f", contrast: 40, ink: "#22201d", surface: "#fdfdfc", diffAdded: "#277c4c", diffRemoved: "#a52f27", skill: "#6836ab"),
        preset(id: "one-light", name: "One Light", codeThemeID: "one-light", variant: .light, accent: "#4078f2", contrast: 45, ink: "#383a42", surface: "#fafafa", diffAdded: "#50a14f", diffRemoved: "#e45649", skill: "#a626a4"),
        preset(id: "proof-light", name: "Proof", codeThemeID: "proof", variant: .light, accent: "#3d755d", contrast: 45, ink: "#2f312d", surface: "#f5f3ed", diffAdded: "#3d755d", diffRemoved: "#ba2623", skill: "#5f6ac2"),
        preset(id: "signal-light", name: "Signal", codeThemeID: "signal", variant: .light, accent: "#a11b0c", contrast: 40, ink: "#271d1b", surface: "#fcf9f8", diffAdded: "#277c4c", diffRemoved: "#a52f27", skill: "#8436ab"),
        preset(id: "rose-pine-dawn", name: "Rosé Pine Dawn", codeThemeID: "rose-pine-dawn", variant: .light, accent: "#d7827e", contrast: 45, ink: "#464261", surface: "#faf4ed", diffAdded: "#56949f", diffRemoved: "#b4637a", skill: "#907aa9"),
        preset(id: "solarized-light", name: "Solarized Light", codeThemeID: "solarized-light", variant: .light, accent: "#268bd2", contrast: 45, ink: "#657b83", surface: "#fdf6e3", diffAdded: "#859900", diffRemoved: "#dc322f", skill: "#d33682"),
        preset(id: "sockpuppet-light", name: "Sockpuppet", codeThemeID: "sockpuppet-light", variant: .light, accent: "#b23b38", contrast: 40, ink: "#241c1b", surface: "#fbf7f3", diffAdded: "#2d8a44", diffRemoved: "#b23b38", skill: "#8a4bbd"),
        preset(id: "monolith-light", name: "Monolith", codeThemeID: "monolith", variant: .light, accent: "#424242", contrast: 40, ink: "#1a1a1a", surface: "#fdfdfd", diffAdded: "#277c4c", diffRemoved: "#a52f27", skill: "#7836ab"),
        preset(id: "workbench-light", name: "Workbench", codeThemeID: "workbench", variant: .light, accent: "#1d6690", contrast: 40, ink: "#181e25", surface: "#f6f7f9", diffAdded: "#277c4c", diffRemoved: "#a52f27", skill: "#6836ab"),
        preset(id: "blueprint-light", name: "Blueprint", codeThemeID: "blueprint", variant: .light, accent: "#0c2fa1", contrast: 40, ink: "#111a30", surface: "#e9edf7", diffAdded: "#277c4c", diffRemoved: "#a52f27", skill: "#8b36ab")
    ]

    public static let darkPresets: [MonknotThemePreset] = [
        preset(id: "parchment-dark", name: "Parchment", codeThemeID: "parchment", variant: .dark, accent: "#cbb072", contrast: 40, ink: "#ede9e3", surface: "#14120f", diffAdded: "#65c387", diffRemoved: "#e56e61", skill: "#dc92e7"),
        preset(id: "ayu-dark", name: "Ayu Dark", codeThemeID: "ayu-dark", variant: .dark, accent: "#e6b450", contrast: 60, ink: "#bfbdb6", surface: "#10141c", diffAdded: "#70bf56", diffRemoved: "#f26d78", skill: "#d2a6ff"),
        preset(id: "brasspants-dark", name: "Brasspants", codeThemeID: "brasspants-dark", variant: .dark, accent: "#d9a94b", contrast: 40, ink: "#dfe6ee", surface: "#0e1319", diffAdded: "#54b98c", diffRemoved: "#e2645e", skill: "#7fa6e8"),
        preset(id: "catppuccin-mocha", name: "Catppuccin Mocha", codeThemeID: "catppuccin-mocha", variant: .dark, accent: "#cba6f7", contrast: 60, ink: "#cdd6f4", surface: "#1e1e2e", diffAdded: "#a6e3a1", diffRemoved: "#f38ba8", skill: "#cba6f7"),
        preset(id: "harbor-dark", name: "Harbor", codeThemeID: "harbor", variant: .dark, accent: "#5399ea", contrast: 40, ink: "#ebebeb", surface: "#121212", diffAdded: "#65c387", diffRemoved: "#e56e61", skill: "#c092e7"),
        preset(id: "codechimp-dark", name: "Codechimp", codeThemeID: "codechimp-dark", variant: .dark, accent: "#4bbf8a", contrast: 40, ink: "#e4eaef", surface: "#12161a", diffAdded: "#4bbf8a", diffRemoved: "#e8615c", skill: "#8f9ef5"),
        preset(id: "dracula-dark", name: "Dracula", codeThemeID: "dracula", variant: .dark, accent: "#ff79c6", contrast: 60, ink: "#f8f8f2", surface: "#282a36", diffAdded: "#50fa7b", diffRemoved: "#ff5555", skill: "#ff79c6"),
        preset(id: "everforest-dark", name: "Everforest", codeThemeID: "everforest", variant: .dark, accent: "#a7c080", contrast: 60, ink: "#d3c6aa", surface: "#2d353b", diffAdded: "#a7c080", diffRemoved: "#e67e80", skill: "#d699b6"),
        preset(id: "forge-dark", name: "Forge", codeThemeID: "forge", variant: .dark, accent: "#5c91e0", contrast: 40, ink: "#e6ebef", surface: "#0c1118", diffAdded: "#65c387", diffRemoved: "#e56e61", skill: "#bd92e7"),
        preset(id: "greaseball-dark", name: "Greaseball", codeThemeID: "greaseball-dark", variant: .dark, accent: "#e08a4c", contrast: 40, ink: "#f2ece1", surface: "#17140f", diffAdded: "#5fb85f", diffRemoved: "#e2564a", skill: "#c98fe0"),
        preset(id: "axis-dark", name: "Axis", codeThemeID: "axis", variant: .dark, accent: "#7e6dd0", contrast: 40, ink: "#e4e3e8", surface: "#111013", diffAdded: "#65c387", diffRemoved: "#e56e61", skill: "#d692e7"),
        preset(id: "lobster-dark", name: "Lobster", codeThemeID: "lobster", variant: .dark, accent: "#ff5c5c", contrast: 60, ink: "#e4e4e7", surface: "#111827", diffAdded: "#22c55e", diffRemoved: "#ff5c5c", skill: "#3b82f6"),
        preset(id: "lagoon-dark", name: "Lagoon", codeThemeID: "lagoon", variant: .dark, accent: "#62dace", contrast: 40, ink: "#e0e9eb", surface: "#0d191c", diffAdded: "#65c387", diffRemoved: "#e56e61", skill: "#a392e7"),
        preset(id: "phosphor-dark", name: "Phosphor", codeThemeID: "phosphor", variant: .dark, accent: "#62da86", contrast: 40, ink: "#dbe6de", surface: "#0b0f0c", diffAdded: "#65c387", diffRemoved: "#e56e61", skill: "#ba92e7"),
        preset(id: "citrus-dark", name: "Citrus", codeThemeID: "citrus", variant: .dark, accent: "#e4db58", contrast: 40, ink: "#efefe7", surface: "#161612", diffAdded: "#65c387", diffRemoved: "#e56e61", skill: "#e792d1"),
        preset(id: "night-owl-dark", name: "Night Owl", codeThemeID: "night-owl", variant: .dark, accent: "#44596b", contrast: 60, ink: "#d6deeb", surface: "#011627", diffAdded: "#c5e478", diffRemoved: "#ef5350", skill: "#c792ea"),
        preset(id: "nord-dark", name: "Nord", codeThemeID: "nord", variant: .dark, accent: "#88c0d0", contrast: 60, ink: "#d8dee9", surface: "#2e3440", diffAdded: "#a3be8c", diffRemoved: "#bf616a", skill: "#b48ead"),
        preset(id: "paper-dark", name: "Paper", codeThemeID: "paper", variant: .dark, accent: "#7da0bf", contrast: 40, ink: "#e9e9e7", surface: "#171717", diffAdded: "#65c387", diffRemoved: "#e56e61", skill: "#b792e7"),
        preset(id: "one-dark", name: "One Dark", codeThemeID: "one-dark", variant: .dark, accent: "#61afef", contrast: 60, ink: "#abb2bf", surface: "#282c34", diffAdded: "#98c379", diffRemoved: "#e06c75", skill: "#c678dd"),
        preset(id: "oscura-dark", name: "Oscura", codeThemeID: "oscura", variant: .dark, accent: "#f9b98c", contrast: 60, ink: "#e6e6e6", surface: "#0b0b0f", diffAdded: "#54c0a3", diffRemoved: "#d84f68", skill: "#479ffa"),
        preset(id: "signal-dark", name: "Signal", codeThemeID: "signal", variant: .dark, accent: "#e86354", contrast: 40, ink: "#ebe6e5", surface: "#141010", diffAdded: "#65c387", diffRemoved: "#e56e61", skill: "#cb92e7"),
        preset(id: "rose-pine-moon", name: "Rosé Pine Moon", codeThemeID: "rose-pine-moon", variant: .dark, accent: "#ea9a97", contrast: 60, ink: "#e0def4", surface: "#232136", diffAdded: "#9ccfd8", diffRemoved: "#eb6f92", skill: "#c4a7e7"),
        preset(id: "watchtower-dark", name: "Watchtower", codeThemeID: "watchtower", variant: .dark, accent: "#a966d6", contrast: 40, ink: "#e3dfe7", surface: "#141019", diffAdded: "#65c387", diffRemoved: "#e56e61", skill: "#c592e7"),
        preset(id: "solarized-dark", name: "Solarized Dark", codeThemeID: "solarized-dark", variant: .dark, accent: "#268bd2", contrast: 60, ink: "#839496", surface: "#002b36", diffAdded: "#859900", diffRemoved: "#dc322f", skill: "#d33682"),
        preset(id: "sockpuppet-dark", name: "Sockpuppet", codeThemeID: "sockpuppet-dark", variant: .dark, accent: "#d9615c", contrast: 40, ink: "#f0e6e3", surface: "#1a1415", diffAdded: "#68b06a", diffRemoved: "#e2564a", skill: "#c184d6"),
        preset(id: "temple-dark", name: "Temple", codeThemeID: "temple", variant: .dark, accent: "#e4f222", contrast: 60, ink: "#c7e6da", surface: "#02120c", diffAdded: "#40c977", diffRemoved: "#fa423e", skill: "#e4f222"),
        preset(id: "tokyo-night-dark", name: "Tokyo Night", codeThemeID: "tokyo-night", variant: .dark, accent: "#3d59a1", contrast: 60, ink: "#a9b1d6", surface: "#1a1b26", diffAdded: "#449dab", diffRemoved: "#914c54", skill: "#9d7cd8"),
        preset(id: "monolith-dark", name: "Monolith", codeThemeID: "monolith", variant: .dark, accent: "#c7c7c7", contrast: 40, ink: "#ededed", surface: "#0a0a0a", diffAdded: "#65c387", diffRemoved: "#e56e61", skill: "#c292e7"),
        preset(id: "workbench-dark", name: "Workbench", codeThemeID: "workbench", variant: .dark, accent: "#6aacd2", contrast: 40, ink: "#e1e6ea", surface: "#12171c", diffAdded: "#65c387", diffRemoved: "#e56e61", skill: "#b792e7"),
        preset(id: "blueprint-dark", name: "Blueprint", codeThemeID: "blueprint", variant: .dark, accent: "#5678e6", contrast: 40, ink: "#dee3ed", surface: "#0b101d", diffAdded: "#65c387", diffRemoved: "#e56e61", skill: "#d192e7")
    ]

    private static func preset(
        id: String,
        name: String,
        codeThemeID: String,
        variant: MonknotThemeVariant,
        accent: String,
        contrast: Double,
        ink: String,
        surface: String,
        diffAdded: String,
        diffRemoved: String,
        skill: String
    ) -> MonknotThemePreset {
        MonknotThemePreset(
            id: id,
            codeThemeID: codeThemeID,
            variant: variant,
            theme: AppTheme(
                id: id,
                name: name,
                codeThemeID: codeThemeID,
                background: surface,
                foreground: ink,
                cursor: accent,
                selectionBackground: selectionBackground(accent: accent, surface: surface, variant: variant),
                selectionForeground: ink,
                palette: palette(accent: accent, ink: ink, surface: surface, diffAdded: diffAdded, diffRemoved: diffRemoved, skill: skill),
                semanticColors: AppThemeSemanticColors(diffAdded: diffAdded, diffRemoved: diffRemoved, skill: skill),
                contrast: contrast
            )
        )
    }

    private static func palette(
        accent: String,
        ink: String,
        surface: String,
        diffAdded: String,
        diffRemoved: String,
        skill: String
    ) -> [String] {
        [
            surface, diffRemoved, diffAdded, accent,
            accent, skill, accent, ink,
            ink, diffRemoved, diffAdded, accent,
            accent, skill, accent, ink
        ]
    }

    private static func selectionBackground(accent: String, surface: String, variant: MonknotThemeVariant) -> String {
        mix(hex: accent, with: surface, amount: variant == .dark ? 0.28 : 0.20)
    }

    private static func mix(hex: String, with otherHex: String, amount: Double) -> String {
        guard let first = RGBHex(hex), let second = RGBHex(otherHex) else {
            return hex
        }

        let clamped = max(0, min(1, amount))
        let red = first.red * clamped + second.red * (1 - clamped)
        let green = first.green * clamped + second.green * (1 - clamped)
        let blue = first.blue * clamped + second.blue * (1 - clamped)

        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

public extension AppTheme {
    static var defaultLight: AppTheme {
        MonknotThemeCatalog.lightPresets.first { $0.id == "harbor-light" }!.theme
    }

    static var defaultDark: AppTheme {
        MonknotThemeCatalog.darkPresets.first { $0.id == "harbor-dark" }!.theme
    }

    static var lightThemes: [AppTheme] {
        MonknotThemeCatalog.lightPresets.map(\.theme)
    }

    static var darkThemes: [AppTheme] {
        MonknotThemeCatalog.darkPresets.map(\.theme)
    }

    static func lightTheme(id: String) -> AppTheme {
        lightThemes.first { $0.id == id } ?? defaultLight
    }

    static func darkTheme(id: String) -> AppTheme {
        darkThemes.first { $0.id == id } ?? defaultDark
    }
}
