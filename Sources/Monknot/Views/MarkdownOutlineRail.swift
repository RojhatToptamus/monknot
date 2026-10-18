import MonknotCore
import SwiftUI

enum MarkdownOutlineRailLayout {
    /// A nil anchor asks SwiftUI to move only enough to reveal the target.
    static let revealAnchor: UnitPoint? = nil

    static func activeIndex(
        forVisibleLine visibleLine: Int,
        items: [MarkdownOutlineItem]
    ) -> Int? {
        guard !items.isEmpty else { return nil }
        return items.lastIndex(where: { $0.location.line <= visibleLine }) ?? 0
    }

    static func leadingIndent(forHeadingLevel level: Int) -> CGFloat {
        CGFloat(max(0, min(5, level - 1))) * 7
    }

    static func markerWidth(forHeadingLevel level: Int) -> CGFloat {
        switch max(1, min(6, level)) {
        case 1: 24
        case 2: 20
        case 3: 16
        case 4: 13
        case 5: 10
        default: 8
        }
    }

    static func revealTargetID(
        hoveredItemID: String?,
        focusedItemID: String?,
        activeItemID: String?
    ) -> String? {
        hoveredItemID ?? focusedItemID ?? activeItemID
    }
}

/// The source line at the top of the visible document. Only the outline rail observes it, so scroll
/// ticks don't re-render the editor pane.
@MainActor
final class MarkdownOutlinePosition: ObservableObject {
    @Published private(set) var visibleLine = 1
    /// The document `visibleLine` was reported for.
    private(set) var documentID: String?

    func update(_ line: Int, documentID: String?) {
        self.documentID = documentID
        guard line != visibleLine else { return }
        visibleLine = line
    }

    /// The line last shown at the top of `documentID`, if this position belongs to it.
    func visibleLine(in documentID: String) -> Int? {
        self.documentID == documentID ? visibleLine : nil
    }
}

/// The rail is redrawn when its headings, theme or zoom change, not on every keystroke in the editor
/// pane around it. The visible line is observed one level down, so scrolling still moves the current
/// marker. `select` forwards to the pane and is not compared; `documentID` stands in for it.
struct MarkdownOutlineRail: View, Equatable {
    let documentID: String
    let items: [MarkdownOutlineItem]
    let position: MarkdownOutlinePosition
    let theme: AppTheme
    let zoomScale: Double
    let select: (MarkdownOutlineItem) -> Void

    nonisolated static func == (lhs: MarkdownOutlineRail, rhs: MarkdownOutlineRail) -> Bool {
        MainActor.assumeIsolated {
            lhs.documentID == rhs.documentID &&
                lhs.position === rhs.position &&
                lhs.zoomScale == rhs.zoomScale &&
                lhs.items == rhs.items &&
                lhs.theme == rhs.theme
        }
    }

    var body: some View {
        MarkdownOutlineRailContent(
            items: items,
            position: position,
            theme: theme,
            zoomScale: zoomScale,
            select: select
        )
    }
}

private struct MarkdownOutlineRailContent: View {
    let items: [MarkdownOutlineItem]
    @ObservedObject var position: MarkdownOutlinePosition
    let theme: AppTheme
    let zoomScale: Double
    let select: (MarkdownOutlineItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var hoveredMarkerID: String?
    @FocusState private var focusedMarkerID: String?

    private var activeIndex: Int? {
        MarkdownOutlineRailLayout.activeIndex(
            forVisibleLine: position.visibleLine,
            items: items
        )
    }

    private var activeItemID: String? {
        guard let activeIndex else { return nil }
        return items[activeIndex].id
    }

    private var isExpanded: Bool {
        isHovered || focusedMarkerID != nil
    }

    private var railWidth: CGFloat { scaled(38) }
    private var panelWidth: CGFloat { scaled(228) }
    private var panelGap: CGFloat { scaled(8) }
    private var contentEdgeInset: CGFloat { scaled(10) }

    private var totalWidth: CGFloat {
        contentEdgeInset + railWidth + (isExpanded ? panelGap + panelWidth : 0)
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: panelGap) {
                if isExpanded {
                    MarkdownOutlineHoverPanel(
                        items: items,
                        activeItemID: activeItemID,
                        revealedItemID: MarkdownOutlineRailLayout.revealTargetID(
                            hoveredItemID: hoveredMarkerID,
                            focusedItemID: focusedMarkerID,
                            activeItemID: activeItemID
                        ),
                        theme: theme,
                        zoomScale: zoomScale,
                        width: panelWidth,
                        maximumHeight: max(0, proxy.size.height - scaled(24)),
                        select: select
                    )
                    .transition(.opacity)
                }

                markerRail
            }
            .padding(.trailing, contentEdgeInset)
            .frame(
                width: totalWidth,
                height: proxy.size.height,
                alignment: .trailing
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
        .frame(width: totalWidth)
        .animation(
            MonknotMotion.outlineAnimation(reduceMotion: reduceMotion),
            value: isExpanded
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document outline")
    }

    private var markerRail: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: scaled(1)) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            markerButton(
                                for: item,
                                isActive: index == activeIndex
                            )
                            .id(item.id)
                        }
                    }
                    .padding(.vertical, scaled(6))
                    .frame(minHeight: proxy.size.height, alignment: .center)
                }
                .onAppear {
                    scrollToActiveMarker(using: scrollProxy, animated: false)
                }
                .onChange(of: activeItemID) { _, _ in
                    scrollToActiveMarker(using: scrollProxy, animated: true)
                }
            }
        }
        .frame(width: railWidth)
        .frame(maxHeight: .infinity)
    }

    private func markerButton(
        for item: MarkdownOutlineItem,
        isActive: Bool
    ) -> some View {
        let isHighlighted = hoveredMarkerID == item.id || focusedMarkerID == item.id

        return Button {
            select(item)
        } label: {
            HStack(spacing: 0) {
                Spacer(minLength: 0)

                Capsule()
                    .fill(markerColor(isActive: isActive, isHighlighted: isHighlighted))
                    .frame(
                        width: scaled(MarkdownOutlineRailLayout.markerWidth(
                            forHeadingLevel: item.level
                        )),
                        height: scaled(2.5)
                    )
            }
                .frame(width: railWidth, height: scaled(11))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(NSApp.isFullKeyboardAccessEnabled)
        .focused($focusedMarkerID, equals: item.id)
        .focusEffectDisabled()
        .onHover { hovering in
            hoveredMarkerID = hovering ? item.id : nil
        }
        .help(item.title)
        .accessibilityLabel("Go to heading: \(item.title)")
        .accessibilityValue("Heading level \(item.level), line \(item.location.line)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .monknotPointerCursor()
    }

    private func scrollToActiveMarker(using proxy: ScrollViewProxy, animated: Bool) {
        guard let activeItemID else { return }
        scroll(
            to: activeItemID,
            using: proxy,
            animated: animated
        )
    }

    private func scroll(to itemID: String, using proxy: ScrollViewProxy, animated: Bool) {
        if animated, let animation = MonknotMotion.outlineAnimation(reduceMotion: reduceMotion) {
            withAnimation(animation) {
                proxy.scrollTo(itemID, anchor: MarkdownOutlineRailLayout.revealAnchor)
            }
        } else {
            proxy.scrollTo(itemID, anchor: MarkdownOutlineRailLayout.revealAnchor)
        }
    }

    /// design.md §10.5: the current section's dash is `accent`, the others `ink3`; under the pointer or
    /// focus a dash goes to `ink`.
    private func markerColor(isActive: Bool, isHighlighted: Bool) -> Color {
        if isActive {
            return theme.accentColor
        }
        if isHighlighted {
            return theme.foregroundColor
        }
        return theme.tertiaryForegroundColor
    }
}

private struct MarkdownOutlineHoverPanel: View {
    let items: [MarkdownOutlineItem]
    let activeItemID: String?
    let revealedItemID: String?
    let theme: AppTheme
    let zoomScale: Double
    let width: CGFloat
    let maximumHeight: CGFloat
    let select: (MarkdownOutlineItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    /// The group header, up to eight menu rows 1 apart, and the menu's inset above and below.
    private var preferredHeight: CGFloat {
        let visibleRows = CGFloat(min(items.count, 8))
        return scaled(
            28 + visibleRows * MonknotMetrics.menuRowHeightBase + max(0, visibleRows - 1)
                + 2 * MonknotMetrics.menuListInsetBase
        )
    }

    private var panelHeight: CGFloat {
        min(maximumHeight, preferredHeight)
    }

    /// The peek card is one of the editor's menus (design.md §10.5): a group header with the heading
    /// count, then a menu row per heading, indented by level, with its line number; the heading at the
    /// reading position is the selected row.
    var body: some View {
        ScrollViewReader { scrollProxy in
            let lineNumberWidthTemplate = lineNumberWidthTemplate
            MonknotScrollView(theme: theme) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        MonknotMenuGroupHeader(title: "Outline", theme: theme, zoomScale: zoomScale)
                        Text("\(items.count)")
                            .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                            .monospacedDigit()
                            .foregroundStyle(theme.tertiaryForegroundColor)
                            .padding(.trailing, scaled(MonknotMetrics.menuRowPaddingBase))
                            .padding(.top, scaled(4))
                            .padding(.bottom, scaled(6))
                            .accessibilityLabel("\(items.count) headings")
                    }

                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(items) { item in
                            outlineRow(for: item, lineNumberWidthTemplate: lineNumberWidthTemplate)
                                .id(item.id)
                        }
                    }
                }
                .padding(scaled(MonknotMetrics.menuListInsetBase))
            }
            .onAppear {
                scrollToRevealedItem(using: scrollProxy, animated: false)
            }
            .onChange(of: revealedItemID) { _, _ in
                scrollToRevealedItem(using: scrollProxy, animated: true)
            }
        }
        .frame(width: width, height: panelHeight, alignment: .top)
        // The same floating surface as the editor's menus: radius 12 at `e2` (design.md §2.1, §7).
        .monknotFloatingSurface(
            .e2,
            cornerRadius: theme.chromeRadius(MonknotMetrics.cardCornerRadius, zoomScale: zoomScale),
            fill: theme.elevatedSurfaceColor,
            theme: theme
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Outline, \(items.count) headings")
    }

    /// One line-number column for the whole list, as wide as its largest line number.
    private var lineNumberWidthTemplate: String {
        MonknotStableWidth.lineNumberTemplate(maximumLine: items.map(\.location.line).max() ?? 0)
    }

    private func outlineRow(for item: MarkdownOutlineItem, lineNumberWidthTemplate: String) -> some View {
        let isRevealed = item.id == revealedItemID

        return Button {
            select(item)
        } label: {
            MonknotMenuRowLabel(
                leading: .none,
                title: item.title,
                indentBase: MarkdownOutlineRailLayout.leadingIndent(forHeadingLevel: item.level),
                isHighlighted: isRevealed,
                theme: theme,
                zoomScale: zoomScale
            ) {
                Text("\(item.location.line)")
                    .monknotReservingWidth(of: lineNumberWidthTemplate)
                    .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .monospacedDigit()
            }
        }
        .buttonStyle(MonknotMenuRowButtonStyle(
            theme: theme,
            isSelected: isRevealed,
            cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)
        ))
        .help("\(item.title), line \(item.location.line)")
        .accessibilityLabel("Go to heading: \(item.title)")
        .accessibilityValue("Heading level \(item.level), line \(item.location.line)")
        .accessibilityAddTraits(item.id == activeItemID ? .isSelected : [])
    }

    private func scrollToRevealedItem(using proxy: ScrollViewProxy, animated: Bool) {
        guard let revealedItemID else { return }
        DispatchQueue.main.async {
            if animated,
               let animation = MonknotMotion.outlineAnimation(reduceMotion: reduceMotion) {
                withAnimation(animation) {
                    proxy.scrollTo(
                        revealedItemID,
                        anchor: MarkdownOutlineRailLayout.revealAnchor
                    )
                }
            } else {
                proxy.scrollTo(
                    revealedItemID,
                    anchor: MarkdownOutlineRailLayout.revealAnchor
                )
            }
        }
    }
}
