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
                .strokeBorder(
                    theme.borderColor.opacity(isDisabled ? MonknotIconButton.disabledBorderOpacity : 1),
                    lineWidth: 1
                )
        )
    }
}

struct MonknotSegmentButton: View {
    static let focusRingLineWidth: CGFloat = 3
    static let focusRingOutset: CGFloat = 2
    static let focusRingOpacity = 0.35

    static func showsFocusRing(isFocused: Bool, isDisabled: Bool) -> Bool {
        isFocused && !isDisabled
    }

    let systemImage: String
    let accessibilityLabel: String
    let isSelected: Bool
    let theme: AppTheme
    let zoomScale: Double
    var isDisabled = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            MonknotSystemGlyph(
                systemImage: systemImage,
                nominalPointSizeBase: 16,
                theme: theme,
                zoomScale: zoomScale
            )
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
                .overlay {
                    if Self.showsFocusRing(isFocused: isFocused, isDisabled: isDisabled) {
                        RoundedRectangle(
                            cornerRadius: theme.chromeRadius(
                                6,
                                zoomScale: zoomScale
                            )
                        )
                        .stroke(
                            theme.accentColor.opacity(Self.focusRingOpacity),
                            lineWidth: Self.focusRingLineWidth
                        )
                        .padding(-Self.focusRingOutset)
                        .allowsHitTesting(false)
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
        .buttonStyle(MonknotPressTrackingButtonStyle(isPressed: $isPressed))
        .focusable(NSApp.isFullKeyboardAccessEnabled)
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
        if isDisabled {
            return theme.disabledForegroundColor
        }
        if isSelected {
            return theme.foregroundColor
        }
        return isHovered ? theme.foregroundColor : theme.mutedForegroundColor
    }

    private var background: Color {
        // A disabled control has no current mode to show (design.md §5.1).
        if isDisabled {
            return .clear
        }
        if isSelected {
            return theme.selectedRowColor
        }
        if isPressed {
            return theme.pressedFillColor
        }
        if isHovered {
            return theme.hoverFillColor
        }
        return .clear
    }
}
