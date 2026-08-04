import MonknotCore
import SwiftUI

/// Layout tokens aligned to the macOS 8pt grid, scaled with zoom and UI font size.
enum MonknotMetrics {
    static let chromeHeightBase: CGFloat = 44
    static let chromeSecondaryHeightBase: CGFloat = 34
    static let chromeHorizontalPaddingBase: CGFloat = 8
    static let iconButtonSizeBase: CGFloat = 28
    // Codex keeps titlebar symbols slightly smaller than adjacent labels. Use
    // one optical size for navigation, tabs, view modes, and drawer controls.
    static let iconPointSizeBase: CGFloat = 12
    // Header actions, folders, and documents share one optical symbol size.
    // It stays below the 13pt labels without shrinking any control or row.
    static let sidebarIconPointSizeBase: CGFloat = 12
    static let sidebarIconWeight: Font.Weight = .regular
    static let iconCornerRadiusBase: CGFloat = 7
    static let trafficLightReserveBase: CGFloat = 72
    static let windowNavigationLeadingGapBase: CGFloat = 8
    static let compactTopBarEffectiveWidth: CGFloat = 600
    static let minimalTopBarEffectiveWidth: CGFloat = 480
    // File tabs follow their measured title width. The bounds only protect the
    // icon/close affordances and prevent one unusually long path from owning
    // the entire titlebar.
    static let tabMinWidthBase: CGFloat = 84
    static let tabMaxWidthBase: CGFloat = 244
    static let pinnedTabMinWidthBase: CGFloat = 38
    static let pinnedTabMaxWidthBase: CGFloat = 38
    /// Below this width, the editor can no longer keep useful content beside
    /// the trailing terminal panel, so the terminal takes over the detail area.
    static let editorMinimumReadableWidth: CGFloat = 360
    static let terminalDrawerMinWidth: CGFloat = 360
    static let terminalDrawerMaxWidth: CGFloat = 720
    static let terminalResizeHitWidth: CGFloat = 32
    static let settingsMaxContentWidth: CGFloat = 720

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let s: CGFloat = 8
        static let m: CGFloat = 10
        static let l: CGFloat = 12
        static let xl: CGFloat = 14
        static let xxl: CGFloat = 16
        static let windowMargin: CGFloat = 20
        static let settingsRowHorizontal: CGFloat = 14
        static let settingsRowVertical: CGFloat = 11
    }

    static func scale(
        _ base: CGFloat,
        theme: AppTheme,
        zoomScale: Double
    ) -> CGFloat {
        max(base * theme.layoutScale(zoomScale: zoomScale), base * 0.75)
    }

    static func interfaceText(_ base: CGFloat, theme: AppTheme, zoomScale: Double) -> CGFloat {
        base * theme.interfaceTextScale(zoomScale: zoomScale)
    }

    static func interfaceGlyph(_ base: CGFloat, theme: AppTheme, zoomScale: Double) -> CGFloat {
        base * theme.interfaceGlyphScale(zoomScale: zoomScale)
    }

    static func interfaceControl(_ base: CGFloat, theme: AppTheme, zoomScale: Double) -> CGFloat {
        base * theme.interfaceControlScale(zoomScale: zoomScale)
    }

    static func interfaceDensity(_ base: CGFloat, theme: AppTheme, zoomScale: Double) -> CGFloat {
        base * theme.interfaceDensityScale(zoomScale: zoomScale)
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
        max(24, interfaceControl(iconButtonSizeBase, theme: theme, zoomScale: zoomScale))
    }

    /// Primary chrome symbols follow the bounded interface curve while their
    /// row retains an independent inset, keeping the toolbar breathable.
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

    static func topBarLayoutMode(
        availableWidth: CGFloat,
        theme: AppTheme,
        zoomScale: Double
    ) -> MonknotTopBarLayoutMode {
        let effectiveWidth = availableWidth / theme.interfaceDensityScale(zoomScale: zoomScale)
        if effectiveWidth < minimalTopBarEffectiveWidth {
            return .minimal
        }
        if effectiveWidth < compactTopBarEffectiveWidth {
            return .compact
        }
        return .regular
    }
}

enum MonknotTopBarLayoutMode: Equatable {
    case regular
    case compact
    case minimal
}

enum WorkspaceZoomPolicy {
    static let minimum = 0.7
    static let maximum = 8.0
    static let step = 0.1
    static let defaultValue = 1.0
    static let minimumDocumentScale = 0.75
    static let maximumDocumentScale = 2.0

    /// Keyboard zoom uses a short perceptual ladder instead of walking every
    /// raw persistence increment. Growth above actual size is deliberately
    /// quicker; reductions below actual size stay gentler for readability.
    static let shortcutDocumentScales = [
        0.75, 0.80, 0.85, 0.90, 0.95,
        1.00, 1.20, 1.40, 1.60, 1.80, 2.00,
    ]

    static var supportedLevels: [Double] {
        shortcutDocumentScales.map(rawZoom(forDocumentScale:))
    }

    static func clamp(_ value: Double) -> Double {
        guard !value.isNaN else { return defaultValue }
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

    /// Maps the extended workspace zoom control onto a readable non-PDF
    /// document scale. PDFKit retains its own focused zoom behavior.
    static func documentScale(_ value: Double) -> Double {
        let zoom = clamp(value)
        if zoom >= defaultValue {
            let progress = log(zoom) / log(maximum)
            return defaultValue + (maximumDocumentScale - defaultValue) * progress
        }

        let progress = (defaultValue - zoom) / (defaultValue - minimum)
        return defaultValue - (defaultValue - minimumDocumentScale) * progress
    }

    private static func rawZoom(forDocumentScale scale: Double) -> Double {
        let boundedScale = min(maximumDocumentScale, max(minimumDocumentScale, scale))
        if boundedScale == minimumDocumentScale { return minimum }
        if boundedScale == defaultValue { return defaultValue }
        if boundedScale == maximumDocumentScale { return maximum }

        if boundedScale >= defaultValue {
            let progress = (boundedScale - defaultValue) / (maximumDocumentScale - defaultValue)
            return exp(log(maximum) * progress)
        }

        let progress = (defaultValue - boundedScale) / (defaultValue - minimumDocumentScale)
        return defaultValue - (defaultValue - minimum) * progress
    }
}
