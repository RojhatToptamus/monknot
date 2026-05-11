import MonknotCore
import SwiftUI

struct TopNavigationBar: View {
    @ObservedObject var store: WorkspaceStore
    @Binding var editorMode: EditorMode
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
    @Binding var documentSearch: DocumentSearchState
    let tabs: [WorkspaceTabItem]
    let activeTabID: String?
    let missingTabIDs: Set<String>
    let selectTab: (String) -> Void
    let closeTab: (String) -> Void
    let togglePinTab: (String) -> Void
    let reorderTab: (String, String?) -> Void
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isSearchFocused: Bool
    @State private var isOutlinePresented = false

    private var emptyStateTitle: String {
        store.workspaceURL?.lastPathComponent ?? "monknot"
    }

    private var isMarkdownSelected: Bool {
        store.selectedDocument?.kind == .markdown
    }

    private var uiFontSize: Double { theme.uiFontSize }

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        HStack(spacing: scaled(6)) {
            leadingNavigation

            sidebarToggleButton

            tabsOrEmptyTitle

            if store.isBusy || store.isDocumentLoading || store.isSaving {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(zoomScale * (uiFontSize / 16))
                    .frame(width: scaled(18), height: scaled(18))
                    .padding(.horizontal, scaled(2))
                    .accessibilityLabel("Working")
            }

            if documentSearch.isPresented {
                documentSearchBar
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .trailing)))
            } else {
                trailingActions
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .trailing)))

                drawerToggleButton
            }
        }
        .padding(.horizontal, scaled(10))
        .frame(height: scaled(44))
        .background(theme.surfaceColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.borderColor)
                .frame(height: 1)
        }
        .animation(.easeOut(duration: 0.14), value: documentSearch.isPresented)
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
            systemImage: "sidebar.right",
            label: isTerminalPresented ? "Hide Right Drawer" : "Show Right Drawer",
            theme: theme,
            zoomScale: zoomScale,
            uiFontSize: uiFontSize,
            isActive: isTerminalPresented,
            action: toggleTerminal
        )
        .keyboardShortcut("t", modifiers: [.command, .option])
        .accessibilityValue(isTerminalPresented ? "Open" : "Closed")
    }

    /// When the sidebar is hidden, the editor pane spans the full window
    /// width and the chrome row sits behind the macOS traffic lights.
    /// Reserve the leading space so chrome content is not under them.
    private var leadingNavigation: some View {
        Group {
            if !isSidebarVisible {
                Color.clear
                    .frame(width: 72)
            }
        }
    }

    private var sidebarToggleButton: some View {
        ChromeBarButton(
            systemImage: "sidebar.left",
            label: isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
            theme: theme,
            zoomScale: zoomScale,
            uiFontSize: uiFontSize,
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
                isDisabled: store.isBusy,
                saveState: { store.saveState(for: $0) },
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
            if isMarkdownSelected {
                outlineButton
                sourcePreviewSwitch
                    .disabled(store.isDocumentLoading)
            }
        }
    }

    private var sourcePreviewSwitch: some View {
        HStack(spacing: scaled(2)) {
            TopBarSegment(
                systemImage: "chevron.left.forwardslash.chevron.right",
                accessibilityLabel: EditorMode.source.title,
                isSelected: editorMode == .source,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            ) {
                editorMode = .source
            }

            TopBarSegment(
                systemImage: "eye",
                accessibilityLabel: EditorMode.preview.title,
                isSelected: editorMode == .preview,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            ) {
                editorMode = .preview
            }
        }
        .padding(scaled(2))
        .background(
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                .fill(theme.controlTrackFillColor)
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
        .padding(.leading, scaled(12))
        .padding(.trailing, scaled(8))
        .frame(height: scaled(34))
        .background(
            RoundedRectangle(cornerRadius: theme.chromeRadius(17, zoomScale: zoomScale))
                .fill(theme.surfaceColor)
                .overlay {
                    RoundedRectangle(cornerRadius: theme.chromeRadius(17, zoomScale: zoomScale))
                        .strokeBorder(theme.borderColor, lineWidth: 1)
                }
        )
        .shadow(color: theme.foregroundColor.opacity(theme.isDark ? 0.18 : 0.08), radius: 18, y: 8)
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
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: scaled(12), weight: .semibold))
                .foregroundStyle(isDisabled ? theme.mutedForegroundColor.opacity(0.42) : theme.mutedForegroundColor)
                .frame(width: scaled(24), height: scaled(24))
                .contentShape(RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale)))
        }
        .buttonStyle(FindBarIconButtonStyle(theme: theme, cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale)))
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
        .monknotPointerCursor(enabled: !isDisabled)
    }

    private var outlineButton: some View {
        ChromeBarButton(
            systemImage: "list.bullet.indent",
            label: isOutlinePresented ? "Close Outline" : "Open Outline",
            theme: theme,
            zoomScale: zoomScale,
            uiFontSize: uiFontSize,
            isActive: isOutlinePresented,
            isDisabled: store.isDocumentLoading,
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

private struct TopBarSegment: View {
    let systemImage: String
    let accessibilityLabel: String
    let isSelected: Bool
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: scaled(12), weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: scaled(32), height: scaled(24))
                .background(background, in: RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale)))
                .contentShape(RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale)))
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .monknotPointerCursor()
    }

    private var foreground: Color {
        if isSelected {
            return theme.foregroundColor
        }
        return theme.mutedForegroundColor.opacity(isHovered ? 1 : 0.85)
    }

    private var background: Color {
        if isSelected {
            return theme.controlTrackFillColor
        }
        return .clear
    }
}

private struct FindBarIconButtonStyle: ButtonStyle {
    let theme: AppTheme
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, theme: theme, cornerRadius: cornerRadius)
    }

    fileprivate struct Body: View {
        let configuration: Configuration
        let theme: AppTheme
        let cornerRadius: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(theme.foregroundColor.opacity(backgroundOpacity(isPressed: configuration.isPressed)))
                }
                .opacity(configuration.isPressed ? 0.9 : 1)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .onHover { isHovered = $0 }
        }

        private func backgroundOpacity(isPressed: Bool) -> Double {
            if isPressed {
                return theme.isDark ? 0.11 : 0.08
            }
            if isHovered {
                return theme.isDark ? 0.075 : 0.055
            }
            return 0
        }
    }
}
