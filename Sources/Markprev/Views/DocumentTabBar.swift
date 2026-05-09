import AppKit
import MarkprevCore
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

    @State private var contentWidth: CGFloat = 0

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        if !tabs.isEmpty {
            GeometryReader { proxy in
                ZStack(alignment: .trailing) {
                    HiddenHorizontalTabScrollView(contentWidth: $contentWidth) {
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

                    if contentWidth > proxy.size.width + scaled(2) {
                        overflowCue
                    }
                }
            }
            .frame(height: scaled(36))
            .background(theme.surfaceColor)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.borderColor)
                    .frame(height: 1)
            }
        }
    }

    private var overflowCue: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [
                    theme.surfaceColor.opacity(0),
                    theme.surfaceColor.opacity(0.92)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: scaled(36))

            Image(systemName: "chevron.right")
                .font(.system(size: scaled(9), weight: .semibold))
                .foregroundStyle(theme.mutedForegroundColor.opacity(0.78))
                .frame(width: scaled(14), height: scaled(30))
                .padding(.trailing, scaled(5))
        }
        .allowsHitTesting(false)
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

    @State private var draggedDocumentID: String?
    @State private var tabFrames: [String: CGRect] = [:]

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        HStack(spacing: scaled(4)) {
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
        .padding(.horizontal, scaled(10))
        .padding(.vertical, scaled(4))
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
                        .font(.system(size: scaled(12), weight: .regular))
                        .foregroundStyle(isSelected ? theme.foregroundColor : theme.mutedForegroundColor)
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
                .padding(.leading, scaled(9))
                .padding(.trailing, scaled(tab.isPinned ? 8 : 4))
                .frame(height: scaled(26))
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
                .markprevPointerCursor(enabled: !isDisabled)
                .padding(.trailing, scaled(3))
            }
        }
        .frame(minWidth: scaled(tab.isPinned ? 118 : 150), maxWidth: scaled(tab.isPinned ? 178 : 232), alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale)))
        .overlay {
            RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale))
                .strokeBorder(borderColor, lineWidth: 1)
        }
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
            return theme.foregroundColor.opacity(theme.isDark ? 0.055 : 0.04)
        }
        return theme.controlTrackFillColor.opacity(0.65)
    }

    private var opacity: Double {
        if isDragging {
            return 0.45
        }
        return isDisabled ? 0.55 : 1
    }

    private var borderColor: Color {
        if isSelected {
            return theme.borderColor
        }
        return theme.borderColor.opacity(isHovered ? 1 : 0.65)
    }

    private var iconColor: Color {
        if isMissing {
            return Color(hex: theme.semanticColors.diffRemoved)
        }
        if isSelected {
            return theme.accentColor
        }
        return theme.mutedForegroundColor
    }

    private var closeIconColor: Color {
        if isHovered {
            return theme.foregroundColor.opacity(0.9)
        }
        return theme.mutedForegroundColor.opacity(0.75)
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

private struct HiddenHorizontalTabScrollView<Content: View>: NSViewRepresentable {
    @Binding var contentWidth: CGFloat
    let content: Content

    init(contentWidth: Binding<CGFloat>, @ViewBuilder content: () -> Content) {
        self._contentWidth = contentWidth
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentWidth: $contentWidth)
    }

    func makeNSView(context: Context) -> TabStripScrollView {
        let scrollView = TabStripScrollView()
        let hostingView = TabStripHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.required, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.required, for: .horizontal)

        scrollView.documentView = hostingView
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            hostingView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
            hostingView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor)
        ])

        context.coordinator.hostingView = hostingView
        context.coordinator.updateContentWidth()
        return scrollView
    }

    func updateNSView(_ scrollView: TabStripScrollView, context: Context) {
        context.coordinator.contentWidth = $contentWidth
        context.coordinator.hostingView?.rootView = content
        context.coordinator.hostingView?.invalidateIntrinsicContentSize()
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        context.coordinator.updateContentWidth()
    }

    final class Coordinator {
        var contentWidth: Binding<CGFloat>
        var hostingView: NSHostingView<Content>?

        init(contentWidth: Binding<CGFloat>) {
            self.contentWidth = contentWidth
        }

        func updateContentWidth() {
            guard let hostingView else { return }
            let width = max(0, hostingView.fittingSize.width)
            let contentWidth = contentWidth
            DispatchQueue.main.async {
                if abs(contentWidth.wrappedValue - width) > 0.5 {
                    contentWidth.wrappedValue = width
                }
            }
        }
    }
}

private final class TabStripHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool {
        false
    }
}

private final class TabStripClipView: NSClipView {
    override var mouseDownCanMoveWindow: Bool {
        false
    }
}

private final class TabStripScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > 0.1 {
            super.scrollWheel(with: event)
            return
        }

        let verticalDelta = event.scrollingDeltaY
        guard abs(verticalDelta) > 0.1 else {
            super.scrollWheel(with: event)
            return
        }

        scrollHorizontally(by: verticalDelta)
    }

    private func configure() {
        let clipView = TabStripClipView(frame: bounds)
        clipView.drawsBackground = false
        contentView = clipView

        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
    }

    private func scrollHorizontally(by delta: CGFloat) {
        guard let documentView else { return }
        let maxX = max(0, documentView.bounds.width - contentView.bounds.width)
        guard maxX > 0 else { return }

        var origin = contentView.bounds.origin
        origin.x = min(max(origin.x + delta, 0), maxX)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
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
