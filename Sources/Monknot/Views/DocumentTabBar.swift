import AppKit
import MonknotCore
import SwiftUI

/// A file tab's width (design.md §10.3): `MonknotTab`'s `10 padding · 18 glyph column · 8 gap · label ·
/// 10 padding`, plus `8 gap · 10 badge` for a pin or a missing-file warning, capped at 220. A label is
/// middle-elided only when the tab would pass the cap, and the tab hugs whatever label it shows.
struct DocumentTabMetrics {
    let padding: CGFloat
    let gap: CGFloat
    let glyphColumn: CGFloat
    let badgeGlyph: CGFloat
    let maximumWidth: CGFloat
    let labelFont: NSFont

    init(theme: AppTheme, zoomScale: Double) {
        padding = MonknotMetrics.interfaceDensity(MonknotTab.paddingBase, theme: theme, zoomScale: zoomScale)
        gap = MonknotMetrics.interfaceDensity(MonknotTab.glyphGapBase, theme: theme, zoomScale: zoomScale)
        glyphColumn = MonknotMetrics.interfaceGlyph(
            MonknotMetrics.rowIconColumnWidthBase,
            theme: theme,
            zoomScale: zoomScale
        )
        badgeGlyph = MonknotMetrics.interfaceGlyph(MonknotTab.badgePointSizeBase, theme: theme, zoomScale: zoomScale)
        maximumWidth = MonknotMetrics.interfaceDensity(
            MonknotMetrics.tabMaxWidthBase,
            theme: theme,
            zoomScale: zoomScale
        )
        labelFont = NSFont.systemFont(
            ofSize: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale),
            weight: .regular
        )
    }

    /// Everything in a tab except its label. No close slot: close takes the glyph's place on hover.
    func chromeWidth(isPinned: Bool, isMissing: Bool) -> CGFloat {
        var width = padding + glyphColumn + gap + padding
        if isPinned {
            width += gap + badgeGlyph
        }
        if isMissing {
            width += gap + badgeGlyph
        }
        return width
    }

    func labelWidth(_ label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: labelFont]).width)
    }

    /// The label as shown: whole when the tab fits under the cap, otherwise middle-elided.
    func fittedLabel(_ label: String, isPinned: Bool, isMissing: Bool) -> String {
        DocumentTabLabel.middleElided(
            label,
            toFit: maximumWidth - chromeWidth(isPinned: isPinned, isMissing: isMissing),
            measure: labelWidth
        )
    }

    func width(fittedLabel: String, isPinned: Bool, isMissing: Bool) -> CGFloat {
        min(maximumWidth, chromeWidth(isPinned: isPinned, isMissing: isMissing) + labelWidth(fittedLabel))
    }
}

/// What a document tab's context menu offers besides Close and Pin (design.md §5.8): closing the
/// other tabs, and the location items every file's menu has.
struct DocumentTabMenuActions {
    var closeOtherTabs: (String) -> Void = { _ in }
    var location: ((String) -> (copyPath: () -> Void, copyRelativePath: () -> Void, revealInFinder: () -> Void))?

    static let none = DocumentTabMenuActions()
}

struct DocumentTabBar: View {
    let tabs: [WorkspaceTabItem]
    let selectedDocumentID: String?
    let missingDocumentIDs: Set<String>
    let theme: AppTheme
    let zoomScale: Double
    let isDisabled: Bool
    let saveState: (String) -> DocumentSaveState
    let selectTab: (String) -> Void
    let closeTab: (String) -> Void
    let togglePin: (String) -> Void
    let reorderTab: (String, String?) -> Void
    var menu: DocumentTabMenuActions = .none

    @State private var viewportTabFrames: [String: CGRect] = [:]
    @State private var revealRequest = HorizontalTabRevealRequest()

    private var chromeRowHeight: CGFloat {
        MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        if !tabs.isEmpty {
            GeometryReader { geometry in
                let viewportWidth = max(0, geometry.size.width)
                let overflow = HorizontalTabOverflowState(
                    frames: viewportTabFrames,
                    viewportWidth: viewportWidth
                )

                ZStack {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            DocumentTabStripContent(
                                tabs: tabs,
                                selectedDocumentID: selectedDocumentID,
                                missingDocumentIDs: missingDocumentIDs,
                                theme: theme,
                                zoomScale: zoomScale,
                                isDisabled: isDisabled,
                                saveState: saveState,
                                selectTab: selectTab,
                                closeTab: closeTab,
                                togglePin: togglePin,
                                reorderTab: reorderTab,
                                menu: menu,
                                minimumContentWidth: viewportWidth
                            )
                            .background(HorizontalTabWheelScrolling())
                        }
                        .coordinateSpace(name: HorizontalTabViewport.documentTabs)
                        .onAppear {
                            revealRequest.request(selectedDocumentID)
                            performPendingReveal(using: proxy, viewportWidth: viewportWidth)
                        }
                        .onPreferenceChange(HorizontalTabFramePreferenceKey.self) { frames in
                            viewportTabFrames = frames
                            performPendingReveal(using: proxy, viewportWidth: viewportWidth)
                        }
                        .onChange(of: selectedDocumentID) { _, selectedDocumentID in
                            revealRequest.request(selectedDocumentID)
                            performPendingReveal(using: proxy, viewportWidth: viewportWidth)
                        }
                        .onChange(of: viewportWidth) { _, _ in
                            revealRequest.request(selectedDocumentID)
                            performPendingReveal(using: proxy, viewportWidth: viewportWidth)
                        }
                    }

                    HorizontalTabEdgeShadows(
                        showsLeading: overflow.hasLeadingOverflow,
                        showsTrailing: overflow.hasTrailingOverflow,
                        theme: theme,
                        zoomScale: zoomScale,
                        surface: theme.chromeSurfaceColor
                    )
                }
                .frame(width: viewportWidth, height: chromeRowHeight)
            }
            .frame(height: chromeRowHeight)
        }
    }

    private func performPendingReveal(
        using proxy: ScrollViewProxy,
        viewportWidth: CGFloat
    ) {
        guard let action = revealRequest.consume(
            frames: viewportTabFrames,
            viewportWidth: viewportWidth
        ) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(
                action.id,
                anchor: action.edge == .leading ? .leading : .trailing
            )
        }
    }
}

private struct DocumentTabStripContent: View {
    static let coordinateSpaceName = "DocumentTabStripContentCoordinateSpace"

    let tabs: [WorkspaceTabItem]
    let selectedDocumentID: String?
    let missingDocumentIDs: Set<String>
    let theme: AppTheme
    let zoomScale: Double
    let isDisabled: Bool
    let saveState: (String) -> DocumentSaveState
    let selectTab: (String) -> Void
    let closeTab: (String) -> Void
    let togglePin: (String) -> Void
    let reorderTab: (String, String?) -> Void
    var menu: DocumentTabMenuActions = .none
    let minimumContentWidth: CGFloat

    @State private var draggedDocumentID: String?
    @State private var tabFrames: [String: CGRect] = [:]

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    private var chromeRowHeight: CGFloat {
        MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        let labels = DocumentTabLabel.labels(for: tabs)
        HStack(spacing: scaled(MonknotTab.spacingBase)) {
            ForEach(tabs) { tab in
                DocumentTabItemView(
                    tab: tab,
                    label: labels[tab.documentID] ?? tab.displayName,
                    isSelected: tab.documentID == selectedDocumentID,
                    isMissing: missingDocumentIDs.contains(tab.documentID),
                    saveState: saveState(tab.documentID),
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: isDisabled,
                    isDragging: draggedDocumentID == tab.documentID,
                    select: { selectTab(tab.documentID) },
                    close: { closeTab(tab.documentID) },
                    togglePin: { togglePin(tab.documentID) },
                    closeOthers: tabs.contains { $0.documentID != tab.documentID && !$0.isPinned }
                        ? { menu.closeOtherTabs(tab.documentID) }
                        : nil,
                    location: menu.location?(tab.documentID)
                )
                .id(tab.documentID)
                .background(TabFrameReader(documentID: tab.documentID))
                .background(
                    HorizontalTabFrameReader(
                        id: tab.documentID,
                        coordinateSpace: HorizontalTabViewport.documentTabs
                    )
                )
                .highPriorityGesture(tabDragGesture(for: tab))
            }

            WindowTitleBarDragArea()
                .frame(minWidth: scaled(28), maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, scaled(MonknotTab.spacingBase))
        .frame(minWidth: minimumContentWidth, alignment: .leading)
        .frame(height: chromeRowHeight, alignment: .center)
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(TabFramePreferenceKey.self) { frames in
            tabFrames = frames
        }
    }

    private func tabDragGesture(for tab: WorkspaceTabItem) -> some Gesture {
        DragGesture(minimumDistance: scaled(5), coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                guard !isDisabled, tabs.count > 1 else { return }
                draggedDocumentID = tab.documentID
                reorderTab(tab.documentID, targetDocumentID(for: value.location.x, dragging: tab.documentID))
            }
            .onEnded { _ in
                draggedDocumentID = nil
            }
    }

    private func targetDocumentID(for xPosition: CGFloat, dragging documentID: String) -> String? {
        let orderedFrames = tabs.compactMap { tab -> (id: String, frame: CGRect)? in
            guard tab.documentID != documentID,
                  let frame = tabFrames[tab.documentID] else {
                return nil
            }
            return (tab.documentID, frame)
        }
        .sorted { $0.frame.minX < $1.frame.minX }

        guard let lastFrame = orderedFrames.last else {
            return nil
        }

        if xPosition > lastFrame.frame.midX {
            return nil
        }

        return orderedFrames.first(where: { xPosition < $0.frame.midX })?.id ?? lastFrame.id
    }
}

private struct DocumentTabItemView: View {
    let tab: WorkspaceTabItem
    let label: String
    let isSelected: Bool
    let isMissing: Bool
    let saveState: DocumentSaveState
    let theme: AppTheme
    let zoomScale: Double
    let isDisabled: Bool
    let isDragging: Bool
    let select: () -> Void
    let close: () -> Void
    let togglePin: () -> Void
    /// Close Other Tabs, while there is an unpinned tab besides this one.
    var closeOthers: (() -> Void)?
    var location: (copyPath: () -> Void, copyRelativePath: () -> Void, revealInFinder: () -> Void)?

    var body: some View {
        let metrics = DocumentTabMetrics(theme: theme, zoomScale: zoomScale)
        MonknotTab(
            title: metrics.fittedLabel(label, isPinned: tab.isPinned, isMissing: isMissing),
            systemImage: tab.kind.resolvedSystemImage,
            isSelected: isSelected,
            placement: .chrome,
            status: status,
            glyphTint: isMissing ? theme.dangerColor : nil,
            badges: badges,
            isDisabled: isDisabled,
            isDragging: isDragging,
            // A pinned tab closes from its menu or with ⌘W, never from a stray click on its glyph.
            closeLabel: tab.isPinned ? nil : "Close \(label)",
            theme: theme,
            zoomScale: zoomScale,
            select: select,
            close: close
        )
        .frame(height: MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale))
        .contextMenu {
            MonknotMenuCommandButton(.closeTab, action: close)
                .disabled(isDisabled)

            if let closeOthers {
                MonknotMenuCommandButton(.closeOtherTabs, action: closeOthers)
                    .disabled(isDisabled)
            }

            Divider()

            MonknotMenuCommandButton(tab.isPinned ? .unpinTab : .pinTab, action: togglePin)
                .disabled(isDisabled)

            if let location {
                Divider()

                MonknotMenuCommandButton(.copyPath, action: location.copyPath)
                MonknotMenuCommandButton(.copyRelativePath, action: location.copyRelativePath)
                MonknotMenuCommandButton(.revealInFinder, action: location.revealInFinder)
            }
        }
        .monknotHelp(isSelected ? nil : helpText)
        .accessibilityLabel(accessibilityLabel)
    }

    private var status: MonknotTab.Status {
        MonknotDocumentStatus(saveState)
    }

    private var badges: [MonknotTab.Badge] {
        var badges: [MonknotTab.Badge] = []
        if tab.isPinned {
            badges.append(.pinned)
        }
        if isMissing {
            badges.append(.warning)
        }
        return badges
    }

    private var helpText: String {
        if isMissing {
            return "\(tab.relativePath) changed on disk"
        }
        return tab.relativePath
    }

    private var accessibilityLabel: String {
        var parts = [label]
        if tab.isPinned {
            parts.append("pinned")
        }
        if isMissing {
            parts.append("file changed on disk")
        }
        if !saveState.isClean {
            parts.append(saveState.accessibilityDescription)
        }
        return parts.joined(separator: ", ")
    }
}

private struct TabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct TabFrameReader: View {
    let documentID: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: TabFramePreferenceKey.self, value: [
                documentID: proxy.frame(in: .named(DocumentTabStripContent.coordinateSpaceName))
            ])
        }
    }
}
