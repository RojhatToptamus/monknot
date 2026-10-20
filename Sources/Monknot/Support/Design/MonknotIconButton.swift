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

/// The one icon button (design.md §5.1), in two sizes, for every bar and every field in the app.
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
    /// Its menu or popover is showing: the `press` fill and an `ink` glyph until it closes (design.md
    /// §5.1), as a pop-up shows its open menu.
    var isOpen: Bool = false
    var isDisabled: Bool = false
    var size: IconButtonSize = .regular
    /// Off only for the search match options, whose "on" is an `accent` glyph with no fill
    /// (design.md §1.3, §5.1).
    var drawsActiveBackground = true
    var focusRingPlacement: FocusRingPlacement = .outside
    /// The unsaved dot on the glyph's corner (a Save button with changes to save).
    var showsDirtyDot = false
    /// Told when the button takes or loses keyboard focus (a switcher row keeps its Remove showing
    /// while Remove has focus).
    var onFocusChange: ((Bool) -> Void)?
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    /// Disabled by its own flag or by an enclosing `.disabled`, so a disabled bar draws its buttons
    /// at `ink4` rather than dimming the whole bar (design.md §5.1: no extra opacity).
    private var disabled: Bool {
        isDisabled || !isEnabled
    }

    enum FocusRingPlacement {
        case outside
        case contained
    }

    /// The two icon buttons (design.md §5.1). Every bar uses `regular`; a button inside a row or a
    /// field uses `small`. There is no third size.
    enum IconButtonSize {
        /// 28 box, 17 pt nominal glyph (optically capped): the titlebar, sidebar and panel headers,
        /// card bars such as the terminal header and the PDF toolbar.
        case regular
        /// 22 box, 13 pt glyph: match options and actions inside a field or a row.
        case small

        var dimensionBase: CGFloat {
            switch self {
            case .regular: return MonknotMetrics.iconButtonSizeBase
            case .small: return MonknotMetrics.smallIconButtonSizeBase
            }
        }

        var iconPointSizeBase: CGFloat {
            switch self {
            case .regular: return MonknotMetrics.iconPointSizeBase
            case .small: return MonknotMetrics.smallIconPointSizeBase
            }
        }

        var cornerRadiusBase: CGFloat {
            switch self {
            case .regular: return MonknotMetrics.iconCornerRadiusBase
            case .small: return 6
            }
        }

        func dimension(theme: AppTheme, zoomScale: Double) -> CGFloat {
            MonknotMetrics.interfaceControl(dimensionBase, theme: theme, zoomScale: zoomScale)
        }

        func height(theme: AppTheme, zoomScale: Double) -> CGFloat {
            dimension(theme: theme, zoomScale: zoomScale)
        }

        func iconSize(theme: AppTheme, zoomScale: Double) -> CGFloat {
            MonknotMetrics.interfaceGlyph(iconPointSizeBase, theme: theme, zoomScale: zoomScale)
        }

        func cornerRadius(theme: AppTheme, zoomScale: Double) -> CGFloat {
            theme.chromeRadius(cornerRadiusBase, zoomScale: zoomScale)
        }
    }

    /// The fill behind an icon button (design.md §5.1). Pressed replaces hover rather than stacking
    /// on it, and an open button holds the pressed fill; a button that is on takes the neutral `on`
    /// fill; a disabled button never fills.
    enum Fill: Equatable {
        case hover
        case pressed
        case on

        func color(_ theme: AppTheme) -> Color {
            switch self {
            case .hover: return theme.hoverFillColor
            case .pressed: return theme.pressedFillColor
            case .on: return theme.onFillColor
            }
        }
    }

    static func fill(
        isActive: Bool,
        isOpen: Bool = false,
        drawsActiveBackground: Bool,
        isHovered: Bool,
        isPressed: Bool,
        isDisabled: Bool
    ) -> Fill? {
        guard !isDisabled else { return nil }
        if isPressed || isOpen { return .pressed }
        if isActive, drawsActiveBackground { return .on }
        return isHovered ? .hover : nil
    }

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
                .monknotStateStyle(Self.iconColor(
                    theme: theme,
                    isActive: isActive,
                    isOpen: isOpen,
                    drawsActiveBackground: drawsActiveBackground,
                    isHovered: isHovered,
                    isDisabled: disabled
                ))
                .monknotDirtyDot(isVisible: showsDirtyDot && !disabled, theme: theme, zoomScale: zoomScale)
                .frame(
                    width: size.dimension(theme: theme, zoomScale: zoomScale),
                    height: size.height(theme: theme, zoomScale: zoomScale)
                )
                .overlay {
                    if Self.showsFocusRing(isFocused: isFocused, isDisabled: disabled) {
                        focusRing
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(MonknotIconButtonStyle(
            theme: theme,
            cornerRadius: cornerRadius,
            isActive: isActive,
            isOpen: isOpen,
            drawsActiveBackground: drawsActiveBackground,
            isHovered: isHovered,
            isDisabled: disabled
        ))
        .focusable(!disabled && NSApp.isFullKeyboardAccessEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
        .monknotPointerCursor(enabled: !disabled)
    }

    /// design.md §1.4: `ink3` at rest, `ink` when hovered, open or on, `ink4` disabled; only a search
    /// match option that is on turns its glyph `accent` (§1.3).
    static func iconColor(
        theme: AppTheme,
        isActive: Bool,
        isOpen: Bool = false,
        drawsActiveBackground: Bool = true,
        isHovered: Bool,
        isDisabled: Bool
    ) -> Color {
        if isDisabled {
            return theme.disabledForegroundColor
        }
        if isOpen {
            return theme.foregroundColor
        }
        if isActive {
            return drawsActiveBackground ? theme.foregroundColor : theme.accentColor
        }
        if isHovered {
            return theme.foregroundColor
        }
        return theme.tertiaryForegroundColor
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
    let isOpen: Bool
    let drawsActiveBackground: Bool
    let isHovered: Bool
    let isDisabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .monknotStateStyle(MonknotIconButton.fill(
                        isActive: isActive,
                        isOpen: isOpen,
                        drawsActiveBackground: drawsActiveBackground,
                        isHovered: isHovered,
                        isPressed: configuration.isPressed,
                        isDisabled: isDisabled
                    )?.color(theme) ?? .clear)
            }
    }
}

/// An icon button that opens a menu of commands ("More"): `MonknotIconButton` itself, so it hovers,
/// presses, takes focus and disables as every bar button does, and holds the `press` fill while its
/// menu, Monknot's own (§5.8), is open below it (design.md §5.1). Each group of commands follows a
/// separator.
struct MonknotMenuButton: View {
    let systemImage: String
    let label: String
    let theme: AppTheme
    let zoomScale: Double
    let commands: [[MonknotPopUpAction]]

    @State private var isMenuPresented = false

    var body: some View {
        MonknotIconButton(
            systemImage: systemImage,
            label: label,
            theme: theme,
            zoomScale: zoomScale,
            isOpen: isMenuPresented
        ) {
            isMenuPresented = true
        }
        .background(
            MonknotMenuPresenter(isPresented: $isMenuPresented, actionGroups: commands, theme: theme, zoomScale: zoomScale)
                .allowsHitTesting(false)
        )
    }
}

extension View {
    /// The unsaved dot (design.md §1.3, place 3): 6 pt `accent` on the glyph's bottom-trailing corner,
    /// knocking a 1.5 pt ring out of the glyph's strokes so it reads on any fill.
    func monknotDirtyDot(isVisible: Bool, theme: AppTheme, zoomScale: Double) -> some View {
        modifier(MonknotDirtyDot(isVisible: isVisible, theme: theme, zoomScale: zoomScale))
    }
}

private struct MonknotDirtyDot: ViewModifier {
    let isVisible: Bool
    let theme: AppTheme
    let zoomScale: Double

    func body(content: Content) -> some View {
        if isVisible {
            let dot = MonknotMetrics.interfaceGlyph(6, theme: theme, zoomScale: zoomScale)
            content
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .frame(width: dot + 3, height: dot + 3)
                        .offset(x: 1.5, y: 1.5)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: dot, height: dot)
                }
        } else {
            content
        }
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

/// The close and clear target: tabs, fields and banners (16 target, 9 pt xmark).
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
        MonknotMetrics.interfaceControl(MonknotMetrics.closeTargetSizeBase, theme: theme, zoomScale: zoomScale)
    }

    private var dimension: CGFloat {
        Self.dimension(theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(
                    size: MonknotMetrics.interfaceGlyph(MonknotMetrics.closeGlyphPointSizeBase, theme: theme, zoomScale: zoomScale),
                    weight: .semibold
                ))
                .monknotStateStyle(
                    isDisabled
                        ? theme.disabledForegroundColor
                        : (isHovered ? theme.foregroundColor : theme.mutedForegroundColor)
                )
                .frame(width: dimension, height: dimension)
                .background {
                    Circle().monknotStateStyle(fill)
                }
                .contentShape(Circle())
        }
        .buttonStyle(MonknotPressTrackingButtonStyle(isPressed: $isPressed))
        .focusEffectDisabled()
        .disabled(isDisabled || !isVisible)
        .allowsHitTesting(isVisible)
        .monknotStateOpacity(isVisible ? 1 : 0)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHidden(!isVisible)
        .monknotPointerCursor(enabled: isVisible && !isDisabled)
    }

    private var fill: Color {
        guard !isDisabled else { return .clear }
        if isPressed { return theme.pressedFillColor }
        return isHovered ? theme.hoverFillColor : .clear
    }
}
