import Foundation
@testable import MonknotCore
import XCTest

final class MarkdownRenderServiceTests: XCTestCase {
    func testThemeCatalogKeepsVersionedCodexDefaultTokens() {
        XCTAssertEqual(MonknotThemeCatalog.sourceVersion, "monknot-theme-v1")
        XCTAssertEqual(AppTheme.defaultLight.id, "codex-light")
        XCTAssertEqual(AppTheme.defaultLight.name, "Codex")
        XCTAssertEqual(AppTheme.defaultLight.codeThemeID, "codex")
        XCTAssertEqual(AppTheme.defaultLight.accent, "#0169cc")
        XCTAssertEqual(AppTheme.defaultLight.background, "#ffffff")
        XCTAssertEqual(AppTheme.defaultLight.foreground, "#0d0d0d")
        XCTAssertEqual(AppTheme.defaultLight.contrast, 45)

        XCTAssertEqual(AppTheme.defaultDark.id, "codex-dark")
        XCTAssertEqual(AppTheme.defaultDark.name, "Codex")
        XCTAssertEqual(AppTheme.defaultDark.codeThemeID, "codex")
        XCTAssertEqual(AppTheme.defaultDark.accent, "#0169cc")
        XCTAssertEqual(AppTheme.defaultDark.background, "#111111")
        XCTAssertEqual(AppTheme.defaultDark.foreground, "#fcfcfc")
        XCTAssertEqual(AppTheme.defaultDark.contrast, 60)

        XCTAssertTrue(AppTheme.lightThemes.contains { $0.id == "rose-pine-light" })
        XCTAssertTrue(AppTheme.darkThemes.contains { $0.id == "night-owl-dark" })
    }

    func testThemeCatalogIncludesEveryCurrentLightAndDarkPreset() {
        let expectedLightNames = [
            "Absolutely", "Brasspants", "Catppuccin", "Codex", "Codechimp", "Everforest",
            "GitHub", "Greaseball", "Gruvbox", "Linear", "Notion", "One", "Proof",
            "Raycast", "Rose Pine", "Solarized", "Sockpuppet", "Vercel", "VS Code Plus", "Xcode"
        ]
        let expectedDarkNames = [
            "Absolutely", "Ayu", "Brasspants", "Catppuccin", "Codex", "Codechimp", "Dracula",
            "Everforest", "GitHub", "Greaseball", "Gruvbox", "Linear", "Lobster", "Material",
            "Matrix", "Monokai", "Night Owl", "Nord", "Notion", "One", "Oscurange", "Raycast",
            "Rose Pine", "Sentry", "Solarized", "Sockpuppet", "Temple", "Tokyo Night", "Vercel",
            "VS Code Plus", "Xcode"
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

    func testMonkeyPresetSeedsMatchTheSuppliedEightPalettesAndUseOneWordNames() throws {
        let expected: [String: (name: String, accent: String, background: String, foreground: String, added: String, removed: String, skill: String)] = [
            "grease-monkey-dark": ("Greaseball", "#e08a4c", "#17140f", "#f2ece1", "#5fb85f", "#e2564a", "#c98fe0"),
            "grease-monkey-light": ("Greaseball", "#a35a17", "#faf6ef", "#221d14", "#2f8f3f", "#c2352b", "#8d4fc4"),
            "code-monkey-dark": ("Codechimp", "#4bbf8a", "#12161a", "#e4eaef", "#4bbf8a", "#e8615c", "#8f9ef5"),
            "code-monkey-light": ("Codechimp", "#12805a", "#fbfcfd", "#1a2027", "#12805a", "#c33b36", "#4457c9"),
            "brass-monkey-dark": ("Brasspants", "#d9a94b", "#0e1319", "#dfe6ee", "#54b98c", "#e2645e", "#7fa6e8"),
            "brass-monkey-light": ("Brasspants", "#8a6410", "#f7f9fb", "#181f28", "#1f7d5c", "#bf3a34", "#2f5fbd"),
            "sock-monkey-dark": ("Sockpuppet", "#d9615c", "#1a1415", "#f0e6e3", "#68b06a", "#e2564a", "#c184d6"),
            "sock-monkey-light": ("Sockpuppet", "#b23b38", "#fbf7f3", "#241c1b", "#2d8a44", "#b23b38", "#8a4bbd")
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
        let vercelLight = try XCTUnwrap(AppTheme.lightThemes.first { $0.id == "vercel-light" })
        XCTAssertEqual(vercelLight.accent, "#006aff")
        XCTAssertEqual(vercelLight.background, "#ffffff")
        XCTAssertEqual(vercelLight.foreground, "#171717")
        XCTAssertEqual(vercelLight.contrast, 40)

        let proofLight = try XCTUnwrap(AppTheme.lightThemes.first { $0.id == "proof-light" })
        XCTAssertEqual(proofLight.accent, "#3d755d")
        XCTAssertEqual(proofLight.background, "#f5f3ed")
        XCTAssertEqual(proofLight.foreground, "#2f312d")

        let vercelDark = try XCTUnwrap(AppTheme.darkThemes.first { $0.id == "vercel-dark" })
        XCTAssertEqual(vercelDark.accent, "#006efe")
        XCTAssertEqual(vercelDark.background, "#000000")
        XCTAssertEqual(vercelDark.foreground, "#ededed")
        XCTAssertEqual(vercelDark.contrast, 50)

        let matrixDark = try XCTUnwrap(AppTheme.darkThemes.first { $0.id == "matrix-dark" })
        XCTAssertEqual(matrixDark.accent, "#1eff5a")
        XCTAssertEqual(matrixDark.background, "#040805")
        XCTAssertEqual(matrixDark.foreground, "#b8ffca")

        let xcodeLight = try XCTUnwrap(AppTheme.lightThemes.first { $0.id == "xcode-light" })
        let xcodeDark = try XCTUnwrap(AppTheme.darkThemes.first { $0.id == "xcode-dark" })
        XCTAssertEqual(xcodeLight.foreground, "#262626")
        XCTAssertEqual(xcodeDark.foreground, "#dedede")

        let ayuDark = try XCTUnwrap(AppTheme.darkThemes.first { $0.id == "ayu-dark" })
        XCTAssertEqual(ayuDark.background, "#10141c")

        let lightHouseTheme = try XCTUnwrap(AppTheme.lightThemes.first { $0.id == "codex-light" })
        let darkHouseTheme = try XCTUnwrap(AppTheme.darkThemes.first { $0.id == "codex-dark" })
        XCTAssertEqual(lightHouseTheme.name, "Codex")
        XCTAssertEqual(darkHouseTheme.name, "Codex")
        XCTAssertEqual(lightHouseTheme.codeThemeID, "codex")
        XCTAssertEqual(darkHouseTheme.codeThemeID, "codex")

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
        XCTAssertTrue(html.contains("--table-border: color-mix(in srgb, #fcfcfc 20.0%, transparent);"))
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
        XCTAssertTrue(html.contains("--bg: #111111;"))
        XCTAssertTrue(html.contains("--fg: #fcfcfc;"))
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
