import MonknotCore
import SwiftUI

struct ExternalDocumentChangeBanner: View {
    let isRemovedExternally: Bool
    let isSaving: Bool
    let theme: AppTheme
    let zoomScale: Double
    let reload: () -> Void
    let keepEditing: () -> Void
    let save: () -> Void

    private var message: String {
        if isRemovedExternally {
            return "This file was removed from the workspace while you have unsaved changes."
        }
        return "This file changed on disk while you have unsaved changes."
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(12)) {
            Image(systemName: isRemovedExternally ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: scaled(14), weight: .semibold))
                .foregroundStyle(theme.accentColor)

            Text(message)
                .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: scaled(8)) {
                if !isRemovedExternally {
                    bannerButton("Reload", role: .secondary) {
                        reload()
                    }
                }

                bannerButton("Keep Editing", role: .secondary) {
                    keepEditing()
                }

                MonknotAccentButton(
                    title: "Save",
                    theme: theme,
                    isDisabled: isSaving
                ) {
                    save()
                }
            }
        }
        .padding(.horizontal, scaled(14))
        .padding(.vertical, scaled(10))
        .background(
            RoundedRectangle(cornerRadius: theme.chromeRadius(10, zoomScale: zoomScale))
                .fill(theme.elevatedSurfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.chromeRadius(10, zoomScale: zoomScale))
                .strokeBorder(theme.accentColor.opacity(0.45), lineWidth: 1)
        )
        .padding(.horizontal, scaled(12))
        .padding(.top, scaled(8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

    @ViewBuilder
    private func bannerButton(_ title: String, role: BannerButtonRole, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(MonknotTypography.settingsButton(theme: theme))
            .foregroundStyle(theme.foregroundColor)
            .padding(.horizontal, scaled(12))
            .padding(.vertical, scaled(6))
            .background(
                RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                    .fill(role == .secondary ? theme.surfaceColor : theme.accentColor.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                    .strokeBorder(theme.borderColor, lineWidth: role == .secondary ? 1 : 0)
            )
            .buttonStyle(.plain)
            .monknotPointerCursor()
    }

    private enum BannerButtonRole {
        case secondary
    }
}
