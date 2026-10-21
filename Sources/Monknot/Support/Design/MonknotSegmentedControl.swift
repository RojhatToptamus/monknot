import MonknotCore
import SwiftUI

struct MonknotSegmentOption: Identifiable {
    let id: String
    let content: MonknotSegmentButton.Content
    let accessibilityLabel: String

    init(id: String, systemImage: String, accessibilityLabel: String) {
        self.id = id
        self.content = .symbol(systemImage)
        self.accessibilityLabel = accessibilityLabel
    }

    init(id: String, title: String) {
        self.id = id
        self.content = .text(title)
        self.accessibilityLabel = title
    }
}

/// The one segmented control (design.md §5.5): cells 24 tall on a `track` 28 tall, like every control
/// beside it, 2 between cells and the track's padding what the two heights leave, so the outer box is
/// one rounding of 28 at every zoom. Icon cells are 28 wide; text cells pad 12. The titlebar's view
/// mode, the PDF tools and navigator, the text style popover and Settings all use it. It chooses one
/// option (a mode), or with `toggled` turns each option on and off on its own (Bold and Italic).
struct MonknotSegmentedControl: View {
    let options: [MonknotSegmentOption]
    let theme: AppTheme
    let zoomScale: Double
    var isDisabled = false
    private let isSelected: (String) -> Bool
    private let choose: (String) -> Void
    @Environment(\.isEnabled) private var isEnabled

    /// One option at a time: choosing a cell selects it.
    init(
        options: [MonknotSegmentOption],
        selection: Binding<String>,
        theme: AppTheme,
        zoomScale: Double,
        isDisabled: Bool = false
    ) {
        self.options = options
        self.theme = theme
        self.zoomScale = zoomScale
        self.isDisabled = isDisabled
        self.isSelected = { selection.wrappedValue == $0 }
        self.choose = { selection.wrappedValue = $0 }
    }

    /// Independent toggles on one track: each cell turns its own option on or off.
    init(
        options: [MonknotSegmentOption],
        toggled: Binding<Set<String>>,
        theme: AppTheme,
        zoomScale: Double,
        isDisabled: Bool = false
    ) {
        self.options = options
        self.theme = theme
        self.zoomScale = zoomScale
        self.isDisabled = isDisabled
        self.isSelected = { toggled.wrappedValue.contains($0) }
        self.choose = { id in
            if toggled.wrappedValue.contains(id) {
                toggled.wrappedValue.remove(id)
            } else {
                toggled.wrappedValue.insert(id)
            }
        }
    }

    /// The track's padding: half of what a 24 cell leaves of the 28 control, each height rounded once,
    /// so the track lands on the same 28 as a button, a pop-up or a tab (design.md §9.3).
    static func trackPadding(theme: AppTheme, zoomScale: Double) -> CGFloat {
        (MonknotMetrics.interfaceControl(MonknotMetrics.iconButtonSizeBase, theme: theme, zoomScale: zoomScale)
            - MonknotMetrics.interfaceControl(MonknotSegmentButton.cellHeightBase, theme: theme, zoomScale: zoomScale)) / 2
    }

    var body: some View {
        HStack(spacing: MonknotMetrics.interfaceDensity(MonknotSegmentButton.cellGapBase, theme: theme, zoomScale: zoomScale)) {
            ForEach(options) { option in
                MonknotSegmentButton(
                    content: option.content,
                    accessibilityLabel: option.accessibilityLabel,
                    isSelected: isSelected(option.id),
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: isDisabled,
                    action: { choose(option.id) }
                )
            }
        }
        .padding(.horizontal, Self.trackPadding(theme: theme, zoomScale: zoomScale))
        .frame(height: MonknotMetrics.interfaceControl(MonknotMetrics.iconButtonSizeBase, theme: theme, zoomScale: zoomScale))
        // A track, not a border: the selected cell lifts out of it (design.md §5.5).
        .background(
            theme.controlTrackFillColor.opacity(isDisabled || !isEnabled ? 0.5 : 1),
            in: RoundedRectangle(cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale))
        )
    }
}

/// The chip (design.md §5.5, §10.3): the active tab on the chrome and a selected segment, lifted out of
/// what holds it — the `chip` fill, a 1 pt `chipring` hairline, and in light themes the one-point
/// `chipseat` under it (radius 0.75, y 1).
struct MonknotChip: View {
    let cornerRadius: CGFloat
    let theme: AppTheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape
            .fill(theme.chipFillColor)
            .shadow(color: theme.chipShadowColor, radius: 0.75, y: 1)
            .overlay { shape.strokeBorder(theme.chipRingColor, lineWidth: 1) }
    }
}

struct MonknotSegmentButton: View {
    enum Content: Equatable {
        case symbol(String)
        case text(String)
    }

    static let cellHeightBase: CGFloat = 24
    static let iconCellWidthBase: CGFloat = 28
    static let textCellPaddingBase: CGFloat = 12
    static let cellRadiusBase: CGFloat = 6
    static let cellGapBase: CGFloat = 2
    static let glyphPointSizeBase: CGFloat = 16

    static func showsFocusRing(isFocused: Bool, isDisabled: Bool) -> Bool {
        isFocused && !isDisabled
    }

    let content: Content
    let accessibilityLabel: String
    let isSelected: Bool
    let theme: AppTheme
    let zoomScale: Double
    var isDisabled = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    /// Disabled by its own flag or by an enclosing `.disabled`.
    private var disabled: Bool {
        isDisabled || !isEnabled
    }

    init(
        content: Content,
        accessibilityLabel: String,
        isSelected: Bool,
        theme: AppTheme,
        zoomScale: Double,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.content = content
        self.accessibilityLabel = accessibilityLabel
        self.isSelected = isSelected
        self.theme = theme
        self.zoomScale = zoomScale
        self.isDisabled = isDisabled
        self.action = action
    }

    init(
        systemImage: String,
        accessibilityLabel: String,
        isSelected: Bool,
        theme: AppTheme,
        zoomScale: Double,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            content: .symbol(systemImage),
            accessibilityLabel: accessibilityLabel,
            isSelected: isSelected,
            theme: theme,
            zoomScale: zoomScale,
            isDisabled: isDisabled,
            action: action
        )
    }

    private var cellRadius: CGFloat {
        theme.chromeRadius(Self.cellRadiusBase, zoomScale: zoomScale)
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(height: MonknotMetrics.interfaceControl(Self.cellHeightBase, theme: theme, zoomScale: zoomScale))
                .background {
                    // The selected cell is the chip lifted out of the track (design.md §5.5); it fades
                    // in and out whole.
                    MonknotChip(cornerRadius: cellRadius, theme: theme)
                        .monknotStateOpacity(isSelected && !disabled ? 1 : 0)
                    RoundedRectangle(cornerRadius: cellRadius).monknotStateStyle(background)
                }
                .monknotFocusRing(
                    isVisible: Self.showsFocusRing(isFocused: isFocused, isDisabled: disabled),
                    cornerRadius: cellRadius,
                    theme: theme
                )
                .contentShape(RoundedRectangle(cornerRadius: cellRadius))
        }
        .buttonStyle(MonknotPressTrackingButtonStyle(isPressed: $isPressed))
        .focusable(NSApp.isFullKeyboardAccessEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .help(content.isSymbol ? accessibilityLabel : "")
        .accessibilityLabel(accessibilityLabel)
        // Disabled, the control shows no current mode, so it reports none either.
        .accessibilityAddTraits(isSelected && !disabled ? .isSelected : [])
        .monknotPointerCursor(enabled: !disabled)
    }

    @ViewBuilder
    private var label: some View {
        switch content {
        case let .symbol(systemImage):
            MonknotSystemGlyph(
                systemImage: systemImage,
                nominalPointSizeBase: Self.glyphPointSizeBase,
                theme: theme,
                zoomScale: zoomScale
            )
            .monknotStateStyle(foreground)
            .frame(width: MonknotMetrics.interfaceControl(Self.iconCellWidthBase, theme: theme, zoomScale: zoomScale))
        case let .text(title):
            Text(title)
                .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                .monknotStateStyle(foreground)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, MonknotMetrics.interfaceDensity(Self.textCellPaddingBase, theme: theme, zoomScale: zoomScale))
        }
    }

    /// design.md §1.4: a glyph rests at `ink3` and a word at `ink2`; both go to `ink` hovered or
    /// selected; a disabled control is `ink4` throughout.
    private var foreground: Color {
        if disabled {
            return theme.disabledForegroundColor
        }
        if isSelected || isHovered {
            return theme.foregroundColor
        }
        return content.isSymbol ? theme.tertiaryForegroundColor : theme.mutedForegroundColor
    }

    private var background: Color {
        // A disabled control has no current mode to show (design.md §5.1).
        if disabled {
            return .clear
        }
        if isSelected {
            // The chip draws the selected fill.
            return .clear
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

private extension MonknotSegmentButton.Content {
    var isSymbol: Bool {
        if case .symbol = self { return true }
        return false
    }
}
