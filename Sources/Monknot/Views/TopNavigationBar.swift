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
    @FocusState private var isSearchFocused: Bool
    @State private var isOutlinePresented = false
    @State private var isOverflowMenuHovered = false

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
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    private func glyphScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceGlyph(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        GeometryReader { proxy in
            let layoutMode = MonknotMetrics.topBarLayoutMode(
                availableWidth: proxy.size.width,
                theme: theme,
                zoomScale: zoomScale
            )

            HStack(spacing: scaled(MonknotMetrics.Spacing.xxs)) {
                leadingSidebarControl

                tabsOrEmptyTitle

                if isBusy || isDocumentLoading || isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(theme.interfaceControlScale(zoomScale: zoomScale))
                        .frame(width: scaled(18), height: scaled(18))
                        .padding(.horizontal, scaled(2))
                        .accessibilityLabel("Working")
                }

                if documentSearch.isPresented {
                    documentSearchBar(layoutMode: layoutMode)
                } else {
                    adaptiveTrailingActions(layoutMode: layoutMode)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .monknotChromeRowLayout(theme: theme, zoomScale: zoomScale)
        .onChange(of: documentSearch.focusSerial) { _, _ in
            isSearchFocused = documentSearch.isPresented
        }
        .onChange(of: documentSearch.isPresented) { _, isPresented in
            guard isPresented else { return }
            isSearchFocused = true
        }
    }

    /// The leading toggle always belongs to the middle toolbar. A persistent
    /// clearance view grows with the same transition as the split column when
    /// the sidebar is hidden, keeping the control clear of the traffic lights
    /// without inserting or reparenting it during the animation.
    private var leadingSidebarControl: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: hiddenSidebarLeadingClearance)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            sidebarToggleButton
        }
        .animation(MonknotMotion.sidebarTransition(reduceMotion: reduceMotion), value: isSidebarVisible)
    }

    private var hiddenSidebarLeadingClearance: CGFloat {
        guard !isSidebarVisible else { return 0 }
        return max(
            0,
            MonknotMetrics.windowChromeLeadingReservedWidth(theme: theme, zoomScale: zoomScale)
                - MonknotMetrics.chromeHorizontalPadding(theme: theme, zoomScale: zoomScale)
        )
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
        .accessibilityValue(isSidebarVisible ? "Open" : "Closed")
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
        .accessibilityValue(isTerminalPresented ? "Open" : "Closed")
    }

    @ViewBuilder
    private var tabsOrEmptyTitle: some View {
        if tabs.isEmpty {
            HStack(spacing: scaled(8)) {
                if !isSidebarVisible {
                    Text(emptyStateTitle)
                        .font(.system(size: textScaled(13), weight: .medium))
                        .foregroundStyle(theme.mutedForegroundColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                }

                WindowTitleBarDragArea()
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

    @ViewBuilder
    private func adaptiveTrailingActions(layoutMode: MonknotTopBarLayoutMode) -> some View {
        switch layoutMode {
        case .regular:
            trailingActions

            drawerToggleButton
                .padding(.leading, scaled(MonknotMetrics.Spacing.xxs))
        case .compact:
            if hasOverflowActions(includeDrawer: false) {
                overflowMenu(includeDrawer: false)
            }

            drawerToggleButton
                .padding(.leading, scaled(MonknotMetrics.Spacing.xxs))
        case .minimal:
            overflowMenu(includeDrawer: true)
        }
    }

    private func hasOverflowActions(includeDrawer: Bool) -> Bool {
        includeDrawer || isMarkdownSelected || supportsSourcePreviewToggle || (isSplitViewEnabled && supportsSplitView)
    }

    private func overflowMenu(includeDrawer: Bool) -> some View {
        Menu {
            if isSplitViewEnabled && supportsSplitView {
                Button("Turn Off Split View", systemImage: "rectangle.split.2x1") {
                    toggleSplitView()
                }
                .disabled(!canToggleSplitView || isDocumentLoading)
            }

            if isMarkdownSelected {
                Button("Document Outline", systemImage: MonknotWorkspaceIcons.outline) {
                    isOutlinePresented = true
                }
                .disabled(isDocumentLoading)
            }

            if supportsSourcePreviewToggle {
                Picker("Editor Mode", selection: Binding(
                    get: { editorMode },
                    set: { editorMode = $0 }
                )) {
                    ForEach(EditorMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.resolvedSystemImage)
                            .tag(mode)
                    }
                }
                .disabled(isDocumentLoading)
            }

            if includeDrawer {
                if isMarkdownSelected || supportsSourcePreviewToggle || (isSplitViewEnabled && supportsSplitView) {
                    Divider()
                }
                Button(
                    isTerminalPresented ? "Hide Right Drawer" : "Show Right Drawer",
                    systemImage: MonknotWorkspaceIcons.sidebarRight,
                    action: toggleTerminal
                )
            }
        } label: {
            TopBarOverflowLabel(
                theme: theme,
                zoomScale: zoomScale,
                isActive: isOutlinePresented || isSplitViewEnabled || (includeDrawer && isTerminalPresented),
                isHovered: isOverflowMenuHovered
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isOverflowMenuHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isOverflowMenuHovered)
        .help("More document actions")
        .accessibilityLabel("More document actions")
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

    private func documentSearchBar(layoutMode: MonknotTopBarLayoutMode) -> some View {
        HStack(spacing: scaled(8)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: glyphScaled(14), weight: .medium))
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
            .font(.system(size: textScaled(13), weight: .regular))
            .foregroundStyle(theme.foregroundColor)
            .frame(width: searchFieldWidth(layoutMode: layoutMode))
            .onSubmit {
                documentSearch.findNext()
            }
            .accessibilityLabel("Search in document")

            if layoutMode != .minimal {
                Text(documentSearch.countText)
                    .font(.system(size: textScaled(11), weight: .medium, design: .rounded))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .monospacedDigit()
                    .frame(minWidth: scaled(42), alignment: .trailing)
                    .accessibilityLabel("Search result \(documentSearch.countText)")
            }

            Rectangle()
                .fill(theme.borderColor)
                .frame(width: 1, height: scaled(20))

            if layoutMode == .regular {
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
            } else {
                searchNavigationMenu
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

    private func searchFieldWidth(layoutMode: MonknotTopBarLayoutMode) -> CGFloat {
        switch layoutMode {
        case .regular:
            return scaled(190)
        case .compact:
            return scaled(112)
        case .minimal:
            return scaled(64)
        }
    }

    private var searchNavigationMenu: some View {
        Menu {
            Button("Previous Match", systemImage: "chevron.up") {
                documentSearch.findPrevious()
            }
            .disabled(documentSearch.totalCount == 0)

            Button("Next Match", systemImage: "chevron.down") {
                documentSearch.findNext()
            }
            .disabled(documentSearch.totalCount == 0)
        } label: {
            TopBarOverflowLabel(
                theme: theme,
                zoomScale: zoomScale,
                isActive: false,
                isHovered: isOverflowMenuHovered
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isOverflowMenuHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isOverflowMenuHovered)
        .help("Search navigation")
        .accessibilityLabel("Search navigation")
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

private struct TopBarOverflowLabel: View {
    let theme: AppTheme
    let zoomScale: Double
    let isActive: Bool
    var isHovered = false

    var body: some View {
        let dimension = MonknotMetrics.chromeButtonDimension(theme: theme, zoomScale: zoomScale)
        let cornerRadius = theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)

        Image(systemName: "ellipsis")
            .font(.system(
                size: MonknotMetrics.chromeGlyphSize(theme: theme, zoomScale: zoomScale),
                weight: .medium
            ))
            .foregroundStyle(isActive || isHovered ? theme.foregroundColor : theme.mutedForegroundColor)
            .frame(width: dimension, height: dimension)
            .background {
                if isActive || isHovered {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(theme.foregroundColor.opacity(
                            isActive
                                ? (theme.isDark ? 0.12 : 0.08)
                                : MonknotIconButton.IconButtonSize.chrome.hoverBackgroundOpacity(
                                    isDark: theme.isDark
                                )
                        ))
                }
            }
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(theme.borderColor, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
