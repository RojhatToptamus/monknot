import AppKit
import MonknotCore
import SwiftUI

/// The outline rail's and its panel's geometry (design.md §10.5, §9.6). Every length is a base at
/// zoom 1, scaled through `MonknotMetrics.interfaceDensity`.
enum MarkdownOutlineRailLayout {
    /// The rail's column, and how far it stays from the document's scroll lane.
    static let railWidthBase: CGFloat = 38
    static let edgeInsetBase: CGFloat = 10
    /// How far left of the rail the panel sits.
    static let panelGapBase: CGFloat = 8
    /// The rail and the panel stay this far inside the card's top and bottom.
    static let cardMarginBase: CGFloat = 12
    /// One slot per heading, shrinking to keep the rail within `maximumHeightBase`; never under the
    /// minimum while the card has room for it.
    static let markPitchBase: CGFloat = 12
    static let minimumMarkPitchBase: CGFloat = 4
    static let markThicknessBase: CGFloat = 2
    /// A mark's length by its depth below the document's shallowest heading. The highlighted
    /// heading's mark reaches out to `highlightedMarkLengthBase`.
    static let markLengthBases: [CGFloat] = [16, 12, 9, 6]
    static let highlightedMarkLengthBase: CGFloat = 24
    /// Indentation stops at this depth, so a deep heading keeps its title in view.
    static let maximumDepth = 3
    /// The rail and the panel are at most as tall as a pop-up's values (design.md §5.8).
    static let maximumHeightBase = MonknotContextMenuLayout.valueMenuMaximumHeightBase
    /// The panel is as wide as a context menu: 232, widened by a long title up to 320.
    static let panelMinimumWidthBase = MonknotContextMenuLayout.minimumWidthBase
    static let panelMaximumWidthBase = MonknotContextMenuLayout.maximumWidthBase
    /// The current section's mark at the end of its row, in a slot every row keeps so the mark
    /// never moves a title.
    static let currentMarkLengthBase: CGFloat = 12
    /// The pointer stays on the rail this long before the panel opens, so crossing the rail on the
    /// way to the scroll bar opens nothing.
    static let openDelay: TimeInterval = 0.2
    /// Leaving the rail and the panel closes it after this long, so the trip from one to the other
    /// never does.
    static let closeGrace: TimeInterval = 0.1

    static func activeIndex(
        forVisibleLine visibleLine: Int,
        items: [MarkdownOutlineItem]
    ) -> Int? {
        guard !items.isEmpty else { return nil }
        return items.lastIndex(where: { $0.location.line <= visibleLine }) ?? 0
    }

    /// How far below the document's shallowest heading a heading sits, up to `maximumDepth`: a
    /// document that starts at `##` draws its `##` headings flush.
    static func depth(forHeadingLevel level: Int, shallowestLevel: Int) -> Int {
        max(0, min(maximumDepth, level - shallowestLevel))
    }

    /// A panel row's indent: the sidebar's 14 per depth.
    static func leadingIndentBase(forDepth depth: Int) -> CGFloat {
        CGFloat(max(0, min(maximumDepth, depth))) * MonknotMetrics.rowIndentBase
    }

    static func markLengthBase(forDepth depth: Int) -> CGFloat {
        markLengthBases[max(0, min(markLengthBases.count - 1, depth))]
    }

    /// The rail: a slot per heading, the slots as tall as fits.
    struct Rail: Equatable {
        let pitch: CGFloat
        let count: Int
        let markThickness: CGFloat

        var height: CGFloat {
            pitch * CGFloat(count)
        }

        /// The heading whose slot holds `y`, measured from the rail's top.
        func index(atY y: CGFloat) -> Int? {
            guard count > 0, pitch > 0 else { return nil }
            return min(count - 1, max(0, Int((y / pitch).rounded(.down))))
        }
    }

    /// Every heading keeps a slot on screen, so any of them can be pointed at without the rail
    /// scrolling: 12 per heading up to 380 tall, then the slots shrink to fit, to 4; past that the
    /// rail runs the card's height and the slots share it.
    static func rail(count: Int, availableHeight: CGFloat, theme: AppTheme, zoomScale: Double) -> Rail {
        func density(_ base: CGFloat) -> CGFloat {
            MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
        }
        let thickness = density(markThicknessBase)
        guard count > 0 else { return Rail(pitch: 0, count: 0, markThickness: thickness) }
        let usable = max(0, availableHeight - 2 * density(cardMarginBase))
        let headings = CGFloat(count)
        var pitch = min(density(markPitchBase), min(density(maximumHeightBase), usable) / headings)
        if pitch < density(minimumMarkPitchBase) {
            pitch = min(density(minimumMarkPitchBase), usable / headings)
        }
        // Marks closer than a point apart would touch; past that they thin rather than merge.
        return Rail(pitch: pitch, count: count, markThickness: max(1, min(thickness, pitch - 1)))
    }

    /// The panel's rows, 1 apart, inside the 6 list inset.
    static func panelContentHeight(rowCount: Int, theme: AppTheme, zoomScale: Double) -> CGFloat {
        let inset = MonknotMetrics.interfaceDensity(MonknotMetrics.menuListInsetBase, theme: theme, zoomScale: zoomScale)
        guard rowCount > 0 else { return 2 * inset }
        let rowHeight = MonknotMetrics.interfaceDensity(MonknotMetrics.menuRowHeightBase, theme: theme, zoomScale: zoomScale)
        return CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) + 2 * inset
    }

    /// As tall as its rows, at most 380 and never past the card's margins; beyond that it scrolls.
    static func panelHeight(rowCount: Int, availableHeight: CGFloat, theme: AppTheme, zoomScale: Double) -> CGFloat {
        let margin = MonknotMetrics.interfaceDensity(cardMarginBase, theme: theme, zoomScale: zoomScale)
        let bound = min(
            MonknotMetrics.interfaceDensity(maximumHeightBase, theme: theme, zoomScale: zoomScale),
            max(0, availableHeight - 2 * margin)
        )
        return min(panelContentHeight(rowCount: rowCount, theme: theme, zoomScale: zoomScale), bound)
    }

    /// Row `index`'s top and bottom in the panel's content.
    static func panelRowSpan(index: Int, theme: AppTheme, zoomScale: Double) -> ClosedRange<CGFloat> {
        let inset = MonknotMetrics.interfaceDensity(MonknotMetrics.menuListInsetBase, theme: theme, zoomScale: zoomScale)
        let rowHeight = MonknotMetrics.interfaceDensity(MonknotMetrics.menuRowHeightBase, theme: theme, zoomScale: zoomScale)
        let top = inset + CGFloat(index) * (rowHeight + 1)
        return top...(top + rowHeight)
    }

    /// 232 wide, a longer title widening it up to 320, and never wider than the card leaves beside
    /// the rail. `widestRow` is the widest row's leading padding, indent and title.
    static func panelWidth(widestRow: CGFloat, availableWidth: CGFloat, theme: AppTheme, zoomScale: Double) -> CGFloat {
        func density(_ base: CGFloat) -> CGFloat {
            MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
        }
        // After the title, the menu row's 8 spacer and its trailing slot, 10 apart, and its trailing
        // padding (`MonknotMenuRowLabel`).
        let natural = 2 * density(MonknotMetrics.menuListInsetBase)
            + widestRow
            + density(MonknotMetrics.menuRowPaddingBase)
            + 2 * density(MonknotMetrics.menuRowGlyphGapBase)
            + density(8)
            + density(currentMarkLengthBase)
        let width = min(max(density(panelMinimumWidthBase), natural), density(panelMaximumWidthBase))
        let room = availableWidth - density(edgeInsetBase) - density(railWidthBase) - density(panelGapBase) - density(cardMarginBase)
        return max(0, min(width, room))
    }

    /// The list's offset from its top that shows `row` (its span in the content): centred when the
    /// panel opens, otherwise the least scroll that brings it `margin` clear of the panel's edge.
    static func scrollOffset(
        revealing row: ClosedRange<CGFloat>,
        from current: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
        margin: CGFloat,
        centred: Bool
    ) -> CGFloat {
        let maximum = max(0, contentHeight - viewportHeight)
        let target: CGFloat
        if centred {
            target = (row.lowerBound + row.upperBound) / 2 - viewportHeight / 2
        } else if row.lowerBound - margin < current {
            target = row.lowerBound - margin
        } else if row.upperBound + margin > current + viewportHeight {
            target = row.upperBound + margin - viewportHeight
        } else {
            target = current
        }
        return min(max(0, target), maximum)
    }
}

/// The headings with what the rail and its panel draw for each, worked out once per outline, theme
/// and zoom rather than on every scroll tick.
struct MarkdownOutlineRailOutline: Equatable {
    let items: [MarkdownOutlineItem]
    let depths: [Int]
    /// The widest row's leading padding, indent and title, which size the panel.
    let widestRow: CGFloat

    init(items: [MarkdownOutlineItem], theme: AppTheme, zoomScale: Double) {
        self.items = items
        let shallowest = items.map(\.level).min() ?? 1
        let depths = items.map {
            MarkdownOutlineRailLayout.depth(forHeadingLevel: $0.level, shallowestLevel: shallowest)
        }
        self.depths = depths
        let font = NSFont.systemFont(ofSize: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale))
        // The row rounds its padding and indent as one length, so they are measured as one here.
        widestRow = zip(items, depths).map { item, depth in
            MonknotMetrics.interfaceDensity(
                MonknotMetrics.menuRowPaddingBase + MarkdownOutlineRailLayout.leadingIndentBase(forDepth: depth),
                theme: theme,
                zoomScale: zoomScale
            ) + ceil((item.title as NSString).size(withAttributes: [.font: font]).width)
        }.max() ?? 0
    }
}

/// When the outline's panel shows and which heading holds the one highlight (design.md §10.5).
/// The pointer on the rail highlights its heading's mark at once and opens the panel after
/// `openDelay`; keyboard focus on a mark opens it at once. The pointer's row in the panel takes the
/// highlight without scrolling; the rail and the keys move it and keep it in view. Leaving the rail
/// and the panel closes it after `closeGrace`.
@MainActor
final class MarkdownOutlinePeek: ObservableObject {
    /// A heading for the panel to bring into view: centred as it opens, then with the least scroll.
    struct Reveal: Equatable {
        let id: String
        let centred: Bool
        let serial: Int
    }

    @Published private(set) var isOpen = false
    @Published private(set) var openedFromKeyboard = false
    @Published private(set) var highlightedID: String?
    @Published private(set) var reveal: Reveal?

    var openDelay = MarkdownOutlineRailLayout.openDelay
    var closeGrace = MarkdownOutlineRailLayout.closeGrace
    var reduceMotion = false

    private var railID: String?
    private var isOnPanel = false
    private var focusedID: String?
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var revealSerial = 0

    /// The pointer is on `id`'s mark, or has left the rail (nil).
    func pointerOnRail(_ id: String?) {
        guard id != railID else { return }
        railID = id
        if let id {
            cancelClose()
            highlight(id, reveals: true)
            if !isOpen, openTask == nil {
                scheduleOpen()
            }
        } else if isOpen {
            closeIfIdle()
        } else {
            openTask?.cancel()
            openTask = nil
            highlightedID = focusedID
        }
    }

    /// The pointer entered or left the panel (and the gap between it and the rail).
    func pointerOnPanel(_ inside: Bool) {
        isOnPanel = inside
        if inside {
            cancelClose()
        } else {
            closeIfIdle()
        }
    }

    /// The pointer moved onto a row of the panel: the row takes the highlight, and the list stays
    /// where it is.
    func pointerOnRow(_ id: String) {
        highlight(id, reveals: false)
    }

    /// Keyboard focus moved to `id`'s mark, or off the rail (nil).
    func focus(_ id: String?) {
        focusedID = id
        if let id {
            cancelClose()
            openTask?.cancel()
            openTask = nil
            highlight(id, reveals: true)
            if !isOpen {
                open(fromKeyboard: true)
            }
        } else {
            closeIfIdle()
        }
    }

    /// Closes the panel now, as when the rail goes away.
    func close(animated: Bool = true) {
        openTask?.cancel()
        openTask = nil
        cancelClose()
        railID = nil
        isOnPanel = false
        focusedID = nil
        highlightedID = nil
        guard isOpen else { return }
        withAnimation(animated ? MonknotMotion.surfaceExit : nil) {
            isOpen = false
        }
        reveal = nil
        openedFromKeyboard = false
    }

    private func highlight(_ id: String, reveals: Bool) {
        guard highlightedID != id else { return }
        highlightedID = id
        if reveals, isOpen {
            revealSerial += 1
            reveal = Reveal(id: id, centred: false, serial: revealSerial)
        }
    }

    private func scheduleOpen() {
        let delay = openDelay
        openTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.open(fromKeyboard: false)
        }
    }

    private func open(fromKeyboard: Bool) {
        openTask = nil
        guard !isOpen, let highlightedID else { return }
        revealSerial += 1
        reveal = Reveal(id: highlightedID, centred: true, serial: revealSerial)
        openedFromKeyboard = fromKeyboard
        // From the keys it appears at once; from the pointer it grows in from the rail.
        withAnimation(fromKeyboard ? nil : MonknotMotion.surfaceEntrance(reduceMotion: reduceMotion)) {
            isOpen = true
        }
    }

    private func closeIfIdle() {
        guard railID == nil, !isOnPanel, focusedID == nil else { return }
        cancelClose()
        let grace = closeGrace
        closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
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
    /// Held, not observed: only the content below watches it, so a hover never re-measures the
    /// outline here.
    @State private var peek: MarkdownOutlinePeek

    /// `peek` lets a test open the panel; the pane leaves it to the rail.
    init(
        documentID: String,
        items: [MarkdownOutlineItem],
        position: MarkdownOutlinePosition,
        theme: AppTheme,
        zoomScale: Double,
        peek: MarkdownOutlinePeek? = nil,
        select: @escaping (MarkdownOutlineItem) -> Void
    ) {
        self.documentID = documentID
        self.items = items
        self.position = position
        self.theme = theme
        self.zoomScale = zoomScale
        self.select = select
        _peek = State(initialValue: peek ?? MarkdownOutlinePeek())
    }

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
        let outline = MarkdownOutlineRailOutline(items: items, theme: theme, zoomScale: zoomScale)
        // The whole card, so the rail can centre on it and the panel can keep within it; only the
        // rail's marks and the open panel take the pointer.
        GeometryReader { proxy in
            MarkdownOutlineRailContent(
                outline: outline,
                availableSize: proxy.size,
                position: position,
                peek: peek,
                theme: theme,
                zoomScale: zoomScale,
                select: select
            )
        }
    }
}

private struct MarkdownOutlineRailContent: View {
    let outline: MarkdownOutlineRailOutline
    let availableSize: CGSize
    @ObservedObject var position: MarkdownOutlinePosition
    @ObservedObject var peek: MarkdownOutlinePeek
    let theme: AppTheme
    let zoomScale: Double
    let select: (MarkdownOutlineItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func density(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    private var activeID: String? {
        MarkdownOutlineRailLayout.activeIndex(forVisibleLine: position.visibleLine, items: outline.items)
            .map { outline.items[$0].id }
    }

    var body: some View {
        let rail = MarkdownOutlineRailLayout.rail(
            count: outline.items.count,
            availableHeight: availableSize.height,
            theme: theme,
            zoomScale: zoomScale
        )
        let panelSize = CGSize(
            width: MarkdownOutlineRailLayout.panelWidth(
                widestRow: outline.widestRow,
                availableWidth: availableSize.width,
                theme: theme,
                zoomScale: zoomScale
            ),
            height: MarkdownOutlineRailLayout.panelHeight(
                rowCount: outline.items.count,
                availableHeight: availableSize.height,
                theme: theme,
                zoomScale: zoomScale
            )
        )
        let gap = density(MarkdownOutlineRailLayout.panelGapBase)
        let activeID = activeID

        MarkdownOutlineMarks(
            outline: outline,
            rail: rail,
            activeID: activeID,
            highlightedID: peek.highlightedID,
            theme: theme,
            zoomScale: zoomScale,
            peek: peek,
            select: select
        )
        .equatable()
        // The panel floats left of the rail, centred on it; it never moves the rail.
        .overlay(alignment: .trailing) {
            ZStack(alignment: .trailing) {
                if peek.isOpen {
                    MarkdownOutlinePanel(
                        outline: outline,
                        currentID: activeID,
                        highlightedID: peek.highlightedID,
                        reveal: peek.reveal,
                        size: panelSize,
                        theme: theme,
                        zoomScale: zoomScale,
                        pointerOnRow: { peek.pointerOnRow($0) },
                        select: select
                    )
                    // The gap is the panel's, so the trip from the rail never leaves it.
                    .padding(.trailing, gap)
                    .contentShape(Rectangle())
                    .onHover { peek.pointerOnPanel($0) }
                    .transition(panelTransition)
                }
            }
            .frame(width: panelSize.width + gap, height: panelSize.height, alignment: .trailing)
            .offset(x: -density(MarkdownOutlineRailLayout.railWidthBase))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document outline")
        .padding(.trailing, density(MarkdownOutlineRailLayout.edgeInsetBase))
        .frame(width: availableSize.width, height: availableSize.height, alignment: .trailing)
        .onAppear { peek.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, reduceMotion in
            peek.reduceMotion = reduceMotion
        }
        .onDisappear { peek.close(animated: false) }
    }

    /// Grown in from the rail as a menu or popover is, from 0.97 with its opacity; at once from the
    /// keys and a plain fade with Reduce Motion; always a fade out (design.md §11). The timing is
    /// the peek's.
    private var panelTransition: AnyTransition {
        let insertion: AnyTransition = peek.openedFromKeyboard || reduceMotion
            ? .opacity
            : .scale(scale: MonknotMotion.surfaceEntranceScale, anchor: .trailing).combined(with: .opacity)
        return .asymmetric(insertion: insertion, removal: .opacity)
    }
}

/// The rail's marks: one per heading, trailing edges together, the current section's in `accent`
/// and the highlighted heading's in `ink` and longer, both at once (design.md §10.5). Redrawn when
/// the current or highlighted heading changes, not on every line the document scrolls.
private struct MarkdownOutlineMarks: View, Equatable {
    let outline: MarkdownOutlineRailOutline
    let rail: MarkdownOutlineRailLayout.Rail
    let activeID: String?
    let highlightedID: String?
    let theme: AppTheme
    let zoomScale: Double
    /// Told where the pointer and focus are; not observed here.
    let peek: MarkdownOutlinePeek
    let select: (MarkdownOutlineItem) -> Void

    @FocusState private var focusedID: String?

    nonisolated static func == (lhs: MarkdownOutlineMarks, rhs: MarkdownOutlineMarks) -> Bool {
        MainActor.assumeIsolated {
            lhs.rail == rhs.rail &&
                lhs.activeID == rhs.activeID &&
                lhs.highlightedID == rhs.highlightedID &&
                lhs.zoomScale == rhs.zoomScale &&
                lhs.peek === rhs.peek &&
                lhs.theme == rhs.theme &&
                lhs.outline == rhs.outline
        }
    }

    private func density(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(outline.items.enumerated()), id: \.element.id) { index, item in
                mark(for: item, depth: outline.depths[index])
            }
        }
        .frame(width: density(MarkdownOutlineRailLayout.railWidthBase), height: rail.height)
        .contentShape(Rectangle())
        // One tracking area for the whole rail, so moving from one slot to the next never passes
        // through "no heading".
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                peek.pointerOnRail(rail.index(atY: location.y).map { outline.items[$0].id })
            case .ended:
                peek.pointerOnRail(nil)
            }
        }
        .onChange(of: focusedID) { _, id in
            peek.focus(id)
        }
    }

    private func mark(for item: MarkdownOutlineItem, depth: Int) -> some View {
        let isActive = item.id == activeID
        let isHighlighted = item.id == highlightedID
        return Button {
            select(item)
        } label: {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Capsule()
                    .fill(markColor(isActive: isActive, isHighlighted: isHighlighted))
                    .frame(
                        width: density(isHighlighted
                            ? MarkdownOutlineRailLayout.highlightedMarkLengthBase
                            : MarkdownOutlineRailLayout.markLengthBase(forDepth: depth)),
                        height: rail.markThickness
                    )
            }
            .frame(width: density(MarkdownOutlineRailLayout.railWidthBase), height: rail.pitch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(NSApp.isFullKeyboardAccessEnabled)
        .focused($focusedID, equals: item.id)
        .focusEffectDisabled()
        .accessibilityLabel("Go to heading: \(item.title)")
        .accessibilityValue("Heading level \(item.level), line \(item.location.line)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .monknotPointerCursor()
    }

    /// design.md §10.5: `ink3` at rest, the current section `accent`, the highlighted heading `ink`.
    private func markColor(isActive: Bool, isHighlighted: Bool) -> Color {
        if isActive {
            return theme.accentColor
        }
        return isHighlighted ? theme.foregroundColor : theme.tertiaryForegroundColor
    }
}

/// The outline's panel: the context menu's surface with a menu row per heading, indented by depth
/// (design.md §10.5). The highlighted heading is the one highlight; the current section carries the
/// rail's accent mark at its row's end. At most 380 tall, then it scrolls under the chrome thumb.
struct MarkdownOutlinePanel: View {
    let outline: MarkdownOutlineRailOutline
    let currentID: String?
    let highlightedID: String?
    let reveal: MarkdownOutlinePeek.Reveal?
    let size: CGSize
    let theme: AppTheme
    let zoomScale: Double
    let pointerOnRow: (String) -> Void
    let select: (MarkdownOutlineItem) -> Void

    @State private var scroller = MarkdownOutlinePanelScroller()

    private func density(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        MonknotScrollView(theme: theme) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(outline.items.enumerated()), id: \.element.id) { index, item in
                    row(for: item, depth: outline.depths[index])
                }
            }
            .padding(density(MonknotMetrics.menuListInsetBase))
            .background(MarkdownOutlineScrollAccess(scroller: scroller))
        }
        .frame(width: size.width, height: size.height)
        // The same floating surface as the editor's menus: radius 12 at `e2` (design.md §2.1, §7).
        .monknotFloatingSurface(
            .e2,
            cornerRadius: theme.chromeRadius(MonknotMetrics.cardCornerRadius, zoomScale: zoomScale),
            fill: theme.elevatedSurfaceColor,
            theme: theme
        )
        .onAppear { bringIntoView(reveal) }
        .onChange(of: reveal) { _, reveal in
            bringIntoView(reveal)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Outline, \(outline.items.count) headings")
    }

    private func row(for item: MarkdownOutlineItem, depth: Int) -> some View {
        let isCurrent = item.id == currentID
        return Button {
            select(item)
        } label: {
            MonknotMenuRowLabel(
                leading: .none,
                title: item.title,
                indentBase: MarkdownOutlineRailLayout.leadingIndentBase(forDepth: depth),
                theme: theme,
                zoomScale: zoomScale
            ) {
                Capsule()
                    .fill(isCurrent ? theme.accentColor : Color.clear)
                    .frame(
                        width: density(MarkdownOutlineRailLayout.currentMarkLengthBase),
                        height: density(MarkdownOutlineRailLayout.markThicknessBase)
                    )
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(MonknotMenuRowButtonStyle(
            theme: theme,
            zoomScale: zoomScale,
            isHighlighted: item.id == highlightedID
        ))
        // The keys stay on the rail's marks; the panel follows them.
        .focusable(false)
        .onHover { inside in
            if inside {
                pointerOnRow(item.id)
            }
        }
        .help("\(item.title), line \(item.location.line)")
        .accessibilityLabel("Go to heading: \(item.title)")
        .accessibilityValue("Heading level \(item.level), line \(item.location.line)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func bringIntoView(_ reveal: MarkdownOutlinePeek.Reveal?) {
        guard let reveal, let index = outline.items.firstIndex(where: { $0.id == reveal.id }) else { return }
        scroller.reveal(.init(
            row: MarkdownOutlineRailLayout.panelRowSpan(index: index, theme: theme, zoomScale: zoomScale),
            margin: density(MonknotMetrics.menuListInsetBase),
            centred: reveal.centred
        ))
    }
}

/// Moves the panel's list to keep a row in view. Rows have fixed frames, so the offset is worked
/// out (`MarkdownOutlineRailLayout.scrollOffset`) and set on the list's scroll view at once: the
/// highlight never trails the pointer, and the list opening centred never shows a first frame at
/// its top.
@MainActor
final class MarkdownOutlinePanelScroller {
    struct Request {
        let row: ClosedRange<CGFloat>
        let margin: CGFloat
        let centred: Bool
    }

    private(set) weak var scrollView: NSScrollView?
    private var pending: Request?

    func attach(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        apply()
    }

    func reveal(_ request: Request) {
        pending = request
        apply()
    }

    /// The list's visible span, from its top.
    var visibleSpan: ClosedRange<CGFloat>? {
        guard let scrollView, let document = scrollView.documentView else { return nil }
        let viewport = scrollView.contentView.bounds.height
        let top = Self.top(of: scrollView.contentView, in: document)
        return top...(top + viewport)
    }

    /// Applies the waiting request once the list is laid out tall enough to hold its row.
    func apply() {
        guard let request = pending, let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let viewport = clip.bounds.height
        let contentHeight = document.frame.height
        guard viewport > 0, contentHeight + 0.5 >= request.row.upperBound else { return }
        pending = nil
        let current = Self.top(of: clip, in: document)
        let target = MarkdownOutlineRailLayout.scrollOffset(
            revealing: request.row,
            from: current,
            viewportHeight: viewport,
            contentHeight: contentHeight,
            margin: request.margin,
            centred: request.centred
        )
        guard abs(target - current) > 0.25 else { return }
        let y = document.isFlipped ? target : contentHeight - viewport - target
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
        // Scrubbing shows the thumb while the list moves, as a scroll does (design.md §5.7).
        if !request.centred {
            scrollView.flashScrollers()
        }
    }

    private static func top(of clip: NSClipView, in document: NSView) -> CGFloat {
        document.isFlipped ? clip.bounds.minY : document.frame.height - clip.bounds.maxY
    }
}

/// Hands the panel's scroll view to its scroller, and applies a waiting reveal as the list's
/// content takes its size.
private struct MarkdownOutlineScrollAccess: NSViewRepresentable {
    let scroller: MarkdownOutlinePanelScroller

    func makeNSView(context: Context) -> AccessView {
        let view = AccessView()
        view.scroller = scroller
        return view
    }

    func updateNSView(_ nsView: AccessView, context: Context) {
        nsView.scroller = scroller
    }

    final class AccessView: NSView {
        weak var scroller: MarkdownOutlinePanelScroller?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scroller?.apply()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        private func attach() {
            if let scrollView = enclosingScrollView {
                scroller?.attach(scrollView)
            }
        }
    }
}
