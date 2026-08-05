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

    /// Docked right-edge terminal surface, matching the left sidebar tier.
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
        foregroundColor.opacity(isDark ? 0.09 : 0.12)
    }

    /// Structural separators (region edges, chrome rules). Derived from the
    /// theme ink rather than pure white/black so it stays stable when the
    /// window is inactive.
    var separatorColor: Color {
        foregroundColor.opacity(isDark ? 0.06 : 0.08)
    }

    var elevatedSurfaceColor: Color {
        Color(hex: recessedSurfaceHex(amount: isDark ? 0.11 : 0.05))
    }

    /// Slightly stronger than `elevatedSurfaceColor` for inset fields and wells.
    var insetFillColor: Color {
        Color(hex: recessedSurfaceHex(amount: isDark ? 0.17 : 0.09))
    }

    var mutedForegroundColor: Color {
        foregroundColor.opacity(0.62)
    }

    var tertiaryForegroundColor: Color {
        foregroundColor.opacity(0.40)
    }

    var disabledForegroundColor: Color {
        foregroundColor.opacity(0.24)
    }

    /// Secondary sidebar ink is derived directly from the theme foreground.
    /// This avoids applying sidebar quieting to an already translucent color,
    /// which made small labels and icons illegible in light themes.
    func sidebarMutedColor(prominence: Double = 1) -> Color {
        foregroundColor.opacity(sidebarMutedOpacity(prominence: prominence))
    }

    func sidebarMutedOpacity(prominence: Double = 1) -> Double {
        let clampedProminence = min(1, max(0, prominence))
        let base = (isDark ? 0.58 : 0.60) + normalizedContrast * 0.12
        let tertiaryReduction = (1 - clampedProminence) * 0.18
        let quietReduction = quietSidebar ? 0.08 : 0
        let minimum = isDark ? 0.48 : 0.52
        return max(minimum, min(0.76, base - tertiaryReduction - quietReduction))
    }

    var selectedRowColor: Color {
        Color(hex: selectionBackground)
    }

    /// Background for compact controls (segmented tracks, terminal tab chips).
    var controlTrackFillColor: Color {
        foregroundColor.opacity(isDark ? 0.06 : 0.055)
    }

    /// Dimming layer over the editor when a drawer overlays constrained content.
    /// A neutral black scrim preserves contrast in both color schemes; using
    /// the theme foreground would brighten dark canvases instead of dimming them.
    var scrimColor: Color {
        Color.black.opacity(isDark ? 0.32 : 0.16)
    }

    func sidebarColor(_ color: Color, opacity: Double = 1) -> Color {
        color.opacity(opacity * (quietSidebar ? 0.8 : 1))
    }

    // MARK: - Layout (scales with UI font size; no hard-coded theme colors)

    private var layoutFontFactor: CGFloat {
        CGFloat(min(1.25, max(0.875, uiFontSize / 16)))
    }

    /// Workspace zoom is one coherent scale. Text, symbols, rows, controls,
    /// padding, and gaps all use the same factor so the interface does not
    /// become typographically large while its hit targets stay behind.
    func layoutScale(zoomScale: Double) -> CGFloat {
        CGFloat(WorkspaceZoomPolicy.clamp(zoomScale))
    }

    func interfaceTextScale(zoomScale: Double) -> CGFloat {
        CGFloat(WorkspaceZoomPolicy.clamp(zoomScale)) * layoutFontFactor
    }

    func interfaceGlyphScale(zoomScale: Double) -> CGFloat {
        CGFloat(WorkspaceZoomPolicy.clamp(zoomScale))
    }

    func interfaceControlScale(zoomScale: Double) -> CGFloat {
        CGFloat(WorkspaceZoomPolicy.clamp(zoomScale))
    }

    func interfaceRowScale(zoomScale: Double) -> CGFloat {
        CGFloat(WorkspaceZoomPolicy.clamp(zoomScale))
    }

    func interfaceDensityScale(zoomScale: Double) -> CGFloat {
        CGFloat(WorkspaceZoomPolicy.clamp(zoomScale))
    }

    func chromeRadius(_ basePoints: CGFloat, zoomScale: Double) -> CGFloat {
        (basePoints * interfaceDensityScale(zoomScale: zoomScale)).rounded()
    }

    /// Settings / static panels (zoom = 1).
    var settingsControlCornerRadius: CGFloat {
        8
    }

    var settingsCardCornerRadius: CGFloat {
        12
    }
}
