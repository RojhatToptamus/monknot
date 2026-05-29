import AppKit
import MonknotCore
import SwiftUI

extension Color {
    init(hex: String) {
        if let rgb = RGBHex(hex) {
            self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
        } else {
            self.init(nsColor: .labelColor)
        }
    }
}

extension NSColor {
    convenience init(hex: String) {
        if let rgb = RGBHex(hex) {
            self.init(calibratedRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
        } else {
            self.init(calibratedWhite: 1, alpha: 1)
        }
    }
}

extension AppTheme {
    private var normalizedContrast: Double {
        min(100, max(0, contrast)) / 100
    }

    /// The primary reading/editing canvas (editor, preview, top bar, tabs).
    var surfaceColor: Color {
        Color(hex: background)
    }

    /// Alias for the content canvas, used where intent should be explicit.
    var contentSurfaceColor: Color {
        surfaceColor
    }

    /// Recessed tool-panel surface for the sidebar. Distinct-but-related to the
    /// content canvas so regions read apart without heavy borders.
    var sidebarSurfaceColor: Color {
        Color(hex: sidebarSurfaceHex)
    }

    /// The terminal shares the content canvas in the two-tier surface model, so
    /// this is an explicit alias of the canvas surface (theme background).
    var terminalSurfaceColor: Color {
        Color(hex: terminalSurfaceHex)
    }

    var foregroundColor: Color {
        Color(hex: foreground)
    }

    var accentColor: Color {
        Color(hex: accent)
    }

    /// Hairline borders on controls and cards. Surface tone carries region
    /// separation, so borders stay subtle.
    var borderColor: Color {
        foregroundColor.opacity((isDark ? 0.05 : 0.045) + normalizedContrast * 0.04)
    }

    /// Structural separators (region edges, chrome rules). Derived from the
    /// theme ink rather than pure white/black so it stays stable when the
    /// window is inactive.
    var separatorColor: Color {
        foregroundColor.opacity((isDark ? 0.07 : 0.06) + normalizedContrast * 0.04)
    }

    var elevatedSurfaceColor: Color {
        foregroundColor.opacity((isDark ? 0.035 : 0.025) + normalizedContrast * 0.055)
    }

    /// Slightly stronger than `elevatedSurfaceColor` for inset fields and wells.
    var insetFillColor: Color {
        foregroundColor.opacity((isDark ? 0.055 : 0.04) + normalizedContrast * 0.065)
    }

    var mutedForegroundColor: Color {
        foregroundColor.opacity((isDark ? 0.52 : 0.45) + normalizedContrast * 0.18)
    }

    var selectedRowColor: Color {
        accentColor.opacity(0.08 + normalizedContrast * 0.10)
    }

    /// Background for compact controls (segmented tracks, terminal tab chips).
    var controlTrackFillColor: Color {
        foregroundColor.opacity((isDark ? 0.035 : 0.028) + normalizedContrast * 0.028)
    }

    /// Dimming layer over the editor when a drawer is presented (theme-aware, not pure black).
    var scrimColor: Color {
        foregroundColor.opacity(isDark ? 0.22 : 0.14)
    }

    func sidebarColor(_ color: Color, opacity: Double = 1) -> Color {
        color.opacity(opacity * (quietSidebar ? 0.8 : 1))
    }

    // MARK: - Layout (scales with UI font size; no hard-coded theme colors)

    private var layoutFontFactor: CGFloat {
        CGFloat(min(28, max(12, uiFontSize)) / 16)
    }

    func layoutScale(zoomScale: Double) -> CGFloat {
        max(CGFloat(zoomScale) * layoutFontFactor, 0.75)
    }

    func chromeRadius(_ basePoints: CGFloat, zoomScale: Double) -> CGFloat {
        max(basePoints * layoutScale(zoomScale: zoomScale), basePoints * 0.8)
    }

    /// Settings / static panels (zoom = 1).
    var settingsControlCornerRadius: CGFloat {
        CGFloat(min(10, max(7, uiFontSize * 0.48)))
    }

    var settingsCardCornerRadius: CGFloat {
        CGFloat(min(14, max(10, uiFontSize * 0.62)))
    }
}
