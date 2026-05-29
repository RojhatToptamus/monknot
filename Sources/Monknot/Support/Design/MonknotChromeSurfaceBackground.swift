import MonknotCore
import SwiftUI

/// Solid chrome fill for a region's surface tier.
///
/// Chrome is intentionally solid: vibrancy materials shift appearance with the
/// window's active state (e.g. when the Settings window takes key focus), which
/// reads as an inconsistent "shadow" on the sidebar. A solid theme-derived tone
/// keeps every region calm and stable. `surface` overrides the fill so a region
/// can paint its own tier (recessed sidebar or terminal); defaults to content.
struct MonknotChromeSurfaceBackground: View {
    let theme: AppTheme
    var surface: Color? = nil

    var body: some View {
        surface ?? theme.surfaceColor
    }
}
