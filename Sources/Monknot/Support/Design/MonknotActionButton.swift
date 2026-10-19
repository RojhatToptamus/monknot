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
            // design.md §5.4: a 14 glyph in a 16 column, 7 to the label, 10 leading and 12 trailing,
            // because the glyph's own side bearing already adds space on its side.
            HStack(spacing: scaled(7)) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(
                            size: MonknotMetrics.interfaceGlyph(14, theme: theme, zoomScale: zoomScale),
                            weight: .regular
                        ))
                        .frame(width: MonknotMetrics.interfaceGlyph(16, theme: theme, zoomScale: zoomScale))
                        .accessibilityHidden(true)
                }

                Text(title)
                    .lineLimit(1)
            }
            .font(.system(
                size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale),
                weight: .regular
            ))
            .monknotStateStyle(foregroundColor)
            .padding(.leading, scaled(systemImage == nil ? MonknotMetrics.Spacing.l : 10))
            .padding(.trailing, scaled(MonknotMetrics.Spacing.l))
            .frame(height: MonknotMetrics.interfaceControl(size.heightBase, theme: theme, zoomScale: zoomScale))
            .background {
                shape.monknotStateStyle(backgroundColor)
                // design.md §5.3: hover and pressed tint the button's own fill; they never replace it.
                shape.monknotStateStyle(stateFill ?? .clear)
            }
            // Push buttons are fills, never outlines (design.md §5.3).
            .monknotFocusRing(isVisible: isFocused && !isDisabled, cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale), theme: theme)
            .contentShape(shape)
        }
        .buttonStyle(MonknotPressTrackingButtonStyle(isPressed: $isPressed))
        .disabled(isDisabled)
        .focusable(!isDisabled && NSApp.isFullKeyboardAccessEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
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
        // design.md §1.4: a push button's word is `ink`; a quiet one rests at `ink2`.
        case .secondary:
            return theme.foregroundColor
        case .quiet:
            return isHovered ? theme.foregroundColor : theme.mutedForegroundColor
        }
    }

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
