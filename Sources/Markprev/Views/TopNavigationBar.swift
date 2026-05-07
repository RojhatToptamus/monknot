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
    let zoomOut: () -> Void
    let resetZoom: () -> Void
    let zoomIn: () -> Void
    let toggleTerminal: () -> Void
    let toggleSidebar: () -> Void
    @Binding var documentSearch: DocumentSearchState
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isSearchFocused: Bool

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

            Spacer(minLength: scaled(16))

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

            zoomCluster

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

    private var zoomCluster: some View {
        HStack(spacing: 0) {
            iconButton(systemImage: "minus.magnifyingglass", label: "Zoom Out", action: zoomOut)

            Button(action: resetZoom) {
                Text("\(Int((zoomScale * 100).rounded()))%")
                    .font(.system(size: scaled(11), weight: .medium, design: .rounded))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .frame(width: scaled(40), height: scaled(26))
                    .contentShape(RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale)))
            }
            .buttonStyle(TopBarTextButtonStyle(theme: theme, cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale)))
            .help("Actual Size")
            .accessibilityLabel("Actual Size")
            .markprevPointerCursor()

            iconButton(systemImage: "plus.magnifyingglass", label: "Zoom In", action: zoomIn)
        }
    }

    private var utilityButtons: some View {
        HStack(spacing: scaled(2)) {
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
            label: isTerminalPresented ? "Close Terminal" : "Open Terminal",
            theme: theme,
            zoomScale: zoomScale,
            uiFontSize: uiFontSize,
            isActive: isTerminalPresented,
            action: toggleTerminal
        )
        .keyboardShortcut("t", modifiers: [.command, .option])
        .accessibilityValue(isTerminalPresented ? "Open" : "Closed")
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
                .font(.system(size: scaled(12), weight: isSelected ? .medium : .regular))
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

private struct TopBarTextButtonStyle: ButtonStyle {
    let theme: AppTheme
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(theme.controlTrackFillColor)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(theme.foregroundColor.opacity(configuration.isPressed ? 0.055 : 0))
                    }
            }
            .opacity(configuration.isPressed ? 0.94 : 1)
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
