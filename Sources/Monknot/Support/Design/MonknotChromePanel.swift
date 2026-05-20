import MonknotCore
import SwiftUI

extension AppTheme {
    /// Legacy alias; chrome panels use `MonknotChromeSurfaceBackground` for the real fill.
    var chromeFillColor: Color {
        surfaceColor
    }
}

/// One continuous chrome block: themed surface fill and a single bottom edge.
struct MonknotChromePanel<Content: View>: View {
    let theme: AppTheme
    var showsBottomBorder: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .background {
            MonknotChromeSurfaceBackground(theme: theme)
        }
        .overlay(alignment: .bottom) {
            if showsBottomBorder {
                Rectangle()
                    .fill(theme.separatorColor)
                    .frame(height: 1)
            }
        }
    }
}

/// Primary chrome row (tabs, sidebar actions, terminal header).
struct MonknotChromeRowLayout: ViewModifier {
    let theme: AppTheme
    let zoomScale: Double

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, MonknotMetrics.chromeHorizontalPadding(theme: theme, zoomScale: zoomScale))
            .frame(height: MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale))
            .frame(maxWidth: .infinity)
    }
}

/// Full-width divider between chrome rows (edge-to-edge inside the panel).
struct MonknotChromeDivider: View {
    let theme: AppTheme

    var body: some View {
        Rectangle()
            .fill(theme.separatorColor)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

/// Secondary chrome row (markdown formatting bar).
struct MonknotChromeSubrowLayout: ViewModifier {
    let theme: AppTheme
    let zoomScale: Double

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, MonknotMetrics.chromeHorizontalPadding(theme: theme, zoomScale: zoomScale))
            .frame(height: MonknotMetrics.chromeSecondaryHeight(theme: theme, zoomScale: zoomScale))
            .frame(maxWidth: .infinity)
    }
}

extension View {
    func monknotChromeRowLayout(theme: AppTheme, zoomScale: Double) -> some View {
        modifier(MonknotChromeRowLayout(theme: theme, zoomScale: zoomScale))
    }

    func monknotChromeSubrowLayout(theme: AppTheme, zoomScale: Double) -> some View {
        modifier(MonknotChromeSubrowLayout(theme: theme, zoomScale: zoomScale))
    }
}
