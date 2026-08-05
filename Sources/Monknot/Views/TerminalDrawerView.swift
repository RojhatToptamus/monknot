import Foundation
import MonknotCore
import SwiftUI

struct TerminalDrawerView: View {
    static let fontSizeBase: CGFloat = 13.5

    @ObservedObject var sessions: TerminalSessionCollectionStore
    let workingDirectory: URL?
    let theme: AppTheme
    let zoomScale: Double
    let usePointerCursors: Bool
    let fontSmoothing: Bool
    var showsChrome = true
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
                MonknotChromePanel(
                    theme: theme,
                    showsBottomBorder: false,
                    surface: theme.terminalSurfaceColor
                ) {
                    TerminalDrawerChromeRow(
                        sessions: sessions,
                        workingDirectory: workingDirectory,
                        theme: theme,
                        zoomScale: zoomScale,
                        close: close
                    )
                }
            }

            terminalSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.terminalSurfaceColor)
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
                    sessions.createTerminal(in: workingDirectory)
                }
            )
        }
    }
}

struct TerminalDrawerChromeRow: View {
    @ObservedObject var sessions: TerminalSessionCollectionStore
    let workingDirectory: URL?
    let theme: AppTheme
    let zoomScale: Double
    let close: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(6)) {
            TerminalDrawerTabGroup(
                sessions: sessions,
                workingDirectory: workingDirectory,
                theme: theme,
                zoomScale: zoomScale
            )
            .frame(minWidth: scaled(60), maxWidth: .infinity)
            .layoutPriority(1)

            MonknotIconButton(
                systemImage: "xmark",
                label: "Hide Terminal Panel",
                theme: theme,
                zoomScale: zoomScale,
                size: .compact,
                action: close
            )
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, scaled(8))
        .frame(height: MonknotMetrics.interfaceControl(36, theme: theme, zoomScale: zoomScale))
        .frame(maxWidth: .infinity)
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

            HStack(spacing: scaled(6)) {
                ZStack {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: scaled(3)) {
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
                        zoomScale: zoomScale,
                        surface: theme.terminalSurfaceColor
                    )
                }
                .frame(width: viewportWidth)

                Rectangle()
                    .fill(theme.separatorColor)
                    .frame(width: 1, height: scaled(13))

                MonknotIconButton(
                    systemImage: "plus",
                    label: "New Terminal",
                    theme: theme,
                    zoomScale: zoomScale,
                    size: .compact,
                    action: {
                        sessions.createTerminal(in: workingDirectory)
                    }
                )
            }
        }
        .frame(height: MonknotMetrics.interfaceControl(36, theme: theme, zoomScale: zoomScale))
    }

    private var fixedControlsWidth: CGFloat {
        MonknotMetrics.interfaceControl(26, theme: theme, zoomScale: zoomScale)
            + scaled(13)
            + 1
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
        HStack(spacing: showsCloseButton ? scaled(6) : 0) {
            Button(action: select) {
                HStack(spacing: scaled(6)) {
                    Image(systemName: "terminal")
                        .font(.system(
                            size: glyphScaled(14),
                            weight: .regular
                        ))
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)

                    Text("\(index)")
                        .font(.system(size: textScaled(12), weight: .regular, design: .monospaced))
                        .foregroundStyle(isSelected ? theme.foregroundColor : theme.mutedForegroundColor)
                        .monospacedDigit()
                }
                .padding(.leading, scaled(8))
                .padding(.trailing, showsCloseButton ? 0 : scaled(8))
                .frame(height: MonknotMetrics.interfaceControl(24, theme: theme, zoomScale: zoomScale))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if showsCloseButton {
                MonknotTabCloseButton(
                    label: "Kill terminal \(index)",
                    theme: theme,
                    zoomScale: zoomScale,
                    action: kill
                )
                .padding(.trailing, scaled(8))
            }
        }
        .frame(height: scaled(24), alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)))
        .overlay {
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
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
        return .clear
    }

    private var showsCloseButton: Bool {
        isSelected || isHovered
    }

    private var borderColor: Color {
        isSelected ? theme.borderColor : .clear
    }

    private var statusColor: Color {
        switch session.status {
        case .running:
            return Color(hex: theme.semanticColors.diffAdded)
        case .failed:
            return Color(hex: theme.semanticColors.diffRemoved)
        case let .exited(status):
            if let status, status != 0 {
                return Color(hex: theme.semanticColors.diffRemoved)
            }
            return theme.tertiaryForegroundColor
        case .idle:
            return theme.tertiaryForegroundColor
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
            title: "No session",
            detail: "⌃⌘T",
            theme: theme,
            zoomScale: zoomScale,
            iconSize: 34
        ) {
            MonknotActionButton(
                title: "New Session",
                systemImage: "plus",
                role: .primary,
                theme: theme,
                zoomScale: zoomScale,
                action: createTerminal
            )
        }
        .background(theme.terminalSurfaceColor)
    }
}
