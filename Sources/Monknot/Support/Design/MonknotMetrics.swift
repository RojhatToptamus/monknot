import MonknotCore
import SwiftUI

/// Layout tokens aligned to the macOS 8pt grid, scaled with zoom and UI font size.
enum MonknotMetrics {
    static let chromeHeightBase: CGFloat = 44
    static let chromeSecondaryHeightBase: CGFloat = 36
    static let chromeHorizontalPaddingBase: CGFloat = 10
    static let iconButtonSizeBase: CGFloat = 24
    static let iconPointSizeBase: CGFloat = 11
    static let iconCornerRadiusBase: CGFloat = 6
    static let trafficLightReserveBase: CGFloat = 72
    static let compactLayoutBreakpoint: CGFloat = 760
    static let tabMinWidthBase: CGFloat = 82
    static let tabMaxWidthBase: CGFloat = 168
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

    static func chromeHeight(theme: AppTheme, zoomScale: Double) -> CGFloat {
        scale(chromeHeightBase, theme: theme, zoomScale: zoomScale)
    }

    static func chromeSecondaryHeight(theme: AppTheme, zoomScale: Double) -> CGFloat {
        scale(chromeSecondaryHeightBase, theme: theme, zoomScale: zoomScale)
    }

    static func chromeHorizontalPadding(theme: AppTheme, zoomScale: Double) -> CGFloat {
        scale(chromeHorizontalPaddingBase, theme: theme, zoomScale: zoomScale)
    }
}
