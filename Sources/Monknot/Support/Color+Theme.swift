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
        accentColor.opacity(0.08 + normalizedContrast * 0.10)
    }

    /// Background for compact controls (segmented tracks, terminal tab chips).
    var controlTrackFillColor: Color {
        foregroundColor.opacity((isDark ? 0.035 : 0.028) + normalizedContrast * 0.028)
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

    /// Text, symbols, hit targets, row heights, and horizontal density have
    /// separate bounded curves. This is the key to keeping the interface
    /// visually balanced at 5× document zoom without recreating top-bar
    /// overlap or making the sidebar unusably wide.
    func interfaceTextScale(zoomScale: Double) -> CGFloat {
        boundedInterfaceScale(
            zoomScale: zoomScale,
            maximumZoomContribution: 0.35,
            minimumZoomScale: 0.90,
            fontInfluence: 1,
            maximum: 1.55
        )
    }

    func interfaceGlyphScale(zoomScale: Double) -> CGFloat {
        boundedInterfaceScale(
            zoomScale: zoomScale,
            maximumZoomContribution: 0.55,
            minimumZoomScale: 0.90,
            fontInfluence: 0.30,
            maximum: 1.65
        )
    }

    func interfaceControlScale(zoomScale: Double) -> CGFloat {
        boundedInterfaceScale(
            zoomScale: zoomScale,
            maximumZoomContribution: 0.40,
            minimumZoomScale: 0.93,
            fontInfluence: 0.20,
            maximum: 1.45
        )
    }

    func interfaceRowScale(zoomScale: Double) -> CGFloat {
        boundedInterfaceScale(
            zoomScale: zoomScale,
            maximumZoomContribution: 0.35,
            minimumZoomScale: 0.93,
            fontInfluence: 0.20,
            maximum: 1.40
        )
    }

    func interfaceDensityScale(zoomScale: Double) -> CGFloat {
        boundedInterfaceScale(
            zoomScale: zoomScale,
            maximumZoomContribution: 0.15,
            minimumZoomScale: 0.95,
            fontInfluence: 0.12,
            maximum: 1.18
        )
    }

    private func boundedInterfaceScale(
        zoomScale: Double,
        maximumZoomContribution: CGFloat,
        minimumZoomScale: CGFloat,
        fontInfluence: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let zoom = CGFloat(WorkspaceZoomPolicy.clamp(zoomScale))
        let zoomComponent: CGFloat
        if zoom >= 1 {
            let progress = CGFloat(log(Double(zoom)) / log(WorkspaceZoomPolicy.maximum))
            zoomComponent = 1 + maximumZoomContribution * progress
        } else {
            let compactProgress = (1 - zoom) / CGFloat(1 - WorkspaceZoomPolicy.minimum)
            zoomComponent = 1 - (1 - minimumZoomScale) * compactProgress
        }

        let fontAdjustment = (layoutFontFactor - 1) * fontInfluence
        return min(maximum, max(0.84, zoomComponent + fontAdjustment))
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
