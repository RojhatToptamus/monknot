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
    /// Secondary marks (design.md §6): disclosure, pop-up and submenu chevrons and a menu row's
    /// check, everywhere, Preview's menus included. Semibold, so at 10 their stroke is a row glyph's.
    static let chevronPointSizeBase: CGFloat = 10
    static let secondaryGlyphWeight: Font.Weight = .semibold
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

/// Every SF Symbol's point size (design.md §8.2). An SF Symbol's stroke is a fixed share of its point
/// size, so glyphs set at different sizes draw different line weights, and symbols differ widely in
/// how much of their box they fill — at one point size `pencil` draws an 11 pt sliver and
/// `folder.badge.plus` a 20 pt mark. Each place a glyph sits (a bar button, a segment, a row, a small
/// button) therefore has one target, and every glyph in it is drawn within 8 % of that target in
/// points, so its stroke is its neighbours'. Within that band a picture is sized by what it draws: its
/// ink is measured once, and its optical size is set to the target. A mark — an open sign read by its
/// extent — is drawn at the target; lettering (B I U S) at the nominal, like type.
enum MonknotSymbolOptics {
    enum Role: Equatable {
        /// An object with area, sized by its measured optical size.
        case picture
        /// An open sign read by its extent (chevrons, single arrows, + − ×, ✓, …, Aa): at the target.
        case mark
        /// The letters a format command applies (B I U S): at the nominal, like type.
        case lettering
    }

    static func role(for systemImage: String) -> Role {
        switch systemImage {
        case "chevron.left", "chevron.right", "chevron.up", "chevron.down",
             "arrow.left", "arrow.right", "arrow.up", "arrow.down",
             "plus", "minus", "xmark", "checkmark", "ellipsis", "textformat", "textformat.size":
            return .mark
        case "bold", "italic", "underline", "strikethrough":
            return .lettering
        default:
            return .picture
        }
    }

    /// The optical size every glyph in a place is drawn to: 0.9 of the nominal, at most 14.5 (14.5 in
    /// a bar button, 14.4 in a segment, 13.5 beside a label, 11.7 in a small button).
    static func targetOpticalSize(nominal: CGFloat) -> CGFloat {
        min(nominal * 0.9, 14.5)
    }

    /// How far from the target a glyph may be drawn, in points: within it, strokes differ by at most
    /// 8 % either way, which reads as one weight.
    static let strokeBand: ClosedRange<CGFloat> = 0.92...1.08

    /// The longest side any glyph may draw: 1.3 × the target, about 2/3 of a button and inside the
    /// 18 glyph column.
    static func longestSide(nominal: CGFloat) -> CGFloat {
        targetOpticalSize(nominal: nominal) * 1.3
    }

    static func pointSizeBase(for systemImage: String, nominal: CGFloat) -> CGFloat {
        let target = targetOpticalSize(nominal: nominal)
        guard let metrics = SymbolInkMetrics.metrics(for: systemImage) else {
            return role(for: systemImage) == .lettering ? nominal : target
        }
        let size: CGFloat
        switch role(for: systemImage) {
        case .mark:
            size = target
        case .lettering:
            size = nominal
        case .picture:
            let optical = target / metrics.opticalSizePerPoint
            size = min(max(optical, target * strokeBand.lowerBound), target * strokeBand.upperBound)
        }
        // The longest side is a hard edge: a very wide glyph shrinks to fit.
        return min(size, longestSide(nominal: nominal) / metrics.longestSidePerPoint)
    }
}

/// What a symbol draws, measured once from its rendered image at a 100 pt reference: its ink box,
/// its base's box, and how much of the ink box its ink fills, all per point of point size.
struct SymbolInkMetrics: Equatable {
    let widthPerPoint: CGFloat
    let heightPerPoint: CGFloat
    /// The box of the layer the others are drawn on (a pencil's square, a badge's folder, Save's tray),
    /// when the symbol is drawn in layers, that layer covers most of the whole box and the others lie
    /// mostly inside it; otherwise the whole box. Layers side by side (a list's bullets and lines, a
    /// stack of pages) are one shape.
    let baseWidthPerPoint: CGFloat
    let baseHeightPerPoint: CGFloat
    /// The share of the ink box the ink covers.
    let inkCoverage: CGFloat

    var longestSidePerPoint: CGFloat {
        max(widthPerPoint, heightPerPoint)
    }

    /// How big the symbol reads: the geometric mean of its box and its base's box — the eye sizes a
    /// pencil on a square mostly by the square, so a mark poking out of the base counts half — weighted
    /// a little by density, so a dense glyph (a filled photo) is set a little smaller than a light one.
    var opticalSizePerPoint: CGFloat {
        let whole = sqrt(widthPerPoint * heightPerPoint)
        let base = sqrt(baseWidthPerPoint * baseHeightPerPoint)
        return sqrt(whole * base) * pow(max(inkCoverage, 0.05) / 0.33, 0.06)
    }

    /// A layer counts as the base when its box covers at least this share of the whole box, and at
    /// least `overlayInside` of the other layers' ink lies inside it.
    static let baseCoverage: CGFloat = 0.7
    static let overlayInside: CGFloat = 0.5

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

    /// Draws the symbol with a palette of pure red, green and blue, one per layer, so one pass gives
    /// both the ink and each layer's box.
    private static func measure(_ systemImage: String) -> SymbolInkMetrics? {
        let layerColors = [
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
            NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
        ]
        let configuration = NSImage.SymbolConfiguration(pointSize: referencePointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: layerColors))
        guard let symbol = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
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

        var whole = CGRect.null
        var layers = [CGRect](repeating: .null, count: layerColors.count)
        var layerOfPixel = [Int8](repeating: -1, count: canvas * canvas)
        var ink: CGFloat = 0
        let bytesPerRow = bitmap.bytesPerRow
        for y in 0..<canvas {
            for x in 0..<canvas {
                let offset = y * bytesPerRow + x * 4
                let alpha = CGFloat(pixels[offset + 3]) / 255
                guard alpha > 0 else { continue }
                ink += alpha
                guard alpha > 0.08 else { continue }
                let red = pixels[offset], green = pixels[offset + 1], blue = pixels[offset + 2]
                let layer = red >= green && red >= blue ? 0 : (green >= blue ? 1 : 2)
                layerOfPixel[y * canvas + x] = Int8(layer)
                let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                layers[layer] = layers[layer].union(pixel)
                whole = whole.union(pixel)
            }
        }
        guard !whole.isNull else { return nil }
        let drawn = layers.indices.filter { !layers[$0].isNull }
        var base = whole
        if drawn.count > 1,
           let largest = drawn.max(by: { layers[$0].width * layers[$0].height < layers[$1].width * layers[$1].height }),
           layers[largest].width * layers[largest].height >= baseCoverage * whole.width * whole.height {
            var others = 0, inside = 0
            for index in layerOfPixel.indices where layerOfPixel[index] >= 0 && Int(layerOfPixel[index]) != largest {
                others += 1
                let point = CGPoint(x: CGFloat(index % canvas) + 0.5, y: CGFloat(index / canvas) + 0.5)
                if layers[largest].contains(point) { inside += 1 }
            }
            if others > 0, CGFloat(inside) >= overlayInside * CGFloat(others) {
                base = layers[largest]
            }
        }
        return SymbolInkMetrics(
            widthPerPoint: whole.width / referencePointSize,
            heightPerPoint: whole.height / referencePointSize,
            baseWidthPerPoint: base.width / referencePointSize,
            baseHeightPerPoint: base.height / referencePointSize,
            inkCoverage: ink / (whole.width * whole.height)
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

/// Shared SF Symbol renderer for chrome. Point size, weight and rendering mode have one owner. No glyph
/// is nudged: SF Symbols centres each one's ink in its box (design.md §8.6).
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
    }
}

/// A secondary mark (design.md §6): a disclosure or pop-up chevron, a menu row's check, the close and
/// clear `xmark`. Smaller than the glyph beside it and semibold, so its stroke — 1.21 at 10 pt, 1.09
/// at 9 — matches a row glyph's (1.17) instead of reading thinner.
struct MonknotSecondaryGlyph: View {
    let systemImage: String
    var pointSizeBase: CGFloat = MonknotMetrics.chevronPointSizeBase
    let theme: AppTheme
    let zoomScale: Double

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(
                size: MonknotMetrics.interfaceGlyph(pointSizeBase, theme: theme, zoomScale: zoomScale),
                weight: MonknotMetrics.secondaryGlyphWeight
            ))
            .symbolRenderingMode(.monochrome)
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
