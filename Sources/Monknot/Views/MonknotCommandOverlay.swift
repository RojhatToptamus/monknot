import MonknotCore
import SwiftUI

/// The overlay sheet's geometry (design.md §5.7): a 44 header, the editor's menu rows at 34 inside the
/// menu's 6 inset and 1 apart, and the menu's 32 footer. The header's glyph and query sit on the rows'
/// glyph and text columns (6 inset + 8 padding, then 18 + 10).
enum MonknotCommandOverlayMetrics {
    static let headerHeightBase: CGFloat = 44
    static let rowHeightBase: CGFloat = MonknotMetrics.overlayRowHeightBase
    static let footerHeightBase: CGFloat = 32
    static let rowGapBase: CGFloat = 1
    /// The rows' glyph column starts here, so the header's glyph and the footer's first hint do too.
    static let contentInsetBase: CGFloat = MonknotMetrics.menuListInsetBase + MonknotMetrics.menuRowPaddingBase

    /// The height that shows `rows` result rows (at most eight) under the header, plus the footer.
    static func panelHeight(
        rows: Int,
        hasFooter: Bool,
        theme: AppTheme,
        zoomScale: Double
    ) -> CGFloat {
        let visibleRows = CGFloat(min(rows, 8))
        let list = rows == 0
            ? 72
            : visibleRows * rowHeightBase + (visibleRows - 1) * rowGapBase + 2 * MonknotMetrics.menuListInsetBase
        // The footer draws its own separator inside its height.
        let footer = hasFooter && rows > 0 ? footerHeightBase : 0
        return MonknotMetrics.interfaceDensity(
            headerHeightBase + 1 + list + footer,
            theme: theme,
            zoomScale: zoomScale
        )
    }
}

/// The command overlays (Quick Open, Go to Heading, Go to Line, Choose Linked Note, Keyboard Shortcuts):
/// the theme scrim and a 16-radius sheet at `e3`, near the top of the window (design.md §2.1, §7).
struct MonknotCommandOverlay<Content: View>: View {
    let theme: AppTheme
    let zoomScale: Double
    let panelHeight: CGFloat
    var width: CGFloat = 560
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                theme.scrimColor
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)

                content()
                    .frame(
                        width: max(1, min(scaled(width), geometry.size.width - scaled(32))),
                        height: max(1, min(panelHeight, geometry.size.height - scaled(106))),
                        alignment: .top
                    )
                    .monknotFloatingSurface(
                        .e3,
                        cornerRadius: theme.chromeRadius(16, zoomScale: zoomScale),
                        fill: theme.elevatedSurfaceColor,
                        theme: theme
                    )
                    .padding(.top, scaled(74))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// An overlay's 44 header: a glyph in the rows' glyph column, the query (13, as every field) on their
/// text edge, and Close.
struct MonknotCommandOverlayField: View {
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding
    let theme: AppTheme
    let zoomScale: Double
    var accessibilityHint: String?
    let submit: () -> Void
    let close: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(MonknotMetrics.menuRowGlyphGapBase)) {
            MonknotFileKindGlyph(systemImage: systemImage, theme: theme, zoomScale: zoomScale)
                .foregroundStyle(theme.tertiaryForegroundColor)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(theme.foregroundColor)
                .accessibilityLabel(placeholder.trimmingCharacters(in: CharacterSet(charactersIn: "…")))
                .accessibilityHint(accessibilityHint ?? "")
                .onSubmit(submit)

            MonknotCommandOverlayCloseButton(theme: theme, zoomScale: zoomScale, close: close)
        }
        .modifier(MonknotCommandOverlayHeaderLayout(theme: theme, zoomScale: zoomScale))
    }
}

/// An overlay header with a title instead of a field, the title on the rows' text edge.
struct MonknotCommandOverlayTitle: View {
    let title: String
    let theme: AppTheme
    let zoomScale: Double
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(MonknotTypography.panelTitle(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(theme.foregroundColor)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            MonknotCommandOverlayCloseButton(theme: theme, zoomScale: zoomScale, close: close)
        }
        .modifier(MonknotCommandOverlayHeaderLayout(theme: theme, zoomScale: zoomScale))
    }
}

/// 44 tall: the content inset leading, and Close as far from the trailing edge as from the top.
private struct MonknotCommandOverlayHeaderLayout: ViewModifier {
    let theme: AppTheme
    let zoomScale: Double

    func body(content: Content) -> some View {
        let height = MonknotCommandOverlayMetrics.headerHeightBase
        let close = MonknotMetrics.smallIconButtonSizeBase
        content
            .padding(.leading, MonknotMetrics.interfaceDensity(MonknotCommandOverlayMetrics.contentInsetBase, theme: theme, zoomScale: zoomScale))
            .padding(.trailing, MonknotMetrics.interfaceDensity((height - close) / 2, theme: theme, zoomScale: zoomScale))
            .frame(height: MonknotMetrics.interfaceDensity(height, theme: theme, zoomScale: zoomScale))
    }
}

/// The line between an overlay's header, results and footer: `line2`, edge to edge.
struct MonknotCommandOverlaySeparator: View {
    let theme: AppTheme

    var body: some View {
        Rectangle()
            .fill(theme.separatorColor)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A result row: the editor's menu row at 34 (design.md §5.7), a glyph or short tag in the 18 column,
/// the title, a 12 `ink3` detail and an optional trailing note. The one highlight, which ↑↓ and the
/// pointer both move, is the `selected` fill and an `ink` glyph.
struct MonknotCommandOverlayRow: View {
    let leading: MonknotMenuRowLeading
    let title: String
    var detail: String? = nil
    var trailing: String? = nil
    let isSelected: Bool
    let theme: AppTheme
    let zoomScale: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MonknotMenuRowLabel(
                leading: leading,
                title: title,
                detail: detail,
                height: .overlay,
                isHighlighted: isSelected,
                theme: theme,
                zoomScale: zoomScale
            ) {
                if let trailing {
                    Text(trailing)
                        .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                        .monospacedDigit()
                        .foregroundStyle(theme.tertiaryForegroundColor)
                }
            }
        }
        .buttonStyle(MonknotMenuRowButtonStyle(theme: theme, zoomScale: zoomScale, isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// An overlay's results: the empty state while nothing matches, otherwise the rows, with the
/// selected one scrolled into view as ↑/↓ move it.
struct MonknotCommandOverlayResults<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let selectedIndex: Int
    let emptyTitle: String
    let emptyMessage: String
    let theme: AppTheme
    let zoomScale: Double
    /// The pointer moved onto the row at this index: it takes the highlight, so the pointer and the
    /// keys move one highlight (design.md §5.8).
    var hover: ((Int) -> Void)?
    @ViewBuilder let row: (_ item: Item, _ isSelected: Bool) -> Row
    /// Where the pointer was when it last moved the highlight. Rows scrolling under a pointer that
    /// holds still (↓ at the bottom of the list) must not take the highlight from the keys.
    @State private var lastPointer: CGPoint?

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        ScrollViewReader { proxy in
            MonknotScrollView(theme: theme) {
                if items.isEmpty {
                    MonknotCommandOverlayEmptyState(
                        title: emptyTitle,
                        message: emptyMessage,
                        theme: theme,
                        zoomScale: zoomScale
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: MonknotCommandOverlayMetrics.rowGapBase) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, index == selectedIndex)
                                .onContinuousHover { phase in
                                    guard case .active = phase, let hover else { return }
                                    let pointer = NSEvent.mouseLocation
                                    guard pointer != lastPointer else { return }
                                    lastPointer = pointer
                                    hover(index)
                                }
                        }
                    }
                    .padding(scaled(MonknotMetrics.menuListInsetBase))
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: selectedIndex) { _, index in
                if items.indices.contains(index) {
                    proxy.scrollTo(items[index].id)
                }
            }
        }
    }
}

/// Keyboard hints under a list: each key sequence as a quiet shortcut label with its action beside it
/// in plain text (design.md §4.4 keeps words out of the label), and an optional count at the end.
struct MonknotCommandOverlayFooter: View {
    struct Hint: Hashable {
        let keys: String
        let action: String
    }

    let hints: [Hint]
    var trailing: String? = nil
    let theme: AppTheme
    let zoomScale: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    /// The editor's menu footer (editor.css `.mk-menu-footer`): 32 tall, hints 14 apart, each key 5
    /// from its action, a `line2` rule above.
    var body: some View {
        HStack(spacing: scaled(14)) {
            ForEach(hints, id: \.self) { hint in
                HStack(spacing: scaled(5)) {
                    MonknotShortcutLabel(shortcut: hint.keys, theme: theme, zoomScale: zoomScale)
                    Text(hint.action)
                        .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                        .foregroundStyle(theme.tertiaryForegroundColor)
                }
                .accessibilityElement(children: .combine)
            }

            Spacer(minLength: 0)

            if let trailing {
                Text(trailing)
                    .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiaryForegroundColor)
            }
        }
        .padding(.horizontal, scaled(MonknotCommandOverlayMetrics.contentInsetBase))
        .frame(height: scaled(MonknotCommandOverlayMetrics.footerHeightBase))
        .overlay(alignment: .top) {
            MonknotCommandOverlaySeparator(theme: theme)
        }
    }
}

struct MonknotCommandOverlayEmptyState: View {
    let title: String
    let message: String
    let theme: AppTheme
    let zoomScale: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(4)) {
            Text(title)
                .font(MonknotTypography.panelTitle(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(theme.foregroundColor)
            Text(message)
                .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(theme.tertiaryForegroundColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, scaled(MonknotCommandOverlayMetrics.contentInsetBase))
        .padding(.vertical, scaled(16))
    }
}

/// Close for an overlay header: the standard close button. Escape closes the overlay too.
struct MonknotCommandOverlayCloseButton: View {
    let theme: AppTheme
    let zoomScale: Double
    let close: () -> Void

    var body: some View {
        MonknotIconButton(
            systemImage: "xmark",
            label: "Close",
            theme: theme,
            zoomScale: zoomScale,
            size: .small,
            action: close
        )
        .keyboardShortcut(.cancelAction)
    }
}
