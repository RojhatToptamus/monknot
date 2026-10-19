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
            contentWidthPercent: DocumentMeasure.defaultContentWidthPercent,
            baseURL: baseURL
        )
    }

    public func htmlDocument(
        markdown: String,
        appTheme: AppTheme,
        zoomScale: Double,
        baseFontSize: Double,
        contentWidthPercent: Double = DocumentMeasure.defaultContentWidthPercent,
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
        \(Self.legacyScrollbarCSS)
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
        let zoom = max(0.5, min(3, zoomScale))
        // The margins follow the code size, as Source's do: Preview's prose is set a step above it.
        let marginTop = Int(DocumentMeasure.verticalMargin(fontSize: baseFontSize * zoomScale / DocumentMeasure.previewProseScale))
        let baseFont = max(8, min(120, baseFontSize * zoomScale))
        let baseFontSize = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), baseFont)
        let contentWidthPercent = DocumentMeasure.clampedContentWidthPercent(contentWidthPercent)
        let contentWidth = String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), contentWidthPercent)
        let contrast = max(0, min(100, theme.contrast))
        let borderMix = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), 8 + contrast * 0.16)
        let softMix = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), 3 + contrast * 0.06)
        let softStrongMix = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), 6 + contrast * 0.10)
        let border = "color-mix(in srgb, \(theme.foreground) \(borderMix)%, transparent)"
        let soft = "color-mix(in srgb, \(theme.foreground) \(softMix)%, transparent)"
        let softStrong = "color-mix(in srgb, \(theme.foreground) \(softStrongMix)%, transparent)"
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
            ("--table-border", border),
            // A light page needs only a wash to set the header row apart; a dark one needs more.
            ("--table-header-bg", theme.isDark ? softStrong : soft),
            ("--selection-bg", theme.selectionBackground),
            ("--selection-fg", theme.selectionForeground),
            ("--tok-keyword", theme.codeKeyword),
            ("--tok-string", theme.codeString),
            ("--tok-number", theme.codeNumber),
            ("--tok-comment", theme.codeComment),
            ("--tok-builtin", theme.codeBuiltin),
            ("--base-font-size", "\(baseFontSize)px"),
            // The page's margins (design.md §10.11). Above the first line, the same as Source's; below
            // the last, twice that or a quarter of the window, so the last block can be read and
            // written above the window's edge; beside the text, at least Source's least inset, which
            // holds the block handles. Text starts at the same x in both modes at every width.
            ("--document-margin-top", "\(marginTop)px"),
            ("--document-margin-bottom", "max(\(2 * marginTop)px, 25vh)"),
            ("--column-gutter", "\(Int(DocumentMeasure.minimumTextEdge(zoomScale: zoom)))px"),
            ("--content-max-width", "\(contentWidth)%"),
            ("--content-measure", DocumentMeasure.previewCSSLength(contentWidthPercent: contentWidthPercent)),
            ("--font-smoothing", fontSmoothing ? "antialiased" : "auto"),
            ("--interactive-cursor", usePointerCursors ? "pointer" : "default"),
            ("--ui-font", uiFontStack),
            ("--code-font", codeFontStack),
            ("--caret", theme.cursor),
            ("--danger", theme.semanticColors.diffRemoved),
            ("--ok", theme.semanticColors.diffAdded),
            ("--skill", theme.semanticColors.skill),
            ("--task-check", taskCheckImage(color: theme.onAccentForegroundHex)),
            // The editor's fills and floating surfaces, from the values the native chrome uses
            // (design.md §1.2, §2.1): a highlighted menu row takes a native menu row's `selected` fill.
            ("--mk-hover", inkMix(theme.foreground, theme.hoverInkOpacity)),
            ("--mk-press", inkMix(theme.foreground, theme.pressInkOpacity)),
            ("--mk-highlight", inkMix(theme.foreground, theme.selectedInkOpacity)),
            ("--mk-accsoft", inkMix(theme.accent, theme.accentSoftOpacity)),
            ("--mk-floating", theme.floatingSurfaceHex),
            ("--mk-shadow-hue", theme.floatingShadowHex),
            ("--mk-ring", inkMix(theme.floatingRingHex, theme.floatingRingOpacity)),
            // The chrome's ink ladder, derived per theme (design.md §1.2), so the page's menus, format
            // bar and hints read exactly like the native sidebar, tabs and Settings.
            ("--mk-ink2", inkMix(theme.foreground, theme.labelInkOpacity)),
            ("--mk-ink3", inkMix(theme.foreground, theme.glyphInkOpacity)),
            ("--mk-ink4", inkMix(theme.foreground, AppTheme.disabledInkOpacity)),
            // The editor's menus and toolbars scale with workspace zoom; text also with the
            // theme's interface font size, as the native chrome does.
            ("--mk-z", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), zoom)),
            ("--mk-tz", String(
                format: "%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                zoom * min(1.25, max(0.875, theme.uiFontSize / 16))
            ))
        ]
    }

    private func inkMix(_ ink: String, _ opacity: Double) -> String {
        "color-mix(in srgb, \(ink) \(Self.cssPercent(opacity)), transparent)"
    }

    private static func cssPercent(_ fraction: Double) -> String {
        var percent = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), fraction * 100)
        if percent.hasSuffix(".0") { percent.removeLast(2) }
        return percent + "%"
    }

    /// With "Show scroll bars: Always" (`legacyScrollbars`) the page draws Monknot's thumb instead of
    /// WebKit's legacy bar (design.md §5.7), and renderer.js draws its stand-in from the same numbers
    /// while a side pane moves the card's edge.
    static let legacyScrollbarCSS: String = {
        let thumb = ScrollThumbGeometry.self
        let resting = "color-mix(in srgb, var(--fg) \(cssPercent(thumb.restingOpacity)), transparent)"
        return thumb.webCSS(
            selector: "html.mk-legacy-scrollbars ",
            restingColor: resting,
            hoveredColor: "color-mix(in srgb, var(--fg) \(cssPercent(thumb.hoveredOpacity)), transparent)"
        ) + """

        :root {
          --mk-scroll-lane: \(ScrollThumbGeometry.cssPixels(thumb.trackWidth));
          --mk-scroll-end: \(ScrollThumbGeometry.cssPixels(thumb.endInset));
          --mk-scroll-thumb: \(ScrollThumbGeometry.cssPixels(thumb.restingThumbWidth));
          --mk-scroll-thumb-color: \(resting);
        }
        """
    }()

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

/// Monknot's scroll thumb (design.md §5.7): a slim capsule with no track, centred in a lane flush with
/// the edge, its ends clear of a card's rounded corners. It rests quiet and widens and darkens under
/// the pointer. The native scroller (`MonknotScrollbarStyle`) and every page that styles a scroll bar
/// (Preview, the terminal) take these numbers.
public enum ScrollThumbGeometry {
    /// The lane, flush with the trailing or bottom edge.
    public static let trackWidth: Double = 9
    public static let restingThumbWidth: Double = 4
    public static let hoveredThumbWidth: Double = 6
    /// The thumb's ends stay this far from the ends of a list or card.
    public static let endInset: Double = 6
    public static let restingOpacity: Double = 0.25
    public static let hoveredOpacity: Double = 0.45

    /// The thumb for a web view's scroll bar. WebKit draws a styled scroll bar as a fixed bar and does
    /// not repaint it when a class changes, so it cannot fade like an overlay scroller: it rests at the
    /// resting strength and brightens only under the pointer.
    public static func webCSS(
        selector: String = "*",
        restingColor: String = "color-mix(in srgb, CanvasText 25%, transparent)",
        hoveredColor: String = "color-mix(in srgb, CanvasText 45%, transparent)"
    ) -> String {
        let restingInset = (trackWidth - restingThumbWidth) / 2
        let hoveredInset = (trackWidth - hoveredThumbWidth) / 2

        // The border is the inset; the radius includes it so the visible thumb is a capsule.
        return """
        \(selector)::-webkit-scrollbar {
          width: \(cssPixels(trackWidth));
          height: \(cssPixels(trackWidth));
          background: transparent;
        }
        \(selector)::-webkit-scrollbar-track {
          background: transparent;
          margin: \(cssPixels(endInset));
        }
        \(selector)::-webkit-scrollbar-thumb {
          background: \(restingColor);
          background-clip: content-box;
          border: \(cssPixels(restingInset)) solid transparent;
          border-radius: \(cssPixels(trackWidth / 2));
        }
        \(selector)::-webkit-scrollbar-thumb:hover {
          background: \(hoveredColor);
          background-clip: content-box;
          border: \(cssPixels(hoveredInset)) solid transparent;
          border-radius: \(cssPixels(trackWidth / 2));
        }
        \(selector)::-webkit-scrollbar-corner {
          background: transparent;
        }
        """
    }

    static func cssPixels(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))px" : "\(value)px"
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
