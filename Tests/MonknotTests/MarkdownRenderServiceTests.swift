import Foundation
@testable import MonknotCore
import XCTest

final class MarkdownRenderServiceTests: XCTestCase {
    func testThemeCatalogKeepsVersionedHarborDefaultTokens() {
        XCTAssertEqual(MonknotThemeCatalog.sourceVersion, "monknot-theme-v3")
        XCTAssertEqual(AppTheme.defaultLight.id, "harbor-light")
        XCTAssertEqual(AppTheme.defaultLight.name, "Harbor")
        XCTAssertEqual(AppTheme.defaultLight.codeThemeID, "harbor")
        XCTAssertEqual(AppTheme.defaultLight.accent, "#0a52a3")
        XCTAssertEqual(AppTheme.defaultLight.background, "#fdfdfe")
        XCTAssertEqual(AppTheme.defaultLight.foreground, "#1c1e22")
        XCTAssertEqual(AppTheme.defaultLight.contrast, 40)

        XCTAssertEqual(AppTheme.defaultDark.id, "harbor-dark")
        XCTAssertEqual(AppTheme.defaultDark.name, "Harbor")
        XCTAssertEqual(AppTheme.defaultDark.codeThemeID, "harbor")
        XCTAssertEqual(AppTheme.defaultDark.accent, "#5399ea")
        XCTAssertEqual(AppTheme.defaultDark.background, "#121212")
        XCTAssertEqual(AppTheme.defaultDark.foreground, "#ebebeb")
        XCTAssertEqual(AppTheme.defaultDark.contrast, 40)

        XCTAssertTrue(AppTheme.lightThemes.contains { $0.id == "rose-pine-dawn" })
        XCTAssertTrue(AppTheme.darkThemes.contains { $0.id == "night-owl-dark" })
    }

    func testThemeCatalogIncludesEveryCurrentLightAndDarkPreset() {
        let expectedLightNames = [
            "Parchment", "Brasspants", "Catppuccin Latte", "Harbor", "Codechimp", "Everforest",
            "Forge", "Greaseball", "Gruvbox", "Axis", "Paper", "One Light", "Proof",
            "Signal", "Rosé Pine Dawn", "Solarized Light", "Sockpuppet", "Monolith", "Workbench", "Blueprint"
        ]
        let expectedDarkNames = [
            "Parchment", "Ayu Dark", "Brasspants", "Catppuccin Mocha", "Harbor", "Codechimp", "Dracula",
            "Everforest", "Forge", "Greaseball", "Gruvbox", "Axis", "Lobster", "Lagoon",
            "Phosphor", "Citrus", "Night Owl", "Nord", "Paper", "One Dark", "Oscura", "Signal",
            "Rosé Pine Moon", "Watchtower", "Solarized Dark", "Sockpuppet", "Temple", "Tokyo Night", "Monolith",
            "Workbench", "Blueprint"
        ]

        XCTAssertEqual(MonknotThemeCatalog.lightPresets.map(\.theme.name), expectedLightNames)
        XCTAssertEqual(MonknotThemeCatalog.darkPresets.map(\.theme.name), expectedDarkNames)

        let allPresets = MonknotThemeCatalog.lightPresets + MonknotThemeCatalog.darkPresets
        XCTAssertEqual(Set(allPresets.map(\.id)).count, allPresets.count)
        XCTAssertTrue(MonknotThemeCatalog.lightPresets.allSatisfy { !$0.theme.isDark })
        XCTAssertTrue(MonknotThemeCatalog.darkPresets.allSatisfy { $0.theme.isDark })

        for preset in allPresets {
            let theme = preset.theme
            let colors = [
                theme.background,
                theme.foreground,
                theme.cursor,
                theme.selectionBackground,
                theme.selectionForeground,
                theme.semanticColors.diffAdded,
                theme.semanticColors.diffRemoved,
                theme.semanticColors.skill
            ] + theme.palette

            XCTAssertTrue(
                colors.allSatisfy { RGBHex($0) != nil },
                "Every color in \(preset.id) must be a six-digit RGB token"
            )
        }
    }

    func testDocumentedCanonicalThemeRoleMappingsRemainExact() throws {
        typealias Roles = (
            accent: String,
            ink: String,
            surface: String,
            added: String,
            removed: String,
            skill: String
        )
        let expected: [String: Roles] = [
            "ayu-dark": ("#e6b450", "#bfbdb6", "#10141c", "#70bf56", "#f26d78", "#d2a6ff"),
            "catppuccin-latte": ("#8839ef", "#4c4f69", "#eff1f5", "#40a02b", "#d20f39", "#8839ef"),
            "catppuccin-mocha": ("#cba6f7", "#cdd6f4", "#1e1e2e", "#a6e3a1", "#f38ba8", "#cba6f7"),
            "dracula-dark": ("#ff79c6", "#f8f8f2", "#282a36", "#50fa7b", "#ff5555", "#ff79c6"),
            "everforest-light": ("#93b259", "#5c6a72", "#fdf6e3", "#8da101", "#f85552", "#df69ba"),
            "everforest-dark": ("#a7c080", "#d3c6aa", "#2d353b", "#a7c080", "#e67e80", "#d699b6"),
            "gruvbox-light": ("#458588", "#3c3836", "#fbf1c7", "#98971a", "#cc241d", "#b16286"),
            "gruvbox-dark": ("#458588", "#ebdbb2", "#282828", "#98971a", "#cc241d", "#b16286"),
            "night-owl-dark": ("#44596b", "#d6deeb", "#011627", "#c5e478", "#ef5350", "#c792ea"),
            "nord-dark": ("#88c0d0", "#d8dee9", "#2e3440", "#a3be8c", "#bf616a", "#b48ead"),
            "one-light": ("#4078f2", "#383a42", "#fafafa", "#50a14f", "#e45649", "#a626a4"),
            "one-dark": ("#61afef", "#abb2bf", "#282c34", "#98c379", "#e06c75", "#c678dd"),
            "oscura-dark": ("#f9b98c", "#e6e6e6", "#0b0b0f", "#54c0a3", "#d84f68", "#479ffa"),
            "rose-pine-dawn": ("#d7827e", "#464261", "#faf4ed", "#56949f", "#b4637a", "#907aa9"),
            "rose-pine-moon": ("#ea9a97", "#e0def4", "#232136", "#9ccfd8", "#eb6f92", "#c4a7e7"),
            "solarized-light": ("#268bd2", "#657b83", "#fdf6e3", "#859900", "#dc322f", "#d33682"),
            "solarized-dark": ("#268bd2", "#839496", "#002b36", "#859900", "#dc322f", "#d33682"),
            "tokyo-night-dark": ("#3d59a1", "#a9b1d6", "#1a1b26", "#449dab", "#914c54", "#9d7cd8"),
        ]
        let themes = Dictionary(
            uniqueKeysWithValues: (AppTheme.lightThemes + AppTheme.darkThemes).map { ($0.id, $0) }
        )

        for (id, roles) in expected {
            let theme = try XCTUnwrap(themes[id], id)
            XCTAssertEqual(theme.accent, roles.accent, id)
            XCTAssertEqual(theme.foreground, roles.ink, id)
            XCTAssertEqual(theme.background, roles.surface, id)
            XCTAssertEqual(theme.semanticColors.diffAdded, roles.added, id)
            XCTAssertEqual(theme.semanticColors.diffRemoved, roles.removed, id)
            XCTAssertEqual(theme.semanticColors.skill, roles.skill, id)
        }
    }

    func testOwnerProvidedReplacementPalettesMatchTheApprovedCatalog() throws {
        let expected: [String: [String]] = [
            "parchment-light": ["#876a26", "#241b12", "#f7f4ed", "#277c4c", "#a52f27", "#9b36ab"],
            "parchment-dark": ["#cbb072", "#ede9e3", "#14120f", "#65c387", "#e56e61", "#dc92e7"],
            "harbor-light": ["#0a52a3", "#1c1e22", "#fdfdfe", "#277c4c", "#a52f27", "#7436ab"],
            "harbor-dark": ["#5399ea", "#ebebeb", "#121212", "#65c387", "#e56e61", "#c092e7"],
            "forge-light": ["#13499a", "#191f29", "#f9fafb", "#277c4c", "#a52f27", "#7036ab"],
            "forge-dark": ["#5c91e0", "#e6ebef", "#0c1118", "#65c387", "#e56e61", "#bd92e7"],
            "axis-light": ["#321f8e", "#1d1c26", "#f6f6f9", "#277c4c", "#a52f27", "#9336ab"],
            "axis-dark": ["#7e6dd0", "#e4e3e8", "#111013", "#65c387", "#e56e61", "#d692e7"],
            "lagoon-dark": ["#62dace", "#e0e9eb", "#0d191c", "#65c387", "#e56e61", "#a392e7"],
            "phosphor-dark": ["#62da86", "#dbe6de", "#0b0f0c", "#65c387", "#e56e61", "#ba92e7"],
            "citrus-dark": ["#e4db58", "#efefe7", "#161612", "#65c387", "#e56e61", "#e792d1"],
            "paper-light": ["#2f597f", "#22201d", "#fdfdfc", "#277c4c", "#a52f27", "#6836ab"],
            "paper-dark": ["#7da0bf", "#e9e9e7", "#171717", "#65c387", "#e56e61", "#b792e7"],
            "signal-light": ["#a11b0c", "#271d1b", "#fcf9f8", "#277c4c", "#a52f27", "#8436ab"],
            "signal-dark": ["#e86354", "#ebe6e5", "#141010", "#65c387", "#e56e61", "#cb92e7"],
            "watchtower-dark": ["#a966d6", "#e3dfe7", "#141019", "#65c387", "#e56e61", "#c592e7"],
            "monolith-light": ["#424242", "#1a1a1a", "#fdfdfd", "#277c4c", "#a52f27", "#7836ab"],
            "monolith-dark": ["#c7c7c7", "#ededed", "#0a0a0a", "#65c387", "#e56e61", "#c292e7"],
            "workbench-light": ["#1d6690", "#181e25", "#f6f7f9", "#277c4c", "#a52f27", "#6836ab"],
            "workbench-dark": ["#6aacd2", "#e1e6ea", "#12171c", "#65c387", "#e56e61", "#b792e7"],
            "blueprint-light": ["#0c2fa1", "#111a30", "#e9edf7", "#277c4c", "#a52f27", "#8b36ab"],
            "blueprint-dark": ["#5678e6", "#dee3ed", "#0b101d", "#65c387", "#e56e61", "#d192e7"],
        ]
        let themes = Dictionary(
            uniqueKeysWithValues: (AppTheme.lightThemes + AppTheme.darkThemes).map { ($0.id, $0) }
        )

        for (id, colors) in expected {
            let theme = try XCTUnwrap(themes[id], id)
            XCTAssertEqual(
                [
                    theme.accent,
                    theme.foreground,
                    theme.background,
                    theme.semanticColors.diffAdded,
                    theme.semanticColors.diffRemoved,
                    theme.semanticColors.skill,
                ],
                colors,
                id
            )
        }
    }

    func testOwnerProvidedReplacementAccentsChooseAccessibleForegrounds() throws {
        let ids: Set<String> = [
            "parchment-light", "parchment-dark", "harbor-light", "harbor-dark",
            "forge-light", "forge-dark", "axis-light", "axis-dark", "lagoon-dark",
            "phosphor-dark", "citrus-dark", "paper-light", "paper-dark", "signal-light",
            "signal-dark", "watchtower-dark", "monolith-light", "monolith-dark",
            "workbench-light", "workbench-dark", "blueprint-light", "blueprint-dark",
        ]
        let themes = (AppTheme.lightThemes + AppTheme.darkThemes).filter { ids.contains($0.id) }
        XCTAssertEqual(themes.count, ids.count)

        for theme in themes {
            let accent = try XCTUnwrap(RGBHex(theme.accent), theme.id)
            let foreground = try XCTUnwrap(RGBHex(theme.onAccentForegroundHex), theme.id)
            XCTAssertGreaterThanOrEqual(
                foreground.contrastRatio(with: accent),
                4.5,
                "\(theme.id) must keep accent-button labels readable"
            )
        }
    }

    func testCustomPresetSeedsMatchTheSuppliedEightPalettesAndUseOneWordNames() throws {
        let expected: [String: (name: String, accent: String, background: String, foreground: String, added: String, removed: String, skill: String)] = [
            "greaseball-dark": ("Greaseball", "#e08a4c", "#17140f", "#f2ece1", "#5fb85f", "#e2564a", "#c98fe0"),
            "greaseball-light": ("Greaseball", "#a35a17", "#faf6ef", "#221d14", "#2f8f3f", "#c2352b", "#8d4fc4"),
            "codechimp-dark": ("Codechimp", "#4bbf8a", "#12161a", "#e4eaef", "#4bbf8a", "#e8615c", "#8f9ef5"),
            "codechimp-light": ("Codechimp", "#12805a", "#fbfcfd", "#1a2027", "#12805a", "#c33b36", "#4457c9"),
            "brasspants-dark": ("Brasspants", "#d9a94b", "#0e1319", "#dfe6ee", "#54b98c", "#e2645e", "#7fa6e8"),
            "brasspants-light": ("Brasspants", "#8a6410", "#f7f9fb", "#181f28", "#1f7d5c", "#bf3a34", "#2f5fbd"),
            "sockpuppet-dark": ("Sockpuppet", "#d9615c", "#1a1415", "#f0e6e3", "#68b06a", "#e2564a", "#c184d6"),
            "sockpuppet-light": ("Sockpuppet", "#b23b38", "#fbf7f3", "#241c1b", "#2d8a44", "#b23b38", "#8a4bbd")
        ]
        let presets = Dictionary(
            uniqueKeysWithValues: (MonknotThemeCatalog.lightPresets + MonknotThemeCatalog.darkPresets)
                .map { ($0.id, $0.theme) }
        )

        for (id, seed) in expected {
            let theme = try XCTUnwrap(presets[id], "Missing supplied preset \(id)")
            XCTAssertEqual(theme.name, seed.name)
            XCTAssertFalse(theme.name.contains(" "))
            XCTAssertEqual(theme.accent, seed.accent)
            XCTAssertEqual(theme.background, seed.background)
            XCTAssertEqual(theme.foreground, seed.foreground)
            XCTAssertEqual(theme.semanticColors.diffAdded, seed.added)
            XCTAssertEqual(theme.semanticColors.diffRemoved, seed.removed)
            XCTAssertEqual(theme.semanticColors.skill, seed.skill)
            XCTAssertEqual(theme.contrast, 40)
            XCTAssertNil(theme.uiFontName)
            XCTAssertNil(theme.codeFontName)
            XCTAssertEqual(theme.uiFontSize, 16)
            XCTAssertEqual(theme.codeFontSize, 13)
        }
    }

    func testCurrentPresetSeedsUseStableSystemTypography() throws {
        let monolithLight = try XCTUnwrap(AppTheme.lightThemes.first { $0.id == "monolith-light" })
        XCTAssertEqual(monolithLight.accent, "#424242")
        XCTAssertEqual(monolithLight.background, "#fdfdfd")
        XCTAssertEqual(monolithLight.foreground, "#1a1a1a")
        XCTAssertEqual(monolithLight.contrast, 40)

        let proofLight = try XCTUnwrap(AppTheme.lightThemes.first { $0.id == "proof-light" })
        XCTAssertEqual(proofLight.accent, "#3d755d")
        XCTAssertEqual(proofLight.background, "#f5f3ed")
        XCTAssertEqual(proofLight.foreground, "#2f312d")

        let monolithDark = try XCTUnwrap(AppTheme.darkThemes.first { $0.id == "monolith-dark" })
        XCTAssertEqual(monolithDark.accent, "#c7c7c7")
        XCTAssertEqual(monolithDark.background, "#0a0a0a")
        XCTAssertEqual(monolithDark.foreground, "#ededed")
        XCTAssertEqual(monolithDark.contrast, 40)

        let phosphorDark = try XCTUnwrap(AppTheme.darkThemes.first { $0.id == "phosphor-dark" })
        XCTAssertEqual(phosphorDark.accent, "#62da86")
        XCTAssertEqual(phosphorDark.background, "#0b0f0c")
        XCTAssertEqual(phosphorDark.foreground, "#dbe6de")

        let blueprintLight = try XCTUnwrap(AppTheme.lightThemes.first { $0.id == "blueprint-light" })
        let blueprintDark = try XCTUnwrap(AppTheme.darkThemes.first { $0.id == "blueprint-dark" })
        XCTAssertEqual(blueprintLight.foreground, "#111a30")
        XCTAssertEqual(blueprintDark.foreground, "#dee3ed")

        let ayuDark = try XCTUnwrap(AppTheme.darkThemes.first { $0.id == "ayu-dark" })
        XCTAssertEqual(ayuDark.background, "#10141c")

        let lightHouseTheme = try XCTUnwrap(AppTheme.lightThemes.first { $0.id == "harbor-light" })
        let darkHouseTheme = try XCTUnwrap(AppTheme.darkThemes.first { $0.id == "harbor-dark" })
        XCTAssertEqual(lightHouseTheme.name, "Harbor")
        XCTAssertEqual(darkHouseTheme.name, "Harbor")
        XCTAssertEqual(lightHouseTheme.codeThemeID, "harbor")
        XCTAssertEqual(darkHouseTheme.codeThemeID, "harbor")

        let allThemes = AppTheme.lightThemes + AppTheme.darkThemes
        XCTAssertTrue(allThemes.allSatisfy { $0.uiFontName == nil && $0.codeFontName == nil })
        XCTAssertEqual(Set(allThemes.map(\.uiFontSize)), [16])
        XCTAssertEqual(Set(allThemes.map(\.codeFontSize)), [13])
    }

    func testHTMLDocumentEmbedsThemeBaseAndLocalAssets() throws {
        let service = MarkdownRenderService(
            stylesheet: "body { color: var(--fg); }",
            rendererJavaScript: "document.body.dataset.ready = 'true';"
        )
        let baseURL = URL(fileURLWithPath: "/tmp/Monknot Workspace", isDirectory: true)

        let html = try service.htmlDocument(
            markdown: "# Hello\n<script>alert('x')</script>",
            theme: .dark,
            baseURL: baseURL
        )

        XCTAssertTrue(html.contains(#"data-theme="dark""#))
        XCTAssertTrue(html.contains(#"<base href="file:///tmp/Monknot%20Workspace/">"#))
        XCTAssertTrue(html.contains("img-src 'self' file: data: blob:;"))
        XCTAssertFalse(html.contains("img-src 'self' file: data: blob: https: http:;"))
        XCTAssertTrue(html.contains("body { color: var(--fg); }"))
        XCTAssertTrue(html.contains("document.body.dataset.ready"))
        XCTAssertTrue(html.contains(#"<script>alert('x')<\/script>"#))
    }

    func testHTMLDocumentEscapesMarkdownForJavaScriptString() throws {
        let service = MarkdownRenderService(stylesheet: "", rendererJavaScript: "")
        let html = try service.htmlDocument(markdown: #"quote " slash \ newline"#, theme: .light, baseURL: nil)

        XCTAssertTrue(html.contains(#"quote \" slash \\ newline"#))
    }

    func testHTMLDocumentInjectsAppThemeVariablesAfterStylesheetDefaults() throws {
        let service = MarkdownRenderService(
            stylesheet: """
            :root { --bg: #AAAAAA; --fg: #BBBBBB; --link: #CCCCCC; }
            :root[data-theme="dark"] { --bg: #DDDDDD; --fg: #EEEEEE; --link: #FFFFFF; }
            a { color: var(--link); }
            """,
            rendererJavaScript: ""
        )
        let theme = AppTheme(
            id: "test-dark",
            name: "Test Dark",
            background: "#010203",
            foreground: "#FDFCFB",
            cursor: "#445566",
            selectionBackground: "#102030",
            selectionForeground: "#FAFAFA",
            palette: [
                "#000000", "#111111", "#228833", "#AA7700",
                "#445566", "#556677", "#66AACC", "#DDEEFF",
                "#778899"
            ]
        )

        let html = try service.htmlDocument(
            markdown: "[Link](https://example.com)\n\n| A |\n| - |\n| B |\n\n> Quote",
            appTheme: theme,
            zoomScale: 1.25,
            baseURL: nil
        )

        let stylesheetRange = try XCTUnwrap(html.range(of: #":root[data-theme="dark"] { --bg: #DDDDDD;"#))
        let variableRange = try XCTUnwrap(html.range(of: "--bg: #010203;"))

        XCTAssertTrue(stylesheetRange.lowerBound < variableRange.lowerBound)
        XCTAssertTrue(html.contains(#"data-theme="dark""#))
        XCTAssertTrue(html.contains(":root[data-theme=\"dark\"] {"))
        XCTAssertTrue(html.contains("--fg: #FDFCFB;"))
        XCTAssertTrue(html.contains("--link: #445566;"))
        XCTAssertTrue(html.contains("--blockquote-border: #445566;"))
        XCTAssertTrue(html.contains("--table-border: color-mix(in srgb, #FDFCFB 16.0%, transparent);"))
        XCTAssertTrue(html.contains("--selection-bg: #102030;"))
        XCTAssertTrue(html.contains("--base-font-size: 16.2px;"))
        XCTAssertTrue(html.contains("--preview-max-width: 88%;"))
    }

    func testHTMLDocumentUsesThemeCodeFontSizeAndContrast() throws {
        let service = MarkdownRenderService(stylesheet: "", rendererJavaScript: "")
        let theme = AppTheme.defaultDark.replacing(codeFontSize: 20, contrast: 75)

        let html = try service.htmlDocument(
            markdown: "# Title",
            appTheme: theme,
            zoomScale: 1.2,
            baseFontSize: theme.codeFontSize,
            previewWidthPercent: 96,
            baseURL: nil
        )

        XCTAssertTrue(html.contains("--base-font-size: 24.0px;"))
        XCTAssertTrue(html.contains("--preview-max-width: 96%;"))
        XCTAssertTrue(html.contains("--table-border: color-mix(in srgb, #ebebeb 20.0%, transparent);"))
    }

    func testMarkdownTypographySupportsTheExtendedApplicationZoomRange() {
        let service = MarkdownRenderService(stylesheet: "", rendererJavaScript: "")

        let compactValues = Dictionary(uniqueKeysWithValues: service.themeVariableValues(
            for: .defaultDark,
            zoomScale: 0.7,
            baseFontSize: 16,
            previewWidthPercent: 88
        ))
        let enlargedValues = Dictionary(uniqueKeysWithValues: service.themeVariableValues(
            for: .defaultDark,
            zoomScale: 8,
            baseFontSize: 16,
            previewWidthPercent: 88
        ))

        XCTAssertEqual(compactValues["--base-font-size"], "11.2px")
        XCTAssertEqual(enlargedValues["--base-font-size"], "120.0px")
    }

    func testBundledStylesheetPreservesThemeColorsForPDFExport() throws {
        let html = try MarkdownRenderService().htmlDocument(
            markdown: "# Export",
            appTheme: AppTheme.defaultDark,
            zoomScale: 1,
            baseFontSize: AppTheme.defaultDark.codeFontSize,
            previewWidthPercent: 82,
            usePointerCursors: false,
            fontSmoothing: true,
            baseURL: nil
        )

        XCTAssertTrue(html.contains("-webkit-print-color-adjust: exact;"))
        XCTAssertTrue(html.contains("print-color-adjust: exact;"))
        XCTAssertTrue(html.contains("--bg: #121212;"))
        XCTAssertTrue(html.contains("--fg: #ebebeb;"))
        XCTAssertTrue(html.contains("--preview-max-width: 82%;"))
        XCTAssertTrue(html.contains("html.monknot-pdf-export"))
        XCTAssertTrue(html.contains(":root.monknot-pdf-export .markdown-body"))
    }

    func testPreviewWidthUsesTheAvailablePaneInsteadOfALegacyPixelCap() throws {
        let html = try MarkdownRenderService().htmlDocument(
            markdown: "# Full width",
            appTheme: .defaultLight,
            zoomScale: 1,
            baseFontSize: AppTheme.defaultLight.codeFontSize,
            previewWidthPercent: 100,
            baseURL: nil
        )

        XCTAssertTrue(html.contains(
            "width: min(var(--preview-max-width, 88%), calc(100% - 28px));"
        ))
        XCTAssertFalse(html.contains(
            "width: min(var(--preview-max-width, 88%), 700px, calc(100% - 28px));"
        ))
        XCTAssertFalse(html.contains("@media (max-width: 720px) {\n  .markdown-body {\n    width: 100%;"))
    }
}
