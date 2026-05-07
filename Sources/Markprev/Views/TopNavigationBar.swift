import MarkprevCore
import SwiftUI

struct TopNavigationBar: View {
    @ObservedObject var store: WorkspaceStore
    @Binding var editorMode: EditorMode
    let theme: AppTheme
    let zoomScale: Double
    let isTerminalPresented: Bool
    let isSidebarVisible: Bool
    let toggleSidebar: () -> Void
    let newMarkdown: () -> Void
    let openFolder: () -> Void
    let zoomOut: () -> Void
    let resetZoom: () -> Void
    let zoomIn: () -> Void
    let toggleTerminal: () -> Void
    @Environment(\.openSettings) private var openSettings

    private var title: String {
        store.selectedFile?.displayName ?? store.workspaceURL?.lastPathComponent ?? "Markprev"
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

            ViewThatFits(in: .horizontal) {
                fullControlSet
                compactControlSet
                minimalControlSet
            }
        }
        .padding(.horizontal, scaled(14))
        .frame(height: scaled(44))
    }

    private var leadingNavigation: some View {
        HStack(spacing: 4) {
            if !isSidebarVisible {
                Spacer()
                    .frame(width: 76)
            }

            ChromeBarButton(
                systemImage: "sidebar.left",
                label: isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                isActive: isSidebarVisible,
                action: toggleSidebar
            )
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }

    private var titleCluster: some View {
        HStack(spacing: scaled(6)) {
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
            sourcePreviewSwitch
                .disabled(store.selectedFile == nil || store.isDocumentLoading)

            zoomCluster

            utilityButtons
        }
    }

    private var compactControlSet: some View {
        HStack(spacing: scaled(10)) {
            sourcePreviewSwitch
                .disabled(store.selectedFile == nil || store.isDocumentLoading)

            HStack(spacing: scaled(2)) {
                iconButton(systemImage: "folder", label: "Open Folder", isDisabled: store.isBusy, action: openFolder)
                terminalButton
            }
        }
    }

    private var minimalControlSet: some View {
        HStack(spacing: scaled(6)) {
            sourcePreviewSwitch
                .disabled(store.selectedFile == nil || store.isDocumentLoading)

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
            RoundedRectangle(cornerRadius: scaled(7))
                .fill(theme.foregroundColor.opacity(theme.isDark ? 0.035 : 0.028))
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
                    .contentShape(RoundedRectangle(cornerRadius: scaled(6)))
            }
            .buttonStyle(TopBarTextButtonStyle(theme: theme, cornerRadius: scaled(6)))
            .help("Actual Size")
            .accessibilityLabel("Actual Size")

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
                .background(background, in: RoundedRectangle(cornerRadius: scaled(5)))
                .contentShape(RoundedRectangle(cornerRadius: scaled(5)))
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foreground: Color {
        if isSelected {
            return theme.foregroundColor
        }
        return theme.mutedForegroundColor.opacity(isHovered ? 1 : 0.85)
    }

    private var background: Color {
        if isSelected {
            return theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.06)
        }
        return .clear
    }
}

private struct TopBarTextButtonStyle: ButtonStyle {
    let theme: AppTheme
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                theme.foregroundColor.opacity(configuration.isPressed ? 0.08 : 0.0),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}
