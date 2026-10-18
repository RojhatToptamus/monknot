import Foundation

public struct MarkdownRenderService: Sendable {
    /// In-app web views load workspace files (images, linked styles) through this URL scheme:
    /// WebKit's sandboxed content process cannot read local files for a page loaded from a string.
    public static let workspaceResourceScheme = "monknot-file"

    private let stylesheet: String
    private let rendererJavaScript: String
    private let editorStylesheet: String?
    private let editorJavaScript: String?

    public init(bundle: Bundle = .main) throws {
        self.stylesheet = try Self.loadResource("preview", extension: "css", bundle: bundle)
        self.rendererJavaScript = try Self.loadResource("renderer", extension: "js", bundle: bundle)
        // The visual editor is optional: without its resources Preview stays read-only.
        self.editorStylesheet = try? Self.loadResource("editor", extension: "css", bundle: bundle)
        self.editorJavaScript = try? Self.loadResource("editor", extension: "js", bundle: bundle)
    }

    public init(
        stylesheet: String,
        rendererJavaScript: String,
        editorStylesheet: String? = nil,
        editorJavaScript: String? = nil
    ) {
        self.stylesheet = stylesheet
        self.rendererJavaScript = rendererJavaScript
        self.editorStylesheet = editorStylesheet
        self.editorJavaScript = editorJavaScript
    }

    /// Whether Preview can be edited in place: the editor's script and stylesheet loaded.
    public var supportsVisualEditing: Bool {
        editorStylesheet != nil && editorJavaScript != nil
    }

    public func htmlDocument(markdown: String, theme: RenderTheme, baseURL: URL?) throws -> String {
        let palette = theme == .dark ? AppTheme.defaultDark : AppTheme.defaultLight
        return try htmlDocument(markdown: markdown, appTheme: palette, zoomScale: 1, baseURL: baseURL)
    }

    public func htmlDocument(markdown: String, appTheme: AppTheme, zoomScale: Double, baseURL: URL?) throws -> String {
        try htmlDocument(
            markdown: markdown,
            appTheme: appTheme,
            zoomScale: zoomScale,
            baseFontSize: appTheme.codeFontSize,
            contentWidthPercent: 88,
            baseURL: baseURL
        )
    }

    public func htmlDocument(
        markdown: String,
        appTheme: AppTheme,
        zoomScale: Double,
        baseFontSize: Double,
        contentWidthPercent: Double = 88,
        usePointerCursors: Bool = false,
        fontSmoothing: Bool = true,
        editable: Bool = false,
        legacyScrollbars: Bool = false,
        baseURL: URL?
    ) throws -> String {
        let includesEditor = editable && supportsVisualEditing
        // "Show scroll bars: Always" draws Monknot's thumb from the first paint (preview.css).
        let rootClass = legacyScrollbars ? #" class="mk-legacy-scrollbars""# : ""
        let editorStyle = includesEditor ? (editorStylesheet ?? "") : ""
        let editorScript = includesEditor
            ? "<script>\n\(editorJavaScript ?? "")\n  </script>"
            : ""
        let markdownLiteral = try javaScriptLiteral(markdown)
        let themeLiteral = try javaScriptLiteral(appTheme.isDark ? "dark" : "light")
        let baseTag = baseURL.map { #"<base href="\#(htmlAttributeEscaped(directoryURLString(for: $0)))">"# } ?? ""
        let cssVariables = themeVariables(
            for: appTheme,
            zoomScale: zoomScale,
            baseFontSize: baseFontSize,
            contentWidthPercent: contentWidthPercent,
            usePointerCursors: usePointerCursors,
            fontSmoothing: fontSmoothing
        )

        return """
        <!doctype html>
        <html lang="en" data-theme="\(appTheme.isDark ? "dark" : "light")"\(rootClass)>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'self' \(Self.workspaceResourceScheme): file: data: blob:; img-src 'self' \(Self.workspaceResourceScheme): file: data: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
          \(baseTag)
          <style>
        \(stylesheet)
        \(editorStyle)
        \(cssVariables)
          </style>
        </head>
        <body>
          <main id="content" class="markdown-body"></main>
          <script>
            window.monknot = {
              markdown: \(markdownLiteral),
              theme: \(themeLiteral)
            };
          </script>
          <script>
        \(rendererJavaScript)
          </script>
          \(editorScript)
        </body>
        </html>
        """
    }

    private func themeVariables(
        for theme: AppTheme,
        zoomScale: Double,
        baseFontSize: Double,
        contentWidthPercent: Double,
        usePointerCursors: Bool,
        fontSmoothing: Bool
    ) -> String {
        let declarations = themeVariableValues(
            for: theme,
            zoomScale: zoomScale,
            baseFontSize: baseFontSize,
            contentWidthPercent: contentWidthPercent,
            usePointerCursors: usePointerCursors,
            fontSmoothing: fontSmoothing
        )

        let variableCSS = declarations
            .map { key, value in "  \(key): \(value);" }
            .joined(separator: "\n")

        return """
        :root,
        :root[data-theme="light"],
        :root[data-theme="dark"] {
          color-scheme: \(theme.isDark ? "dark" : "light");
        \(variableCSS)
        }
        """
    }

    public func themeVariableValues(
        for theme: AppTheme,
        zoomScale: Double,
        baseFontSize: Double,
        contentWidthPercent: Double,
        usePointerCursors: Bool = false,
        fontSmoothing: Bool = true
    ) -> [(String, String)] {
        let baseFont = max(8, min(120, baseFontSize * zoomScale))
        let baseFontSize = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), baseFont)
        let contentWidth = String(
            format: "%.0f",
            locale: Locale(identifier: "en_US_POSIX"),
            max(55, min(100, contentWidthPercent))
        )
        let contrast = max(0, min(100, theme.contrast))
        let borderMix = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), 8 + contrast * 0.16)
        let softMix = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), 3 + contrast * 0.06)
        let softStrongMix = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), 6 + contrast * 0.10)
        let quoteMix = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), 8 + contrast * 0.08)
        let border = "color-mix(in srgb, \(theme.foreground) \(borderMix)%, transparent)"
        let soft = "color-mix(in srgb, \(theme.foreground) \(softMix)%, transparent)"
        let softStrong = "color-mix(in srgb, \(theme.foreground) \(softStrongMix)%, transparent)"
        let blockquoteBackground = "color-mix(in srgb, \(theme.accent) \(quoteMix)%, transparent)"
        let uiFontStack = fontStack(
            preferred: theme.uiFontName,
            fallback: "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Segoe UI\", sans-serif"
        )
        let codeFontStack = fontStack(
            preferred: theme.codeFontName,
            fallback: "ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, monospace"
        )

        return [
            ("--accent", theme.accent),
            ("--link", theme.accent),
            ("--bg", theme.background),
            ("--fg", theme.foreground),
            ("--muted", theme.palette[safe: 8] ?? theme.foreground),
            ("--border", border),
            ("--soft", soft),
            ("--soft-strong", softStrong),
            ("--code-bg", "color-mix(in srgb, \(theme.background) \(theme.isDark ? "93" : "95.5")%, \(theme.foreground))"),
            ("--code-fg", theme.foreground),
            ("--blockquote-bg", blockquoteBackground),
            ("--blockquote-border", theme.accent),
            ("--quote-bg", "var(--blockquote-bg)"),
            ("--quote-border", "var(--blockquote-border)"),
            ("--table-border", border),
            // A light page needs only a wash to set the header row apart; a dark one needs more.
            ("--table-header-bg", theme.isDark ? softStrong : soft),
            ("--table-row-alt-bg", soft),
            ("--shadow", "rgba(0, 0, 0, \(theme.isDark ? "0.36" : "0.08"))"),
            ("--selection-bg", theme.selectionBackground),
            ("--selection-fg", theme.selectionForeground),
            ("--tok-keyword", theme.codeKeyword),
            ("--tok-string", theme.codeString),
            ("--tok-number", theme.codeNumber),
            ("--tok-comment", theme.codeComment),
            ("--tok-builtin", theme.codeBuiltin),
            ("--base-font-size", "\(baseFontSize)px"),
            ("--content-max-width", "\(contentWidth)%"),
            ("--content-measure", DocumentMeasure.previewCSSLength(contentWidthPercent: max(55, min(100, contentWidthPercent)))),
            ("--font-smoothing", fontSmoothing ? "antialiased" : "auto"),
            ("--interactive-cursor", usePointerCursors ? "pointer" : "default"),
            ("--ui-font", uiFontStack),
            ("--code-font", codeFontStack),
            ("--caret", theme.cursor),
            ("--danger", theme.semanticColors.diffRemoved),
            ("--ok", theme.semanticColors.diffAdded),
            ("--skill", theme.semanticColors.skill),
            ("--onaccent", theme.onAccentForegroundHex),
            ("--task-check", taskCheckImage(color: theme.onAccentForegroundHex)),
            // The neutral fill under a highlighted menu row or a hovered control: the ink, faintly.
            ("--highlight", "color-mix(in srgb, \(theme.foreground) \(theme.isDark ? "9" : "6.5")%, transparent)"),
            // The editor's menus and toolbars scale with workspace zoom; text also with the
            // theme's interface font size, as the native chrome does.
            ("--mk-z", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0.5, min(3, zoomScale)))),
            ("--mk-tz", String(
                format: "%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                max(0.5, min(3, zoomScale)) * min(1.25, max(0.875, theme.uiFontSize / 16))
            ))
        ]
    }

    /// The tick drawn inside a checked task box, in the colour that reads on the accent. The SVG
    /// namespace is a name, not an address; its colon is percent-encoded so the page holds no
    /// `http:` at all (the preview loads nothing from the network).
    private func taskCheckImage(color: String) -> String {
        let stroke = color.replacingOccurrences(of: "#", with: "%23")
        let svg = "<svg xmlns='http%3A//www.w3.org/2000/svg' viewBox='0 0 12 12'>"
            + "<path d='M2.6 6.3l2.3 2.3 4.6-5' fill='none' stroke='\(stroke)' stroke-width='1.8' "
            + "stroke-linecap='round' stroke-linejoin='round'/></svg>"
        return "url(\"data:image/svg+xml;charset=utf-8,\(svg)\")"
    }

    private func fontStack(preferred: String?, fallback: String) -> String {
        guard let preferred, !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }

        return "\"\(preferred.replacingOccurrences(of: "\"", with: ""))\", \(fallback)"
    }

    private static func loadResource(_ name: String, extension resourceExtension: String, bundle: Bundle) throws -> String {
        let resourceName = "\(name).\(resourceExtension)"
        let fileManager = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let candidates = [
            bundle.url(forResource: name, withExtension: resourceExtension),
            currentDirectory.appendingPathComponent("Sources/MonknotCore/Resources/\(resourceName)"),
            currentDirectory.deletingLastPathComponent().appendingPathComponent("Sources/MonknotCore/Resources/\(resourceName)")
        ].compactMap { $0 }

        guard let url = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw MarkdownRenderError.missingResource(resourceName)
        }

        return try String(contentsOf: url, encoding: .utf8)
    }

    private func javaScriptLiteral(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard var literal = String(data: data, encoding: .utf8) else {
            throw MarkdownRenderError.invalidJavaScriptLiteral
        }

        literal = literal.replacingOccurrences(of: "</", with: "<\\/")
        return literal
    }

    private func directoryURLString(for url: URL) -> String {
        guard url.isFileURL else {
            // A `workspaceResourceScheme` base from an in-app web view; already a directory URL.
            return url.absoluteString
        }
        return URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true).absoluteString
    }

    private func htmlAttributeEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

public enum MarkdownRenderError: Error, LocalizedError {
    case missingResource(String)
    case invalidJavaScriptLiteral

    public var errorDescription: String? {
        switch self {
        case .missingResource(let resourceName):
            return "Missing bundled preview resource: \(resourceName)"
        case .invalidJavaScriptLiteral:
            return "Could not encode Markdown content for the preview renderer."
        }
    }
}
