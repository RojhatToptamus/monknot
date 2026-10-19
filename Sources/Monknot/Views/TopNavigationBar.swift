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
    var tabMenu: DocumentTabMenuActions = .none
    /// Where the document card starts; the tab strip starts there while the sidebar is open.
    var chromeAlignment: ChromeAlignmentModel? = nil
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

    private var isWorking: Bool {
        isBusy || isDocumentLoading || isSaving
    }

    var body: some View {
        // Groups 8 apart, items within a group 2 apart, and never a rule (design.md §10.1).
        HStack(spacing: scaled(MonknotMetrics.barGroupGapBase)) {
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

            tabsOrEmptyTitle
                .modifier(TitlebarCardAlignment(alignment: chromeAlignment, stripInset: scaled(3)))
                .layoutPriority(1)

            // The spinner keeps its slot while idle, so starting work never moves the controls after it.
            MonknotProgressIndicator(
                size: MonknotMetrics.interfaceControl(MonknotMetrics.loadingSpinnerSizeBase, theme: theme, zoomScale: zoomScale),
                theme: theme,
                isAnimating: isWorking
            )
                .frame(width: scaled(MonknotMetrics.rowIconColumnWidthBase), height: scaled(MonknotMetrics.rowIconColumnWidthBase))
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

            drawerToggleButton
                .allowsTopBarWindowActivationEvents()
        }
        .monknotTitlebarRowLayout(theme: theme, zoomScale: zoomScale)
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
            action: toggleSidebar
        )
        .accessibilityValue(isSidebarVisible ? "Open" : "Closed")
    }

    /// Like the sidebar toggle: the open panel shows its own state, so the button never lights up.
    private var drawerToggleButton: some View {
        MonknotIconButton(
            systemImage: MonknotWorkspaceIcons.sidebarRight,
            label: isTerminalPresented ? "Hide Terminal Panel" : "Show Terminal Panel",
            theme: theme,
            zoomScale: zoomScale,
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
                reorderTab: reorderTab,
                menu: tabMenu
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsTopBarWindowActivationEvents()
        }
    }

    /// The find bar: the shared field (design.md §5.7) holding small buttons, with no rule inside it.
    /// Short of room it drops, in turn, the option toggles, the match count and the match arrows
    /// (Return, Shift-Return and Command-G still step through matches); only then does the field
    /// narrow. The field and Close always stay, and there is only ever one field, so focus and typing
    /// survive the bar changing shape.
    private var documentSearchBar: some View {
        HStack(spacing: scaled(6)) {
            MonknotSearchGlyph(theme: theme, zoomScale: zoomScale)
                .foregroundStyle(theme.tertiaryForegroundColor)

            TextField(
                "Find in document",
                text: Binding(
                    get: { documentSearch.query },
                    set: { documentSearch.setQuery($0) }
                )
            )
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
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
        .monknotField(isFocused: isSearchFocused, trailingPadding: 3, theme: theme, zoomScale: zoomScale)
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
        HStack(spacing: scaled(6)) {
            if showsOptions {
                HStack(spacing: scaled(MonknotMetrics.barItemGapBase)) {
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
            }

            if showsCount {
                // A count: 12 `ink3` in tabular figures, as wide as any count it shows.
                Text(documentSearch.countText)
                    .monknotReservingWidth(of: DocumentSearchState.countWidthTemplate)
                    .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .monospacedDigit()
                    .accessibilityLabel("Search result \(documentSearch.countText)")
            }

            if showsNavigation {
                HStack(spacing: scaled(MonknotMetrics.barItemGapBase)) {
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
            size: .small,
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
            size: .small,
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


/// The document card's leading edge in window coordinates, published by the split view. Only the
/// tab strip's alignment observes it, so a sliding sidebar re-lays out the titlebar and nothing else.
@MainActor
final class ChromeAlignmentModel: ObservableObject {
    @Published var documentLeadingEdge: CGFloat = 0
}

/// Starts the tab strip on the document card's leading edge, as in Linear: the first tab's chip sits
/// on the card's edge while the sidebar is open, and right after the navigation buttons when it is
/// closed. Padding rather than a spacer, so the titlebar's own spacing is not added twice.
private struct TitlebarCardAlignment: ViewModifier {
    let alignment: ChromeAlignmentModel?
    let stripInset: CGFloat

    func body(content: Content) -> some View {
        if let alignment {
            AlignedContent(alignment: alignment, stripInset: stripInset, content: content)
        } else {
            content
        }
    }

    private struct AlignedContent: View {
        @ObservedObject var alignment: ChromeAlignmentModel
        let stripInset: CGFloat
        let content: Content
        @State private var start: CGFloat = 0

        var body: some View {
            content
                .padding(.leading, max(0, alignment.documentLeadingEdge - start - stripInset))
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { start = proxy.frame(in: .global).minX }
                            .onChange(of: proxy.frame(in: .global).minX) { _, minX in start = minX }
                    }
                }
        }
    }
}
