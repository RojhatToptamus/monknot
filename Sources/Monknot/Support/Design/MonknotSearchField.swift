import MonknotCore
import SwiftUI

/// The search field's glyph: `magnifyingglass` sized as a picture beside the query (14 nominal), drawn
/// as the search buttons draw it.
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
