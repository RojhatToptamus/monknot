import MonknotCore
import SwiftUI

/// A group of Settings rows (design.md §12): the control `track` on the page, radius 12, no border,
/// as macOS groups a form. The PDF export sheet uses it too.
struct MonknotPanelCard<Content: View>: View {
    let theme: AppTheme
    let zoomScale: Double
    @ViewBuilder let content: () -> Content

    private var cornerRadius: CGFloat {
        theme.chromeRadius(12, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(theme.controlTrackFillColor)
        )
    }
}

typealias SettingsGroupCard = MonknotPanelCard

/// The layout every sheet uses (design.md §4.3, §5.3): 20 padding; a 13/600 title with an optional 12
/// `ink3` line under it; the sheet's content; then its push buttons at the sheet height of 30, trailing,
/// Cancel before the default action.
struct MonknotSheetLayout<Content: View, Buttons: View>: View {
    let title: String
    var message: String? = nil
    let theme: AppTheme
    let zoomScale: Double
    var width: CGFloat = 440
    @ViewBuilder let content: () -> Content
    @ViewBuilder let buttons: () -> Buttons

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(16)) {
            VStack(alignment: .leading, spacing: scaled(6)) {
                Text(title)
                    .font(MonknotTypography.panelTitle(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.foregroundColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                if let message {
                    Text(message)
                        .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                        .foregroundStyle(theme.tertiaryForegroundColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content()

            HStack(spacing: scaled(8)) {
                Spacer(minLength: 0)
                buttons()
            }
        }
        .padding(scaled(20))
        .frame(width: scaled(width))
        .background(theme.surfaceColor)
    }
}
