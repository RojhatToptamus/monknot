import MonknotCore
import SwiftUI

/// Layout tokens aligned to the macOS 8pt grid, scaled with zoom and UI font size.
enum MonknotMetrics {
    static let chromeHeightBase: CGFloat = 40
    static let chromeSecondaryHeightBase: CGFloat = 40
    static let chromeHorizontalPaddingBase: CGFloat = 10
    static let iconButtonSizeBase: CGFloat = 28
    static let iconPointSizeBase: CGFloat = 13
    static let iconCornerRadiusBase: CGFloat = 6
    static let trafficLightReserveBase: CGFloat = 72
    static let windowNavigationLeadingGapBase: CGFloat = 8
    static let compactTopBarEffectiveWidth: CGFloat = 600
    static let minimalTopBarEffectiveWidth: CGFloat = 480
    // A file tab must retain enough room for a recognizable hard-clipped name
    // after its icon, status, and close slots. Overflowing one tab sooner is
    // more useful than rendering a row of nearly indistinguishable labels.
    static let tabMinWidthBase: CGFloat = 148
    static let tabMaxWidthBase: CGFloat = 192
    static let pinnedTabMinWidthBase: CGFloat = 108
    static let pinnedTabMaxWidthBase: CGFloat = 132
    /// In terminal takeover the document lane must still show one meaningful
    /// file tab plus its fixed controls. Terminal tabs can scroll inside their
    /// own narrower lane instead of starving the active document identity.
    static let takeoverDocumentChromeMinWidthBase: CGFloat = 270
    static let takeoverTerminalChromeMinWidthBase: CGFloat = 135
    static let takeoverTerminalChromeMaxWidthBase: CGFloat = 220
    /// Below this width, the document can no longer keep useful content and
    /// adaptive chrome visible beside the terminal drawer.
    static let editorMinimumReadableWidth: CGFloat = 440
    static let terminalDrawerMinWidth: CGFloat = 320
    static let terminalDrawerMaxWidth: CGFloat = 720
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
        static let settingsRowHorizontal: CGFloat = 18
        static let settingsRowVertical: CGFloat = 13
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
    static let maximum = 5.0
    static let step = 0.1
    /// Terminal glyphs need a tighter ceiling than document content: at the
    /// full workspace range xterm otherwise becomes a single oversized cursor
    /// instead of a usable secondary tool.
    static let maximumTerminalContentScale = 2.5

    static var supportedLevels: [Double] {
        let minimumStep = Int((minimum * 10).rounded())
        let maximumStep = Int((maximum * 10).rounded())
        return (minimumStep...maximumStep).map { Double($0) / 10 }
    }

    static func clamp(_ value: Double) -> Double {
        min(maximum, max(minimum, value))
    }

    static func stepped(_ value: Double, by delta: Double) -> Double {
        let next = ((value + delta) / step).rounded() * step
        return clamp(next)
    }

    static func terminalContentScale(_ value: Double) -> Double {
        min(maximumTerminalContentScale, clamp(value))
    }
}
