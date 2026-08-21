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

struct MonknotSearchField: View {
    let placeholder: String
    @Binding var text: String
    let theme: AppTheme
    let zoomScale: Double
    var onSubmit: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: MonknotMetrics.scale(MonknotMetrics.Spacing.s, theme: theme, zoomScale: zoomScale)) {
            MonknotSearchGlyph(
                theme: theme,
                zoomScale: zoomScale,
                pointSizeBase: 12
            )
                .foregroundStyle(theme.mutedForegroundColor)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(MonknotTypography.chromeLabel(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(theme.foregroundColor)
                .focused($isFocused)
                .onSubmit { onSubmit?() }

            if !text.isEmpty || onCancel != nil {
                MonknotIconButton(
                    systemImage: "xmark.circle.fill",
                    label: "Clear Search",
                    theme: theme,
                    zoomScale: zoomScale,
                    size: .compact,
                    action: {
                        text = ""
                        onCancel?()
                    }
                )
            }
        }
        .padding(.horizontal, MonknotMetrics.scale(MonknotMetrics.Spacing.l, theme: theme, zoomScale: zoomScale))
        .padding(.vertical, MonknotMetrics.scale(MonknotMetrics.Spacing.s, theme: theme, zoomScale: zoomScale))
        .background(
            RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale))
                .fill(theme.insetFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale))
                .strokeBorder(theme.borderColor, lineWidth: 1)
        )
        .onAppear { isFocused = true }
    }
}
