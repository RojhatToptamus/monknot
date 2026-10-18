import MonknotCore
import SwiftUI

private struct MonknotSettingsZoomScaleKey: EnvironmentKey {
    static let defaultValue = WorkspaceZoomPolicy.defaultValue
}

extension EnvironmentValues {
    var monknotSettingsZoomScale: Double {
        get { self[MonknotSettingsZoomScaleKey.self] }
        set { self[MonknotSettingsZoomScaleKey.self] = WorkspaceZoomPolicy.clamp(newValue) }
    }
}

/// Shared workspace geometry. Interface Zoom applies one bounded factor to
/// layout, controls, rows, text, and symbols; text and symbols snap to half
/// points while box metrics snap to whole points.
enum MonknotMetrics {
    static let chromeHeightBase: CGFloat = 44
    static let chromeSecondaryHeightBase: CGFloat = 34
    static let chromeHorizontalPaddingBase: CGFloat = 8
    static let iconButtonSizeBase: CGFloat = 28
    static let iconPointSizeBase: CGFloat = 17
    static let sidebarIconPointSizeBase: CGFloat = 14
    static let rowIconColumnWidthBase: CGFloat = 16
    /// The chrome row primitive (design.md §0): 26 tall, 8 padding, a 14 glyph in the 16 column, 7 gap,
    /// 13 label, 1 between rows and 14 per depth, inside a 6 list gutter.
    static let rowHeightBase: CGFloat = 26
    static let rowGapBase: CGFloat = 1
    static let rowPaddingBase: CGFloat = 8
    static let rowGlyphGapBase: CGFloat = 7
    static let rowIndentBase: CGFloat = 14
    static let listGutterBase: CGFloat = 6
    static let iconCornerRadiusBase: CGFloat = 8
    /// The document and terminal cards (design.md §7, §10.0).
    static let cardCornerRadius: CGFloat = 12
    /// The fixed-size native traffic lights and their leading inset.
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
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let settingsRowHorizontal: CGFloat = 14
        static let settingsRowVertical: CGFloat = 11
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

    static func chromeSecondaryHeight(theme: AppTheme, zoomScale: Double) -> CGFloat {
        (chromeSecondaryHeightBase * theme.interfaceRowScale(zoomScale: zoomScale)).rounded()
    }

    static func chromeHorizontalPadding(theme: AppTheme, zoomScale: Double) -> CGFloat {
        interfaceDensity(chromeHorizontalPaddingBase, theme: theme, zoomScale: zoomScale)
    }

    static func chromeButtonDimension(theme: AppTheme, zoomScale: Double) -> CGFloat {
        interfaceControl(iconButtonSizeBase, theme: theme, zoomScale: zoomScale)
    }
}

/// Optical corrections for SF Symbols whose visible bounds are materially
/// larger than adjacent symbols at the same nominal point size.
enum MonknotSymbolOptics {
    static func pointSizeBase(for systemImage: String, nominal: CGFloat) -> CGFloat {
        guard let maximum = maximumPointSizeBase(for: systemImage) else {
            return nominal
        }
        return min(nominal, maximum)
    }

    static func maximumPointSizeBase(for systemImage: String) -> CGFloat? {
        switch systemImage {
        case "character.cursor.ibeam":
            return 12.5
        // Wide or dense glyphs in the Preview editor's menus, sized to their neighbours' ink.
        case "chevron.left.forwardslash.chevron.right":
            return 12
        case "textformat", "speaker.wave.2", "list.bullet.rectangle":
            return 13
        case "tablecells", "text.bubble", "face.smiling", "calendar", "arrow.triangle.2.circlepath",
             "arrow.up.right.square", "exclamationmark.bubble", "exclamationmark.triangle",
             "exclamationmark.octagon", "plus.square.on.square", "doc.on.doc",
             "trash", "pencil", "link.badge.minus":
            return 14
        case "curlybraces", "link", "play.rectangle":
            return 13
        case "magnifyingglass",
             "doc", "doc.fill",
             "doc.text", "doc.text.fill",
             "doc.richtext", "doc.richtext.fill",
             "checklist", "text.quote",
             "arrow.up.left.and.arrow.down.right",
             "arrow.down.right.and.arrow.up.left":
            return 14
        // Filled glyphs are sized for ink weight, not bounds: at 14 pt the photo carries about 13 %
        // ink in its 30 pt box against 6-9 % for its neighbours (design.md §10.7).
        case "photo":
            return 12
        case "sidebar.left", "sidebar.right":
            return 15
        default:
            return nil
        }
    }

    static func horizontalOffsetBase(for systemImage: String) -> CGFloat {
        systemImage == "magnifyingglass" ? -0.5 : 0
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

    /// Non-PDF document content and workspace chrome share the same factor.
    /// PDFKit retains its own focused zoom behavior.
    static func documentScale(_ value: Double) -> Double {
        clamp(value)
    }

    static func rawZoom(forDocumentScale scale: Double) -> Double {
        clamp(scale)
    }
}
