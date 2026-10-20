import MonknotCore
import SwiftUI

/// What a menu row shows in its glyph column.
enum MonknotMenuRowLeading {
    case none
    case glyph(String)
    /// An empty glyph column, so a row without a glyph keeps its label on its siblings' edge.
    case blank
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
    /// The row ↑↓ has chosen: its glyph goes to `ink`, as in the editor's menus. The pointer's row
    /// rises the same way through `MonknotMenuRowButtonStyle`.
    var isHighlighted = false
    var isDisabled = false
    /// A command that destroys something (Move to Trash): highlighted, its label and glyph are
    /// `danger`, as in the editor's menus.
    var isDestructive = false
    let theme: AppTheme
    let zoomScale: Double
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.monknotRowIsHighlighted) private var isRowHighlighted

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
            case .blank:
                Color.clear
                    .frame(width: MonknotMetrics.interfaceGlyph(MonknotMetrics.rowIconColumnWidthBase, theme: theme, zoomScale: zoomScale), height: 1)
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
            .foregroundStyle(isDisabled ? theme.disabledForegroundColor : showsDanger ? theme.dangerColor : theme.foregroundColor)
            .lineLimit(1)
    }

    private var showsDanger: Bool {
        isDestructive && !isDisabled && (isHighlighted || isRowHighlighted)
    }

    private var glyphColor: Color {
        if isDisabled {
            return theme.disabledForegroundColor
        }
        if showsDanger {
            return theme.dangerColor
        }
        if isCurrent {
            return theme.accentColor
        }
        return isHighlighted || isRowHighlighted ? theme.foregroundColor : theme.mutedForegroundColor
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
        isDestructive: Bool = false,
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
            isDestructive: isDestructive,
            theme: theme,
            zoomScale: zoomScale,
            trailing: { EmptyView() }
        )
    }
}

/// A menu row's fills: the one highlight — the keyboard's row, or the row under the pointer — is the
/// `selected` fill, `press` while held, on the row's radius 8, applied at once as the keys move it
/// (design.md §5.8); a menu never trails the pointer. Highlighted or held, it tells
/// `MonknotMenuRowLabel` to raise its glyph to `ink`.
struct MonknotMenuRowButtonStyle: ButtonStyle {
    let theme: AppTheme
    let zoomScale: Double
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        MonknotMenuRowButtonStyleBody(
            configuration: configuration,
            theme: theme,
            isSelected: isSelected,
            cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)
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
                .environment(\.monknotRowIsHighlighted, isEnabled && (isHovered || configuration.isPressed))
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(fill)
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { isHovered = $0 }
        }

        /// Menu rows keep the arrow, as the system's menus do.
        private var fill: Color {
            if isSelected {
                return theme.chromeSelectedFillColor
            }
            guard isEnabled else { return .clear }
            if configuration.isPressed {
                return theme.pressedFillColor
            }
            return isHovered ? theme.chromeSelectedFillColor : .clear
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
    /// True while the pointer is over a row, the row is held down or its menu is open; its label and
    /// glyph then go to `ink` (design.md §1.4).
    @Entry var monknotRowIsHighlighted = false
}

/// Fills a list row (the sidebar and its header, Recents, Find in Workspace's results, Links, Settings'
/// sections): `selected` when selected, `press` while held or while its menu is open, `hover` under the
/// pointer, and tells the row's label (`MonknotListRowLabel`) when to raise its ink.
struct MonknotListRowButtonStyle: ButtonStyle {
    let theme: AppTheme
    let zoomScale: Double
    var isSelected = false
    /// Its popover or menu is showing (the workspace switcher): `press` and `ink` until it closes, as an
    /// open icon button or pop-up (design.md §5.1).
    var isOpen = false
    /// The row has a context menu: right-clicked, it holds its open state while the menu shows.
    var hasContextMenu = false
    /// Selected rows next to each other, in a list with no gap between rows, share one fill: the
    /// corners where a selected row meets another are square (design.md §10.4).
    var joinsSelectionAbove = false
    var joinsSelectionBelow = false

    /// design.md §1.4: the neutral `selected` fill when selected, otherwise `press` while held or open,
    /// then `hover`. A disabled row draws neither, so it never looks clickable, but keeps its selection.
    static func fill(
        theme: AppTheme,
        isSelected: Bool,
        isOpen: Bool = false,
        isHovered: Bool,
        isPressed: Bool,
        isEnabled: Bool
    ) -> Color {
        if isSelected {
            return theme.chromeSelectedFillColor
        }
        guard isEnabled else { return .clear }
        if isPressed || isOpen {
            return theme.pressedFillColor
        }
        return isHovered ? theme.hoverFillColor : .clear
    }

    func makeBody(configuration: Configuration) -> some View {
        RowBody(
            configuration: configuration,
            theme: theme,
            isSelected: isSelected,
            isOpen: isOpen,
            hasContextMenu: hasContextMenu,
            cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale),
            joinsAbove: isSelected && joinsSelectionAbove,
            joinsBelow: isSelected && joinsSelectionBelow
        )
    }

    private struct RowBody: View {
        let configuration: Configuration
        let theme: AppTheme
        let isSelected: Bool
        let isOpen: Bool
        let hasContextMenu: Bool
        let cornerRadius: CGFloat
        let joinsAbove: Bool
        let joinsBelow: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        @State private var holdsContextMenu = false
        @ObservedObject private var contextMenu = MonknotContextMenuController.shared

        var body: some View {
            // Fill and ink changes animate colour only, here and in the row's label, never a frame.
            configuration.label
                .environment(\.monknotRowIsHighlighted, isEnabled && (isHovered || configuration.isPressed || isShowingOpen))
                .background {
                    UnevenRoundedRectangle(cornerRadii: fillCornerRadii)
                        .monknotStateStyle(fill)
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { isHovered = $0 }
                .onChange(of: contextMenu.presentationID) { _, id in
                    // The row under the pointer as its menu opens is the one the menu acts on.
                    holdsContextMenu = hasContextMenu && id != nil && isHovered
                }
                .monknotPointerCursor(enabled: isEnabled)
        }

        private var isShowingOpen: Bool {
            isOpen || holdsContextMenu
        }

        private var fillCornerRadii: RectangleCornerRadii {
            RectangleCornerRadii(
                topLeading: joinsAbove ? 0 : cornerRadius,
                bottomLeading: joinsBelow ? 0 : cornerRadius,
                bottomTrailing: joinsBelow ? 0 : cornerRadius,
                topTrailing: joinsAbove ? 0 : cornerRadius
            )
        }

        private var fill: Color {
            MonknotListRowButtonStyle.fill(
                theme: theme,
                isSelected: isSelected,
                isOpen: isShowingOpen,
                isHovered: isHovered,
                isPressed: configuration.isPressed,
                isEnabled: isEnabled
            )
        }
    }
}

/// A folder or group's disclosure chevron in the 18 glyph column: one 10 pt chevron that turns a
/// quarter as the folder opens (120 ms ease-out; none with Reduce Motion). It is centred in the
/// column with no nudge: measured, its ink already sits on the file glyphs' centre line, and any
/// offset turns with it, so a nudge right would also drop the open chevron below the row's centre.
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
            // Only the turn animates. A value-keyed animation here would also animate the row's
            // move when the list lays out the folder's children in the same transaction, so the
            // chevron would draw at its old place and slide back.
            .animation(MonknotMotion.stateMotion(reduceMotion: reduceMotion)) {
                $0.rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
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
                .monknotStateStyle(glyphColor)
                .accessibilityHidden(true)

            Text(title)
                .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                .monknotStateStyle(labelColor)
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
