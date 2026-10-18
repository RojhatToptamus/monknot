import MonknotCore
import SwiftUI

enum MonknotTypography {
    /// design.md §4.3 group header: 12, weight 400, sentence case, in `ink3` — the section header of
    /// the editor's menus, so a sidebar group and a menu section read as one system.
    static func eyebrow(theme: AppTheme, zoomScale: Double) -> Font {
        text(12, weight: .regular, theme: theme, zoomScale: zoomScale)
    }

    static func eyebrowTracking(theme: AppTheme, zoomScale: Double) -> CGFloat {
        0
    }

    static func rowTitle(theme: AppTheme, zoomScale: Double) -> Font {
        text(13, weight: .regular, theme: theme, zoomScale: zoomScale)
    }

    static func rowDetail(theme: AppTheme, zoomScale: Double) -> Font {
        text(12, theme: theme, zoomScale: zoomScale)
    }

    /// Sheets and panels title like a heading row: 13, weight 600 (design.md §4.1, §4.3).
    static func panelTitle(theme: AppTheme, zoomScale: Double = 1) -> Font {
        text(13, weight: .semibold, theme: theme, zoomScale: zoomScale)
    }

    /// Empty states title like panels and sheets (design.md §4.3).
    static func emptyStateTitle(theme: AppTheme, zoomScale: Double) -> Font {
        panelTitle(theme: theme, zoomScale: zoomScale)
    }

    static func emptyStateDetail(theme: AppTheme, zoomScale: Double) -> Font {
        text(12, theme: theme, zoomScale: zoomScale)
    }

    static func settingsRowTitle(theme: AppTheme, zoomScale: Double = 1) -> Font {
        text(13, weight: .regular, theme: theme, zoomScale: zoomScale)
    }

    static func settingsRowDetail(theme: AppTheme, zoomScale: Double = 1) -> Font {
        text(12, theme: theme, zoomScale: zoomScale)
    }

    static func settingsButton(theme: AppTheme, zoomScale: Double = 1) -> Font {
        text(13, weight: .regular, theme: theme, zoomScale: zoomScale)
    }

    /// The system font at `size` under the interface text zoom.
    private static func text(
        _ size: CGFloat,
        weight: Font.Weight? = nil,
        theme: AppTheme,
        zoomScale: Double
    ) -> Font {
        .system(size: MonknotMetrics.interfaceText(size, theme: theme, zoomScale: zoomScale), weight: weight)
    }
}
