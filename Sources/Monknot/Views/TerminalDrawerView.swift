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
    let close: () -> Void

    private var uiFontSize: Double { theme.uiFontSize }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                fontSize: scaled(13.5),
                usePointerCursors: usePointerCursors,
                fontSmoothing: fontSmoothing
            )
            .id(sessions.activeTerminalID)
        } else {
            TerminalEmptySurface(theme: theme, zoomScale: zoomScale, uiFontSize: uiFontSize)
        }
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
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    private var terminalTabsWidth: CGFloat {
        min(scaled(220), max(scaled(60), CGFloat(sessions.tabs.count) * scaled(68)))
    }

    var body: some View {
        HStack(spacing: scaled(4)) {
            terminalTabs

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

            Spacer(minLength: 0)

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

    private var terminalTabs: some View {
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
                    }
                }
            }
        }
        .frame(minWidth: scaled(60), maxWidth: scaled(220))
        .frame(width: terminalTabsWidth, alignment: .leading)
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
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: scaled(5)) {
                    Image(systemName: "terminal")
                        .font(.system(size: scaled(11), weight: .regular))
                        .foregroundStyle(iconColor)
                        .accessibilityHidden(true)

                    Circle()
                        .fill(statusColor)
                        .frame(width: scaled(5), height: scaled(5))
                        .accessibilityHidden(true)

                    Text("\(index)")
                        .font(.system(size: scaled(11), weight: .medium, design: .rounded))
                        .foregroundStyle(isSelected ? theme.foregroundColor : theme.mutedForegroundColor)
                        .monospacedDigit()
                }
                .padding(.leading, scaled(8))
                .padding(.trailing, scaled(4))
                .frame(height: scaled(26))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected || isHovered {
                Button(action: kill) {
                    Image(systemName: "xmark")
                        .font(.system(size: scaled(8), weight: .bold))
                        .foregroundStyle(theme.mutedForegroundColor.opacity(isHovered ? 0.92 : 0.72))
                        .frame(width: scaled(16), height: scaled(20))
                        .contentShape(RoundedRectangle(cornerRadius: theme.chromeRadius(4, zoomScale: zoomScale)))
                }
                .buttonStyle(.plain)
                .help("Kill Terminal")
                .accessibilityLabel("Kill terminal \(index)")
                .monknotPointerCursor()
                .padding(.trailing, scaled(3))
            }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    let uiFontSize: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Image(systemName: "terminal")
            .font(.system(size: scaled(30), weight: .regular))
            .foregroundStyle(theme.mutedForegroundColor.opacity(0.54))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.contentSurfaceColor)
            .accessibilityLabel("No terminal session")
    }
}
