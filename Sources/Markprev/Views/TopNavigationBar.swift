import MarkprevCore
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
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isSearchFocused: Bool
    @State private var isOutlinePresented = false

    private var title: String {
        store.selectedDocument?.displayName ?? store.workspaceURL?.lastPathComponent ?? "Markprev"
    }

    private var isMarkdownSelected: Bool {
        store.selectedDocument?.kind == .markdown
    }

    private var uiFontSize: Double { theme.uiFontSize }

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        HStack(spacing: scaled(10)) {
            leadingNavigation

            titleCluster

            WindowDoubleClickZoomArea()
                .frame(minWidth: scaled(16), maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)

            if store.isBusy || store.isDocumentLoading || store.isSaving {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(zoomScale * (uiFontSize / 16))
                    .frame(width: scaled(18), height: scaled(18))
                    .accessibilityLabel("Working")
            }

            if documentSearch.isPresented {
                documentSearchBar
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .trailing)))
            } else {
                ViewThatFits(in: .horizontal) {
                    fullControlSet
                    compactControlSet
                    minimalControlSet
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .trailing)))
            }
        }
        .padding(.horizontal, scaled(14))
        .frame(height: scaled(44))
        .animation(.easeOut(duration: 0.14), value: documentSearch.isPresented)
        .onChange(of: documentSearch.focusSerial) { _, _ in
            isSearchFocused = documentSearch.isPresented
        }
        .onChange(of: documentSearch.isPresented) { _, isPresented in
            guard isPresented else { return }
            isSearchFocused = true
        }
    }

    /// When the sidebar is collapsed, the detail column spans the full window width under the
    /// traffic lights. Reserve leading space so the title row does not sit under the buttons.
    private var leadingNavigation: some View {
        Group {
            if !isSidebarVisible {
                Color.clear
                    .frame(width: 76)
            }
        }
    }

    private var titleCluster: some View {
        HStack(spacing: scaled(8)) {
            ChromeBarButton(
                systemImage: "sidebar.left",
                label: isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                action: toggleSidebar
            )
            .keyboardShortcut("s", modifiers: [.command, .control])

            Text(title)
                .font(.system(size: scaled(14), weight: .semibold))
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(titleAccessibilityLabel)

            TopBarSaveStateIndicator(
                state: selectedSaveState,
                theme: theme,
                zoomScale: zoomScale,
                size: scaled(12)
            )

            Image(systemName: "ellipsis")
                .font(.system(size: scaled(11), weight: .semibold))
                .foregroundStyle(theme.mutedForegroundColor.opacity(0.7))
                .accessibilityHidden(true)
        }
        .frame(minWidth: scaled(120), maxWidth: scaled(420), alignment: .leading)
    }

    private var fullControlSet: some View {
        HStack(spacing: scaled(14)) {
            if isMarkdownSelected {
                sourcePreviewSwitch
                    .disabled(store.isDocumentLoading)
            }

            utilityButtons
        }
    }

    private var compactControlSet: some View {
        HStack(spacing: scaled(10)) {
            if isMarkdownSelected {
                sourcePreviewSwitch
                    .disabled(store.isDocumentLoading)
            }

            HStack(spacing: scaled(2)) {
                if isMarkdownSelected {
                    outlineButton
                }
                iconButton(systemImage: "folder", label: "Open Folder", isDisabled: store.isBusy, action: openFolder)
                terminalButton
            }
        }
    }

    private var minimalControlSet: some View {
        HStack(spacing: scaled(6)) {
            if isMarkdownSelected {
                sourcePreviewSwitch
                    .disabled(store.isDocumentLoading)
            }

            terminalButton
        }
    }

    private var sourcePreviewSwitch: some View {
        HStack(spacing: 0) {
            TopBarSegment(
                title: EditorMode.source.title,
                isSelected: editorMode == .source,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            ) {
                editorMode = .source
            }

            TopBarSegment(
                title: EditorMode.preview.title,
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

    private var utilityButtons: some View {
        HStack(spacing: scaled(2)) {
            if isMarkdownSelected {
                outlineButton
            }

            iconButton(systemImage: "gearshape", label: "Open Settings", action: openSettings.callAsFunction)

            iconButton(
                systemImage: "square.and.pencil",
                label: "New Markdown",
                isDisabled: store.workspaceURL == nil || store.isBusy,
                action: newMarkdown
            )

            iconButton(systemImage: "folder", label: "Open Folder", isDisabled: store.isBusy, action: openFolder)

            terminalButton
        }
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
        .markprevPointerCursor(enabled: !isDisabled)
    }

    private var terminalButton: some View {
        ChromeBarButton(
            systemImage: "terminal",
            label: isTerminalPresented ? "Hide Terminal Panel" : "Open Terminal",
            theme: theme,
            zoomScale: zoomScale,
            uiFontSize: uiFontSize,
            isActive: isTerminalPresented,
            action: toggleTerminal
        )
        .keyboardShortcut("t", modifiers: [.command, .option])
        .accessibilityValue(isTerminalPresented ? "Open" : "Closed")
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

    private var selectedSaveState: DocumentSaveState {
        guard let id = store.selectedDocumentID else { return .clean }
        return store.saveState(for: id)
    }

    private var titleAccessibilityLabel: String {
        guard !selectedSaveState.isClean else { return title }
        return "\(title), \(selectedSaveState.accessibilityDescription)"
    }

    private func iconButton(
        systemImage: String,
        label: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        ChromeBarButton(
            systemImage: systemImage,
            label: label,
            theme: theme,
            zoomScale: zoomScale,
            uiFontSize: uiFontSize,
            isDisabled: isDisabled,
            action: action
        )
    }
}

private struct TopBarSaveStateIndicator: View {
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
                    .frame(width: max(5, size * 0.48), height: max(5, size * 0.48))
            case .saving:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(max(0.65, zoomScale * 0.78))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: max(9, size * 0.82), weight: .semibold))
                    .foregroundStyle(Color(hex: theme.semanticColors.diffRemoved))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(state.accessibilityDescription)
    }
}

private struct TopBarSegment: View {
    let title: String
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
            Text(title)
                .font(.system(size: scaled(12), weight: .regular))
                .foregroundStyle(foreground)
                .padding(.horizontal, scaled(10))
                .frame(height: scaled(22))
                .background(background, in: RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale)))
                .contentShape(RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale)))
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .markprevPointerCursor()
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
