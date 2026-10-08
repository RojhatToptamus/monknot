import MonknotCore
import SwiftUI

enum MonknotTypography {
    static func chromeLabel(theme: AppTheme, zoomScale: Double) -> Font {
        .system(size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale), weight: .regular)
    }

    /// design.md §4.3 eyebrow / group header: 10, weight 600, uppercase, tracking 0.09 em (apply
    /// `eyebrowTracking` and `.textCase(.uppercase)` with it).
    static func eyebrow(theme: AppTheme, zoomScale: Double) -> Font {
        .system(size: MonknotMetrics.interfaceText(10, theme: theme, zoomScale: zoomScale), weight: .semibold)
    }

    static func eyebrowTracking(theme: AppTheme, zoomScale: Double) -> CGFloat {
        MonknotMetrics.interfaceText(10, theme: theme, zoomScale: zoomScale) * 0.09
    }

    static func rowTitle(theme: AppTheme, zoomScale: Double) -> Font {
        .system(size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale), weight: .regular)
    }

    static func rowDetail(theme: AppTheme, zoomScale: Double) -> Font {
        .system(size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale))
    }

    static func panelTitle(theme: AppTheme) -> Font {
        .system(size: 15.5, weight: .semibold)
    }

    static func settingsSectionTitle(theme: AppTheme) -> Font {
        .system(size: 15.5, weight: .semibold)
    }

    static func emptyStateTitle(theme: AppTheme, zoomScale: Double) -> Font {
        .system(size: MonknotMetrics.interfaceText(15.5, theme: theme, zoomScale: zoomScale), weight: .semibold)
    }

    static func emptyStateDetail(theme: AppTheme, zoomScale: Double) -> Font {
        .system(size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale))
    }

    static func tabLabel(theme: AppTheme, zoomScale: Double) -> Font {
        .system(size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale), weight: .regular)
    }

    static func settingsRowTitle(theme: AppTheme, zoomScale: Double = 1) -> Font {
        .system(size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale), weight: .regular)
    }

    static func settingsRowDetail(theme: AppTheme, zoomScale: Double = 1) -> Font {
        .system(size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale))
    }

    static func settingsButton(theme: AppTheme, zoomScale: Double = 1) -> Font {
        .system(size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale), weight: .regular)
    }
}
