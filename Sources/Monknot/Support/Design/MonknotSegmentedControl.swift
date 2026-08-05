import MonknotCore
import SwiftUI

struct MonknotSegmentOption: Identifiable {
    let id: String
    let systemImage: String
    let accessibilityLabel: String
}

struct MonknotSegmentedControl: View {
    let options: [MonknotSegmentOption]
    @Binding var selection: String
    let theme: AppTheme
    let zoomScale: Double
    var isDisabled = false

    var body: some View {
        HStack(spacing: MonknotMetrics.scale(2, theme: theme, zoomScale: zoomScale)) {
            ForEach(options) { option in
                MonknotSegmentButton(
                    systemImage: option.systemImage,
                    accessibilityLabel: option.accessibilityLabel,
                    isSelected: selection == option.id,
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: isDisabled,
                    action: { selection = option.id }
                )
            }
        }
        .padding(MonknotMetrics.scale(2, theme: theme, zoomScale: zoomScale))
        .overlay(
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                .strokeBorder(theme.borderColor, lineWidth: 1)
        )
        .opacity(isDisabled ? 0.40 : 1)
    }
}

struct MonknotSegmentButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let isSelected: Bool
    let theme: AppTheme
    let zoomScale: Double
    var isDisabled = false
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(
                    size: MonknotMetrics.interfaceGlyph(16, theme: theme, zoomScale: zoomScale),
                    weight: .regular
                ))
                .foregroundStyle(foreground)
                .frame(
                    width: MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale),
                    height: MonknotMetrics.interfaceControl(22, theme: theme, zoomScale: zoomScale)
                )
                .background(
                    background,
                    in: RoundedRectangle(
                        cornerRadius: theme.chromeRadius(
                            6,
                            zoomScale: zoomScale
                        )
                    )
                )
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: theme.chromeRadius(
                            6,
                            zoomScale: zoomScale
                        )
                    )
                )
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled()
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .animation(MonknotMotion.hoverAnimation, value: isSelected)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .monknotPointerCursor()
    }

    private var foreground: Color {
        if isSelected {
            return theme.foregroundColor
        }
        return isHovered ? theme.foregroundColor : theme.mutedForegroundColor
    }

    private var background: Color {
        if isSelected {
            return theme.selectedRowColor
        }
        if isHovered {
            return theme.foregroundColor.opacity(theme.isDark ? 0.06 : 0.055)
        }
        return .clear
    }
}
