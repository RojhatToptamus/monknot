import AppKit
import MonknotCore
import SwiftUI

enum DocumentTabWidthPolicy {
    static func preferredWidth(
        title: String,
        isPinned: Bool,
        theme: AppTheme,
        zoomScale: Double
    ) -> CGFloat {
        let fontSize = MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let labelWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let maximumTabWidth = MonknotMetrics.interfaceDensity(
            MonknotMetrics.tabMaxWidthBase,
            theme: theme,
            zoomScale: zoomScale
        )
        let documentGlyphColumn = MonknotMetrics.interfaceGlyph(
            MonknotMetrics.rowIconColumnWidthBase,
            theme: theme,
            zoomScale: zoomScale
        )
        let outerPadding = MonknotMetrics.interfaceDensity(20, theme: theme, zoomScale: zoomScale)
        let labelGaps = MonknotMetrics.interfaceDensity(16, theme: theme, zoomScale: zoomScale)
        let fixedControls: CGFloat
        if isPinned {
            fixedControls = MonknotMetrics.interfaceDensity(18, theme: theme, zoomScale: zoomScale)
                + labelGaps
                + documentGlyphColumn
                + MonknotMetrics.interfaceGlyph(9, theme: theme, zoomScale: zoomScale)
        } else {
            fixedControls = outerPadding
                + labelGaps
                + documentGlyphColumn
                + MonknotTabCloseButton.dimension(theme: theme, zoomScale: zoomScale)
        }
        return min(maximumTabWidth, labelWidth + fixedControls)
    }
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
                        zoomScale: zoomScale,
                        surface: theme.sidebarSurfaceColor
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
        HStack(spacing: scaled(3)) {
            ForEach(tabs) { tab in
                DocumentTabItemView(
                    tab: tab,
                    isSelected: tab.documentID == selectedDocumentID,
                    isMissing: missingDocumentIDs.contains(tab.documentID),
                    saveState: saveState(tab.documentID),
                    theme: theme,
                    zoomScale: zoomScale,
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
        .padding(.horizontal, scaled(3))
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
    let isDisabled: Bool
    let isDragging: Bool
    let select: () -> Void
    let close: () -> Void
    let togglePin: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                HStack(spacing: scaled(8)) {
                    MonknotFileKindGlyph(
                        systemImage: documentIconName,
                        theme: theme,
                        zoomScale: zoomScale
                    )
                        .foregroundStyle(iconColor)
                        .overlay(alignment: .bottomTrailing) {
                            if tab.isPinned, !saveState.isClean {
                                Circle()
                                    .fill(theme.accentColor)
                                    .frame(width: 6, height: 6)
                                    .overlay(Circle().stroke(theme.surfaceColor, lineWidth: 2))
                                    .offset(x: 2, y: 2)
                            }
                        }
                        .accessibilityHidden(true)

                    if tab.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: glyphScaled(9), weight: .medium))
                            .foregroundStyle(theme.mutedForegroundColor)
                            .accessibilityHidden(true)
                    }

                    Text(tab.displayName)
                        .font(.system(size: textScaled(13), weight: .regular))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(
                            maxWidth: scaled(MonknotMetrics.tabMaxWidthBase),
                            alignment: .leading
                        )
                        .accessibilityLabel(tab.displayName)
                    .layoutPriority(0)

                    if isMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: glyphScaled(10), weight: .semibold))
                            .foregroundStyle(Color(hex: theme.semanticColors.diffRemoved))
                            .accessibilityHidden(true)
                    }

                }
                .padding(.leading, scaled(10))
                .padding(.trailing, scaled(8))
                .frame(
                    maxWidth: .infinity,
                    minHeight: MonknotMetrics.interfaceControl(30, theme: theme, zoomScale: zoomScale),
                    maxHeight: MonknotMetrics.interfaceControl(30, theme: theme, zoomScale: zoomScale),
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .frame(maxWidth: .infinity)

            if !tab.isPinned {
                trailingSlot
                    .padding(.trailing, scaled(10))
            }
        }
        .frame(width: preferredTabWidth, alignment: .leading)
        .frame(height: chromeRowHeight, alignment: .center)
        .clipped()
        .background {
            tabBackground
                .padding(.vertical, scaled(7))
        }
        .opacity(opacity)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : MonknotMotion.hoverAnimation, value: isHovered)
        .animation(reduceMotion ? nil : MonknotMotion.hoverAnimation, value: isSelected)
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
        .monknotHelp(isSelected ? nil : helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var tabBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                .fill(theme.elevatedSurfaceColor)
                .overlay {
                    RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                        .strokeBorder(theme.borderColor, lineWidth: 1)
                }
        } else if isHovered && !isDisabled {
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                .fill(theme.foregroundColor.opacity(0.06))
        }
    }

    @ViewBuilder
    private var trailingSlot: some View {
        if isSelected || isHovered {
            MonknotTabCloseButton(
                label: "Close \(tab.displayName)",
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: isDisabled,
                action: close
            )
        } else {
            TabSaveStateIndicator(
                state: saveState,
                theme: theme,
                zoomScale: zoomScale,
                size: glyphScaled(10)
            )
            .frame(
                width: MonknotTabCloseButton.dimension(theme: theme, zoomScale: zoomScale),
                height: MonknotTabCloseButton.dimension(theme: theme, zoomScale: zoomScale)
            )
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
        return theme.mutedForegroundColor
    }

    private var iconColor: Color {
        if isMissing {
            return Color(hex: theme.semanticColors.diffRemoved)
        }
        if isSelected {
            return theme.accentColor
        }
        return isHovered ? theme.mutedForegroundColor : theme.tertiaryForegroundColor
    }

    private var documentIconName: String {
        tab.kind.resolvedSystemImage
    }

    private var preferredTabWidth: CGFloat {
        DocumentTabWidthPolicy.preferredWidth(
            title: tab.displayName,
            isPinned: tab.isPinned,
            theme: theme,
            zoomScale: zoomScale
        )
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
                    .frame(
                        width: MonknotMetrics.interfaceGlyph(6, theme: theme, zoomScale: zoomScale),
                        height: MonknotMetrics.interfaceGlyph(6, theme: theme, zoomScale: zoomScale)
                    )
            case .saving:
                MonknotProgressIndicator(size: size * 0.82, theme: theme)
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
