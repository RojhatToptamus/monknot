import MonknotCore
import SwiftUI

/// Shared workspace geometry. Interface Zoom applies one bounded factor to
/// layout, controls, rows, text, and symbols; text and symbols snap to half
/// points while box metrics snap to whole points.
enum MonknotMetrics {
    static let chromeHeightBase: CGFloat = 44
    static let iconButtonSizeBase: CGFloat = 28
    static let iconPointSizeBase: CGFloat = 17
    /// The small icon button, inside a row or a field (design.md §5.1).
    static let smallIconButtonSizeBase: CGFloat = 22
    static let smallIconPointSizeBase: CGFloat = 13
    /// The close and clear target of a tab or a field, and its xmark.
    static let closeTargetSizeBase: CGFloat = 16
    static let closeGlyphPointSizeBase: CGFloat = 9
    /// Disclosure, pop-up and submenu chevrons, everywhere (design.md §8.2).
    static let chevronPointSizeBase: CGFloat = 10
    /// A bar inside a card or a panel (the terminal header, the PDF toolbar, panel headers): 40 tall,
    /// 6 padding, items 2 apart, groups 8 apart, never a rule (design.md §10.6).
    static let barHeightBase: CGFloat = 40
    static let barPaddingBase: CGFloat = 6
    static let barItemGapBase: CGFloat = 2
    static let barGroupGapBase: CGFloat = 8
    /// Activity indicators: inline beside a status line, and alone in a loading state.
    static let inlineSpinnerSizeBase: CGFloat = 12
    static let loadingSpinnerSizeBase: CGFloat = 16
    static let sidebarIconPointSizeBase: CGFloat = 15
    static let rowIconColumnWidthBase: CGFloat = 18
    /// The chrome row primitive (design.md §0): 28 tall, 8 padding, a 15 glyph in the 18 column, 8 gap,
    /// a 13 / 400 label, no gap between rows and 14 per depth, inside a 10 list inset. A tab is this row
    /// with 10 padding (`MonknotTab`).
    static let rowHeightBase: CGFloat = 28
    static let rowGapBase: CGFloat = 0
    static let rowPaddingBase: CGFloat = 8
    static let rowGlyphGapBase: CGFloat = 8
    static let rowIndentBase: CGFloat = 14
    static let listGutterBase: CGFloat = 10
    static let listTopInsetBase: CGFloat = 4
    /// A menu row, as in the editor's menus (editor.css `.mk-menu-row`): 30 tall, 8 padding, the glyph
    /// in an 18 column, 10 gap, a 13 / 400 label, inside a 6 list inset (design.md §10.10).
    static let menuRowHeightBase: CGFloat = 30
    static let menuRowPaddingBase: CGFloat = 8
    static let menuRowGlyphGapBase: CGFloat = 10
    static let menuListInsetBase: CGFloat = 6
    /// An overlay's result row (Quick Open, Go to Symbol): the menu row at 34.
    static let overlayRowHeightBase: CGFloat = 34
    static let iconCornerRadiusBase: CGFloat = 8
    /// The document and terminal cards (design.md §7, §10.0).
    static let cardCornerRadius: CGFloat = 12
    /// The titlebar's room for the fixed-size native traffic lights, from the close light's edge:
    /// the trio is 52 wide, and 12 more keep it clear of the first control.
    static let trafficLightReserveBase: CGFloat = 64
    /// File tabs hug their label up to this width and have no minimum (design.md §10.3).
    static let tabMaxWidthBase: CGFloat = 220
    /// Native settings content is 532 points tall so the standard 28-point
    /// macOS title bar produces the specification's 600 × 560 window.
    /// The window scales with workspace zoom, up to the screen's visible area.
    static let settingsWindowWidth: CGFloat = 600
    static let settingsWindowContentHeight: CGFloat = 532
    static let settingsSidebarWidth: CGFloat = 168

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let l: CGFloat = 12
    }

    static func scale(
        _ base: CGFloat,
        theme: AppTheme,
        zoomScale: Double
    ) -> CGFloat {
        (base * theme.layoutScale(zoomScale: zoomScale)).rounded()
    }

    static func interfaceText(_ base: CGFloat, theme: AppTheme, zoomScale: Double) -> CGFloat {
        (base * theme.interfaceTextScale(zoomScale: zoomScale) * 2).rounded() / 2
    }

    static func interfaceGlyph(_ base: CGFloat, theme: AppTheme, zoomScale: Double) -> CGFloat {
        (base * theme.interfaceGlyphScale(zoomScale: zoomScale) * 2).rounded() / 2
    }

    static func interfaceControl(_ base: CGFloat, theme: AppTheme, zoomScale: Double) -> CGFloat {
        (base * theme.interfaceControlScale(zoomScale: zoomScale)).rounded()
    }

    static func interfaceDensity(_ base: CGFloat, theme: AppTheme, zoomScale: Double) -> CGFloat {
        (base * theme.interfaceDensityScale(zoomScale: zoomScale)).rounded()
    }

    static func chromeHeight(theme: AppTheme, zoomScale: Double) -> CGFloat {
        (chromeHeightBase * theme.interfaceRowScale(zoomScale: zoomScale)).rounded()
    }

    /// The titlebar's leading edge (design.md §10.1): the close light starts on the sidebar's glyph
    /// column, the list gutter plus a row's padding, level with the rows and the workspace badge.
    static func titlebarLeadingInset(theme: AppTheme, zoomScale: Double) -> CGFloat {
        interfaceDensity(listGutterBase, theme: theme, zoomScale: zoomScale)
            + interfaceDensity(rowPaddingBase, theme: theme, zoomScale: zoomScale)
    }

    /// The titlebar's trailing edge (design.md §10.1): its last control ends over the terminal bar's
    /// buttons, the card's margin plus a bar's padding.
    static func titlebarTrailingInset(theme: AppTheme, zoomScale: Double) -> CGFloat {
        WorkspaceSplitMetrics.dividerThickness
            + interfaceDensity(barPaddingBase, theme: theme, zoomScale: zoomScale)
    }

    static func barHeight(theme: AppTheme, zoomScale: Double) -> CGFloat {
        interfaceControl(barHeightBase, theme: theme, zoomScale: zoomScale)
    }
}

/// Every SF Symbol's point size (design.md §8.2). Symbols differ widely in how much of their box
/// they fill — at one point size `pencil` draws an 11 pt mark and `folder.badge.plus` a 20 pt one —
/// so a list of glyphs at one size reads ragged. Pictures are therefore sized by what they draw:
/// each symbol's ink box and density are measured once, and its point size is chosen so its optical
/// size (the box's geometric mean, lightly weighted by ink) is the same as its neighbours'. Marks —
/// open strokes and lettering (chevrons, plus, xmark, ellipsis, arrows, B I S, "Aa") — are not
/// pictures and keep their nominal size, or the ceiling listed for them.
enum MonknotSymbolOptics {
    /// The optical size a picture is sized to: 0.9 of the nominal, at most 14.5 (13.5 beside a
    /// label, 14.5 alone in a bar button, 11.7 in a small button).
    static func targetOpticalSize(nominal: CGFloat) -> CGFloat {
        min(nominal * 0.9, 14.5)
    }

    /// The longest side a picture may draw: its column, at most 16.
    static func longestSide(nominal: CGFloat) -> CGFloat {
        min(nominal * 1.2, 16)
    }

    /// How far measuring may move a picture from its nominal size.
    static let scaleRange: ClosedRange<CGFloat> = 0.8...1.12

    static func pointSizeBase(for systemImage: String, nominal: CGFloat) -> CGFloat {
        if let ceiling = markCeiling(for: systemImage) {
            return min(nominal, ceiling)
        }
        guard let metrics = SymbolInkMetrics.metrics(for: systemImage) else {
            return nominal
        }
        let optical = targetOpticalSize(nominal: nominal) / metrics.opticalSizePerPoint
        let ranged = min(max(optical, nominal * scaleRange.lowerBound), nominal * scaleRange.upperBound)
        // The column is a hard edge: a very wide glyph (the Save badge) shrinks past the range to fit.
        return min(ranged, longestSide(nominal: nominal) / metrics.longestSidePerPoint)
    }

    /// A mark's ceiling, or nil for a picture. Open strokes span their whole box, so at the nominal
    /// size they read largest in a bar; lettering is sized as text.
    static func markCeiling(for systemImage: String) -> CGFloat? {
        switch systemImage {
        case "character.cursor.ibeam":
            return 12.5
        case "textformat":
            return 13
        case "xmark":
            return 14
        case "plus", "chevron.left", "chevron.right":
            return 15
        case "minus", "ellipsis", "checkmark", "chevron.up", "chevron.down",
             "arrow.up", "arrow.down", "arrow.left", "arrow.right",
             "bold", "italic", "underline", "strikethrough", "character.textbox", "textformat.size":
            return .infinity
        default:
            return nil
        }
    }

    static func horizontalOffsetBase(for systemImage: String) -> CGFloat {
        systemImage == "magnifyingglass" ? -0.5 : 0
    }
}

/// What a symbol draws, measured once from its rendered image at a 100 pt reference: its ink box
/// and how much of that box its ink fills, both per point of point size.
struct SymbolInkMetrics: Equatable {
    let widthPerPoint: CGFloat
    let heightPerPoint: CGFloat
    /// The share of the ink box the ink covers.
    let inkCoverage: CGFloat

    var longestSidePerPoint: CGFloat {
        max(widthPerPoint, heightPerPoint)
    }

    /// The box's geometric mean, weighted a little by density, so a dense glyph (a filled photo)
    /// is set a little smaller than a light one of the same box.
    var opticalSizePerPoint: CGFloat {
        sqrt(widthPerPoint * heightPerPoint) * pow(max(inkCoverage, 0.05) / 0.33, 0.06)
    }

    private static let referencePointSize: CGFloat = 100
    private static let cache = SymbolInkMetricsCache()

    static func metrics(for systemImage: String) -> SymbolInkMetrics? {
        if let cached = cache.value(for: systemImage) {
            return cached.metrics
        }
        let measured = measure(systemImage)
        cache.store(measured, for: systemImage)
        return measured
    }

    private static func measure(_ systemImage: String) -> SymbolInkMetrics? {
        guard let symbol = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: referencePointSize, weight: .regular))
        else { return nil }
        let size = symbol.size
        let canvas = Int(referencePointSize * 2)
        guard size.width > 0, size.height > 0, size.width < CGFloat(canvas), size.height < CGFloat(canvas),
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: canvas,
                  pixelsHigh: canvas,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap),
              let pixels = bitmap.bitmapData
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        symbol.draw(in: NSRect(
            x: (CGFloat(canvas) - size.width) / 2,
            y: (CGFloat(canvas) - size.height) / 2,
            width: size.width,
            height: size.height
        ))
        NSGraphicsContext.restoreGraphicsState()

        var minX = canvas, minY = canvas, maxX = -1, maxY = -1
        var ink: CGFloat = 0
        let bytesPerRow = bitmap.bytesPerRow
        for y in 0..<canvas {
            for x in 0..<canvas {
                let alpha = CGFloat(pixels[y * bytesPerRow + x * 4 + 3]) / 255
                guard alpha > 0 else { continue }
                ink += alpha
                if alpha > 0.08 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let width = CGFloat(maxX - minX + 1)
        let height = CGFloat(maxY - minY + 1)
        return SymbolInkMetrics(
            widthPerPoint: width / referencePointSize,
            heightPerPoint: height / referencePointSize,
            inkCoverage: ink / (width * height)
        )
    }
}

/// Measured symbols, shared across windows; a few dozen entries at most.
private final class SymbolInkMetricsCache: @unchecked Sendable {
    struct Entry {
        let metrics: SymbolInkMetrics?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func value(for name: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[name]
    }

    func store(_ metrics: SymbolInkMetrics?, for name: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[name] = Entry(metrics: metrics)
    }
}

/// Shared SF Symbol renderer for chrome. Point-size normalization, weight,
/// rendering mode, and positional correction have one owner.
struct MonknotSystemGlyph: View {
    let systemImage: String
    let nominalPointSizeBase: CGFloat
    let theme: AppTheme
    let zoomScale: Double

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(
                size: MonknotMetrics.interfaceGlyph(
                    MonknotSymbolOptics.pointSizeBase(
                        for: systemImage,
                        nominal: nominalPointSizeBase
                    ),
                    theme: theme,
                    zoomScale: zoomScale
                ),
                weight: .regular
            ))
            .symbolRenderingMode(.monochrome)
            .offset(x: MonknotMetrics.interfaceGlyph(
                MonknotSymbolOptics.horizontalOffsetBase(for: systemImage),
                theme: theme,
                zoomScale: zoomScale
            ))
    }
}

enum WorkspaceZoomPolicy {
    static let minimum = 0.8
    static let maximum = 2.0
    static let step = 0.1
    static let defaultValue = 1.0
    static let supportedLevels = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
    static let shortcutDocumentScales = supportedLevels

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else {
            if value == .infinity { return maximum }
            if value == -.infinity { return minimum }
            return defaultValue
        }
        return min(maximum, max(minimum, value))
    }

    static func stepped(_ value: Double, by delta: Double) -> Double {
        let current = clamp(value)
        guard delta.isFinite, delta != 0 else { return current }

        let epsilon = 0.000_001
        if delta > 0 {
            return supportedLevels.first(where: { $0 > current + epsilon }) ?? maximum
        }
        return supportedLevels.last(where: { $0 < current - epsilon }) ?? minimum
    }

    /// The zoom's place among the supported levels, for a stepper that counts in levels (Settings'
    /// workspace zoom); a zoom between two levels counts as the one above it.
    static func levelIndex(_ value: Double) -> Int {
        let current = clamp(value)
        return supportedLevels.firstIndex { $0 >= current - 0.000_001 } ?? supportedLevels.count - 1
    }

    /// The zoom a level stepper moves to from `value` when it asks for level `index`: the next
    /// supported level up or down, as ⌘+ and ⌘− do.
    static func zoom(steppingToLevel index: Int, from value: Double) -> Double {
        let current = levelIndex(value)
        guard index != current else { return clamp(value) }
        return stepped(value, by: index > current ? step : -step)
    }

    /// Non-PDF document content and workspace chrome share the same factor.
    /// PDFKit retains its own focused zoom behavior.
    static func documentScale(_ value: Double) -> Double {
        clamp(value)
    }

    static func rawZoom(forDocumentScale scale: Double) -> Double {
        clamp(scale)
    }
}
