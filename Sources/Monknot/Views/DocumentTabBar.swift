import AppKit
import MonknotCore
import SwiftUI

struct DocumentTabBar: View {
    let tabs: [WorkspaceTabItem]
    let selectedDocumentID: String?
    let missingDocumentIDs: Set<String>
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let isDisabled: Bool
    let saveState: (String) -> DocumentSaveState
    let selectTab: (String) -> Void
    let closeTab: (String) -> Void
    let togglePin: (String) -> Void
    let reorderTab: (String, String?) -> Void

    @State private var viewportTabFrames: [String: CGRect] = [:]
    @State private var revealRequest = HorizontalTabRevealRequest()
    @State private var isOverflowMenuHovered = false

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    private var chromeRowHeight: CGFloat {
        MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        if !tabs.isEmpty {
            GeometryReader { geometry in
                let overflowButtonWidth = MonknotMetrics.chromeButtonDimension(
                    theme: theme,
                    zoomScale: zoomScale
                ) + scaled(4)
                let viewportWidth = max(0, geometry.size.width - overflowButtonWidth)
                let overflow = HorizontalTabOverflowState(
                    frames: viewportTabFrames,
                    viewportWidth: viewportWidth
                )
                let hiddenTabs = tabs.filter { overflow.hiddenIDs.contains($0.documentID) }

                HStack(spacing: 0) {
                    ZStack {
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                DocumentTabStripContent(
                                    tabs: tabs,
                                    selectedDocumentID: selectedDocumentID,
                                    missingDocumentIDs: missingDocumentIDs,
                                    theme: theme,
                                    zoomScale: zoomScale,
                                    uiFontSize: uiFontSize,
                                    isDisabled: isDisabled,
                                    saveState: saveState,
                                    selectTab: selectTab,
                                    closeTab: closeTab,
                                    togglePin: togglePin,
                                    reorderTab: reorderTab,
                                    minimumContentWidth: viewportWidth
                                )
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
                            zoomScale: zoomScale
                        )
                    }
                    .frame(width: viewportWidth, height: chromeRowHeight)

                    overflowMenu(hiddenTabs: hiddenTabs)
                        .padding(.leading, scaled(2))
                        .opacity(hiddenTabs.isEmpty ? 0 : 1)
                        .allowsHitTesting(!hiddenTabs.isEmpty)
                        .accessibilityHidden(hiddenTabs.isEmpty)
                }
                .frame(width: geometry.size.width, height: chromeRowHeight, alignment: .leading)
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

    private func overflowMenu(hiddenTabs: [WorkspaceTabItem]) -> some View {
        Menu {
            ForEach(hiddenTabs) { tab in
                Button {
                    selectTab(tab.documentID)
                } label: {
                    Label(tab.displayName, systemImage: tab.kind.resolvedSystemImage)
                }
            }
        } label: {
            DocumentTabOverflowLabel(
                theme: theme,
                zoomScale: zoomScale,
                isHovered: isOverflowMenuHovered
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isDisabled)
        .onHover { isOverflowMenuHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isOverflowMenuHovered)
        .help("\(hiddenTabs.count) more open \(hiddenTabs.count == 1 ? "tab" : "tabs")")
        .accessibilityLabel("More open tabs")
        .accessibilityValue("\(hiddenTabs.count) hidden")
    }
}

private struct DocumentTabOverflowLabel: View {
    let theme: AppTheme
    let zoomScale: Double
    let isHovered: Bool

    var body: some View {
        let dimension = MonknotMetrics.chromeButtonDimension(theme: theme, zoomScale: zoomScale)
        let cornerRadius = theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)

        Image(systemName: "rectangle.stack.fill")
            .font(.system(
                size: MonknotMetrics.chromeGlyphSize(theme: theme, zoomScale: zoomScale) + 1,
                weight: .semibold
            ))
            .foregroundStyle(isHovered ? theme.foregroundColor : theme.mutedForegroundColor)
            .frame(width: dimension, height: dimension)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(theme.foregroundColor.opacity(
                            MonknotIconButton.IconButtonSize.chrome.hoverBackgroundOpacity(
                                isDark: theme.isDark
                            )
                        ))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .accessibilityHidden(true)
    }
}

private struct DocumentTabStripContent: View {
    static let coordinateSpaceName = "DocumentTabStripContentCoordinateSpace"

    let tabs: [WorkspaceTabItem]
    let selectedDocumentID: String?
    let missingDocumentIDs: Set<String>
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let isDisabled: Bool
    let saveState: (String) -> DocumentSaveState
    let selectTab: (String) -> Void
    let closeTab: (String) -> Void
    let togglePin: (String) -> Void
    let reorderTab: (String, String?) -> Void
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
        HStack(spacing: scaled(2)) {
            ForEach(tabs) { tab in
                DocumentTabItemView(
                    tab: tab,
                    isSelected: tab.documentID == selectedDocumentID,
                    isMissing: missingDocumentIDs.contains(tab.documentID),
                    saveState: saveState(tab.documentID),
                    theme: theme,
                    zoomScale: zoomScale,
                    uiFontSize: uiFontSize,
                    isDisabled: isDisabled,
                    isDragging: draggedDocumentID == tab.documentID,
                    select: { selectTab(tab.documentID) },
                    close: { closeTab(tab.documentID) },
                    togglePin: { togglePin(tab.documentID) }
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
        .padding(.horizontal, scaled(2))
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
    let isSelected: Bool
    let isMissing: Bool
    let saveState: DocumentSaveState
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let isDisabled: Bool
    let isDragging: Bool
    let select: () -> Void
    let close: () -> Void
    let togglePin: () -> Void

    @State private var isHovered = false

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    private func glyphScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceGlyph(base, theme: theme, zoomScale: zoomScale)
    }

    private var chromeRowHeight: CGFloat {
        MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: scaled(5)) {
                    Image(systemName: documentIconName)
                        .font(.system(
                            size: MonknotMetrics.chromeGlyphSize(theme: theme, zoomScale: zoomScale),
                            weight: .regular
                        ))
                        .foregroundStyle(iconColor)
                        .frame(width: max(glyphScaled(15), MonknotMetrics.chromeGlyphSize(theme: theme, zoomScale: zoomScale)))
                        .accessibilityHidden(true)

                    if tab.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: glyphScaled(9), weight: .medium))
                            .foregroundStyle(theme.mutedForegroundColor)
                            .accessibilityHidden(true)
                    }

                    ClippedTabTitle(
                        title: tab.displayName,
                        fontSize: textScaled(12),
                        color: textColor
                    )
                        .layoutPriority(0)

                    if isMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: glyphScaled(10), weight: .semibold))
                            .foregroundStyle(Color(hex: theme.semanticColors.diffRemoved))
                            .accessibilityHidden(true)
                    }

                    TabSaveStateIndicator(
                        state: saveState,
                        theme: theme,
                        zoomScale: zoomScale,
                        size: glyphScaled(10)
                    )
                }
                .padding(.leading, scaled(8))
                .padding(.trailing, scaled(tab.isPinned ? 10 : 2))
                .frame(
                    maxWidth: .infinity,
                    minHeight: MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale),
                    maxHeight: MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale),
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .frame(maxWidth: .infinity)

            if !tab.isPinned {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: glyphScaled(10), weight: .bold))
                        .foregroundStyle(closeIconColor)
                        .frame(
                            width: max(24, MonknotMetrics.interfaceControl(22, theme: theme, zoomScale: zoomScale)),
                            height: max(24, MonknotMetrics.interfaceControl(22, theme: theme, zoomScale: zoomScale))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: theme.chromeRadius(5, zoomScale: zoomScale)))
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .help("Close Tab")
                .accessibilityLabel("Close \(tab.displayName)")
                .monknotPointerCursor(enabled: !isDisabled)
                .padding(.trailing, scaled(2))
            }
        }
        .frame(width: preferredTabWidth, alignment: .leading)
        .frame(height: chromeRowHeight, alignment: .center)
        .background {
            tabHoverBackground
                .padding(.vertical, scaled(6))
        }
        .overlay(alignment: .bottom) { tabSelectionIndicator }
        .opacity(opacity)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .contextMenu {
            Button {
                togglePin()
            } label: {
                Label(tab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: tab.isPinned ? "pin.slash" : "pin")
            }

            Button {
                close()
            } label: {
                Label("Close Tab", systemImage: "xmark")
            }
        }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var tabHoverBackground: some View {
        if isHovered && !isSelected && !isDisabled {
            RoundedRectangle(cornerRadius: theme.chromeRadius(4, zoomScale: zoomScale))
                .fill(theme.foregroundColor.opacity(theme.isDark ? 0.05 : 0.035))
        }
    }

    @ViewBuilder
    private var tabSelectionIndicator: some View {
        if isSelected {
            Rectangle()
                .fill(theme.accentColor)
                .frame(height: max(1, scaled(1)))
                .padding(.horizontal, scaled(4))
        }
    }

    private var opacity: Double {
        if isDragging {
            return 0.45
        }
        return isDisabled ? 0.55 : 1
    }

    private var textColor: Color {
        if isSelected {
            return theme.foregroundColor
        }
        if isHovered && !isDisabled {
            return theme.foregroundColor.opacity(0.78)
        }
        return theme.foregroundColor.opacity(theme.isDark ? 0.64 : 0.62)
    }

    private var iconColor: Color {
        if isMissing {
            return Color(hex: theme.semanticColors.diffRemoved)
        }
        if isSelected {
            return theme.accentColor
        }
        return theme.foregroundColor.opacity(theme.isDark ? 0.58 : 0.54)
    }

    private var closeIconColor: Color {
        if isHovered {
            return theme.foregroundColor.opacity(0.85)
        }
        return theme.mutedForegroundColor.opacity(isSelected ? 0.6 : 0)
    }

    private var documentIconName: String {
        tab.kind.resolvedSystemImage
    }

    private var preferredTabWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: textScaled(12), weight: .regular)
        let labelWidth = ceil((tab.displayName as NSString).size(withAttributes: [.font: font]).width)
        let minimum = scaled(tab.isPinned ? MonknotMetrics.pinnedTabMinWidthBase : MonknotMetrics.tabMinWidthBase)
        let maximum = scaled(tab.isPinned ? MonknotMetrics.pinnedTabMaxWidthBase : MonknotMetrics.tabMaxWidthBase)
        let fixedControls = scaled(tab.isPinned ? 58 : 82)
        return min(maximum, max(minimum, labelWidth + fixedControls))
    }

    private var helpText: String {
        if isMissing {
            return "\(tab.relativePath) changed on disk"
        }
        return tab.relativePath
    }

    private var accessibilityLabel: String {
        var parts = [tab.displayName]
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

private struct ClippedTabTitle: View {
    let title: String
    let fontSize: CGFloat
    let color: Color

    var body: some View {
        GeometryReader { _ in
            Text(title)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(color)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: fontSize * 1.25, maxHeight: fontSize * 1.25)
        .clipped()
        .accessibilityLabel(title)
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

private struct TabSaveStateIndicator: View {
    let state: DocumentSaveState
    let theme: AppTheme
    let zoomScale: Double
    let size: CGFloat

    var body: some View {
        Group {
            switch state {
            case .clean:
                Color.clear
            case .edited:
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: max(5, size * 0.58), height: max(5, size * 0.58))
            case .saving:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(max(0.65, theme.layoutScale(zoomScale: zoomScale) * 0.78))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: max(9, size * 0.9), weight: .semibold))
                    .foregroundStyle(Color(hex: theme.semanticColors.diffRemoved))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(state.accessibilityDescription)
    }
}
