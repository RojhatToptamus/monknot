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
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false
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
                            weight: .semibold
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
            .frame(height: MonknotMetrics.interfaceControl(30, theme: theme, zoomScale: zoomScale))
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: borderWidth)
            }
            .overlay {
                if isFocused, !isDisabled {
                    shape
                        .strokeBorder(focusColor, lineWidth: 1.5)
                        .padding(1)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(
            MonknotActionButtonStyle(
                role: role,
                theme: theme,
                shape: shape,
                isHovered: isHovered,
                isDisabled: isDisabled
            )
        )
        .disabled(isDisabled)
        .focusable(!isDisabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .monknotPointerCursor(enabled: !isDisabled)
        .accessibilityLabel(title)
    }

    private var foregroundColor: Color {
        if isDisabled {
            return theme.foregroundColor.opacity(0.38)
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

    private var borderColor: Color {
        if isDisabled {
            return role == .quiet ? .clear : theme.borderColor
        }
        return role == .secondary ? theme.borderColor : .clear
    }

    private var borderWidth: CGFloat {
        if isDisabled {
            return role == .quiet ? 0 : 1
        }
        return role == .secondary ? 1 : 0
    }

    private var focusColor: Color {
        switch role {
        case .primary, .destructive:
            return theme.onAccentForegroundColor.opacity(0.92)
        case .secondary, .quiet:
            return theme.accentColor.opacity(0.92)
        }
    }
}

private struct MonknotActionButtonStyle: ButtonStyle {
    let role: MonknotActionRole
    let theme: AppTheme
    let shape: RoundedRectangle
    let isHovered: Bool
    let isDisabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                shape.fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .opacity(configuration.isPressed && !isDisabled ? 0.88 : 1)
            .animation(MonknotMotion.hoverAnimation, value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isDisabled {
            return role == .quiet ? .clear : theme.insetFillColor
        }

        let interactionStrength: Double
        if isPressed {
            interactionStrength = 0.82
        } else if isHovered {
            interactionStrength = 0.90
        } else {
            interactionStrength = 1
        }

        switch role {
        case .primary:
            return theme.accentColor.opacity(interactionStrength)
        case .destructive:
            return Color(hex: theme.semanticColors.diffRemoved).opacity(interactionStrength)
        case .secondary:
            if isPressed {
                return theme.foregroundColor.opacity(theme.isDark ? 0.11 : 0.08)
            }
            if isHovered {
                return theme.foregroundColor.opacity(theme.isDark ? 0.085 : 0.06)
            }
            return theme.insetFillColor
        case .quiet:
            guard isHovered || isPressed else { return .clear }
            return theme.foregroundColor.opacity(
                isPressed
                    ? (theme.isDark ? 0.10 : 0.07)
                    : (theme.isDark ? 0.065 : 0.048)
            )
        }
    }
}

struct MonknotAccentButton: View {
    let title: String
    let theme: AppTheme
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        MonknotActionButton(
            title: title,
            role: .primary,
            theme: theme,
            isDisabled: isDisabled,
            action: action
        )
    }
}
