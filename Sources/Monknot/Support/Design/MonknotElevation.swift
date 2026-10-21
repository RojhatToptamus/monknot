import MonknotCore
import SwiftUI

/// design.md §2.1: the two elevations a floating surface can take. A floating surface (menu, popover,
/// toast, the outline's panel, sheet, overlay) casts in both appearances, because a shadow is what says
/// "dismissible"; docked and resting surfaces never cast.
enum MonknotElevation {
    /// Popovers, menus, toasts, the outline's panel.
    case e2
    /// Sheets and full overlay panels.
    case e3

    struct Shadow {
        let opacity: Double
        let blur: CGFloat
        let y: CGFloat
    }

    /// The inset ring: white 14 % in dark, the shadow hue at 8 % in light, the values Preview's page
    /// draws its menus with (`AppTheme.floatingRingHex`).
    func ringColor(_ theme: AppTheme) -> Color {
        Color(hex: theme.floatingRingHex).opacity(theme.floatingRingOpacity)
    }

    /// The wide ambient shadow, then the tight key shadow.
    func shadows(_ theme: AppTheme) -> (ambient: Shadow, key: Shadow) {
        switch (self, theme.isDark) {
        case (.e2, true):
            return (Shadow(opacity: 0.50, blur: 24, y: 8), Shadow(opacity: 0.34, blur: 6, y: 2))
        case (.e2, false):
            return (Shadow(opacity: 0.08, blur: 12, y: 4), Shadow(opacity: 0.05, blur: 3, y: 1))
        case (.e3, true):
            return (Shadow(opacity: 0.64, blur: 60, y: 24), Shadow(opacity: 0.40, blur: 16, y: 6))
        case (.e3, false):
            return (Shadow(opacity: 0.14, blur: 40, y: 16), Shadow(opacity: 0.06, blur: 10, y: 4))
        }
    }
}

extension View {
    /// Clips the view to a rounded box, fills it with `fill` and lifts it by `elevation`: one inset ring
    /// and two shadows in the theme's shadow hue (design.md §2.1).
    func monknotFloatingSurface(
        _ elevation: MonknotElevation,
        cornerRadius: CGFloat,
        fill: Color,
        theme: AppTheme
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let shadows = elevation.shadows(theme)
        // Clipped before the background is added, so the shadows stay outside the clip. SwiftUI's
        // shadow radius is about half a CSS blur.
        return clipShape(shape)
            .background {
                shape.fill(fill)
                    .shadow(
                        color: theme.floatingShadowColor.opacity(shadows.ambient.opacity),
                        radius: shadows.ambient.blur / 2,
                        y: shadows.ambient.y
                    )
                    .shadow(
                        color: theme.floatingShadowColor.opacity(shadows.key.opacity),
                        radius: shadows.key.blur / 2,
                        y: shadows.key.y
                    )
            }
            .overlay {
                shape.strokeBorder(elevation.ringColor(theme), lineWidth: 1)
            }
    }
}
