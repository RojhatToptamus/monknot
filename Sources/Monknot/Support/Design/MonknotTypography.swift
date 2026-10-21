import MonknotCore
import SwiftUI

/// The chrome's type scale (design.md §4.3): every label is 13 / 400, every title 13 / 600 and every
/// secondary line, count and group header 12 / 400, at the interface zoom.
enum MonknotTypography {
    /// A group header: 12, weight 400, sentence case, in `ink3` (design.md §4.3), the section header of
    /// the editor's menus, so a sidebar group and a menu section read as one system.
    static func groupHeader(theme: AppTheme, zoomScale: Double) -> Font {
        text(12, weight: .regular, theme: theme, zoomScale: zoomScale)
    }

    /// Every label: rows, tabs, menu rows, buttons, fields and Settings' rows (design.md §4.3).
    static func rowTitle(theme: AppTheme, zoomScale: Double) -> Font {
        text(13, weight: .regular, theme: theme, zoomScale: zoomScale)
    }

    /// Secondary text: paths, counts, captions, status lines and details.
    static func rowDetail(theme: AppTheme, zoomScale: Double) -> Font {
        text(12, theme: theme, zoomScale: zoomScale)
    }

    /// Sheets, panels, overlays, empty states and the workspace name title like a heading row: 13,
    /// weight 600 (design.md §4.1, §4.3).
    static func panelTitle(theme: AppTheme, zoomScale: Double) -> Font {
        text(13, weight: .semibold, theme: theme, zoomScale: zoomScale)
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
