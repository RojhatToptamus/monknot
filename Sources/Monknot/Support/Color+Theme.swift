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
            // Theme hex values are sRGB, as in `Color(hex:)`; calibrated (generic)
            // RGB drew AppKit surfaces lighter than the SwiftUI and WebKit ones.
            self.init(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
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

    /// design.md §1.2 `ink2` and `ink3` as opacities of the theme foreground.
    static let mutedInkOpacity = 0.62
    static let tertiaryInkOpacity = 0.40

    var mutedForegroundColor: Color {
        foregroundColor.opacity(Self.mutedInkOpacity)
    }

    var tertiaryForegroundColor: Color {
        foregroundColor.opacity(Self.tertiaryInkOpacity)
    }

    var disabledForegroundColor: Color {
        foregroundColor.opacity(0.24)
    }

    /// Shadow hue for floating surfaces. Light themes carry 10% of the accent
    /// so shadows stay neutral to the theme instead of turning muddy black.
    var floatingShadowColor: Color {
        guard !isDark else { return .black }
        let ink = NSColor(hex: foreground)
        let accent = NSColor(hex: accent)
        return Color(nsColor: ink.blended(withFraction: 0.10, of: accent) ?? ink)
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
        return max(sidebarLegibleInkFloor, min(0.76, base - tertiaryReduction - quietReduction))
    }

    /// Below this opacity small sidebar labels and icons stop being legible in light themes.
    private var sidebarLegibleInkFloor: Double {
        isDark ? 0.48 : 0.52
    }

    var selectedRowColor: Color {
        Color(hex: selectionBackground)
    }

    /// design.md §1.2 `hover`: the one hover fill for every row, tab, cell and button.
    var hoverFillColor: Color {
        foregroundColor.opacity(isDark ? 0.06 : 0.055)
    }

    /// design.md §1.2 `press`: replaces the hover fill while a control is held down.
    var pressedFillColor: Color {
        foregroundColor.opacity(isDark ? 0.11 : 0.10)
    }

    /// design.md §1.2 `accsoft`: the fill of an icon button whose panel is open.
    var accentSoftFillColor: Color {
        accentColor.opacity(isDark ? 0.18 : 0.14)
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

    /// Sidebar ink: `color` at `opacity`, which Quiet Sidebar subdues (see `sidebarOpacity`). Pass an
    /// opaque color and the ink level as `opacity`, never an already translucent color.
    func sidebarColor(_ color: Color, opacity: Double = 1) -> Color {
        color.opacity(sidebarOpacity(opacity))
    }

    /// Quiet Sidebar takes a fifth off the opacity once, never below the legibility floor, and leaves
    /// ink already under the floor (resting glyphs at `ink3`) where it is, clear of the disabled `ink4`.
    func sidebarOpacity(_ opacity: Double) -> Double {
        guard quietSidebar else { return opacity }
        return max(min(opacity, sidebarLegibleInkFloor), opacity * 0.8)
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
