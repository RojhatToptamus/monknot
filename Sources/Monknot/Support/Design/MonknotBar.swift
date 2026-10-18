import MonknotCore
import SwiftUI

/// The titlebar row (design.md §10.1): 44 tall, 8 from the window's edges.
struct MonknotTitlebarRowLayout: ViewModifier {
    let theme: AppTheme
    let zoomScale: Double

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, MonknotMetrics.chromeHorizontalPadding(theme: theme, zoomScale: zoomScale))
            .frame(
                height: MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale),
                alignment: .center
            )
            .frame(maxWidth: .infinity)
    }
}

extension View {
    func monknotTitlebarRowLayout(theme: AppTheme, zoomScale: Double) -> some View {
        modifier(MonknotTitlebarRowLayout(theme: theme, zoomScale: zoomScale))
    }
}

/// The one bar below the titlebar (design.md §10.6): 40 tall, 6 padding, 28 controls 2 apart, groups
/// 8 apart (`MonknotBarGroupGap`). It has no fill and no rule of its own: it sits on its card or panel,
/// and space alone groups its controls. The terminal's header and the PDF toolbar are this bar.
struct MonknotBar<Content: View>: View {
    let theme: AppTheme
    let zoomScale: Double
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: MonknotMetrics.interfaceDensity(MonknotMetrics.barItemGapBase, theme: theme, zoomScale: zoomScale)) {
            content()
        }
        .padding(.horizontal, MonknotMetrics.interfaceDensity(MonknotMetrics.barPaddingBase, theme: theme, zoomScale: zoomScale))
        .frame(height: MonknotMetrics.barHeight(theme: theme, zoomScale: zoomScale))
        .frame(maxWidth: .infinity)
    }
}

/// The space between two groups of a bar. With the bar's own 2 on either side, groups sit 8 apart.
struct MonknotBarGroupGap: View {
    let theme: AppTheme
    let zoomScale: Double

    static func width(theme: AppTheme, zoomScale: Double) -> CGFloat {
        MonknotMetrics.interfaceDensity(
            MonknotMetrics.barGroupGapBase - 2 * MonknotMetrics.barItemGapBase,
            theme: theme,
            zoomScale: zoomScale
        )
    }

    var body: some View {
        Color.clear
            .frame(width: Self.width(theme: theme, zoomScale: zoomScale), height: 1)
            .accessibilityHidden(true)
    }
}
