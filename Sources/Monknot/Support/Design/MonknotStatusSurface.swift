import MonknotCore
import SwiftUI

/// Shared quiet state for empty and unavailable workspace surfaces.
/// Actions are supplied by the owning feature so this view does not duplicate
/// product behavior or state.
struct MonknotEmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    let detail: String?
    let theme: AppTheme
    let zoomScale: Double
    @ViewBuilder let actions: () -> Actions

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(spacing: scaled(14)) {
            Image(systemName: systemImage)
                .font(.system(size: scaled(28), weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(theme.mutedForegroundColor)
                .accessibilityHidden(true)

            VStack(spacing: scaled(5)) {
                Text(title)
                    .font(MonknotTypography.emptyStateTitle(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.foregroundColor)
                    .multilineTextAlignment(.center)

                if let detail {
                    Text(detail)
                        .font(MonknotTypography.emptyStateDetail(theme: theme, zoomScale: zoomScale))
                        .foregroundStyle(theme.mutedForegroundColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
            .accessibilityElement(children: .combine)

            actions()
        }
        .frame(maxWidth: scaled(360))
        .padding(scaled(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
