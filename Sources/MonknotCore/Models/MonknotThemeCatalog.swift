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
        preset(id: "absolutely-light", name: "Absolutely", codeThemeID: "absolutely", variant: .light, accent: "#cc7d5e", contrast: 45, ink: "#2d2d2b", surface: "#f9f9f7", diffAdded: "#00c853", diffRemoved: "#ff5f38", skill: "#cc7d5e"),
        preset(id: "brass-monkey-light", name: "Brasspants", codeThemeID: "brass-monkey-light", variant: .light, accent: "#8a6410", contrast: 40, ink: "#181f28", surface: "#f7f9fb", diffAdded: "#1f7d5c", diffRemoved: "#bf3a34", skill: "#2f5fbd"),
        preset(id: "catppuccin-light", name: "Catppuccin", codeThemeID: "catppuccin", variant: .light, accent: "#8839ef", contrast: 45, ink: "#4c4f69", surface: "#eff1f5", diffAdded: "#40a02b", diffRemoved: "#d20f39", skill: "#8839ef"),
        preset(id: "codex-light", name: "Codex", codeThemeID: "codex", variant: .light, accent: "#0169cc", contrast: 45, ink: "#0d0d0d", surface: "#ffffff", diffAdded: "#00a240", diffRemoved: "#e02e2a", skill: "#751ed9"),
        preset(id: "code-monkey-light", name: "Codechimp", codeThemeID: "code-monkey-light", variant: .light, accent: "#12805a", contrast: 40, ink: "#1a2027", surface: "#fbfcfd", diffAdded: "#12805a", diffRemoved: "#c33b36", skill: "#4457c9"),
        preset(id: "everforest-light", name: "Everforest", codeThemeID: "everforest", variant: .light, accent: "#93b259", contrast: 45, ink: "#5c6a72", surface: "#fdf6e3", diffAdded: "#8da101", diffRemoved: "#f85552", skill: "#df69ba"),
        preset(id: "github-light", name: "GitHub", codeThemeID: "github", variant: .light, accent: "#0969da", contrast: 45, ink: "#1f2328", surface: "#ffffff", diffAdded: "#1a7f37", diffRemoved: "#cf222e", skill: "#8250df"),
        preset(id: "grease-monkey-light", name: "Greaseball", codeThemeID: "grease-monkey-light", variant: .light, accent: "#a35a17", contrast: 40, ink: "#221d14", surface: "#faf6ef", diffAdded: "#2f8f3f", diffRemoved: "#c2352b", skill: "#8d4fc4"),
        preset(id: "gruvbox-light", name: "Gruvbox", codeThemeID: "gruvbox", variant: .light, accent: "#458588", contrast: 45, ink: "#3c3836", surface: "#fbf1c7", diffAdded: "#3c3836", diffRemoved: "#cc241d", skill: "#b16286"),
        preset(id: "linear-light", name: "Linear", codeThemeID: "linear", variant: .light, accent: "#5e6ad2", contrast: 45, ink: "#1b1b1b", surface: "#fcfcfd", diffAdded: "#52a450", diffRemoved: "#c94446", skill: "#8160d8"),
        preset(id: "notion-light", name: "Notion", codeThemeID: "notion", variant: .light, accent: "#3183d8", contrast: 45, ink: "#37352f", surface: "#ffffff", diffAdded: "#008000", diffRemoved: "#a31515", skill: "#0000ff"),
        preset(id: "one-light", name: "One", codeThemeID: "one", variant: .light, accent: "#526fff", contrast: 45, ink: "#383a42", surface: "#fafafa", diffAdded: "#3bba54", diffRemoved: "#e45649", skill: "#526fff"),
        preset(id: "proof-light", name: "Proof", codeThemeID: "proof", variant: .light, accent: "#3d755d", contrast: 45, ink: "#2f312d", surface: "#f5f3ed", diffAdded: "#3d755d", diffRemoved: "#ba2623", skill: "#5f6ac2"),
        preset(id: "raycast-light", name: "Raycast", codeThemeID: "raycast", variant: .light, accent: "#ff6363", contrast: 45, ink: "#030303", surface: "#ffffff", diffAdded: "#006b4f", diffRemoved: "#b12424", skill: "#9a1b6e"),
        preset(id: "rose-pine-light", name: "Rose Pine", codeThemeID: "rose-pine", variant: .light, accent: "#d7827e", contrast: 45, ink: "#575279", surface: "#faf4ed", diffAdded: "#56949f", diffRemoved: "#797593", skill: "#907aa9"),
        preset(id: "solarized-light", name: "Solarized", codeThemeID: "solarized", variant: .light, accent: "#b58900", contrast: 45, ink: "#657b83", surface: "#fdf6e3", diffAdded: "#859900", diffRemoved: "#dc322f", skill: "#d33682"),
        preset(id: "sock-monkey-light", name: "Sockpuppet", codeThemeID: "sock-monkey-light", variant: .light, accent: "#b23b38", contrast: 40, ink: "#241c1b", surface: "#fbf7f3", diffAdded: "#2d8a44", diffRemoved: "#b23b38", skill: "#8a4bbd"),
        preset(id: "vercel-light", name: "Vercel", codeThemeID: "vercel", variant: .light, accent: "#006aff", contrast: 40, ink: "#171717", surface: "#ffffff", diffAdded: "#28a948", diffRemoved: "#eb001d", skill: "#a100f8"),
        preset(id: "vscode-plus-light", name: "VS Code Plus", codeThemeID: "vscode-plus", variant: .light, accent: "#007acc", contrast: 45, ink: "#000000", surface: "#ffffff", diffAdded: "#008000", diffRemoved: "#ee0000", skill: "#0000ff"),
        preset(id: "xcode-light", name: "Xcode", codeThemeID: "xcode", variant: .light, accent: "#0e0eff", contrast: 45, ink: "#262626", surface: "#ffffff", diffAdded: "#00a240", diffRemoved: "#c41a16", skill: "#0e0eff")
    ]

    public static let darkPresets: [MonknotThemePreset] = [
        preset(id: "absolutely-dark", name: "Absolutely", codeThemeID: "absolutely", variant: .dark, accent: "#cc7d5e", contrast: 60, ink: "#f9f9f7", surface: "#2d2d2b", diffAdded: "#00c853", diffRemoved: "#ff5f38", skill: "#cc7d5e"),
        preset(id: "ayu-dark", name: "Ayu", codeThemeID: "ayu", variant: .dark, accent: "#e6b450", contrast: 60, ink: "#bfbdb6", surface: "#10141c", diffAdded: "#70bf56", diffRemoved: "#f26d78", skill: "#d0a1ff"),
        preset(id: "brass-monkey-dark", name: "Brasspants", codeThemeID: "brass-monkey-dark", variant: .dark, accent: "#d9a94b", contrast: 40, ink: "#dfe6ee", surface: "#0e1319", diffAdded: "#54b98c", diffRemoved: "#e2645e", skill: "#7fa6e8"),
        preset(id: "catppuccin-dark", name: "Catppuccin", codeThemeID: "catppuccin", variant: .dark, accent: "#cba6f7", contrast: 60, ink: "#cdd6f4", surface: "#1e1e2e", diffAdded: "#a6e3a1", diffRemoved: "#f38ba8", skill: "#cba6f7"),
        preset(id: "codex-dark", name: "Codex", codeThemeID: "codex", variant: .dark, accent: "#0169cc", contrast: 60, ink: "#fcfcfc", surface: "#111111", diffAdded: "#00a240", diffRemoved: "#e02e2a", skill: "#b06dff"),
        preset(id: "code-monkey-dark", name: "Codechimp", codeThemeID: "code-monkey-dark", variant: .dark, accent: "#4bbf8a", contrast: 40, ink: "#e4eaef", surface: "#12161a", diffAdded: "#4bbf8a", diffRemoved: "#e8615c", skill: "#8f9ef5"),
        preset(id: "dracula-dark", name: "Dracula", codeThemeID: "dracula", variant: .dark, accent: "#ff79c6", contrast: 60, ink: "#f8f8f2", surface: "#282a36", diffAdded: "#50fa7b", diffRemoved: "#ff5555", skill: "#ff79c6"),
        preset(id: "everforest-dark", name: "Everforest", codeThemeID: "everforest", variant: .dark, accent: "#a7c080", contrast: 60, ink: "#d3c6aa", surface: "#2d353b", diffAdded: "#a7c080", diffRemoved: "#e67e80", skill: "#d699b6"),
        preset(id: "github-dark", name: "GitHub", codeThemeID: "github", variant: .dark, accent: "#1f6feb", contrast: 60, ink: "#e6edf3", surface: "#0d1117", diffAdded: "#3fb950", diffRemoved: "#f85149", skill: "#bc8cff"),
        preset(id: "grease-monkey-dark", name: "Greaseball", codeThemeID: "grease-monkey-dark", variant: .dark, accent: "#e08a4c", contrast: 40, ink: "#f2ece1", surface: "#17140f", diffAdded: "#5fb85f", diffRemoved: "#e2564a", skill: "#c98fe0"),
        preset(id: "gruvbox-dark", name: "Gruvbox", codeThemeID: "gruvbox", variant: .dark, accent: "#458588", contrast: 60, ink: "#ebdbb2", surface: "#282828", diffAdded: "#ebdbb2", diffRemoved: "#cc241d", skill: "#b16286"),
        preset(id: "linear-dark", name: "Linear", codeThemeID: "linear", variant: .dark, accent: "#606acc", contrast: 60, ink: "#e3e4e6", surface: "#0f0f11", diffAdded: "#69c967", diffRemoved: "#ff7e78", skill: "#c2a1ff"),
        preset(id: "lobster-dark", name: "Lobster", codeThemeID: "lobster", variant: .dark, accent: "#ff5c5c", contrast: 60, ink: "#e4e4e7", surface: "#111827", diffAdded: "#22c55e", diffRemoved: "#ff5c5c", skill: "#3b82f6"),
        preset(id: "material-dark", name: "Material", codeThemeID: "material", variant: .dark, accent: "#80cbc4", contrast: 60, ink: "#eeffff", surface: "#212121", diffAdded: "#c3e88d", diffRemoved: "#f07178", skill: "#c792ea"),
        preset(id: "matrix-dark", name: "Matrix", codeThemeID: "matrix", variant: .dark, accent: "#1eff5a", contrast: 60, ink: "#b8ffca", surface: "#040805", diffAdded: "#1eff5a", diffRemoved: "#fa423e", skill: "#1eff5a"),
        preset(id: "monokai-dark", name: "Monokai", codeThemeID: "monokai", variant: .dark, accent: "#99947c", contrast: 60, ink: "#f8f8f2", surface: "#272822", diffAdded: "#86b42b", diffRemoved: "#c4265e", skill: "#8c6bc8"),
        preset(id: "night-owl-dark", name: "Night Owl", codeThemeID: "night-owl", variant: .dark, accent: "#44596b", contrast: 60, ink: "#d6deeb", surface: "#011627", diffAdded: "#c5e478", diffRemoved: "#ef5350", skill: "#c792ea"),
        preset(id: "nord-dark", name: "Nord", codeThemeID: "nord", variant: .dark, accent: "#88c0d0", contrast: 60, ink: "#d8dee9", surface: "#2e3440", diffAdded: "#a3be8c", diffRemoved: "#bf616a", skill: "#b48ead"),
        preset(id: "notion-dark", name: "Notion", codeThemeID: "notion", variant: .dark, accent: "#3183d8", contrast: 60, ink: "#d9d9d8", surface: "#191919", diffAdded: "#4ec9b0", diffRemoved: "#fa423e", skill: "#3183d8"),
        preset(id: "one-dark", name: "One", codeThemeID: "one", variant: .dark, accent: "#4d78cc", contrast: 60, ink: "#abb2bf", surface: "#282c34", diffAdded: "#8cc265", diffRemoved: "#e05561", skill: "#c162de"),
        preset(id: "oscurange-dark", name: "Oscurange", codeThemeID: "oscurange", variant: .dark, accent: "#f9b98c", contrast: 60, ink: "#e6e6e6", surface: "#0b0b0f", diffAdded: "#40c977", diffRemoved: "#fa423e", skill: "#479ffa"),
        preset(id: "raycast-dark", name: "Raycast", codeThemeID: "raycast", variant: .dark, accent: "#ff6363", contrast: 60, ink: "#fefefe", surface: "#101010", diffAdded: "#59d499", diffRemoved: "#ff6363", skill: "#cf2f98"),
        preset(id: "rose-pine-dark", name: "Rose Pine", codeThemeID: "rose-pine", variant: .dark, accent: "#ea9a97", contrast: 60, ink: "#e0def4", surface: "#232136", diffAdded: "#9ccfd8", diffRemoved: "#908caa", skill: "#c4a7e7"),
        preset(id: "sentry-dark", name: "Sentry", codeThemeID: "sentry", variant: .dark, accent: "#7055f6", contrast: 60, ink: "#e6dff9", surface: "#2d2935", diffAdded: "#8ee6d7", diffRemoved: "#fa423e", skill: "#7055f6"),
        preset(id: "solarized-dark", name: "Solarized", codeThemeID: "solarized", variant: .dark, accent: "#d30102", contrast: 60, ink: "#839496", surface: "#002b36", diffAdded: "#859900", diffRemoved: "#dc322f", skill: "#d33682"),
        preset(id: "sock-monkey-dark", name: "Sockpuppet", codeThemeID: "sock-monkey-dark", variant: .dark, accent: "#d9615c", contrast: 40, ink: "#f0e6e3", surface: "#1a1415", diffAdded: "#68b06a", diffRemoved: "#e2564a", skill: "#c184d6"),
        preset(id: "temple-dark", name: "Temple", codeThemeID: "temple", variant: .dark, accent: "#e4f222", contrast: 60, ink: "#c7e6da", surface: "#02120c", diffAdded: "#40c977", diffRemoved: "#fa423e", skill: "#e4f222"),
        preset(id: "tokyo-night-dark", name: "Tokyo Night", codeThemeID: "tokyo-night", variant: .dark, accent: "#3d59a1", contrast: 60, ink: "#a9b1d6", surface: "#1a1b26", diffAdded: "#449dab", diffRemoved: "#914c54", skill: "#9d7cd8"),
        preset(id: "vercel-dark", name: "Vercel", codeThemeID: "vercel", variant: .dark, accent: "#006efe", contrast: 50, ink: "#ededed", surface: "#000000", diffAdded: "#00ad3a", diffRemoved: "#f13342", skill: "#9540d5"),
        preset(id: "vscode-plus-dark", name: "VS Code Plus", codeThemeID: "vscode-plus", variant: .dark, accent: "#007acc", contrast: 60, ink: "#d4d4d4", surface: "#1e1e1e", diffAdded: "#369432", diffRemoved: "#f44747", skill: "#000080"),
        preset(id: "xcode-dark", name: "Xcode", codeThemeID: "xcode", variant: .dark, accent: "#5482ff", contrast: 60, ink: "#dedede", surface: "#1f1f24", diffAdded: "#67b7a4", diffRemoved: "#fc6a5d", skill: "#5482ff")
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
        MonknotThemeCatalog.lightPresets.first { $0.id == "codex-light" }!.theme
    }

    static var defaultDark: AppTheme {
        MonknotThemeCatalog.darkPresets.first { $0.id == "codex-dark" }!.theme
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
