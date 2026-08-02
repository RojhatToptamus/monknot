import Foundation
import MonknotCore
import SwiftUI

struct TerminalDrawerView: View {
    @ObservedObject var sessions: TerminalSessionCollectionStore
    let workingDirectory: URL?
    let theme: AppTheme
    let zoomScale: Double
    let usePointerCursors: Bool
    let fontSmoothing: Bool
    var showsChrome = true
    let close: () -> Void

    private var uiFontSize: Double { theme.uiFontSize }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsChrome {
                MonknotChromePanel(
                    theme: theme,
                    showsBottomBorder: false,
                    surface: theme.contentSurfaceColor
                ) {
                    TerminalDrawerChromeRow(
                        sessions: sessions,
                        workingDirectory: workingDirectory,
                        theme: theme,
                        zoomScale: zoomScale,
                        uiFontSize: uiFontSize,
                        close: close
                    )
                }
            }

            terminalSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.contentSurfaceColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal panel")
        .onAppear {
            sessions.ensureActiveTerminal(in: workingDirectory)
        }
        .onChange(of: workingDirectory?.standardizedFileURL.path ?? "") { _, _ in
            sessions.setDefaultDirectory(workingDirectory)
        }
    }

    @ViewBuilder
    private var terminalSurface: some View {
        if let session = sessions.activeSession {
            TerminalWebView(
                session: session,
                theme: theme,
                fontSize: CGFloat(13.5 * WorkspaceZoomPolicy.terminalContentScale(zoomScale)),
                usePointerCursors: usePointerCursors,
                fontSmoothing: fontSmoothing
            )
            .id(sessions.activeTerminalID)
        } else {
            TerminalEmptySurface(
                theme: theme,
                zoomScale: zoomScale,
                createTerminal: {
                    sessions.createTerminal(in: workingDirectory)
                }
            )
        }
    }
}

/// Terminal controls embedded in the editor's primary chrome while the
/// terminal takes over a constrained detail column. The tab lane is bounded
/// and scrolls horizontally only when its contents exceed the available row.
struct TerminalDrawerTakeoverSegment: View {
    @ObservedObject var sessions: TerminalSessionCollectionStore
    let workingDirectory: URL?
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let close: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(4)) {
            TerminalDrawerTabGroup(
                sessions: sessions,
                workingDirectory: workingDirectory,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            )
            .frame(minWidth: scaled(60), maxWidth: scaled(160))

            ChromeBarButton(
                systemImage: "xmark",
                label: "Hide Terminal Panel",
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                action: close
            )
            .keyboardShortcut(.cancelAction)
        }
        .padding(.leading, scaled(4))
        .padding(.trailing, MonknotMetrics.chromeHorizontalPadding(theme: theme, zoomScale: zoomScale))
        .frame(height: MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale))
        .frame(
            minWidth: scaled(MonknotMetrics.takeoverTerminalChromeMinWidthBase),
            maxWidth: scaled(MonknotMetrics.takeoverTerminalChromeMaxWidthBase),
            alignment: .trailing
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal controls")
    }
}

struct TerminalDrawerChromeRow: View {
    @ObservedObject var sessions: TerminalSessionCollectionStore
    let workingDirectory: URL?
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let close: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(4)) {
            TerminalDrawerTabGroup(
                sessions: sessions,
                workingDirectory: workingDirectory,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            )
            .frame(minWidth: scaled(60), maxWidth: scaled(320))

            WindowTitleBarDragArea()
                .frame(minWidth: scaled(28), maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)

            ChromeBarButton(
                systemImage: "xmark",
                label: "Hide Terminal Panel",
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                action: close
            )
            .keyboardShortcut(.cancelAction)
        }
        .monknotChromeRowLayout(theme: theme, zoomScale: zoomScale)
    }
}

/// Stable terminal tab controls used in both drawer presentations. Every tab
/// stays in one horizontal scroll lane; New Terminal remains fixed at its
/// trailing edge and edge fades appear only when content is offscreen.
private struct TerminalDrawerTabGroup: View {
    @ObservedObject var sessions: TerminalSessionCollectionStore
    let workingDirectory: URL?
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double

    @State private var viewportTabFrames: [String: CGRect] = [:]
    @State private var revealRequest = HorizontalTabRevealRequest()

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = max(0, geometry.size.width - fixedControlsWidth)
            let overflow = HorizontalTabOverflowState(
                frames: viewportTabFrames,
                viewportWidth: viewportWidth
            )

            HStack(spacing: scaled(4)) {
                ZStack {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: scaled(4)) {
                                ForEach(Array(sessions.tabs.enumerated()), id: \.element.id) { offset, tab in
                                    if let session = sessions.session(for: tab.id) {
                                        TerminalTabChip(
                                            tab: tab,
                                            session: session,
                                            index: offset + 1,
                                            isSelected: tab.id == sessions.activeTerminalID,
                                            theme: theme,
                                            zoomScale: zoomScale,
                                            uiFontSize: uiFontSize,
                                            select: {
                                                sessions.selectTerminal(id: tab.id)
                                            },
                                            restart: {
                                                sessions.restartTerminal(id: tab.id)
                                            },
                                            kill: {
                                                sessions.killTerminal(id: tab.id)
                                            }
                                        )
                                        .id(tab.id)
                                        .background(
                                            HorizontalTabFrameReader(
                                                id: tab.id,
                                                coordinateSpace: HorizontalTabViewport.terminalTabs
                                            )
                                        )
                                    }
                                }

                                WindowTitleBarDragArea()
                                    .frame(minWidth: scaled(28), maxWidth: .infinity, maxHeight: .infinity)
                                    .accessibilityHidden(true)
                            }
                            .frame(minWidth: viewportWidth, alignment: .leading)
                        }
                        .coordinateSpace(name: HorizontalTabViewport.terminalTabs)
                        .onAppear {
                            revealRequest.request(sessions.activeTerminalID)
                            performPendingReveal(using: proxy, viewportWidth: viewportWidth)
                        }
                        .onPreferenceChange(HorizontalTabFramePreferenceKey.self) { frames in
                            viewportTabFrames = frames
                            performPendingReveal(using: proxy, viewportWidth: viewportWidth)
                        }
                        .onChange(of: sessions.activeTerminalID) { _, activeTerminalID in
                            revealRequest.request(activeTerminalID)
                            performPendingReveal(using: proxy, viewportWidth: viewportWidth)
                        }
                        .onChange(of: viewportWidth) { _, _ in
                            revealRequest.request(sessions.activeTerminalID)
                            performPendingReveal(using: proxy, viewportWidth: viewportWidth)
                        }
                    }

                    HorizontalTabEdgeShadows(
                        showsLeading: overflow.hasLeadingOverflow,
                        showsTrailing: overflow.hasTrailingOverflow,
                        theme: theme,
                        zoomScale: zoomScale
                    )
                }
                .frame(width: viewportWidth)

                ChromeBarButton(
                    systemImage: "plus",
                    label: "New Terminal",
                    theme: theme,
                    zoomScale: zoomScale,
                    uiFontSize: uiFontSize,
                    action: {
                        sessions.createTerminal(in: workingDirectory)
                    }
                )
            }
        }
        .frame(height: MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale))
    }

    private var fixedControlsWidth: CGFloat {
        MonknotMetrics.chromeButtonDimension(theme: theme, zoomScale: zoomScale) + scaled(4)
    }

    private func performPendingReveal(
        using proxy: ScrollViewProxy,
        viewportWidth: CGFloat
    ) {
        guard let action = revealRequest.consume(
            frames: viewportTabFrames,
            viewportWidth: viewportWidth
        ) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(
                action.id,
                anchor: action.edge == .leading ? .leading : .trailing
            )
        }
    }
}

private struct TerminalTabChip: View {
    let tab: TerminalTabItem
    @ObservedObject var session: TerminalSessionStore
    let index: Int
    let isSelected: Bool
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let select: () -> Void
    let restart: () -> Void
    let kill: () -> Void

    @State private var isHovered = false

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
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: scaled(5)) {
                    Image(systemName: "terminal")
                        .font(.system(
                            size: MonknotMetrics.chromeGlyphSize(theme: theme, zoomScale: zoomScale),
                            weight: .regular
                        ))
                        .foregroundStyle(iconColor)
                        .accessibilityHidden(true)

                    Circle()
                        .fill(statusColor)
                        .frame(width: scaled(5), height: scaled(5))
                        .accessibilityHidden(true)

                    Text("\(index)")
                        .font(.system(size: textScaled(11), weight: .medium, design: .rounded))
                        .foregroundStyle(isSelected ? theme.foregroundColor : theme.mutedForegroundColor)
                        .monospacedDigit()
                }
                .padding(.leading, scaled(8))
                .padding(.trailing, scaled(4))
                .frame(height: MonknotMetrics.interfaceControl(26, theme: theme, zoomScale: zoomScale))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button(action: kill) {
                Image(systemName: "xmark")
                    .font(.system(size: glyphScaled(8), weight: .bold))
                    .foregroundStyle(theme.mutedForegroundColor.opacity(isHovered ? 0.92 : 0.72))
                    .frame(
                        width: max(22, MonknotMetrics.interfaceControl(18, theme: theme, zoomScale: zoomScale)),
                        height: max(22, MonknotMetrics.interfaceControl(18, theme: theme, zoomScale: zoomScale))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: theme.chromeRadius(4, zoomScale: zoomScale)))
            }
            .buttonStyle(.plain)
            .help("Kill Terminal")
            .accessibilityLabel("Kill terminal \(index)")
            .accessibilityHidden(!showsCloseButton)
            .disabled(!showsCloseButton)
            .opacity(showsCloseButton ? 1 : 0)
            .monknotPointerCursor(enabled: showsCloseButton)
            .padding(.trailing, scaled(3))
        }
        .frame(minWidth: scaled(54), maxWidth: scaled(82), alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale)))
        .overlay {
            RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale))
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .help(tab.title)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .contextMenu {
            Button {
                restart()
            } label: {
                Label("Restart Terminal", systemImage: "arrow.clockwise")
            }

            Button(role: .destructive) {
                kill()
            } label: {
                Label("Kill Terminal", systemImage: "trash")
            }
        }
        .help(helpText)
    }

    private var background: Color {
        if isSelected {
            return theme.elevatedSurfaceColor
        }
        if isHovered {
            return theme.foregroundColor.opacity(theme.isDark ? 0.055 : 0.04)
        }
        return theme.controlTrackFillColor.opacity(0.65)
    }

    private var showsCloseButton: Bool {
        isSelected || isHovered
    }

    private var borderColor: Color {
        if isSelected {
            return theme.borderColor
        }
        return theme.borderColor.opacity(isHovered ? 1 : 0.65)
    }

    private var iconColor: Color {
        isSelected ? theme.accentColor : theme.mutedForegroundColor
    }

    private var statusColor: Color {
        switch session.status {
        case .running:
            return theme.accentColor
        case .failed:
            return Color(hex: theme.semanticColors.diffRemoved)
        case .exited:
            return theme.mutedForegroundColor.opacity(0.62)
        case .idle:
            return theme.mutedForegroundColor.opacity(0.34)
        }
    }

    private var helpText: String {
        session.workingDirectory.path
    }

    private var accessibilityLabel: String {
        "\(tab.title), \(statusDescription), \(session.workingDirectory.path)"
    }

    private var statusDescription: String {
        switch session.status {
        case .idle:
            return "not started"
        case .running:
            return "running"
        case let .exited(status):
            if let status {
                return "exited with status \(status)"
            }
            return "exited"
        case .failed:
            return "failed"
        }
    }
}

private struct TerminalEmptySurface: View {
    let theme: AppTheme
    let zoomScale: Double
    let createTerminal: () -> Void

    var body: some View {
        MonknotEmptyState(
            systemImage: "terminal",
            title: "No active terminal",
            detail: "Start a shell for this workspace.",
            theme: theme,
            zoomScale: zoomScale
        ) {
            MonknotActionButton(
                title: "New Terminal",
                systemImage: "plus",
                role: .primary,
                theme: theme,
                zoomScale: zoomScale,
                action: createTerminal
            )
        }
        .background(theme.contentSurfaceColor)
    }
}
