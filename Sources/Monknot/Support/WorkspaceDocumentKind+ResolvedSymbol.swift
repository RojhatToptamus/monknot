import MonknotCore
import SwiftUI

/// One file-kind glyph primitive for tabs, sidebar rows, and document lists.
/// The symbol's optical size is independent from its stable layout column.
struct MonknotFileKindGlyph: View {
    let systemImage: String
    let theme: AppTheme
    let zoomScale: Double
    var pointSizeBase: CGFloat = MonknotMetrics.sidebarIconPointSizeBase

    var body: some View {
        MonknotSystemGlyph(
            systemImage: systemImage,
            nominalPointSizeBase: pointSizeBase,
            theme: theme,
            zoomScale: zoomScale
        )
            .frame(width: MonknotMetrics.interfaceGlyph(
                MonknotMetrics.rowIconColumnWidthBase,
                theme: theme,
                zoomScale: zoomScale
            ))
    }
}

extension EditorMode {
    var resolvedSystemImage: String {
        switch self {
        case .source:
            return MonknotSFSymbol.resolve("text.alignleft", fallback: systemImage)
        case .preview:
            return MonknotSFSymbol.resolve("eye", fallback: systemImage)
        }
    }
}
