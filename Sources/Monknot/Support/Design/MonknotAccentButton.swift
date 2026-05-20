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

    var body: some View {
        Button(title, action: action)
            .font(MonknotTypography.settingsButton(theme: theme))
            .foregroundStyle(theme.onAccentForegroundColor.opacity(isDisabled ? 0.5 : 1))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius)
                    .fill(theme.accentColor.opacity(isDisabled ? 0.45 : 1))
            )
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .monknotPointerCursor(enabled: !isDisabled)
    }
}
