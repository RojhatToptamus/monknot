import MonknotCore
import SwiftUI

extension View {
    /// The keyboard focus ring, design.md §3: 3 pt `accent` at 35 % outside the control's box, in
    /// addition to its own border and never part of layout.
    func monknotFocusRing(isVisible: Bool, cornerRadius: CGFloat, theme: AppTheme) -> some View {
        overlay {
            if isVisible {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        theme.accentColor.opacity(MonknotIconButton.focusRingOpacity),
                        lineWidth: MonknotIconButton.focusRingLineWidth
                    )
                    .padding(-MonknotIconButton.focusRingOutset)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Installs help only when a meaningful inactive-control hint exists.
    /// Passing `nil` avoids creating an empty tooltip surface.
    @ViewBuilder
    func monknotHelp(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            help(text)
        } else {
            self
        }
    }
}

/// Shared chrome/toolbar icon button used across sidebar, top bar, PDF, and find UI.
struct MonknotIconButton: View {
    static let focusRingLineWidth: CGFloat = 3
    static let focusRingOutset: CGFloat = 2
    static let focusRingOpacity = 0.35

    static func showsFocusRing(isFocused: Bool, isDisabled: Bool) -> Bool {
        isFocused && !isDisabled
    }

    let systemImage: String
    let label: String
    let theme: AppTheme
    let zoomScale: Double
    var isActive: Bool = false
    var isDisabled: Bool = false
    var size: IconButtonSize = .chrome
    var drawsBorder = false
    var drawsActiveBackground = true
    var focusRingPlacement: FocusRingPlacement = .outside
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    enum FocusRingPlacement {
        case outside
        case contained
    }

    enum IconButtonSize {
        case chrome
        case windowNavigation
        case sidebarHeader
        case compact
        case settings
        case smallAction
        case editorToolbar
        case findBar

        func dimension(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome:
                return MonknotMetrics.chromeButtonDimension(theme: theme, zoomScale: zoomScale)
            case .windowNavigation, .settings, .findBar:
                return MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale)
            case .compact:
                return MonknotMetrics.interfaceControl(26, theme: theme, zoomScale: zoomScale)
            case .sidebarHeader, .smallAction:
                return MonknotMetrics.interfaceControl(22, theme: theme, zoomScale: zoomScale)
            case .editorToolbar:
                return MonknotMetrics.interfaceControl(30, theme: theme, zoomScale: zoomScale)
            }
        }

        func height(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .windowNavigation:
                return MonknotMetrics.interfaceControl(22, theme: theme, zoomScale: zoomScale)
            case .chrome, .sidebarHeader, .compact, .settings, .smallAction, .editorToolbar, .findBar:
                return dimension(theme: theme, zoomScale: zoomScale)
            }
        }

        func iconSize(theme: AppTheme, zoomScale: Double) -> CGFloat {
            MonknotMetrics.interfaceGlyph(
                iconPointSizeBase,
                theme: theme,
                zoomScale: zoomScale
            )
        }

        var iconPointSizeBase: CGFloat {
            switch self {
            case .chrome:
                return MonknotMetrics.iconPointSizeBase
            case .windowNavigation, .sidebarHeader, .compact:
                return 16
            case .settings:
                return 15
            case .smallAction:
                return 11
            case .findBar, .editorToolbar:
                return 17
            }
        }

        func cornerRadius(theme: AppTheme, zoomScale: Double) -> CGFloat {
            switch self {
            case .chrome, .sidebarHeader, .compact, .settings, .smallAction, .editorToolbar, .findBar:
                return theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)
            case .windowNavigation:
                return theme.chromeRadius(6, zoomScale: zoomScale)
            }
        }
    }

    /// The fill behind an icon button (design.md §5.1). Pressed replaces hover rather than stacking
    /// on it; an open panel's toggle is `accsoft`; a disabled button never fills.
    enum Fill: Equatable {
        case hover
        case pressed
        case accentSoft

        func color(_ theme: AppTheme) -> Color {
            switch self {
            case .hover: return theme.hoverFillColor
            case .pressed: return theme.pressedFillColor
            case .accentSoft: return theme.accentSoftFillColor
            }
        }
    }

    static func fill(
        isActive: Bool,
        drawsActiveBackground: Bool,
        isHovered: Bool,
        isPressed: Bool,
        isDisabled: Bool
    ) -> Fill? {
        guard !isDisabled else { return nil }
        if isPressed { return .pressed }
        if isActive, drawsActiveBackground { return .accentSoft }
        return isHovered ? .hover : nil
    }

    /// A disabled button keeps its border at this opacity; its glyph is `ink4` (design.md §5.1).
    static let disabledBorderOpacity = 0.4

    private var cornerRadius: CGFloat {
        size.cornerRadius(theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Button(action: action) {
            MonknotSystemGlyph(
                systemImage: systemImage,
                nominalPointSizeBase: size.iconPointSizeBase,
                theme: theme,
                zoomScale: zoomScale
            )
                .foregroundStyle(iconColor)
                .frame(
                    width: size.dimension(theme: theme, zoomScale: zoomScale),
                    height: size.height(theme: theme, zoomScale: zoomScale)
                )
                .overlay {
                    if Self.showsFocusRing(isFocused: isFocused, isDisabled: isDisabled) {
                        focusRing
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(MonknotIconButtonStyle(
            theme: theme,
            cornerRadius: cornerRadius,
            isActive: isActive,
            drawsActiveBackground: drawsActiveBackground,
            isHovered: isHovered,
            isDisabled: isDisabled
        ))
        .focusable(!isDisabled && NSApp.isFullKeyboardAccessEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .disabled(isDisabled)
        .overlay {
            // The border is structure: it never turns accent with state (design.md §5.2).
            if drawsBorder {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        theme.borderColor.opacity(isDisabled ? Self.disabledBorderOpacity : 1),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
        }
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .animation(MonknotMotion.hoverAnimation, value: isActive)
        .help(label)
        .accessibilityLabel(label)
        .monknotPointerCursor(enabled: !isDisabled)
    }

    private var iconColor: Color {
        if isDisabled {
            return theme.disabledForegroundColor
        }
        if isActive {
            return theme.accentColor
        }
        if isHovered {
            return theme.foregroundColor
        }
        return theme.mutedForegroundColor
    }

    @ViewBuilder
    private var focusRing: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let color = theme.accentColor.opacity(Self.focusRingOpacity)
        switch focusRingPlacement {
        case .outside:
            shape
                .stroke(color, lineWidth: Self.focusRingLineWidth)
                .padding(-Self.focusRingOutset)
                .allowsHitTesting(false)
        case .contained:
            shape
                .strokeBorder(color, lineWidth: Self.focusRingLineWidth)
                .allowsHitTesting(false)
        }
    }
}

/// Draws the icon button's one fill, so that pressed can replace hover (the style alone sees the press).
private struct MonknotIconButtonStyle: ButtonStyle {
    let theme: AppTheme
    let cornerRadius: CGFloat
    let isActive: Bool
    let drawsActiveBackground: Bool
    let isHovered: Bool
    let isDisabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if let fill = MonknotIconButton.fill(
                    isActive: isActive,
                    drawsActiveBackground: drawsActiveBackground,
                    isHovered: isHovered,
                    isPressed: configuration.isPressed,
                    isDisabled: isDisabled
                ) {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(fill.color(theme))
                }
            }
            .animation(MonknotMotion.hoverAnimation, value: configuration.isPressed)
    }
}

/// A plain button style that reports its pressed state, for views that draw their own fill around more
/// than the button's label (a tab chip, a row with trailing controls).
struct MonknotPressTrackingButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
    }
}

/// Shared trailing close affordance for document and terminal tabs.
struct MonknotTabCloseButton: View {
    let label: String
    let theme: AppTheme
    let zoomScale: Double
    var isVisible = true
    var isDisabled = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    static func dimension(theme: AppTheme, zoomScale: Double) -> CGFloat {
        MonknotMetrics.interfaceControl(16, theme: theme, zoomScale: zoomScale)
    }

    private var dimension: CGFloat {
        Self.dimension(theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(
                    size: MonknotMetrics.interfaceGlyph(11, theme: theme, zoomScale: zoomScale),
                    weight: .regular
                ))
                .foregroundStyle(isHovered ? theme.foregroundColor : theme.tertiaryForegroundColor)
                .frame(width: dimension, height: dimension)
                .background {
                    if isPressed {
                        Circle().fill(theme.pressedFillColor)
                    } else if isHovered {
                        Circle().fill(theme.hoverFillColor)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(MonknotPressTrackingButtonStyle(isPressed: $isPressed))
        .focusEffectDisabled()
        .disabled(isDisabled || !isVisible)
        .opacity(isVisible ? 1 : 0)
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHidden(!isVisible)
        .monknotPointerCursor(enabled: isVisible && !isDisabled)
    }
}
