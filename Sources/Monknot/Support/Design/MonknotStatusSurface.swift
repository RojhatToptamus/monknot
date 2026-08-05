import MonknotCore
import SwiftUI

struct MonknotProgressIndicator: View {
    let size: CGFloat
    let theme: AppTheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let turns = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 0.9) / 0.9

            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(
                    theme.mutedForegroundColor,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(reduceMotion ? 0 : turns * 360))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Shared quiet state for empty and unavailable workspace surfaces.
/// Actions are supplied by the owning feature so this view does not duplicate
/// product behavior or state.
struct MonknotEmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    let detail: String?
    let theme: AppTheme
    let zoomScale: Double
    var iconSize: CGFloat = 28
    @ViewBuilder let actions: () -> Actions

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(spacing: scaled(14)) {
            Image(systemName: systemImage)
                .font(.system(size: scaled(iconSize), weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(theme.disabledForegroundColor)
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
