import Foundation

public enum MonknotThemeVariant: String, Codable, Sendable {
    case light
    case dark
}

public struct MonknotThemePreset: Identifiable, Codable, Equatable, Sendable {
    public static let sourceVersion = "monknot-theme-v1"

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

    public static let lightPresets: [MonknotThemePreset] = [
        preset(id: "monknot-light", name: "Monknot", codeThemeID: "monknot", variant: .light, accent: "#339cff", contrast: 45, ink: "#1a1c1f", surface: "#ffffff", diffAdded: "#00a240", diffRemoved: "#ba2623", skill: "#924ff7"),
        preset(id: "absolutely-light", name: "Absolutely", codeThemeID: "absolutely", variant: .light, accent: "#cc7d5e", contrast: 45, ink: "#2d2d2b", surface: "#f9f9f7", diffAdded: "#00c853", diffRemoved: "#ff5f38", skill: "#cc7d5e"),
        preset(id: "monknot-blue-light", name: "Monknot Blue", codeThemeID: "monknot", variant: .light, accent: "#0169cc", contrast: 45, ink: "#0d0d0d", surface: "#ffffff", diffAdded: "#00a240", diffRemoved: "#e02e2a", skill: "#751ed9"),
        preset(id: "everforest-light", name: "Everforest", codeThemeID: "everforest", variant: .light, accent: "#93b259", contrast: 45, ink: "#5c6a72", surface: "#fdf6e3", diffAdded: "#8da101", diffRemoved: "#f85552", skill: "#df69ba"),
        preset(id: "github-light", name: "GitHub", codeThemeID: "github", variant: .light, accent: "#0969da", contrast: 45, ink: "#1f2328", surface: "#ffffff", diffAdded: "#1a7f37", diffRemoved: "#cf222e", skill: "#8250df"),
        preset(id: "gruvbox-light", name: "Gruvbox", codeThemeID: "gruvbox", variant: .light, accent: "#458588", contrast: 45, ink: "#3c3836", surface: "#fbf1c7", diffAdded: "#3c3836", diffRemoved: "#cc241d", skill: "#b16286"),
        preset(id: "linear-light", name: "Linear", codeThemeID: "linear", variant: .light, accent: "#5e6ad2", contrast: 45, ink: "#1b1b1b", surface: "#fcfcfd", diffAdded: "#52a450", diffRemoved: "#c94446", skill: "#8160d8", uiFontName: "Inter"),
        preset(id: "notion-light", name: "Notion", codeThemeID: "notion", variant: .light, accent: "#3183d8", contrast: 45, ink: "#37352f", surface: "#ffffff", diffAdded: "#008000", diffRemoved: "#a31515", skill: "#0000ff"),
        preset(id: "solarized-light", name: "Solarized", codeThemeID: "solarized", variant: .light, accent: "#b58900", contrast: 45, ink: "#657b83", surface: "#fdf6e3", diffAdded: "#859900", diffRemoved: "#dc322f", skill: "#d33682"),
        preset(id: "one-light", name: "One", codeThemeID: "one", variant: .light, accent: "#526fff", contrast: 45, ink: "#383a42", surface: "#fafafa", diffAdded: "#3bba54", diffRemoved: "#e45649", skill: "#526fff"),
        preset(id: "raycast-light", name: "Raycast", codeThemeID: "raycast", variant: .light, accent: "#ff6363", contrast: 45, ink: "#030303", surface: "#ffffff", diffAdded: "#006b4f", diffRemoved: "#b12424", skill: "#9a1b6e", uiFontName: "Inter", codeFontName: "Jetbrains Mono"),
        preset(id: "rose-pine-light", name: "Rose Pine", codeThemeID: "rose-pine", variant: .light, accent: "#d7827e", contrast: 45, ink: "#575279", surface: "#faf4ed", diffAdded: "#56949f", diffRemoved: "#797593", skill: "#907aa9", uiFontName: "Inter", codeFontName: "Jetbrains Mono")
    ]

    public static let darkPresets: [MonknotThemePreset] = [
        preset(id: "monknot-dark", name: "Monknot", codeThemeID: "monknot", variant: .dark, accent: "#0169cc", contrast: 60, ink: "#fcfcfc", surface: "#111111", diffAdded: "#00a240", diffRemoved: "#e02e2a", skill: "#b06dff"),
        preset(id: "absolutely-dark", name: "Absolutely", codeThemeID: "absolutely", variant: .dark, accent: "#cc7d5e", contrast: 60, ink: "#f9f9f7", surface: "#2d2d2b", diffAdded: "#00c853", diffRemoved: "#ff5f38", skill: "#cc7d5e"),
        preset(id: "ayu-dark", name: "Ayu", codeThemeID: "ayu", variant: .dark, accent: "#e6b450", contrast: 60, ink: "#bfbdb6", surface: "#0b0e14", diffAdded: "#7fd962", diffRemoved: "#ea6c73", skill: "#cda1fa"),
        preset(id: "catppuccin-dark", name: "Catppuccin", codeThemeID: "catppuccin", variant: .dark, accent: "#cba6f7", contrast: 60, ink: "#cdd6f4", surface: "#1e1e2e", diffAdded: "#a6e3a1", diffRemoved: "#f38ba8", skill: "#cba6f7"),
        preset(id: "dracula-dark", name: "Dracula", codeThemeID: "dracula", variant: .dark, accent: "#ff79c6", contrast: 60, ink: "#f8f8f2", surface: "#282a36", diffAdded: "#50fa7b", diffRemoved: "#ff5555", skill: "#ff79c6"),
        preset(id: "everforest-dark", name: "Everforest", codeThemeID: "everforest", variant: .dark, accent: "#a7c080", contrast: 60, ink: "#d3c6aa", surface: "#2d353b", diffAdded: "#a7c080", diffRemoved: "#e67e80", skill: "#d699b6"),
        preset(id: "github-dark", name: "GitHub", codeThemeID: "github", variant: .dark, accent: "#1f6feb", contrast: 60, ink: "#e6edf3", surface: "#0d1117", diffAdded: "#3fb950", diffRemoved: "#f85149", skill: "#bc8cff"),
        preset(id: "gruvbox-dark", name: "Gruvbox", codeThemeID: "gruvbox", variant: .dark, accent: "#458588", contrast: 60, ink: "#ebdbb2", surface: "#282828", diffAdded: "#ebdbb2", diffRemoved: "#cc241d", skill: "#b16286"),
        preset(id: "linear-dark", name: "Linear", codeThemeID: "linear", variant: .dark, accent: "#606acc", contrast: 60, ink: "#e3e4e6", surface: "#0f0f11", diffAdded: "#69c967", diffRemoved: "#ff7e78", skill: "#c2a1ff", uiFontName: "Inter"),
        preset(id: "notion-dark", name: "Notion", codeThemeID: "notion", variant: .dark, accent: "#3183d8", contrast: 60, ink: "#d9d9d8", surface: "#191919", diffAdded: "#4ec9b0", diffRemoved: "#fa423e", skill: "#3183d8"),
        preset(id: "solarized-dark", name: "Solarized", codeThemeID: "solarized", variant: .dark, accent: "#d30102", contrast: 60, ink: "#839496", surface: "#002b36", diffAdded: "#859900", diffRemoved: "#dc322f", skill: "#d33682"),
        preset(id: "vscode-plus-dark", name: "VS Code Plus", codeThemeID: "vscode-plus", variant: .dark, accent: "#007acc", contrast: 60, ink: "#d4d4d4", surface: "#1e1e1e", diffAdded: "#369432", diffRemoved: "#f44747", skill: "#000080"),
        preset(id: "night-owl-dark", name: "Night Owl", codeThemeID: "night-owl", variant: .dark, accent: "#44596b", contrast: 60, ink: "#d6deeb", surface: "#011627", diffAdded: "#c5e478", diffRemoved: "#ef5350", skill: "#c792ea")
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
        skill: String,
        uiFontName: String? = nil,
        codeFontName: String? = nil
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
                uiFontName: uiFontName,
                codeFontName: codeFontName,
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
    static var monknotLight: AppTheme {
        MonknotThemeCatalog.lightPresets.first { $0.id == "monknot-light" }!.theme
    }

    static var monknotDark: AppTheme {
        MonknotThemeCatalog.darkPresets.first { $0.id == "monknot-dark" }!.theme
    }

    static var lightThemes: [AppTheme] {
        MonknotThemeCatalog.lightPresets.map(\.theme)
    }

    static var darkThemes: [AppTheme] {
        MonknotThemeCatalog.darkPresets.map(\.theme)
    }

    static func lightTheme(id: String) -> AppTheme {
        lightThemes.first { $0.id == id } ?? monknotLight
    }

    static func darkTheme(id: String) -> AppTheme {
        darkThemes.first { $0.id == id } ?? monknotDark
    }
}
