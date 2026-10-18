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

/// The one segmented control (design.md §5.5): a `track` with 2 padding and 2 between cells, cells 24
/// tall, so the control is 28 like every control beside it. Icon cells are 28 wide; text cells pad 12.
/// The titlebar's view mode, the PDF tools and navigator, and Settings all use it.
struct MonknotSegmentedControl: View {
    let options: [MonknotSegmentOption]
    @Binding var selection: String
    let theme: AppTheme
    let zoomScale: Double
    var isDisabled = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: MonknotMetrics.scale(MonknotSegmentButton.cellGapBase, theme: theme, zoomScale: zoomScale)) {
            ForEach(options) { option in
                MonknotSegmentButton(
                    content: option.content,
                    accessibilityLabel: option.accessibilityLabel,
                    isSelected: selection == option.id,
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: isDisabled,
                    action: { selection = option.id }
                )
            }
        }
        .padding(MonknotMetrics.scale(MonknotSegmentButton.trackPaddingBase, theme: theme, zoomScale: zoomScale))
        // A track, not a border: the selected cell lifts out of it (design.md §5.5).
        .background(
            theme.controlTrackFillColor.opacity(isDisabled || !isEnabled ? 0.5 : 1),
            in: RoundedRectangle(cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale))
        )
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
    static let trackPaddingBase: CGFloat = 2
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
                    let shape = RoundedRectangle(cornerRadius: cellRadius)
                    // The selected cell is a chip lifted out of the track (design.md §5.5).
                    if isSelected, !disabled {
                        shape
                            .fill(background)
                            .shadow(color: theme.chipShadowColor, radius: 0.75, y: 1)
                            .overlay { shape.strokeBorder(theme.chipRingColor, lineWidth: 0.5) }
                    } else {
                        shape.fill(background)
                    }
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
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .animation(MonknotMotion.hoverAnimation, value: isSelected)
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
            .foregroundStyle(foreground)
            .frame(width: MonknotMetrics.interfaceControl(Self.iconCellWidthBase, theme: theme, zoomScale: zoomScale))
        case let .text(title):
            Text(title)
                .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(foreground)
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
            return theme.segmentSelectedFillColor
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
