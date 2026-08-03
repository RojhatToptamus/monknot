import Foundation
@testable import MonknotCore
import XCTest

final class MarkdownRenderServiceTests: XCTestCase {
    func testCodexThemeCatalogKeepsVersionedDefaultTokens() {
        XCTAssertEqual(CodexThemeCatalog.sourceVersion, "codex-theme-v1")
        XCTAssertEqual(AppTheme.codexLight.codeThemeID, "codex")
        XCTAssertEqual(AppTheme.codexLight.accent, "#339cff")
        XCTAssertEqual(AppTheme.codexLight.background, "#ffffff")
        XCTAssertEqual(AppTheme.codexLight.foreground, "#1a1c1f")
        XCTAssertEqual(AppTheme.codexLight.contrast, 45)

        XCTAssertEqual(AppTheme.codexDark.codeThemeID, "codex")
        XCTAssertEqual(AppTheme.codexDark.accent, "#0169cc")
        XCTAssertEqual(AppTheme.codexDark.background, "#111111")
        XCTAssertEqual(AppTheme.codexDark.foreground, "#fcfcfc")
        XCTAssertEqual(AppTheme.codexDark.contrast, 60)

        XCTAssertTrue(AppTheme.lightThemes.contains { $0.id == "rose-pine-light" })
        XCTAssertTrue(AppTheme.darkThemes.contains { $0.id == "night-owl-dark" })
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
        let theme = AppTheme.codexDark.replacing(codeFontSize: 20, contrast: 75)

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
            for: .codexDark,
            zoomScale: 0.7,
            baseFontSize: 16,
            previewWidthPercent: 88
        ))
        let enlargedValues = Dictionary(uniqueKeysWithValues: service.themeVariableValues(
            for: .codexDark,
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
            appTheme: AppTheme.codexDark,
            zoomScale: 1,
            baseFontSize: AppTheme.codexDark.codeFontSize,
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
            appTheme: .codexLight,
            zoomScale: 1,
            baseFontSize: AppTheme.codexLight.codeFontSize,
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
