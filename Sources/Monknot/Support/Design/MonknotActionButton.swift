import MonknotCore
import SwiftUI

extension AppTheme {
    var onAccentForegroundColor: Color {
        Color(hex: onAccentForegroundHex)
    }
}

enum MonknotActionRole {
    case primary
    case destructive
    case secondary
    case quiet
}

enum MonknotActionButtonSize {
    case bar
    case sheet

    var heightBase: CGFloat {
        switch self {
        case .bar: return 28
        case .sheet: return 30
        }
    }
}

/// A compact macOS action with an explicit semantic role.
///
/// This keeps primary, secondary, and quiet text actions on the same geometry
/// and interaction model without replacing native menu, toolbar, or destructive
/// confirmation controls. Role color is applied once so disabled and secondary
/// labels don't disappear through stacked opacity modifiers.
struct MonknotActionButton: View {
    let title: String
    var systemImage: String? = nil
    let role: MonknotActionRole
    let theme: AppTheme
    var zoomScale: Double = 1
    var size: MonknotActionButtonSize = .sheet
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false
    @FocusState private var isFocused: Bool

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: scaled(MonknotMetrics.Spacing.xs)) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(
                            size: MonknotMetrics.interfaceGlyph(11, theme: theme, zoomScale: zoomScale),
                            weight: .regular
                        ))
                        .accessibilityHidden(true)
                }

                Text(title)
                    .lineLimit(1)
            }
            .font(.system(
                size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale),
                weight: .regular
            ))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, scaled(MonknotMetrics.Spacing.l))
            .frame(height: MonknotMetrics.interfaceControl(size.heightBase, theme: theme, zoomScale: zoomScale))
            .background {
                shape.fill(backgroundColor)
                // design.md §5.3: hover and pressed tint the button's own fill; they never replace it.
                if let stateFill {
                    shape.fill(stateFill)
                }
            }
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: borderWidth)
            }
            .monknotFocusRing(isVisible: isFocused && !isDisabled, cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale), theme: theme)
            .contentShape(shape)
        }
        .buttonStyle(MonknotPressTrackingButtonStyle(isPressed: $isPressed))
        .disabled(isDisabled)
        .focusable(!isDisabled && NSApp.isFullKeyboardAccessEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .monknotPointerCursor(enabled: !isDisabled)
        .accessibilityLabel(title)
    }

    private var foregroundColor: Color {
        if isDisabled {
            return theme.disabledForegroundColor
        }

        switch role {
        case .primary, .destructive:
            return theme.onAccentForegroundColor
        case .secondary:
            return theme.foregroundColor.opacity(0.88)
        case .quiet:
            return theme.foregroundColor.opacity(0.72)
        }
    }

    // Push buttons are fills, never outlines (design.md §5.3).
    private var borderColor: Color { .clear }

    private var borderWidth: CGFloat { 0 }

    private var backgroundColor: Color {
        if isDisabled {
            return role == .quiet ? .clear : theme.controlTrackFillColor.opacity(0.5)
        }

        switch role {
        case .primary:
            return theme.accentColor
        case .destructive:
            return Color(hex: theme.semanticColors.diffRemoved)
        case .secondary:
            return theme.secondaryButtonFillColor
        case .quiet:
            return .clear
        }
    }

    private var stateFill: Color? {
        guard !isDisabled else { return nil }
        if isPressed {
            return theme.pressedFillColor
        }
        return isHovered ? theme.hoverFillColor : nil
    }
}
