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

    var body: some View {
        HStack(spacing: MonknotMetrics.scale(2, theme: theme, zoomScale: zoomScale)) {
            ForEach(options) { option in
                MonknotSegmentButton(
                    systemImage: option.systemImage,
                    accessibilityLabel: option.accessibilityLabel,
                    isSelected: selection == option.id,
                    theme: theme,
                    zoomScale: zoomScale,
                    action: { selection = option.id }
                )
            }
        }
        .padding(MonknotMetrics.scale(2, theme: theme, zoomScale: zoomScale))
        .overlay(
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                .strokeBorder(theme.borderColor, lineWidth: 1)
        )
    }
}

struct MonknotSegmentButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let isSelected: Bool
    let theme: AppTheme
    let zoomScale: Double
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(
                    size: MonknotMetrics.chromeGlyphSize(theme: theme, zoomScale: zoomScale),
                    weight: .medium
                ))
                .foregroundStyle(foreground)
                .frame(
                    width: MonknotMetrics.chromeButtonDimension(theme: theme, zoomScale: zoomScale),
                    height: max(22, MonknotMetrics.interfaceControl(24, theme: theme, zoomScale: zoomScale))
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
                .overlay {
                    if isFocused {
                        RoundedRectangle(
                            cornerRadius: theme.chromeRadius(
                                6,
                                zoomScale: zoomScale
                            )
                        )
                        .strokeBorder(theme.accentColor.opacity(0.9), lineWidth: 1.5)
                        .padding(1)
                    }
                }
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
        if isHovered {
            return theme.foregroundColor.opacity(theme.isDark ? 0.06 : 0.055)
        }
        return .clear
    }
}
