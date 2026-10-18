import MonknotCore
import SwiftUI

struct MonknotRowButtonStyle: ButtonStyle {
    let theme: AppTheme
    let isSelected: Bool
    var isActive = false
    var cornerRadius: CGFloat = 8

    /// design.md §5.1: `sel` when selected, otherwise press, then hover. A disabled row draws neither,
    /// so it never looks clickable; a label that sets its own ink must also switch to `ink4` itself.
    static func fill(
        theme: AppTheme,
        isSelected: Bool,
        isActive: Bool,
        isHovered: Bool,
        isPressed: Bool,
        isEnabled: Bool
    ) -> Color {
        // A neutral fill, like a highlighted menu row in the editor (design.md §1.4).
        if isSelected {
            return theme.chromeSelectedFillColor
        }
        guard isEnabled else { return .clear }
        if isPressed {
            return theme.pressedFillColor
        }
        if isActive || isHovered {
            return theme.hoverFillColor
        }
        return .clear
    }

    func makeBody(configuration: Configuration) -> some View {
        MonknotRowButtonStyleBody(
            configuration: configuration,
            theme: theme,
            isSelected: isSelected,
            isActive: isActive,
            cornerRadius: cornerRadius
        )
    }

    private struct MonknotRowButtonStyleBody: View {
        let configuration: Configuration
        let theme: AppTheme
        let isSelected: Bool
        let isActive: Bool
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            // Fill and ink changes animate colour only, never a frame.
            configuration.label
                .animation(MonknotMotion.hoverAnimation) { $0.foregroundStyle(foreground) }
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .animation(MonknotMotion.hoverAnimation) { $0.foregroundStyle(background) }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { isHovered = $0 }
                .monknotPointerCursor(enabled: isEnabled)
        }

        private var background: Color {
            MonknotRowButtonStyle.fill(
                theme: theme,
                isSelected: isSelected,
                isActive: isActive,
                isHovered: isHovered,
                isPressed: configuration.isPressed,
                isEnabled: isEnabled
            )
        }

        private var foreground: Color {
            if !isEnabled, !isSelected {
                return theme.disabledForegroundColor
            }
            if isSelected || isActive || isHovered || configuration.isPressed {
                return theme.foregroundColor
            }
            return theme.mutedForegroundColor
        }
    }
}

struct MonknotListRow<Label: View>: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(MonknotRowButtonStyle(theme: theme, isSelected: isSelected))
        .monknotPointerCursor()
    }
}

/// What a menu row shows in its glyph column.
enum MonknotMenuRowLeading {
    case none
    case glyph(String)
    /// A short text in the glyph column, such as a line number.
    case tag(String)
}

/// A menu row is 30 tall in a popover and 34 in an overlay.
enum MonknotMenuRowHeight {
    case menu
    case overlay

    var base: CGFloat {
        switch self {
        case .menu: return MonknotMetrics.menuRowHeightBase
        case .overlay: return MonknotMetrics.overlayRowHeightBase
        }
    }
}

/// The menu row (design.md §0; editor.css `.mk-menu-row`), for popovers and overlays: 8 padding, a 15
/// glyph in the 18 column at `ink2`, 10 gap, a 13 label at full `ink` as a native menu item's, then a
/// 12 `ink3` detail and a trailing slot. 30 tall in a popover, 34 in an overlay.
struct MonknotMenuRowLabel<Trailing: View>: View {
    typealias Leading = MonknotMenuRowLeading
    typealias Height = MonknotMenuRowHeight

    let leading: Leading
    let title: String
    var detail: String?
    var height: Height = .menu
    /// Extra leading indent, for nested items such as lower headings.
    var indentBase: CGFloat = 0
    /// The current item (the open workspace): an `accent` glyph (design.md §1.3, place 2).
    var isCurrent = false
    /// The row ↑↓ or the pointer has chosen: its glyph goes to `ink`, as in the editor's menus.
    var isHighlighted = false
    var isDisabled = false
    let theme: AppTheme
    let zoomScale: Double
    @ViewBuilder var trailing: () -> Trailing

    private func density(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: density(MonknotMetrics.menuRowGlyphGapBase)) {
            switch leading {
            case .none:
                EmptyView()
            case .glyph(let systemImage):
                MonknotFileKindGlyph(systemImage: systemImage, theme: theme, zoomScale: zoomScale)
                    .foregroundStyle(glyphColor)
                    .accessibilityHidden(true)
            case .tag(let tag):
                Text(tag)
                    .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                    .monospacedDigit()
                    .foregroundStyle(isDisabled ? theme.disabledForegroundColor : theme.tertiaryForegroundColor)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: MonknotMetrics.interfaceGlyph(MonknotMetrics.rowIconColumnWidthBase, theme: theme, zoomScale: zoomScale))
            }

            if let detail, !detail.isEmpty {
                // The detail only beside the whole title, and only with room to read: a clipped stub of
                // a path is noise, so a long title shows alone.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: density(MonknotMetrics.menuRowGlyphGapBase)) {
                        titleText
                            .fixedSize()
                        Text(detail)
                            .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                            .foregroundStyle(isDisabled ? theme.disabledForegroundColor : theme.tertiaryForegroundColor)
                            .lineLimit(1)
                            .truncationMode(.head)
                            // Its ideal is its minimum, so it shows, truncated, wherever 48 is left.
                            .frame(minWidth: density(48), idealWidth: density(48), alignment: .leading)
                    }
                    titleText
                }
                .layoutPriority(1)
            } else {
                titleText
                    .layoutPriority(1)
            }

            Spacer(minLength: density(8))

            trailing()
        }
        .padding(.leading, density(MonknotMetrics.menuRowPaddingBase + indentBase))
        .padding(.trailing, density(MonknotMetrics.menuRowPaddingBase))
        .frame(height: density(height.base))
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        Text(title)
            .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
            .foregroundStyle(isDisabled ? theme.disabledForegroundColor : theme.foregroundColor)
            .lineLimit(1)
    }

    private var glyphColor: Color {
        if isDisabled {
            return theme.disabledForegroundColor
        }
        if isCurrent {
            return theme.accentColor
        }
        return isHighlighted ? theme.foregroundColor : theme.mutedForegroundColor
    }
}

extension MonknotMenuRowLabel where Trailing == EmptyView {
    init(
        leading: Leading,
        title: String,
        detail: String? = nil,
        height: Height = .menu,
        indentBase: CGFloat = 0,
        isCurrent: Bool = false,
        isHighlighted: Bool = false,
        isDisabled: Bool = false,
        theme: AppTheme,
        zoomScale: Double
    ) {
        self.init(
            leading: leading,
            title: title,
            detail: detail,
            height: height,
            indentBase: indentBase,
            isCurrent: isCurrent,
            isHighlighted: isHighlighted,
            isDisabled: isDisabled,
            theme: theme,
            zoomScale: zoomScale,
            trailing: { EmptyView() }
        )
    }
}

/// A menu row's fills: `selected` for the current or keyboard-chosen row, `press` while held and the
/// `hover` (highlight) fill under the pointer. Its ink is the label's own (`MonknotMenuRowLabel`).
struct MonknotMenuRowButtonStyle: ButtonStyle {
    let theme: AppTheme
    var isSelected = false
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        MonknotMenuRowButtonStyleBody(
            configuration: configuration,
            theme: theme,
            isSelected: isSelected,
            cornerRadius: cornerRadius
        )
    }

    private struct MonknotMenuRowButtonStyleBody: View {
        let configuration: Configuration
        let theme: AppTheme
        let isSelected: Bool
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .animation(MonknotMotion.hoverAnimation) { $0.foregroundStyle(fill) }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { isHovered = $0 }
                .monknotPointerCursor(enabled: isEnabled)
        }

        private var fill: Color {
            if isSelected {
                return theme.chromeSelectedFillColor
            }
            guard isEnabled else { return .clear }
            if configuration.isPressed {
                return theme.pressedFillColor
            }
            return isHovered ? theme.hoverFillColor : .clear
        }
    }
}

/// A menu's group header (editor.css `.mk-menu-group`): 12 `ink3`, sentence case, 10 from the row
/// edge, 4 above the first group and 10 above the others, 6 above its rows.
struct MonknotMenuGroupHeader: View {
    let title: String
    var isFirst = true
    /// 10, so the header lines up with the rows' glyphs; 8 over rows without glyphs, on their text.
    var leadingPaddingBase: CGFloat = 10
    let theme: AppTheme
    let zoomScale: Double

    var body: some View {
        Text(title)
            .font(MonknotTypography.groupHeader(theme: theme, zoomScale: zoomScale))
            .foregroundStyle(theme.tertiaryForegroundColor)
            .padding(.horizontal, MonknotMetrics.interfaceDensity(leadingPaddingBase, theme: theme, zoomScale: zoomScale))
            .padding(.top, MonknotMetrics.interfaceDensity(isFirst ? 4 : 10, theme: theme, zoomScale: zoomScale))
            .padding(.bottom, MonknotMetrics.interfaceDensity(6, theme: theme, zoomScale: zoomScale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A menu's separator (editor.css `.mk-menu-separator`): a `line2` hairline 4 inside the list inset,
/// 6 above and below.
struct MonknotMenuSeparator: View {
    let theme: AppTheme
    let zoomScale: Double

    var body: some View {
        Rectangle()
            .fill(theme.separatorColor)
            .frame(height: 1)
            .padding(.horizontal, MonknotMetrics.interfaceDensity(4, theme: theme, zoomScale: zoomScale))
            .padding(.vertical, MonknotMetrics.interfaceDensity(6, theme: theme, zoomScale: zoomScale))
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// True while the pointer is over a list row or the row is held down; its label and glyph then go
    /// to `ink` (design.md §1.4).
    @Entry var monknotRowIsHighlighted = false
}

/// Fills a list row (the sidebar, Recents, Settings' sections): `selected` when selected, `press` while
/// held, `hover` under the pointer, and tells `MonknotListRowLabel` when to raise its ink.
struct MonknotListRowButtonStyle: ButtonStyle {
    let theme: AppTheme
    let zoomScale: Double
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        RowBody(
            configuration: configuration,
            theme: theme,
            isSelected: isSelected,
            cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)
        )
    }

    private struct RowBody: View {
        let configuration: Configuration
        let theme: AppTheme
        let isSelected: Bool
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            // Fill and ink changes animate colour only, here and in MonknotListRowLabel, never a frame.
            configuration.label
                .environment(\.monknotRowIsHighlighted, isEnabled && (isHovered || configuration.isPressed))
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .animation(MonknotMotion.hoverAnimation) { $0.foregroundStyle(fill) }
                }
                .onHover { isHovered = $0 }
                .monknotPointerCursor(enabled: isEnabled)
        }

        private var fill: Color {
            MonknotRowButtonStyle.fill(
                theme: theme,
                isSelected: isSelected,
                isActive: false,
                isHovered: isHovered,
                isPressed: configuration.isPressed,
                isEnabled: isEnabled
            )
        }
    }
}

/// A folder or group's disclosure chevron in the 18 glyph column: one 10 pt chevron that turns a
/// quarter as the folder opens (150 ms ease-out; none with Reduce Motion), nudged per design.md §8.6:
/// the right chevron's ink sits left of centre in its box.
struct MonknotDisclosureChevron: View {
    let isExpanded: Bool
    let theme: AppTheme
    let zoomScale: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func glyphScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceGlyph(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: glyphScaled(MonknotMetrics.chevronPointSizeBase), weight: .semibold))
            .offset(x: glyphScaled(0.5))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isExpanded)
            .frame(width: glyphScaled(MonknotMetrics.rowIconColumnWidthBase))
            .accessibilityHidden(true)
    }
}

/// What a list row shows in its glyph column.
enum MonknotListRowGlyph {
    case disclosure(isExpanded: Bool)
    case kind(systemImage: String)
}

/// The list row (design.md §0, §10.4): 28 tall, 8 padding plus 14 per depth, a glyph in the 18 column,
/// 8 gap, a 13 / 400 label. A folder's disclosure chevron takes the glyph column, so every row has one
/// glyph, names at one depth share an edge, and a child steps right by one indent. The label rests at
/// `ink2` and the glyph at `ink3`; hovered or held both go to `ink`; the selected row's label is `ink`
/// and its glyph `accent` (§1.3); disabled, both are `ink4`. Quiet Sidebar subdues all of it.
struct MonknotListRowLabel<Trailing: View>: View {
    let leading: MonknotListRowGlyph
    let title: String
    var depth = 0
    var isSelected = false
    /// A file's save state, drawn on its kind glyph as a tab draws it.
    var status: MonknotDocumentStatus = .clean
    let theme: AppTheme
    let zoomScale: Double
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.monknotRowIsHighlighted) private var isHighlighted
    @Environment(\.isEnabled) private var isEnabled

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(MonknotMetrics.rowGlyphGapBase)) {
            leadingGlyph
                .animation(MonknotMotion.hoverAnimation) { $0.foregroundStyle(glyphColor) }
                .accessibilityHidden(true)

            Text(title)
                .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                .animation(MonknotMotion.hoverAnimation) { $0.foregroundStyle(labelColor) }
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .padding(.leading, scaled(MonknotMetrics.rowPaddingBase) + CGFloat(depth) * scaled(MonknotMetrics.rowIndentBase))
        .padding(.trailing, scaled(MonknotMetrics.rowPaddingBase))
        .frame(height: scaled(MonknotMetrics.rowHeightBase))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        switch leading {
        case .disclosure(let isExpanded):
            MonknotDisclosureChevron(isExpanded: isExpanded, theme: theme, zoomScale: zoomScale)
        case .kind(let systemImage):
            MonknotDocumentGlyph(systemImage: systemImage, status: status, color: glyphColor, theme: theme, zoomScale: zoomScale)
        }
    }

    private var labelColor: Color {
        guard isEnabled || isSelected else { return theme.disabledForegroundColor }
        return theme.sidebarColor(
            theme.foregroundColor,
            opacity: isSelected || isHighlighted ? 1 : theme.labelInkOpacity
        )
    }

    private var glyphColor: Color {
        if isSelected {
            return theme.sidebarColor(theme.accentColor)
        }
        guard isEnabled else { return theme.disabledForegroundColor }
        return theme.sidebarColor(
            theme.foregroundColor,
            opacity: isHighlighted ? 1 : theme.glyphInkOpacity
        )
    }
}

extension MonknotListRowLabel where Trailing == EmptyView {
    init(
        leading: MonknotListRowGlyph,
        title: String,
        depth: Int = 0,
        isSelected: Bool = false,
        status: MonknotDocumentStatus = .clean,
        theme: AppTheme,
        zoomScale: Double
    ) {
        self.init(
            leading: leading,
            title: title,
            depth: depth,
            isSelected: isSelected,
            status: status,
            theme: theme,
            zoomScale: zoomScale,
            trailing: { EmptyView() }
        )
    }
}
