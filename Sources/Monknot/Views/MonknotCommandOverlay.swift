import MonknotCore
import SwiftUI

enum MonknotCommandOverlayMetrics {
    static let headerHeightBase: CGFloat = 44
    static let rowHeightBase: CGFloat = 34
    static let footerHeightBase: CGFloat = 30

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
            : visibleRows * rowHeightBase + (visibleRows - 1) * 2 + 12
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

/// An overlay's 44 header: a glyph, the query field at the size of every other field (13), and Close.
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
        HStack(spacing: scaled(8)) {
            MonknotSystemGlyph(systemImage: systemImage, nominalPointSizeBase: 15, theme: theme, zoomScale: zoomScale)
                .foregroundStyle(theme.mutedForegroundColor)
                .frame(width: scaled(MonknotMetrics.rowIconColumnWidthBase))
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
        .padding(.leading, scaled(16))
        .padding(.trailing, scaled(9))
        .frame(height: scaled(MonknotCommandOverlayMetrics.headerHeightBase))
    }
}

/// An overlay header with a title instead of a field.
struct MonknotCommandOverlayTitle: View {
    let title: String
    let theme: AppTheme
    let zoomScale: Double
    let close: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(8)) {
            Text(title)
                .font(.system(
                    size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale),
                    weight: .semibold
                ))
                .foregroundStyle(theme.foregroundColor)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            MonknotCommandOverlayCloseButton(theme: theme, zoomScale: zoomScale, close: close)
        }
        .padding(.leading, scaled(16))
        .padding(.trailing, scaled(9))
        .frame(height: scaled(MonknotCommandOverlayMetrics.headerHeightBase))
    }
}

/// A result row, 34 tall (design.md §5.7): a glyph or short tag in the 18 column, the title, a detail in
/// 12 `ink3` beside it, and an optional trailing note. Hover and selection are the shared row states.
struct MonknotCommandOverlayRow: View {
    enum Leading {
        case glyph(String)
        case tag(String)
    }

    let leading: Leading
    let title: String
    var detail: String? = nil
    var trailing: String? = nil
    let isSelected: Bool
    let theme: AppTheme
    let zoomScale: Double
    let action: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    private var secondaryFont: Font {
        .system(size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: scaled(8)) {
                switch leading {
                case .glyph(let systemImage):
                    MonknotFileKindGlyph(systemImage: systemImage, theme: theme, zoomScale: zoomScale)
                        .foregroundStyle(theme.tertiaryForegroundColor)
                case .tag(let tag):
                    Text(tag)
                        .font(secondaryFont)
                        .monospacedDigit()
                        .foregroundStyle(theme.tertiaryForegroundColor)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: scaled(MonknotMetrics.rowIconColumnWidthBase))
                }

                Text(title)
                    .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                    .lineLimit(1)
                    .layoutPriority(1)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(secondaryFont)
                        .foregroundStyle(theme.tertiaryForegroundColor)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: scaled(8))

                if let trailing {
                    Text(trailing)
                        .font(secondaryFont)
                        .monospacedDigit()
                        .foregroundStyle(theme.tertiaryForegroundColor)
                }
            }
            .padding(.horizontal, scaled(10))
            .frame(height: scaled(MonknotCommandOverlayMetrics.rowHeightBase))
            .contentShape(Rectangle())
        }
        .buttonStyle(MonknotRowButtonStyle(
            theme: theme,
            isSelected: isSelected,
            cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
        ))
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
    @ViewBuilder let row: (_ item: Item, _ isSelected: Bool) -> Row

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
                    LazyVStack(alignment: .leading, spacing: scaled(2)) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, index == selectedIndex)
                        }
                    }
                    .padding(scaled(6))
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

    var body: some View {
        HStack(spacing: scaled(16)) {
            ForEach(hints, id: \.self) { hint in
                HStack(spacing: scaled(6)) {
                    MonknotShortcutLabel(shortcut: hint.keys, theme: theme, zoomScale: zoomScale)
                    Text(hint.action)
                        .font(.system(size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale)))
                        .foregroundStyle(theme.tertiaryForegroundColor)
                }
                .accessibilityElement(children: .combine)
            }

            Spacer(minLength: 0)

            if let trailing {
                Text(trailing)
                    .font(.system(size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale)))
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiaryForegroundColor)
            }
        }
        .padding(.horizontal, scaled(16))
        .frame(height: scaled(MonknotCommandOverlayMetrics.footerHeightBase))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separatorColor).frame(height: 1)
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
                .font(.system(
                    size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale),
                    weight: .semibold
                ))
                .foregroundStyle(theme.foregroundColor)
            Text(message)
                .font(.system(
                    size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale),
                    weight: .regular
                ))
                .foregroundStyle(theme.tertiaryForegroundColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, scaled(14))
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
            size: .compact,
            action: close
        )
        .keyboardShortcut(.cancelAction)
    }
}
