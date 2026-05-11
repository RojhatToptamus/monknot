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

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    private var chromeRowHeight: CGFloat {
        scaled(44)
    }

    var body: some View {
        if !tabs.isEmpty {
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
                    reorderTab: reorderTab
                )
            }
            .frame(maxHeight: chromeRowHeight)
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
    let uiFontSize: Double
    let isDisabled: Bool
    let saveState: (String) -> DocumentSaveState
    let selectTab: (String) -> Void
    let closeTab: (String) -> Void
    let togglePin: (String) -> Void
    let reorderTab: (String, String?) -> Void

    @State private var draggedDocumentID: String?
    @State private var tabFrames: [String: CGRect] = [:]

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    private var chromeRowHeight: CGFloat {
        scaled(44)
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
                .background(TabFrameReader(documentID: tab.documentID))
                .highPriorityGesture(tabDragGesture(for: tab))
            }
        }
        .padding(.horizontal, scaled(2))
        .frame(height: chromeRowHeight, alignment: .center)
        .fixedSize(horizontal: true, vertical: false)
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(TabFramePreferenceKey.self) { frames in
            tabFrames = frames
        }
    }

    private func tabDragGesture(for tab: WorkspaceTabItem) -> some Gesture {
        DragGesture(minimumDistance: scaled(5), coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                guard !isDisabled else { return }
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
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: scaled(6)) {
                    Image(systemName: documentIconName)
                        .font(.system(size: scaled(12), weight: .regular))
                        .foregroundStyle(iconColor)
                        .frame(width: scaled(15))
                        .accessibilityHidden(true)

                    if tab.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: scaled(9), weight: .medium))
                            .foregroundStyle(theme.mutedForegroundColor)
                            .accessibilityHidden(true)
                    }

                    Text(tab.displayName)
                        .font(.system(size: scaled(12), weight: isSelected ? .medium : .regular))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: scaled(tab.isPinned ? 130 : 180), alignment: .leading)

                    if isMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: scaled(10), weight: .semibold))
                            .foregroundStyle(Color(hex: theme.semanticColors.diffRemoved))
                            .accessibilityHidden(true)
                    }

                    TabSaveStateIndicator(
                        state: saveState,
                        theme: theme,
                        zoomScale: zoomScale,
                        size: scaled(10)
                    )
                }
                .padding(.leading, scaled(10))
                .padding(.trailing, scaled(tab.isPinned ? 10 : 4))
                .frame(height: scaled(28))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)

            if !tab.isPinned {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: scaled(9), weight: .bold))
                        .foregroundStyle(closeIconColor)
                        .frame(width: scaled(20), height: scaled(22))
                        .contentShape(RoundedRectangle(cornerRadius: theme.chromeRadius(5, zoomScale: zoomScale)))
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .help("Close Tab")
                .accessibilityLabel("Close \(tab.displayName)")
                .monknotPointerCursor(enabled: !isDisabled)
                .padding(.trailing, scaled(4))
            }
        }
        .frame(minWidth: scaled(tab.isPinned ? 110 : 140), maxWidth: scaled(tab.isPinned ? 178 : 232), alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale)))
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

    private var background: Color {
        if isSelected {
            return theme.elevatedSurfaceColor
        }
        if isHovered && !isDisabled {
            return theme.foregroundColor.opacity(theme.isDark ? 0.05 : 0.035)
        }
        return .clear
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
        return theme.mutedForegroundColor.opacity(0.78)
    }

    private var iconColor: Color {
        if isMissing {
            return Color(hex: theme.semanticColors.diffRemoved)
        }
        if isSelected {
            return theme.accentColor
        }
        return theme.mutedForegroundColor.opacity(0.7)
    }

    private var closeIconColor: Color {
        if isHovered {
            return theme.foregroundColor.opacity(0.85)
        }
        return theme.mutedForegroundColor.opacity(isSelected ? 0.6 : 0)
    }

    private var documentIconName: String {
        switch tab.kind {
        case .markdown:
            return "doc.text.fill"
        case .pdf:
            return "doc.richtext"
        case .text:
            return "doc.plaintext"
        case .media:
            return "play.rectangle"
        case .nativePreview:
            return "doc.viewfinder"
        case .unsupported:
            return "doc"
        }
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
                    .frame(width: max(5, size * 0.58), height: max(5, size * 0.58))
            case .saving:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(max(0.6, zoomScale * 0.7))
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
