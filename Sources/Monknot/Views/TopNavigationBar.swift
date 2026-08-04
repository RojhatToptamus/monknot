import MonknotCore
import SwiftUI

struct TopNavigationBar: View {
    static let markdownViewModeOptions = [
        MonknotSegmentOption(
            id: EditorMode.source.rawValue,
            systemImage: EditorMode.source.resolvedSystemImage,
            accessibilityLabel: "Source"
        ),
        MonknotSegmentOption(
            id: EditorMode.preview.rawValue,
            systemImage: EditorMode.preview.resolvedSystemImage,
            accessibilityLabel: "Preview"
        )
    ]

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
    let toggleSplitView: () -> Void
    @Binding var documentSearch: DocumentSearchState
    let tabs: [WorkspaceTabItem]
    let activeTabID: String?
    let missingTabIDs: Set<String>
    let saveState: (String) -> DocumentSaveState
    let selectTab: (String) -> Void
    let closeTab: (String) -> Void
    let togglePinTab: (String) -> Void
    let reorderTab: (String, String?) -> Void
    var navigateBack: () -> Void = {}
    var navigateForward: () -> Void = {}
    var canNavigateBack = false
    var canNavigateForward = false
    @FocusState private var isSearchFocused: Bool
    @State private var isOverflowMenuHovered = false

    private var showsMarkdownViewControls: Bool {
        selectedDocument?.kind == .markdown
    }

    private var uiFontSize: Double { theme.uiFontSize }

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
        HStack(spacing: scaled(MonknotMetrics.Spacing.m)) {
            Color.clear
                .frame(width: scaled(64))
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            sidebarToggleButton

            WindowNavigationControls(
                navigateBack: navigateBack,
                navigateForward: navigateForward,
                canNavigateBack: canNavigateBack,
                canNavigateForward: canNavigateForward,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            )

            Rectangle()
                .fill(theme.separatorColor)
                .frame(width: 1, height: scaled(20))
                .padding(.horizontal, scaled(2))

            tabsOrEmptyTitle
                .layoutPriority(1)

            if isBusy || isDocumentLoading || isSaving {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(theme.interfaceControlScale(zoomScale: zoomScale))
                    .frame(width: scaled(18), height: scaled(18))
                    .accessibilityLabel("Working")
            }

            if documentSearch.isPresented {
                documentSearchBar(layoutMode: .regular)
            } else {
                if showsMarkdownViewControls {
                    viewModeControl
                        .disabled(isDocumentLoading)
                }

                drawerToggleButton
            }
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
            label: isTerminalPresented ? "Hide Terminal Panel" : "Show Terminal Panel",
            theme: theme,
            zoomScale: zoomScale,
            uiFontSize: uiFontSize,
            isActive: isTerminalPresented,
            action: toggleTerminal
        )
        .accessibilityValue(isTerminalPresented ? "Open" : "Closed")
    }

    private var viewModeControl: some View {
        MonknotSegmentedControl(
            options: Self.markdownViewModeOptions,
            selection: Binding(
                get: {
                    editorMode.rawValue
                },
                set: { selection in
                    if isSplitViewEnabled {
                        toggleSplitView()
                    }
                    if selection == EditorMode.preview.rawValue {
                        editorMode = .preview
                    } else {
                        editorMode = .source
                    }
                }
            ),
            theme: theme,
            zoomScale: zoomScale
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View mode")
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
