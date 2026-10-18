import MonknotCore
import SwiftUI

struct MonknotRowButtonStyle: ButtonStyle {
    let theme: AppTheme
    let isSelected: Bool
    var isActive = false
    var cornerRadius: CGFloat = 8

    /// design.md §5.1: `sel` when selected, otherwise press, then hover. A disabled row draws neither,
    /// so it never looks clickable; a label that sets its own ink must also switch to `ink4` itself.
    static func fill(
        theme: AppTheme,
        isSelected: Bool,
        isActive: Bool,
        isHovered: Bool,
        isPressed: Bool,
        isEnabled: Bool
    ) -> Color {
        // A neutral fill, like a highlighted menu row in the editor (design.md §1.4).
        if isSelected {
            return theme.chromeSelectedFillColor
        }
        guard isEnabled else { return .clear }
        if isPressed {
            return theme.pressedFillColor
        }
        if isActive || isHovered {
            return theme.hoverFillColor
        }
        return .clear
    }

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
            // Fill and ink changes animate colour only, never a frame.
            configuration.label
                .animation(MonknotMotion.hoverAnimation) { $0.foregroundStyle(foreground) }
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .animation(MonknotMotion.hoverAnimation) { $0.foregroundStyle(background) }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { isHovered = $0 }
                .monknotPointerCursor(enabled: isEnabled)
        }

        private var background: Color {
            MonknotRowButtonStyle.fill(
                theme: theme,
                isSelected: isSelected,
                isActive: isActive,
                isHovered: isHovered,
                isPressed: configuration.isPressed,
                isEnabled: isEnabled
            )
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
