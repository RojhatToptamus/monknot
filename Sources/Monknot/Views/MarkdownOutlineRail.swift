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

struct MarkdownOutlineRail: View {
    let items: [MarkdownOutlineItem]
    let visibleLine: Int
    let theme: AppTheme
    let zoomScale: Double
    let select: (MarkdownOutlineItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var hoveredMarkerID: String?
    @FocusState private var focusedMarkerID: String?

    private var activeIndex: Int? {
        MarkdownOutlineRailLayout.activeIndex(
            forVisibleLine: visibleLine,
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
        .focusable()
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

    private func markerColor(isActive: Bool, isHighlighted: Bool) -> Color {
        if isActive {
            return theme.accentColor.opacity(0.92)
        }
        if isHighlighted {
            return theme.foregroundColor.opacity(0.62)
        }
        return theme.mutedForegroundColor.opacity(theme.isDark ? 0.42 : 0.50)
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

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    private var preferredHeight: CGFloat {
        let visibleRows = CGFloat(min(items.count, 8))
        return scaled(44 + visibleRows * 28)
    }

    private var panelHeight: CGFloat {
        min(maximumHeight, preferredHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(theme.borderColor)
                .frame(height: 1)

            ScrollViewReader { scrollProxy in
                MonknotScrollView {
                    LazyVStack(alignment: .leading, spacing: scaled(2)) {
                        ForEach(items) { item in
                            outlineRow(for: item)
                                .id(item.id)
                        }
                    }
                    .padding(scaled(6))
                }
                .onAppear {
                    scrollToRevealedItem(using: scrollProxy, animated: false)
                }
                .onChange(of: revealedItemID) { _, _ in
                    scrollToRevealedItem(using: scrollProxy, animated: true)
                }
            }
        }
        .frame(width: width, height: panelHeight, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: scaled(11), style: .continuous)
                .fill(theme.elevatedSurfaceColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: scaled(11), style: .continuous)
                .strokeBorder(theme.borderColor, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: scaled(11), style: .continuous))
        .shadow(
            color: .black.opacity(theme.isDark ? 0.28 : 0.12),
            radius: scaled(8),
            y: scaled(3)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Outline, \(items.count) headings")
    }

    private var header: some View {
        HStack(spacing: scaled(7)) {
            Image(systemName: MonknotWorkspaceIcons.outline)
                .font(.system(size: textScaled(11.5), weight: .medium))
                .foregroundStyle(theme.accentColor)
                .accessibilityHidden(true)

            Text("Outline")
                .font(.system(size: textScaled(12), weight: .semibold))
                .foregroundStyle(theme.foregroundColor)

            Spacer(minLength: 0)

            Text("\(items.count)")
                .font(.system(size: textScaled(10), weight: .medium, design: .monospaced))
                .foregroundStyle(theme.mutedForegroundColor)
                .monospacedDigit()
                .accessibilityLabel("\(items.count) headings")
        }
        .padding(.horizontal, scaled(12))
        .frame(height: scaled(38))
    }

    private func outlineRow(for item: MarkdownOutlineItem) -> some View {
        let isRevealed = item.id == revealedItemID

        return Button {
            select(item)
        } label: {
            HStack(spacing: scaled(7)) {
                Text(item.title)
                    .font(.system(size: textScaled(11), weight: isRevealed ? .medium : .regular))
                    .foregroundStyle(isRevealed ? theme.accentColor : theme.foregroundColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: scaled(6))

                Text("\(item.location.line)")
                    .font(.system(size: textScaled(9.5), weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .monospacedDigit()
            }
            .padding(.leading, scaled(
                8 + MarkdownOutlineRailLayout.leadingIndent(forHeadingLevel: item.level)
            ))
            .padding(.trailing, scaled(8))
            .padding(.vertical, scaled(5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(MarkdownOutlineRowButtonStyle(
            theme: theme,
            cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale),
            isActive: isRevealed
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

private struct MarkdownOutlineRowButtonStyle: ButtonStyle {
    let theme: AppTheme
    let cornerRadius: CGFloat
    let isActive: Bool

    func makeBody(configuration: Configuration) -> Body {
        Body(
            configuration: configuration,
            theme: theme,
            cornerRadius: cornerRadius,
            isActive: isActive
        )
    }

    fileprivate struct Body: View {
        let configuration: Configuration
        let theme: AppTheme
        let cornerRadius: CGFloat
        let isActive: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(backgroundColor)
                }
                .opacity(configuration.isPressed ? 0.82 : 1)
                .onHover { isHovered = $0 }
                .monknotPointerCursor()
        }

        private var backgroundColor: Color {
            if isHovered {
                return theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.055)
            }
            if isActive {
                return theme.accentColor.opacity(theme.isDark ? 0.10 : 0.075)
            }
            return .clear
        }
    }
}
