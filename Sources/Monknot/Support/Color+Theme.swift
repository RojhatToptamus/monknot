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
            // Theme hex values are sRGB, matching `Color(hex:)`.
            self.init(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
        } else {
            self.init(calibratedWhite: 1, alpha: 1)
        }
    }
}

extension AppTheme {
    /// The primary reading/editing canvas (editor, preview, top bar, tabs).
    var surfaceColor: Color {
        Color(hex: background)
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
        foregroundColor.opacity(lineInkOpacity)
    }

    /// Structural separators (region edges, chrome rules). Derived from the
    /// theme ink rather than pure white/black so it stays stable when the
    /// window is inactive.
    var separatorColor: Color {
        foregroundColor.opacity(dividerInkOpacity)
    }

    /// The window chrome around the cards: titlebar, sidebar and the gaps between cards (design.md
    /// §10.0). The sidebar tier, so the sidebar reads as part of the frame rather than a panel.
    var chromeSurfaceColor: Color {
        Color(hex: chromeSurfaceHex)
    }

    /// The hairline ring of the document and terminal cards (design.md §10.0, `cardring`).
    var cardRingColor: Color {
        foregroundColor.opacity(isDark ? 0.09 : 0.11)
    }

    /// A selected sidebar row or terminal session: a neutral fill, like a highlighted menu row in the
    /// editor, so it never reads as a text selection or competes with the accent glyph (`selected`).
    var chromeSelectedFillColor: Color {
        foregroundColor.opacity(selectedInkOpacity)
    }

    /// A secondary push button: a fill a step deeper than the control track, with no border.
    var secondaryButtonFillColor: Color {
        foregroundColor.opacity(isDark ? 0.10 : 0.08)
    }

    /// A chip: the active tab and the selected cell of a segmented control, lifted out of the chrome
    /// or its track — the card's own colour in light themes, a raised tone in dark ones (`chip`).
    var chipFillColor: Color {
        isDark ? Color(hex: AppTheme.blendHex(background, toward: foreground, amount: 0.12)) : surfaceColor
    }

    /// The chip's hairline, and in light themes its one-point seat (`chipring`, `chipshadow`).
    var chipRingColor: Color {
        foregroundColor.opacity(isDark ? 0.09 : 0.10)
    }

    var chipShadowColor: Color {
        isDark ? .clear : foregroundColor.opacity(0.09)
    }

    /// The selected cell of a segmented control: the chip (design.md §5.5).
    var segmentSelectedFillColor: Color {
        chipFillColor
    }

    /// A floating surface's fill (`surf2`), the same as Preview's menus (`AppTheme.floatingSurfaceHex`).
    var elevatedSurfaceColor: Color {
        Color(hex: floatingSurfaceHex)
    }

    /// Slightly stronger than `elevatedSurfaceColor` for inset fields and wells.
    var insetFillColor: Color {
        Color(hex: recessedSurfaceHex(amount: isDark ? 0.17 : 0.09))
    }

    /// design.md §1.2 `ink2`: every label at rest, in the sidebar, tabs, menus and Settings alike. The
    /// opacity is derived per theme so it always reads 4.5:1 (`AppTheme.labelInkOpacity`).
    var mutedForegroundColor: Color {
        foregroundColor.opacity(labelInkOpacity)
    }

    /// design.md §1.2 `ink3`: every glyph at rest and all secondary text, at 3:1 or better.
    var tertiaryForegroundColor: Color {
        foregroundColor.opacity(glyphInkOpacity)
    }

    /// design.md §1.2 `ink4`: disabled controls and placeholders.
    var disabledForegroundColor: Color {
        foregroundColor.opacity(AppTheme.disabledInkOpacity)
    }

    /// design.md §1.2 `on`: a toggle that is on, such as a format in the format bar. Neutral, so an
    /// active control never spends the accent.
    var onFillColor: Color {
        foregroundColor.opacity(onInkOpacity)
    }

    /// Shadow hue for floating surfaces (`AppTheme.floatingShadowHex`), as Preview's page casts them.
    var floatingShadowColor: Color {
        isDark ? .black : Color(hex: floatingShadowHex)
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
        foregroundColor.opacity(hoverInkOpacity)
    }

    /// design.md §1.2 `press`: replaces the hover fill while a control is held down.
    var pressedFillColor: Color {
        foregroundColor.opacity(pressInkOpacity)
    }

    /// design.md §1.2 `accsoft`: the 3 pt ring around a focused field (`View.monknotField`).
    var accentSoftFillColor: Color {
        accentColor.opacity(accentSoftOpacity)
    }

    /// design.md §1.2 `danger`: destructive and failed — a destructive push button, an invalid field's
    /// hairline, a failed save, a file missing on disk. The theme's removed-diff colour.
    var dangerColor: Color {
        Color(hex: semanticColors.diffRemoved)
    }

    /// design.md §1.2 `dangersoft`: `danger` at 12 % dark, 10 % light, the fill of a banner whose file
    /// is gone.
    var dangerSoftFillColor: Color {
        dangerColor.opacity(isDark ? 0.12 : 0.10)
    }

    /// The track of a segmented control and the fill of a pop-up or settings button (`track`).
    var controlTrackFillColor: Color {
        foregroundColor.opacity(isDark ? 0.07 : 0.06)
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
}
