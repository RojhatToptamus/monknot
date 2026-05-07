import AppKit
import MarkprevCore
import SwiftUI

struct EditorPaneView: View {
    @ObservedObject var store: WorkspaceStore
    @Binding var editorMode: EditorMode
    @AppStorage("Markprev.terminalDrawerWidth") private var terminalDrawerWidth = 420.0
    @StateObject private var terminalSession = TerminalSessionStore()
    let theme: AppTheme
    let zoomScale: Double
    let codeFontSize: CGFloat
    let previewWidthPercent: Double
    @Binding var isTerminalPresented: Bool
    @Binding var sourceLocation: MarkdownSourceLocation?
    let isSidebarVisible: Bool
    let toggleSidebar: () -> Void
    let newMarkdown: () -> Void
    let openFolder: () -> Void
    let zoomOut: () -> Void
    let resetZoom: () -> Void
    let zoomIn: () -> Void
    let toggleTerminal: () -> Void
    let onPreviewSourceJump: (MarkdownSourceLocation) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TopNavigationBar(
                store: store,
                editorMode: $editorMode,
                theme: theme,
                zoomScale: zoomScale,
                isTerminalPresented: isTerminalPresented,
                isSidebarVisible: isSidebarVisible,
                toggleSidebar: toggleSidebar,
                newMarkdown: newMarkdown,
                openFolder: openFolder,
                zoomOut: zoomOut,
                resetZoom: resetZoom,
                zoomIn: zoomIn,
                toggleTerminal: toggleTerminal
            )

            GeometryReader { proxy in
                editorWithTerminalDrawer(in: proxy.size)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(theme.surfaceColor)
        .onExitCommand {
            guard isTerminalPresented else { return }
            setTerminalPresented(false)
        }
        .onAppear {
            terminalSession.setDefaultDirectory(store.workspaceURL)
        }
        .onChange(of: store.workspaceURL) { _, newURL in
            terminalSession.setDefaultDirectory(newURL)
        }
    }

    @ViewBuilder
    private func editorWithTerminalDrawer(in size: CGSize) -> some View {
        let isCompact = size.width < 760
        let drawerWidth = terminalDrawerWidth(for: size.width)

        if isCompact {
            ZStack(alignment: .trailing) {
                editorContent

                if isTerminalPresented {
                    Color.black
                        .opacity(theme.isDark ? 0.26 : 0.16)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture {
                            setTerminalPresented(false)
                        }
                        .accessibilityHidden(true)

                    resizableTerminalDrawer(width: drawerWidth, maxWidth: drawerMaxWidth(for: size.width)) {
                        setTerminalPresented(false)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
                }
            }
            .animation(drawerAnimation, value: isTerminalPresented)
        } else {
            HStack(spacing: 0) {
                editorContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isTerminalPresented {
                    resizableTerminalDrawer(width: drawerWidth, maxWidth: drawerMaxWidth(for: size.width)) {
                        setTerminalPresented(false)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(drawerAnimation, value: isTerminalPresented)
        }
    }

    private func resizableTerminalDrawer(width: CGFloat, maxWidth: CGFloat, close: @escaping () -> Void) -> some View {
        TerminalDrawerView(session: terminalSession, theme: theme, zoomScale: zoomScale, close: close)
            .frame(width: width)
            .overlay(alignment: .leading) {
                TerminalResizeHandle(
                    theme: theme,
                    width: $terminalDrawerWidth,
                    minWidth: terminalDrawerMinWidth,
                    maxWidth: maxWidth
                )
            }
    }

    @ViewBuilder
    private var editorContent: some View {
        if let selectedFile = store.selectedFile {
            editor(for: selectedFile)
                .overlay {
                    if store.isDocumentLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
        } else {
            EmptyDetailView(theme: theme)
        }
    }

    @ViewBuilder
    private func editor(for selectedFile: MarkdownFile) -> some View {
        if editorMode == .source {
            MarkdownTextEditor(
                text: Binding(
                    get: { store.documentText },
                    set: { store.setDocumentText($0) }
                ),
                theme: theme,
                fontSize: codeFontSize * zoomScale,
                sourceLocation: $sourceLocation
            )
            .help(selectedFile.relativePath)
        } else {
            MarkdownPreviewView(
                markdown: store.documentText,
                baseURL: store.workspaceURL,
                theme: theme,
                zoomScale: zoomScale,
                codeFontSize: Double(codeFontSize),
                previewWidthPercent: previewWidthPercent,
                onSourceJump: onPreviewSourceJump
            )
            .help(selectedFile.relativePath)
        }
    }

    private var drawerAnimation: Animation {
        .spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.08)
    }

    private func terminalDrawerWidth(for availableWidth: CGFloat) -> CGFloat {
        let maxWidth = Double(drawerMaxWidth(for: availableWidth))
        let minWidth = Double(terminalDrawerMinWidth)
        return CGFloat(min(max(terminalDrawerWidth, minWidth), maxWidth))
    }

    private var terminalDrawerMinWidth: CGFloat {
        320
    }

    private func drawerMaxWidth(for availableWidth: CGFloat) -> CGFloat {
        if availableWidth < 760 {
            return min(max(availableWidth * 0.92, terminalDrawerMinWidth), availableWidth)
        }

        return max(terminalDrawerMinWidth, min(720, availableWidth - 360))
    }

    private func setTerminalPresented(_ value: Bool) {
        withAnimation(drawerAnimation) {
            isTerminalPresented = value
        }
    }
}

private struct TerminalResizeHandle: View {
    let theme: AppTheme
    @Binding var width: Double
    let minWidth: CGFloat
    let maxWidth: CGFloat
    @State private var dragStartWidth: Double?
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(isHovered ? theme.accentColor.opacity(0.36) : Color.clear)
            .frame(width: 7)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let startWidth = dragStartWidth ?? width
                        dragStartWidth = startWidth
                        width = clamped(startWidth - Double(value.translation.width))
                    }
                    .onEnded { _ in
                        width = clamped(width)
                        dragStartWidth = nil
                    }
            )
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovered {
                    NSCursor.pop()
                }
            }
            .accessibilityLabel("Resize terminal sidebar")
            .accessibilityAddTraits(.allowsDirectInteraction)
    }

    private func clamped(_ value: Double) -> Double {
        min(Double(maxWidth), max(Double(minWidth), value))
    }
}

private struct EmptyDetailView: View {
    let theme: AppTheme

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "markdown")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(theme.mutedForegroundColor.opacity(0.6))

            VStack(spacing: 5) {
                Text("Select a Markdown file")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.foregroundColor)
                Text("Open a folder or drop Markdown files into the sidebar.")
                    .foregroundStyle(theme.mutedForegroundColor)
            }

            Text("⇧⌘O to open a folder")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.mutedForegroundColor.opacity(0.6))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
