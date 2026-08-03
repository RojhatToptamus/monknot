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
        foregroundColor.opacity(isDark ? 0.075 : 0.10)
    }

    /// Structural separators (region edges, chrome rules). Derived from the
    /// theme ink rather than pure white/black so it stays stable when the
    /// window is inactive.
    var separatorColor: Color {
        foregroundColor.opacity(isDark ? 0.045 : 0.055)
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

    /// General layout scaling stays intentionally gentle. Components that need
    /// stronger high-zoom compensation use the interface token scales below,
    /// so wider glyphs do not also inflate every gap and tab width.
    func layoutScale(zoomScale: Double) -> CGFloat {
        let clampedZoom = CGFloat(WorkspaceZoomPolicy.clamp(zoomScale))
        let zoomFactor: CGFloat
        if clampedZoom >= 1 {
            zoomFactor = 1 + min(clampedZoom - 1, 2) * 0.10
        } else {
            zoomFactor = 1 + (clampedZoom - 1) * 0.35
        }

        return min(1.35, max(zoomFactor * layoutFontFactor, 0.875))
    }

    /// Workspace zoom primarily changes document content. Application chrome
    /// follows a much gentler curve that reaches its ceiling at 3x, keeping
    /// text, glyphs, controls, rows, and spacing visually proportionate without
    /// allowing the titlebar or sidebars to consume the window at extreme zoom.
    func interfaceTextScale(zoomScale: Double) -> CGFloat {
        interfaceScale(
            zoomScale: zoomScale,
            fontInfluence: 1,
            zoomInfluence: 0.20,
            minimum: 0.84,
            maximum: 1.30
        )
    }

    func interfaceGlyphScale(zoomScale: Double) -> CGFloat {
        interfaceScale(
            zoomScale: zoomScale,
            fontInfluence: 0.30,
            zoomInfluence: 0.14,
            minimum: 0.92,
            maximum: 1.18
        )
    }

    func interfaceControlScale(zoomScale: Double) -> CGFloat {
        interfaceScale(
            zoomScale: zoomScale,
            fontInfluence: 0.20,
            zoomInfluence: 0.12,
            minimum: 0.94,
            maximum: 1.16
        )
    }

    func interfaceRowScale(zoomScale: Double) -> CGFloat {
        interfaceScale(
            zoomScale: zoomScale,
            fontInfluence: 0.20,
            zoomInfluence: 0.10,
            minimum: 0.95,
            maximum: 1.14
        )
    }

    func interfaceDensityScale(zoomScale: Double) -> CGFloat {
        interfaceScale(
            zoomScale: zoomScale,
            fontInfluence: 0.12,
            zoomInfluence: 0.08,
            minimum: 0.97,
            maximum: 1.10
        )
    }

    private func interfaceScale(
        zoomScale: Double,
        fontInfluence: CGFloat,
        zoomInfluence: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let fontAdjustment = (layoutFontFactor - 1) * fontInfluence
        let clampedZoom = CGFloat(WorkspaceZoomPolicy.clamp(zoomScale))
        let normalizedZoom: CGFloat
        if clampedZoom >= 1 {
            normalizedZoom = min(clampedZoom - 1, 2) / 2
        } else {
            normalizedZoom = clampedZoom - 1
        }
        let zoomAdjustment = normalizedZoom * zoomInfluence
        return min(maximum, max(minimum, 1 + fontAdjustment + zoomAdjustment))
    }

    func chromeRadius(_ basePoints: CGFloat, zoomScale: Double) -> CGFloat {
        max(basePoints * interfaceDensityScale(zoomScale: zoomScale), basePoints * 0.8)
    }

    /// Settings / static panels (zoom = 1).
    var settingsControlCornerRadius: CGFloat {
        CGFloat(min(10, max(7, uiFontSize * 0.48)))
    }

    var settingsCardCornerRadius: CGFloat {
        CGFloat(min(14, max(10, uiFontSize * 0.62)))
    }
}
