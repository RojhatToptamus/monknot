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
    @Binding var searchOptions: MonknotSearchOptions
    let dismissDocumentSearch: () -> Void
    let documentSearchFocusChanged: (Bool) -> Void
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

    private var hasPreviewMode: Bool {
        selectedDocument?.hasPreviewMode == true
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

    private var isWorking: Bool {
        isBusy || isDocumentLoading || isSaving
    }

    var body: some View {
        HStack(spacing: scaled(MonknotMetrics.Spacing.s)) {
            Color.clear
                .frame(width: MonknotMetrics.trafficLightReserveBase)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            sidebarToggleButton
                .allowsTopBarWindowActivationEvents()

            WindowNavigationControls(
                navigateBack: navigateBack,
                navigateForward: navigateForward,
                canNavigateBack: canNavigateBack,
                canNavigateForward: canNavigateForward,
                theme: theme,
                zoomScale: zoomScale
            )
            .allowsTopBarWindowActivationEvents()

            Rectangle()
                .fill(theme.separatorColor)
                .frame(width: 1, height: scaled(16))
                .padding(.horizontal, scaled(2))

            tabsOrEmptyTitle
                .layoutPriority(1)

            // The spinner keeps its slot while idle, so starting work never moves the controls after it.
            MonknotProgressIndicator(
                size: MonknotMetrics.interfaceGlyph(16, theme: theme, zoomScale: zoomScale),
                theme: theme,
                isAnimating: isWorking
            )
                .frame(width: scaled(18), height: scaled(18))
                .opacity(isWorking ? 1 : 0)
                .accessibilityLabel("Working")
                .accessibilityHidden(!isWorking)

            // Find sits before the trailing cluster, which never disappears (design.md §10.1–10.2).
            // The tab strip scrolls to make room first; in a narrow, zoomed window the find bar gives
            // way itself (see `documentSearchBar`) rather than push the row past the window.
            if documentSearch.isPresented {
                documentSearchBar
                    // Above the tab strip's priority: the find bar is sized first, the tabs take the rest.
                    .layoutPriority(2)
                    .allowsTopBarWindowActivationEvents()
            }

            viewModeControl
                .allowsTopBarWindowActivationEvents()

            Rectangle()
                .fill(theme.separatorColor)
                .frame(width: 1, height: scaled(16))
                .padding(.horizontal, scaled(4))

            drawerToggleButton
                .allowsTopBarWindowActivationEvents()
        }
        .monknotChromeRowLayout(theme: theme, zoomScale: zoomScale)
        .onChange(of: documentSearch.focusSerial) { _, _ in
            focusDocumentSearchField()
        }
        .onChange(of: documentSearch.isPresented) { _, isPresented in
            if !isPresented {
                isSearchFocused = false
            }
        }
    }

    /// The field is inserted by the same update that presents it; a focus
    /// request made in that update is intermittently dropped.
    private func focusDocumentSearchField() {
        DispatchQueue.main.async {
            isSearchFocused = documentSearch.isPresented
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
            isDisabled: !hasPreviewMode || isDocumentLoading
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View mode")
        .accessibilityValue(hasPreviewMode ? editorMode.rawValue : "Unavailable")
    }

    @ViewBuilder
    private var tabsOrEmptyTitle: some View {
        if tabs.isEmpty {
            WindowTitleBarDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
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
            .allowsTopBarWindowActivationEvents()
        }
    }

    /// The find bar. Short of room it drops, in turn, the option toggles, the match count and the
    /// match arrows (Return, Shift-Return and Command-G still step through matches); only then does the
    /// field narrow. The field and Close always stay, and there is only ever one field, so focus and
    /// typing survive the bar changing shape.
    private var documentSearchBar: some View {
        HStack(spacing: scaled(8)) {
            MonknotSearchGlyph(theme: theme, zoomScale: zoomScale)
                .foregroundStyle(theme.mutedForegroundColor)

            Rectangle()
                .fill(theme.borderColor)
                .frame(width: 1, height: scaled(16))

            TextField(
                "Find in document",
                text: Binding(
                    get: { documentSearch.query },
                    set: { documentSearch.setQuery($0) }
                )
            )
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .font(.system(size: textScaled(13), weight: .regular))
            .foregroundStyle(theme.foregroundColor)
            .frame(minWidth: scaled(60), idealWidth: scaled(150), maxWidth: scaled(150))
            // Sized before the optional controls, which take what is left.
            .layoutPriority(1)
            .onSubmit {
                documentSearch.findNext()
            }
            .accessibilityLabel("Find in document")

            ViewThatFits(in: .horizontal) {
                findBarControls(showsOptions: true, showsCount: true, showsNavigation: true)
                findBarControls(showsOptions: false, showsCount: true, showsNavigation: true)
                findBarControls(showsOptions: false, showsCount: false, showsNavigation: true)
                findBarControls(showsOptions: false, showsCount: false, showsNavigation: false)
            }

            findBarButton(systemImage: "xmark", label: "Close Search") {
                dismissDocumentSearch()
            }
        }
        .padding(.horizontal, scaled(MonknotMetrics.Spacing.l))
        .frame(height: scaled(28))
        .background(
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                .fill(theme.insetFillColor)
                .overlay {
                    // design.md §3: a focused field takes the 1px accent stroke.
                    RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                        .strokeBorder(isSearchFocused ? theme.accentColor : theme.borderColor, lineWidth: 1)
                }
        )
        .onAppear {
            focusDocumentSearchField()
        }
        .onChange(of: isSearchFocused) { _, isFocused in
            documentSearchFocusChanged(isFocused)
        }
        .onDisappear {
            documentSearchFocusChanged(false)
        }
        .onExitCommand(perform: dismissDocumentSearch)
    }

    private func findBarControls(showsOptions: Bool, showsCount: Bool, showsNavigation: Bool) -> some View {
        HStack(spacing: scaled(8)) {
            if showsOptions {
                searchOptionButton(
                    systemImage: "textformat",
                    label: "Match Case",
                    isActive: searchOptions.isCaseSensitive
                ) {
                    searchOptions.isCaseSensitive.toggle()
                }

                searchOptionButton(
                    systemImage: "character.cursor.ibeam",
                    label: "Match Whole Word",
                    isActive: searchOptions.isWholeWord
                ) {
                    searchOptions.isWholeWord.toggle()
                }
            }

            if showsCount {
                Text(documentSearch.countText)
                    .monknotReservingWidth(of: DocumentSearchState.countWidthTemplate)
                    .font(.system(size: textScaled(12), weight: .regular, design: .rounded))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .monospacedDigit()
                    .accessibilityLabel("Search result \(documentSearch.countText)")
            }

            if showsNavigation {
                Rectangle()
                    .fill(theme.borderColor)
                    .frame(width: 1, height: scaled(16))

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
            }
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
            focusRingPlacement: .contained,
            action: action
        )
    }

    private func searchOptionButton(
        systemImage: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        MonknotIconButton(
            systemImage: systemImage,
            label: label,
            theme: theme,
            zoomScale: zoomScale,
            isActive: isActive,
            size: .findBar,
            drawsActiveBackground: false,
            focusRingPlacement: .contained,
            action: action
        )
        .accessibilityValue(isActive ? "On" : "Off")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

}

private extension View {
    @ViewBuilder
    func allowsTopBarWindowActivationEvents() -> some View {
        if #available(macOS 15.0, *) {
            allowsWindowActivationEvents()
        } else {
            self
        }
    }
}
