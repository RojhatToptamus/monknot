import MonknotCore
import SwiftUI

/// Shared search-field symbol with the same optical centering as search
/// buttons. Point size can vary by role without changing the correction.
struct MonknotSearchGlyph: View {
    let theme: AppTheme
    let zoomScale: Double
    var pointSizeBase: CGFloat = 14

    var body: some View {
        MonknotSystemGlyph(
            systemImage: "magnifyingglass",
            nominalPointSizeBase: pointSizeBase,
            theme: theme,
            zoomScale: zoomScale
        )
            .accessibilityHidden(true)
    }
}
