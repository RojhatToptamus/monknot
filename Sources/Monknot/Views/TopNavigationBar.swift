import MonknotCore
import SwiftUI

struct TopNavigationBar: View {
    @Binding var editorMode: EditorMode
    @Binding var isSplitViewEnabled: Bool
    let emptyStateTitle: String
    let selectedDocument: WorkspaceDocument?
    let isBusy: Bool
    let isDocumentLoading: Bool
    let isSaving: Bool
    let theme: AppTheme
    let zoomScale: Double
    let isTerminalPresented: Bool
    let isSidebarVisible: Bool
    let newMarkdown: () -> Void
    let openFolder: () -> Void
    let toggleTerminal: () -> Void
    let toggleSidebar: () -> Void
    let outlineItems: [MarkdownOutlineItem]
    let selectOutlineItem: (MarkdownOutlineItem) -> Void
    let toggleSplitView: () -> Void
    let canToggleSplitView: Bool
    @Binding var documentSearch: DocumentSearchState
    let tabs: [WorkspaceTabItem]
    let activeTabID: String?
    let missingTabIDs: Set<String>
    let saveState: (String) -> DocumentSaveState
    let selectTab: (String) -> Void
    let closeTab: (String) -> Void
    let togglePinTab: (String) -> Void
    let reorderTab: (String, String?) -> Void
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isSearchFocused: Bool
    @State private var isOutlinePresented = false

    private var isMarkdownSelected: Bool {
        selectedDocument?.kind == .markdown
    }

    private var supportsSourcePreviewToggle: Bool {
        guard let document = selectedDocument else { return false }
        return (document.kind == .markdown || document.capabilities.canPreviewHTML) && !isSplitViewEnabled
    }

    private var supportsSplitView: Bool {
        guard let document = selectedDocument else { return false }
        return document.kind == .markdown || document.capabilities.canPreviewHTML
    }

    private var uiFontSize: Double { theme.uiFontSize }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(MonknotMetrics.Spacing.s)) {
            leadingNavigation

            sidebarToggleButton

            tabsOrEmptyTitle

            if isBusy || isDocumentLoading || isSaving {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(zoomScale * (uiFontSize / 16))
                    .frame(width: scaled(18), height: scaled(18))
                    .padding(.horizontal, scaled(2))
                    .accessibilityLabel("Working")
            }

            if documentSearch.isPresented {
                documentSearchBar
                    .transition(MonknotMotion.searchBarTransition(reduceMotion: reduceMotion))
            } else {
                trailingActions
                    .transition(MonknotMotion.searchBarTransition(reduceMotion: reduceMotion))

                drawerToggleButton
            }
        }
        .monknotChromeRowLayout(theme: theme, zoomScale: zoomScale)
        .animation(MonknotMotion.chromeTransition(reduceMotion: reduceMotion), value: documentSearch.isPresented)
        .onChange(of: documentSearch.focusSerial) { _, _ in
            isSearchFocused = documentSearch.isPresented
        }
        .onChange(of: documentSearch.isPresented) { _, isPresented in
            guard isPresented else { return }
            isSearchFocused = true
        }
    }

    private var drawerToggleButton: some View {
        ChromeBarButton(
            systemImage: MonknotWorkspaceIcons.sidebarRight,
            label: isTerminalPresented ? "Hide Right Drawer" : "Show Right Drawer",
            theme: theme,
            zoomScale: zoomScale,
            uiFontSize: uiFontSize,
            isActive: isTerminalPresented,
            action: toggleTerminal
        )
        .keyboardShortcut("j", modifiers: [.command, .option])
        .accessibilityValue(isTerminalPresented ? "Open" : "Closed")
    }

    /// When the sidebar is hidden, the editor pane spans the full window
    /// width and the chrome row sits behind the macOS traffic lights.
    /// Reserve just enough leading space to clear them. The chrome row
    /// already insets content by its horizontal padding and adds spacing
    /// before the first control, so subtract both to avoid an oversized
    /// gap while keeping the toggle clear of the traffic lights.
    private var leadingNavigation: some View {
        Group {
            if !isSidebarVisible {
                Color.clear
                    .frame(width: MonknotMetrics.scale(
                        MonknotMetrics.trafficLightReserveBase
                            - MonknotMetrics.chromeHorizontalPaddingBase
                            - MonknotMetrics.Spacing.s,
                        theme: theme,
                        zoomScale: zoomScale
                    ))
            }
        }
    }

    private var sidebarToggleButton: some View {
        ChromeBarButton(
            systemImage: MonknotWorkspaceIcons.sidebarLeft,
            label: isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
            theme: theme,
            zoomScale: zoomScale,
            uiFontSize: uiFontSize,
            isActive: isSidebarVisible,
            action: toggleSidebar
        )
        .keyboardShortcut("s", modifiers: [.command, .control])
    }

    @ViewBuilder
    private var tabsOrEmptyTitle: some View {
        if tabs.isEmpty {
            HStack(spacing: scaled(8)) {
                Text(emptyStateTitle)
                    .font(.system(size: scaled(13), weight: .medium))
                    .foregroundStyle(theme.mutedForegroundColor.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)

                WindowDoubleClickZoomArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
            .padding(.leading, scaled(6))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            DocumentTabBar(
                tabs: tabs,
                selectedDocumentID: activeTabID,
                missingDocumentIDs: missingTabIDs,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                isDisabled: isBusy,
                saveState: saveState,
                selectTab: selectTab,
                closeTab: closeTab,
                togglePin: togglePinTab,
                reorderTab: reorderTab
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            WindowDoubleClickZoomArea()
                .frame(width: scaled(20))
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        HStack(spacing: scaled(4)) {
            if isSplitViewEnabled && supportsSplitView {
                splitViewIndicator
            }
            if isMarkdownSelected {
                outlineButton
            }
            if supportsSourcePreviewToggle {
                sourcePreviewSwitch
                    .disabled(isDocumentLoading)
            }
        }
    }

    private var splitViewIndicator: some View {
        ChromeBarButton(
            systemImage: "rectangle.split.2x1",
            label: isSplitViewEnabled ? "Turn Off Split View" : "Split View",
            theme: theme,
            zoomScale: zoomScale,
            uiFontSize: uiFontSize,
            isActive: isSplitViewEnabled,
            isDisabled: !canToggleSplitView || isDocumentLoading,
            action: toggleSplitView
        )
        .help("Split view is on (⌘\\). Click to turn off.")
        .accessibilityValue(isSplitViewEnabled ? "On" : "Off")
    }

    private var sourcePreviewSwitch: some View {
        MonknotSegmentedControl(
            options: [
                MonknotSegmentOption(id: EditorMode.source.rawValue, systemImage: EditorMode.source.resolvedSystemImage, accessibilityLabel: EditorMode.source.title),
                MonknotSegmentOption(id: EditorMode.preview.rawValue, systemImage: EditorMode.preview.resolvedSystemImage, accessibilityLabel: EditorMode.preview.title)
            ],
            selection: Binding(
                get: { editorMode.rawValue },
                set: { editorMode = EditorMode(rawValue: $0) ?? .preview }
            ),
            theme: theme,
            zoomScale: zoomScale
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor mode")
    }

    private var documentSearchBar: some View {
        HStack(spacing: scaled(8)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: scaled(14), weight: .medium))
                .foregroundStyle(theme.mutedForegroundColor)
                .accessibilityHidden(true)

            Rectangle()
                .fill(theme.borderColor)
                .frame(width: 1, height: scaled(20))

            TextField(
                "Search in doc...",
                text: Binding(
                    get: { documentSearch.query },
                    set: { documentSearch.setQuery($0) }
                )
            )
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .font(.system(size: scaled(13), weight: .regular))
            .foregroundStyle(theme.foregroundColor)
            .frame(width: scaled(190))
            .onSubmit {
                documentSearch.findNext()
            }
            .accessibilityLabel("Search in document")

            Text(documentSearch.countText)
                .font(.system(size: scaled(11), weight: .medium, design: .rounded))
                .foregroundStyle(theme.mutedForegroundColor)
                .monospacedDigit()
                .frame(minWidth: scaled(42), alignment: .trailing)
                .accessibilityLabel("Search result \(documentSearch.countText)")

            Rectangle()
                .fill(theme.borderColor)
                .frame(width: 1, height: scaled(20))

            findBarButton(
                systemImage: "chevron.up",
                label: "Previous Match",
                isDisabled: documentSearch.totalCount == 0
            ) {
                documentSearch.findPrevious()
            }

            findBarButton(
                systemImage: "chevron.down",
                label: "Next Match",
                isDisabled: documentSearch.totalCount == 0
            ) {
                documentSearch.findNext()
            }

            findBarButton(systemImage: "xmark", label: "Close Search") {
                documentSearch.dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, scaled(MonknotMetrics.Spacing.l))
        .frame(height: scaled(32))
        .background(
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                .fill(theme.insetFillColor)
                .overlay {
                    RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                        .strokeBorder(theme.borderColor, lineWidth: 1)
                }
        )
        .onAppear {
            isSearchFocused = true
        }
    }

    private func findBarButton(
        systemImage: String,
        label: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        MonknotIconButton(
            systemImage: systemImage,
            label: label,
            theme: theme,
            zoomScale: zoomScale,
            isDisabled: isDisabled,
            size: .findBar,
            action: action
        )
    }

    private var outlineButton: some View {
        ChromeBarButton(
            systemImage: MonknotWorkspaceIcons.outline,
            label: isOutlinePresented ? "Close Outline" : "Open Outline",
            theme: theme,
            zoomScale: zoomScale,
            uiFontSize: uiFontSize,
            isActive: isOutlinePresented,
            isDisabled: isDocumentLoading,
            action: { isOutlinePresented.toggle() }
        )
        .popover(isPresented: $isOutlinePresented, arrowEdge: .bottom) {
            MarkdownOutlinePanel(
                items: outlineItems,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                select: { item in
                    isOutlinePresented = false
                    selectOutlineItem(item)
                }
            )
        }
    }

}
