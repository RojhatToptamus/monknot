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

    private var showsMarkdownViewControls: Bool {
        selectedDocument?.kind == .markdown
    }

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
        HStack(spacing: scaled(MonknotMetrics.Spacing.s)) {
            Color.clear
                .frame(width: 64)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            sidebarToggleButton

            WindowNavigationControls(
                navigateBack: navigateBack,
                navigateForward: navigateForward,
                canNavigateBack: canNavigateBack,
                canNavigateForward: canNavigateForward,
                theme: theme,
                zoomScale: zoomScale
            )

            Rectangle()
                .fill(theme.separatorColor)
                .frame(width: 1, height: scaled(16))
                .padding(.horizontal, scaled(2))

            tabsOrEmptyTitle
                .layoutPriority(1)

            if isBusy || isDocumentLoading || isSaving {
                MonknotProgressIndicator(
                    size: MonknotMetrics.interfaceGlyph(16, theme: theme, zoomScale: zoomScale),
                    theme: theme
                )
                    .frame(width: scaled(18), height: scaled(18))
                    .accessibilityLabel("Working")
            }

            if documentSearch.isPresented {
                documentSearchBar
            } else {
                viewModeControl

                Rectangle()
                    .fill(theme.separatorColor)
                    .frame(width: 1, height: scaled(16))
                    .padding(.horizontal, scaled(4))

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
        MonknotIconButton(
            systemImage: MonknotWorkspaceIcons.sidebarLeft,
            label: isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
            theme: theme,
            zoomScale: zoomScale,
            drawsBorder: true,
            action: toggleSidebar
        )
        .accessibilityValue(isSidebarVisible ? "Open" : "Closed")
    }

    private var drawerToggleButton: some View {
        MonknotIconButton(
            systemImage: MonknotWorkspaceIcons.sidebarRight,
            label: isTerminalPresented ? "Hide Terminal Panel" : "Show Terminal Panel",
            theme: theme,
            zoomScale: zoomScale,
            isActive: isTerminalPresented,
            drawsBorder: true,
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
            zoomScale: zoomScale,
            isDisabled: !showsMarkdownViewControls || isDocumentLoading
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View mode")
        .accessibilityValue(showsMarkdownViewControls ? editorMode.rawValue : "Unavailable")
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

    private var documentSearchBar: some View {
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
            .frame(width: scaled(190))
            .onSubmit {
                documentSearch.findNext()
            }
            .accessibilityLabel("Search in document")

            Text(documentSearch.countText)
                .font(.system(size: textScaled(11), weight: .medium, design: .rounded))
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

}
