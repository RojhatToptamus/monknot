import MonknotCore
import SwiftUI

/// Chrome fill driven by the theme's `chromeSurfaceStyle` and Reduce Transparency.
struct MonknotChromeSurfaceBackground: View {
    let theme: AppTheme
    @Environment(\.monknotReduceTransparency) private var reduceTransparency

    private var effectiveStyle: MonknotChromeSurfaceStyle {
        MonknotChromeSurfaceStyleResolver.effective(
            requested: theme.chromeSurfaceStyle,
            reduceTransparency: reduceTransparency
        )
    }

    var body: some View {
        ZStack {
            switch effectiveStyle {
            case .solid:
                theme.surfaceColor
            case .translucent:
                Rectangle().fill(.thinMaterial)
                theme.surfaceColor.opacity(theme.isDark ? 0.42 : 0.55)
            case .liquidGlass:
                liquidGlassFill
            }
        }
    }

    @ViewBuilder
    private var liquidGlassFill: some View {
        if #available(macOS 26.0, *) {
            Rectangle().fill(.ultraThinMaterial)
            theme.surfaceColor.opacity(theme.isDark ? 0.28 : 0.38)
        } else {
            Rectangle().fill(.thinMaterial)
            theme.surfaceColor.opacity(theme.isDark ? 0.42 : 0.55)
        }
    }
}
