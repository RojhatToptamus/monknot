import MonknotCore
import SwiftUI

extension AppTheme {
    var onAccentForegroundColor: Color {
        guard let rgb = RGBHex(accent) else {
            return foregroundColor
        }
        return rgb.relativeLuminance > 0.55 ? Color(hex: "#1a1c1f") : Color(hex: "#fcfcfc")
    }
}

struct MonknotAccentButton: View {
    let title: String
    let theme: AppTheme
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(title, action: action)
            .font(MonknotTypography.settingsButton(theme: theme))
            .foregroundStyle(
                isDisabled
                    ? theme.mutedForegroundColor.opacity(0.72)
                    : theme.onAccentForegroundColor
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                    .fill(
                        isDisabled
                            ? theme.insetFillColor
                            : theme.accentColor.opacity(isHovered ? 0.9 : 1)
                    )
            )
            .overlay {
                if isDisabled {
                    RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                        .strokeBorder(theme.borderColor, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .onHover { isHovered = $0 }
            .animation(MonknotMotion.hoverAnimation, value: isHovered)
            .monknotPointerCursor(enabled: !isDisabled)
    }
}
