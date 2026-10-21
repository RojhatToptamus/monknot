import Foundation
import MonknotCore
import SwiftUI

struct TerminalDrawerView: View {
    static let fontSizeBase: CGFloat = 13.5

    @ObservedObject var sessions: TerminalSessionCollectionStore
    let workingDirectory: URL?
    var workspaceRoot: URL? = nil
    let theme: AppTheme
    let zoomScale: Double
    let usePointerCursors: Bool
    let fontSmoothing: Bool
    var showsChrome = true
    var isFullscreen = false
    var toggleFullscreen: () -> Void = {}
    let close: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    static func terminalFontSize(theme: AppTheme, zoomScale: Double) -> CGFloat {
        MonknotMetrics.interfaceText(fontSizeBase, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsChrome {
                TerminalDrawerChromeRow(
                    sessions: sessions,
                    workingDirectory: workingDirectory,
                    workspaceRoot: workspaceRoot,
                    theme: theme,
                    zoomScale: zoomScale,
                    isFullscreen: isFullscreen,
                    toggleFullscreen: toggleFullscreen,
                    close: close
                )
            }

            terminalSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surfaceColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal panel")
        .onAppear {
            sessions.ensureActiveTerminal(in: workingDirectory, workspaceRoot: workspaceRoot)
        }
    }

    @ViewBuilder
    private var terminalSurface: some View {
        if let session = sessions.activeSession {
            TerminalWebView(
                session: session,
                theme: theme,
                fontSize: Self.terminalFontSize(theme: theme, zoomScale: zoomScale),
                usePointerCursors: usePointerCursors,
                fontSmoothing: fontSmoothing
            )
            .id(sessions.activeTerminalID)
        } else {
            TerminalEmptySurface(
                theme: theme,
                zoomScale: zoomScale,
                createTerminal: {
                    sessions.createTerminal(in: workingDirectory, workspaceRoot: workspaceRoot)
                }
            )
        }
    }
}

/// The terminal card's bar (design.md §10.6): the session scroller, then Expand, New Terminal and
/// Hide Terminal Panel, 2 apart, outside the scroller so adding a session never moves them.
struct TerminalDrawerChromeRow: View {
    @ObservedObject var sessions: TerminalSessionCollectionStore
    let workingDirectory: URL?
    var workspaceRoot: URL? = nil
    let theme: AppTheme
    let zoomScale: Double
    var isFullscreen = false
    var toggleFullscreen: () -> Void = {}
    let close: () -> Void

    var body: some View {
        MonknotBar(theme: theme, zoomScale: zoomScale) {
            TerminalDrawerTabGroup(
                sessions: sessions,
                workingDirectory: workingDirectory,
                workspaceRoot: workspaceRoot,
                theme: theme,
                zoomScale: zoomScale
            )
            .frame(maxWidth: .infinity)
            .layoutPriority(1)

            MonknotBarGroupGap(theme: theme, zoomScale: zoomScale)

            MonknotIconButton(
                systemImage: isFullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                label: isFullscreen ? "Restore Terminal Panel" : "Expand Terminal Panel",
                theme: theme,
                zoomScale: zoomScale,
                // Its arrows say which way it goes; like the panel toggles, it never lights up.
                action: toggleFullscreen
            )
            .accessibilityValue(isFullscreen ? "Fullscreen" : "Docked")

            MonknotIconButton(
                systemImage: "plus",
                label: "New Terminal",
                theme: theme,
                zoomScale: zoomScale,
                action: {
                    sessions.createTerminal(in: workingDirectory, workspaceRoot: workspaceRoot)
                }
            )

            MonknotIconButton(
                systemImage: "xmark",
                label: "Hide Terminal Panel",
                theme: theme,
                zoomScale: zoomScale,
                action: close
            )
        }
    }
}

/// The session tabs: every tab in one horizontal scroll lane, with edge fades only while tabs are
/// offscreen.
private struct TerminalDrawerTabGroup: View {
    @ObservedObject var sessions: TerminalSessionCollectionStore
    let workingDirectory: URL?
    var workspaceRoot: URL? = nil
    let theme: AppTheme
    let zoomScale: Double

    @State private var viewportTabFrames: [String: CGRect] = [:]
    @State private var revealRequest = HorizontalTabRevealRequest()

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = max(0, geometry.size.width)
            let overflow = HorizontalTabOverflowState(
                frames: viewportTabFrames,
                viewportWidth: viewportWidth
            )

            ZStack {
                tabLane(viewportWidth: viewportWidth)

                HorizontalTabEdgeShadows(
                    showsLeading: overflow.hasLeadingOverflow,
                    showsTrailing: overflow.hasTrailingOverflow,
                    theme: theme,
                    zoomScale: zoomScale,
                    surface: theme.surfaceColor
                )
            }
            .frame(width: viewportWidth)
        }
        .frame(height: MonknotMetrics.barHeight(theme: theme, zoomScale: zoomScale))
    }

    /// Every tab in one horizontal scroll lane, followed by window drag space.
    private func tabLane(viewportWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: scaled(MonknotTab.spacingBase)) {
                    ForEach(Array(sessions.tabs.enumerated()), id: \.element.id) { offset, tab in
                        if let session = sessions.session(for: tab.id) {
                            TerminalTabChip(
                                tab: tab,
                                session: session,
                                index: offset + 1,
                                isSelected: tab.id == sessions.activeTerminalID,
                                theme: theme,
                                zoomScale: zoomScale,
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

                    WindowTitleBarDragArea(doubleClickZoomsWindow: false)
                        .frame(minWidth: scaled(28), maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
                .frame(minWidth: viewportWidth, alignment: .leading)
                .background(HorizontalTabWheelScrolling())
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

/// A session tab: the shared tab inside the card, its glyph tinted by the run state (design.md §10.6)
/// and its label the session's number, which is what tells sessions apart.
private struct TerminalTabChip: View {
    let tab: TerminalTabItem
    @ObservedObject var session: TerminalSessionStore
    let index: Int
    let isSelected: Bool
    let theme: AppTheme
    let zoomScale: Double
    let select: () -> Void
    let restart: () -> Void
    let kill: () -> Void

    var body: some View {
        MonknotTab(
            title: "\(index)",
            systemImage: "terminal",
            isSelected: isSelected,
            placement: .card,
            glyphTint: statusTint,
            hoverButton: MonknotTab.HoverButton(label: "Kill Terminal \(index)", action: kill),
            theme: theme,
            zoomScale: zoomScale,
            select: select
        )
        .contextMenu {
            MonknotMenuCommandButton(.restartTerminal, action: restart)

            Divider()

            MonknotMenuCommandButton(.killTerminal, action: kill)
        }
        .help(session.workingDirectory.path)
        .accessibilityLabel(accessibilityLabel)
    }

    /// `ok` running, `danger` failed or exited non-zero; otherwise the tab's own ink.
    private var statusTint: Color? {
        switch session.status {
        case .running:
            return Color(hex: theme.semanticColors.diffAdded)
        case .failed:
            return theme.dangerColor
        case let .exited(status):
            if let status, status != 0 {
                return theme.dangerColor
            }
            return nil
        case .idle:
            return nil
        }
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
            title: "No terminal session",
            detail: "Start a shell in this workspace.",
            theme: theme,
            zoomScale: zoomScale
        ) {
            MonknotActionButton(
                title: "New Session",
                role: .secondary,
                theme: theme,
                zoomScale: zoomScale,
                size: .bar,
                action: createTerminal
            )
        }
        .background(theme.surfaceColor)
    }
}
