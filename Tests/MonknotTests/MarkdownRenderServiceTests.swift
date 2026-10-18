import Foundation
import XCTest
@testable import MonknotCore

final class MarkdownRenderServiceTests: MarkdownRenderServiceTestCase {
    func testHTMLDocumentEscapesMarkdownForJavaScriptString() throws {
        let service = MarkdownRenderService(stylesheet: "", rendererJavaScript: "")
        let html = try service.htmlDocument(markdown: #"quote " slash \ newline"#, theme: .light, baseURL: nil)

        XCTAssertTrue(html.contains(#"quote \" slash \\ newline"#))
    }

    /// "Show scroll bars: Always" reaches the page with its shell, so its first paint has Monknot's thumb.
    func testLegacyScrollBarsMarkTheShellRoot() throws {
        func shell(legacy: Bool) throws -> String {
            try MarkdownRenderService().htmlDocument(
                markdown: "",
                appTheme: .defaultLight,
                zoomScale: 1,
                baseFontSize: AppTheme.defaultLight.codeFontSize,
                legacyScrollbars: legacy,
                baseURL: nil
            )
        }
        XCTAssertTrue(try shell(legacy: true).contains(#"<html lang="en" data-theme="light" class="mk-legacy-scrollbars">"#))
        XCTAssertTrue(try shell(legacy: false).contains(#"<html lang="en" data-theme="light">"#))
    }

    func testContentWidthUsesTheAvailablePaneInsteadOfALegacyPixelCap() throws {
        let html = try MarkdownRenderService().htmlDocument(
            markdown: "# Full width",
            appTheme: .defaultLight,
            zoomScale: 1,
            baseFontSize: AppTheme.defaultLight.codeFontSize,
            contentWidthPercent: 100,
            baseURL: nil
        )

        XCTAssertTrue(html.contains(
            "width: min(calc(var(--column-text) + 2 * var(--column-gutter)), 100%);"
        ))
        XCTAssertTrue(html.contains("--content-measure: 100000px;"), "At 100% the column fills the pane")
        XCTAssertFalse(html.contains(
            "width: min(var(--content-max-width, 88%), 700px, calc(100% - 28px));"
        ))
        XCTAssertFalse(html.contains("@media (max-width: 720px) {\n  .markdown-body {\n    width: 100%;"))
    }

    /// Below 100% a wide pane stops at a comfortable line length that the setting scales: 640 pt of
    /// 13 pt text at the default 88%, in `em` of Preview's 14 pt prose.
    func testContentWidthBelowFullStopsAtTheMeasure() throws {
        let values = Dictionary(uniqueKeysWithValues: MarkdownRenderService(stylesheet: "", rendererJavaScript: "").themeVariableValues(
            for: .defaultLight,
            zoomScale: 1,
            baseFontSize: 14,
            contentWidthPercent: 88
        ))
        XCTAssertEqual(values["--content-measure"], "45.71em")
        XCTAssertEqual(DocumentMeasure.points(contentWidthPercent: 88), 640, accuracy: 0.01)
        XCTAssertEqual(DocumentMeasure.points(contentWidthPercent: 66, fontSize: 26), 960, accuracy: 0.01)
        XCTAssertTrue(DocumentMeasure.points(contentWidthPercent: 100).isInfinite)
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
        // Local images only: workspace files arrive through the in-app resource scheme.
        XCTAssertTrue(html.contains("img-src 'self' monknot-file: file: data: blob:;"))
        XCTAssertFalse(html.contains("https:"))
        XCTAssertFalse(html.contains("http:"))
        XCTAssertTrue(html.contains("body { color: var(--fg); }"))
        XCTAssertTrue(html.contains("document.body.dataset.ready"))
        XCTAssertTrue(html.contains(#"<script>alert('x')<\/script>"#))
    }

    func testInAppResourceBaseURLKeepsItsScheme() throws {
        let service = MarkdownRenderService(stylesheet: "", rendererJavaScript: "")
        let baseURL = try XCTUnwrap(URL(string: "monknot-file:///tmp/Monknot%20Workspace/"))

        let html = try service.htmlDocument(markdown: "", theme: .light, baseURL: baseURL)

        XCTAssertTrue(html.contains(#"<base href="monknot-file:///tmp/Monknot%20Workspace/">"#))
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
        XCTAssertTrue(html.contains("--content-max-width: 88%;"))
    }

    func testHTMLDocumentUsesThemeCodeFontSizeAndContrast() throws {
        let service = MarkdownRenderService(stylesheet: "", rendererJavaScript: "")
        let theme = AppTheme.defaultDark.replacing(codeFontSize: 20, contrast: 75)

        let html = try service.htmlDocument(
            markdown: "# Title",
            appTheme: theme,
            zoomScale: 1.2,
            baseFontSize: theme.codeFontSize,
            contentWidthPercent: 96,
            baseURL: nil
        )

        XCTAssertTrue(html.contains("--base-font-size: 24.0px;"))
        XCTAssertTrue(html.contains("--content-max-width: 96%;"))
        XCTAssertTrue(html.contains("--table-border: color-mix(in srgb, #ebebeb 20.0%, transparent);"))
    }

    func testMarkdownTypographySupportsTheExtendedApplicationZoomRange() {
        let service = MarkdownRenderService(stylesheet: "", rendererJavaScript: "")

        let compactValues = Dictionary(uniqueKeysWithValues: service.themeVariableValues(
            for: .defaultDark,
            zoomScale: 0.7,
            baseFontSize: 16,
            contentWidthPercent: 88
        ))
        let enlargedValues = Dictionary(uniqueKeysWithValues: service.themeVariableValues(
            for: .defaultDark,
            zoomScale: 8,
            baseFontSize: 16,
            contentWidthPercent: 88
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
            contentWidthPercent: 82,
            usePointerCursors: false,
            fontSmoothing: true,
            baseURL: nil
        )

        XCTAssertTrue(html.contains("-webkit-print-color-adjust: exact;"))
        XCTAssertTrue(html.contains("print-color-adjust: exact;"))
        XCTAssertTrue(html.contains("--bg: #121212;"))
        XCTAssertTrue(html.contains("--fg: #ebebeb;"))
        XCTAssertTrue(html.contains("--content-max-width: 82%;"))
        XCTAssertTrue(html.contains("html.monknot-pdf-export"))
        XCTAssertTrue(html.contains(":root.monknot-pdf-export .markdown-body"))
    }
}
