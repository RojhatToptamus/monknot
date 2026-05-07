import MarkprevCore
import SwiftUI

struct TopNavigationBar: View {
    @ObservedObject var store: WorkspaceStore
    @Binding var editorMode: EditorMode
    let theme: AppTheme
    let zoomScale: Double
    let isTerminalPresented: Bool
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

    var body: some View {
        HStack(spacing: 14) {
            titleCluster

            Spacer(minLength: 18)

            if store.isBusy || store.isDocumentLoading || store.isSaving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }

            ViewThatFits(in: .horizontal) {
                fullControlSet
                compactControlSet
                minimalControlSet
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 12)
        .frame(height: 44)
        .background(topBarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.borderColor)
                .frame(height: 1)
        }
    }

    private var titleCluster: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)

            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.mutedForegroundColor)
                .frame(width: 24, height: 24)
            .accessibilityHidden(true)
        }
        .frame(minWidth: 120, maxWidth: 420, alignment: .leading)
    }

    private var fullControlSet: some View {
        HStack(spacing: 10) {
            sourcePreviewSwitch
                .disabled(store.selectedFile == nil || store.isDocumentLoading)

            TopBarDivider(theme: theme)

            zoomCluster

            TopBarDivider(theme: theme)

            utilityButtons
        }
    }

    private var compactControlSet: some View {
        HStack(spacing: 8) {
            sourcePreviewSwitch
                .disabled(store.selectedFile == nil || store.isDocumentLoading)

            TopBarDivider(theme: theme)

            TopBarIconButton(
                systemImage: "folder",
                accessibilityLabel: "Open Folder",
                theme: theme,
                isDisabled: store.isBusy,
                action: openFolder
            )

            terminalButton
        }
    }

    private var minimalControlSet: some View {
        HStack(spacing: 8) {
            sourcePreviewSwitch
                .disabled(store.selectedFile == nil || store.isDocumentLoading)

            terminalButton
        }
    }

    private var sourcePreviewSwitch: some View {
        HStack(spacing: 2) {
            TopBarSegment(
                title: EditorMode.source.title,
                isSelected: editorMode == .source,
                theme: theme
            ) {
                editorMode = .source
            }

            TopBarSegment(
                title: EditorMode.preview.title,
                isSelected: editorMode == .preview,
                theme: theme
            ) {
                editorMode = .preview
            }
        }
        .padding(3)
        .background(theme.elevatedSurfaceColor.opacity(theme.isDark ? 1.4 : 1.0), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.borderColor, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor mode")
    }

    private var zoomCluster: some View {
        HStack(spacing: 4) {
            TopBarIconButton(
                systemImage: "minus.magnifyingglass",
                accessibilityLabel: "Zoom Out",
                theme: theme,
                action: zoomOut
            )

            Button(action: resetZoom) {
                Text("\(Int((zoomScale * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.foregroundColor.opacity(0.9))
                    .frame(width: 46, height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(TopBarTextButtonStyle(theme: theme))
            .help("Actual Size")
            .accessibilityLabel("Actual Size")

            TopBarIconButton(
                systemImage: "plus.magnifyingglass",
                accessibilityLabel: "Zoom In",
                theme: theme,
                action: zoomIn
            )
        }
    }

    private var utilityButtons: some View {
        HStack(spacing: 6) {
            TopBarIconButton(
                systemImage: "gearshape",
                accessibilityLabel: "Open Settings",
                theme: theme,
                action: openSettings.callAsFunction
            )

            TopBarIconButton(
                systemImage: "square.and.pencil",
                accessibilityLabel: "New Markdown",
                theme: theme,
                isDisabled: store.workspaceURL == nil || store.isBusy,
                action: newMarkdown
            )

            TopBarIconButton(
                systemImage: "folder",
                accessibilityLabel: "Open Folder",
                theme: theme,
                isDisabled: store.isBusy,
                action: openFolder
            )

            terminalButton
        }
    }

    private var terminalButton: some View {
        TopBarIconButton(
            systemImage: "terminal",
            accessibilityLabel: isTerminalPresented ? "Close Terminal" : "Open Terminal",
            theme: theme,
            isActive: isTerminalPresented,
            action: toggleTerminal
        )
        .keyboardShortcut("t", modifiers: [.command, .option])
        .accessibilityValue(isTerminalPresented ? "Open" : "Closed")
    }

    @ViewBuilder
    private var topBarBackground: some View {
        if theme.opaqueWindows {
            theme.surfaceColor
        } else {
            ZStack {
                Rectangle()
                    .fill(.regularMaterial)
                theme.surfaceColor
                    .opacity(theme.isDark ? 0.78 : 0.86)
            }
        }
    }
}

private struct TopBarSegment: View {
    let title: String
    let isSelected: Bool
    let theme: AppTheme
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(isSelected ? theme.foregroundColor : theme.mutedForegroundColor)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.accentColor.opacity(0.75), lineWidth: 1.4)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected {
            return theme.foregroundColor.opacity(theme.isDark ? 0.14 : 0.09)
        }

        if isHovered {
            return theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.06)
        }

        return .clear
    }
}

private struct TopBarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let theme: AppTheme
    var isActive = false
    var isDisabled = false
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 30)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.accentColor.opacity(0.75), lineWidth: 1.4)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .focusable(!isDisabled)
        .focused($isFocused)
        .opacity(isDisabled ? 0.38 : 1)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.14), value: isActive)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }

    private var background: Color {
        if isActive {
            return theme.accentColor.opacity(theme.isDark ? 0.22 : 0.16)
        }

        if isHovered {
            return theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.06)
        }

        return .clear
    }

    private var iconColor: Color {
        if isActive {
            return theme.accentColor
        }

        return theme.mutedForegroundColor
    }
}

private struct TopBarTextButtonStyle: ButtonStyle {
    let theme: AppTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                theme.foregroundColor.opacity(configuration.isPressed ? 0.11 : 0.0),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}

private struct TopBarDivider: View {
    let theme: AppTheme

    var body: some View {
        Rectangle()
            .fill(theme.borderColor)
            .frame(width: 1, height: 22)
    }
}
