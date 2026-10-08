import MonknotCore
import SwiftUI

struct MonknotRowButtonStyle: ButtonStyle {
    let theme: AppTheme
    let isSelected: Bool
    var isActive = false
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        MonknotRowButtonStyleBody(
            configuration: configuration,
            theme: theme,
            isSelected: isSelected,
            isActive: isActive,
            cornerRadius: cornerRadius
        )
    }

    private struct MonknotRowButtonStyleBody: View {
        let configuration: Configuration
        let theme: AppTheme
        let isSelected: Bool
        let isActive: Bool
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(background)
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .animation(MonknotMotion.hoverAnimation, value: isHovered)
                .animation(MonknotMotion.hoverAnimation, value: configuration.isPressed)
                .onHover { isHovered = $0 }
                .monknotPointerCursor(enabled: isEnabled)
        }

        private var background: Color {
            if isSelected {
                return theme.selectedRowColor
            }
            if configuration.isPressed {
                return theme.pressedFillColor
            }
            if isActive || isHovered {
                return theme.hoverFillColor
            }
            return .clear
        }

        private var foreground: Color {
            if !isEnabled, !isSelected {
                return theme.disabledForegroundColor
            }
            if isSelected || isActive || isHovered || configuration.isPressed {
                return theme.foregroundColor
            }
            return theme.mutedForegroundColor
        }
    }
}

struct MonknotListRow<Label: View>: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(MonknotRowButtonStyle(theme: theme, isSelected: isSelected))
        .monknotPointerCursor()
    }
}
