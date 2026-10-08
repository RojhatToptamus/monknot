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

/// The one empty state, for empty and unavailable surfaces: a 34 glyph in `ink3` (design.md §10.7: the
/// only glyphs above 17 are empty-state illustrations at 34), a 13/600 title, one 12 `ink3` line, and
/// the owner's actions. Actions are supplied by the owning feature so this view does not duplicate
/// product behavior or state.
struct MonknotEmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    let detail: String?
    let theme: AppTheme
    let zoomScale: Double
    @ViewBuilder let actions: () -> Actions

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(spacing: scaled(12)) {
            Image(systemName: systemImage)
                .font(.system(
                    size: MonknotMetrics.interfaceGlyph(34, theme: theme, zoomScale: zoomScale),
                    weight: .regular
                ))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(theme.tertiaryForegroundColor)
                .accessibilityHidden(true)

            VStack(spacing: scaled(4)) {
                Text(title)
                    .font(MonknotTypography.emptyStateTitle(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.foregroundColor)
                    .multilineTextAlignment(.center)

                if let detail {
                    Text(detail)
                        .font(MonknotTypography.emptyStateDetail(theme: theme, zoomScale: zoomScale))
                        .foregroundStyle(theme.tertiaryForegroundColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
            .accessibilityElement(children: .combine)

            actions()
                .padding(.top, scaled(4))
        }
        .frame(maxWidth: scaled(320))
        .padding(scaled(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A push button with its keyboard shortcut beside it as a quiet hint, for empty states.
struct MonknotShortcutActionButton: View {
    let title: String
    var role: MonknotActionRole = .primary
    let shortcut: String?
    let theme: AppTheme
    let zoomScale: Double
    let action: () -> Void

    var body: some View {
        HStack(spacing: MonknotMetrics.interfaceDensity(8, theme: theme, zoomScale: zoomScale)) {
            MonknotActionButton(
                title: title,
                role: role,
                theme: theme,
                zoomScale: zoomScale,
                size: .bar,
                action: action
            )
            if let shortcut {
                MonknotShortcutLabel(shortcut: shortcut, theme: theme, zoomScale: zoomScale)
            }
        }
    }
}
