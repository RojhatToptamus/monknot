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
    static let sidebarIconPointSizeBase: CGFloat = 15
    static let sidebarIconWeight: Font.Weight = .regular
    static let iconCornerRadiusBase: CGFloat = 8
    static let trafficLightReserveBase: CGFloat = 72
    static let windowNavigationLeadingGapBase: CGFloat = 8
    // File tabs follow their measured title width. The bounds only protect the
    // icon/close affordances and prevent one unusually long path from owning
    // the entire titlebar.
    static let tabMinWidthBase: CGFloat = 0
    static let tabMaxWidthBase: CGFloat = 220
    /// Below this width, the editor can no longer keep useful content beside
    /// the trailing terminal panel, so the terminal takes over the detail area.
    static let editorMinimumReadableWidth: CGFloat = 360
    static let terminalDrawerMinWidth: CGFloat = 320
    static let terminalDrawerMaxWidth: CGFloat = 640
    static let terminalResizeHitWidth: CGFloat = 32
    static let settingsMaxContentWidth: CGFloat = 720
    /// Native settings content is 532 points tall so the standard 28-point
    /// macOS title bar produces the specification's 600 × 560 window.
    static let settingsWindowWidth: CGFloat = 600
    static let settingsWindowContentHeight: CGFloat = 532

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
        static let windowMargin: CGFloat = 24
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

    /// Primary chrome symbols use the same workspace zoom as their control box.
    static func chromeGlyphSize(theme: AppTheme, zoomScale: Double) -> CGFloat {
        interfaceGlyph(iconPointSizeBase, theme: theme, zoomScale: zoomScale)
    }

    static func windowNavigationButtonDimension(theme: AppTheme, zoomScale: Double) -> CGFloat {
        chromeButtonDimension(theme: theme, zoomScale: zoomScale)
    }

    static func windowNavigationLeadingGap(theme: AppTheme, zoomScale: Double) -> CGFloat {
        interfaceDensity(windowNavigationLeadingGapBase, theme: theme, zoomScale: zoomScale)
    }

    static func windowChromeLeadingReservedWidth(theme: AppTheme, zoomScale: Double) -> CGFloat {
        trafficLightReserveBase
            + windowNavigationLeadingGap(theme: theme, zoomScale: zoomScale)
            + windowNavigationButtonDimension(theme: theme, zoomScale: zoomScale) * 2
            + interfaceDensity(10, theme: theme, zoomScale: zoomScale)
    }

}

enum WorkspaceZoomPolicy {
    static let minimum = 0.8
    static let maximum = 2.0
    static let step = 0.1
    static let defaultValue = 1.0
    static let minimumDocumentScale = 0.8
    static let maximumDocumentScale = 2.0
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
