import Foundation

public struct MarkdownRenderService: Sendable {
    private let stylesheet: String
    private let rendererJavaScript: String

    public init(bundle: Bundle = .main) throws {
        self.stylesheet = try Self.loadResource("preview", extension: "css", bundle: bundle)
        self.rendererJavaScript = try Self.loadResource("renderer", extension: "js", bundle: bundle)
    }

    public init(stylesheet: String, rendererJavaScript: String) {
        self.stylesheet = stylesheet
        self.rendererJavaScript = rendererJavaScript
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
        baseURL: URL?
    ) throws -> String {
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
        <html lang="en" data-theme="\(appTheme.isDark ? "dark" : "light")">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'self' file: data: blob:; img-src 'self' file: data: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
          \(baseTag)
          <style>
        \(stylesheet)
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
            ("--code-bg", "color-mix(in srgb, \(theme.background) 88%, \(theme.foreground) 12%)"),
            ("--code-fg", theme.foreground),
            ("--blockquote-bg", blockquoteBackground),
            ("--blockquote-border", theme.accent),
            ("--quote-bg", "var(--blockquote-bg)"),
            ("--quote-border", "var(--blockquote-border)"),
            ("--table-border", border),
            ("--table-header-bg", softStrong),
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
            ("--font-smoothing", fontSmoothing ? "antialiased" : "auto"),
            ("--interactive-cursor", usePointerCursors ? "pointer" : "default"),
            ("--ui-font", uiFontStack),
            ("--code-font", codeFontStack)
        ]
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
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true).absoluteString
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
