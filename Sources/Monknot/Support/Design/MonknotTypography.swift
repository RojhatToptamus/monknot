import MonknotCore
import SwiftUI

enum MonknotTypography {
    static func chromeLabel(theme: AppTheme, zoomScale: Double) -> Font {
        .system(size: MonknotMetrics.scale(13, theme: theme, zoomScale: zoomScale), weight: .regular)
    }

    static func rowTitle(theme: AppTheme, zoomScale: Double) -> Font {
        .system(size: MonknotMetrics.scale(14, theme: theme, zoomScale: zoomScale), weight: .medium)
    }

    static func rowDetail(theme: AppTheme, zoomScale: Double) -> Font {
        .system(size: MonknotMetrics.scale(12, theme: theme, zoomScale: zoomScale))
    }

    static func panelTitle(theme: AppTheme) -> Font {
        .system(size: 18, weight: .semibold)
    }

    static func settingsSectionTitle(theme: AppTheme) -> Font {
        .system(size: 14, weight: .semibold)
    }

    static func emptyStateTitle(theme: AppTheme, zoomScale: Double) -> Font {
        .system(size: MonknotMetrics.scale(17, theme: theme, zoomScale: zoomScale), weight: .semibold)
    }

    static func emptyStateDetail(theme: AppTheme, zoomScale: Double) -> Font {
        .system(size: MonknotMetrics.scale(12, theme: theme, zoomScale: zoomScale))
    }

    static func tabLabel(theme: AppTheme, zoomScale: Double) -> Font {
        .system(size: MonknotMetrics.scale(12, theme: theme, zoomScale: zoomScale), weight: .medium)
    }

    static func settingsRowTitle(theme: AppTheme) -> Font {
        .system(size: 14, weight: .medium)
    }

    static func settingsRowDetail(theme: AppTheme) -> Font {
        .system(size: 12)
    }

    static func settingsButton(theme: AppTheme) -> Font {
        .system(size: 13, weight: .medium)
    }
}
