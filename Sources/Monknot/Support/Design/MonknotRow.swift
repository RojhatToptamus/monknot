import MonknotCore
import SwiftUI

struct MonknotRowButtonStyle: ButtonStyle {
    let theme: AppTheme
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        MonknotRowButtonStyleBody(configuration: configuration, theme: theme, isSelected: isSelected)
    }

    private struct MonknotRowButtonStyleBody: View {
        let configuration: Configuration
        let theme: AppTheme
        let isSelected: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(background)
                .animation(MonknotMotion.hoverAnimation, value: isHovered)
                .onHover { isHovered = $0 }
        }

        private var background: Color {
            if isSelected {
                return theme.selectedRowColor
            }
            if configuration.isPressed || isHovered {
                return theme.foregroundColor.opacity(theme.isDark ? 0.06 : 0.04)
            }
            return .clear
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
