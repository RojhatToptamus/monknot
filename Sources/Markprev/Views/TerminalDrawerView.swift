import Foundation
import MarkprevCore
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
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        VStack(spacing: 0) {
            terminalTopBar

            Divider()
                .overlay(theme.borderColor)

            terminalSurface
        }
        .background(theme.surfaceColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal panel")
        .onAppear {
            sessions.ensureActiveTerminal(in: workingDirectory)
        }
        .onChange(of: workingDirectory?.standardizedFileURL.path ?? "") { _, _ in
            sessions.setDefaultDirectory(workingDirectory)
        }
    }

    private var terminalTopBar: some View {
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
        .padding(.horizontal, scaled(10))
        .frame(height: scaled(44))
    }

    private var terminalTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: scaled(4)) {
                ForEach(sessions.tabs) { tab in
                    if let session = sessions.session(for: tab.id) {
                        TerminalTabChip(
                            tab: tab,
                            session: session,
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
            .padding(.vertical, scaled(4))
        }
        .frame(minWidth: scaled(96), maxWidth: scaled(360), maxHeight: scaled(34))
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

private struct TerminalTabChip: View {
    let tab: TerminalTabItem
    @ObservedObject var session: TerminalSessionStore
    let isSelected: Bool
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let select: () -> Void
    let restart: () -> Void
    let kill: () -> Void

    @State private var isHovered = false

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: scaled(6)) {
                    Image(systemName: "terminal")
                        .font(.system(size: scaled(12), weight: .regular))
                        .foregroundStyle(iconColor)
                        .frame(width: scaled(15))
                        .accessibilityHidden(true)

                    Circle()
                        .fill(statusColor)
                        .frame(width: scaled(6), height: scaled(6))
                        .accessibilityHidden(true)

                    Text(tab.title)
                        .font(.system(size: scaled(12), weight: .medium))
                        .foregroundStyle(isSelected ? theme.foregroundColor : theme.mutedForegroundColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: scaled(96), alignment: .leading)
                }
                .padding(.leading, scaled(9))
                .padding(.trailing, scaled(4))
                .frame(height: scaled(26))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected || isHovered {
                Button(action: kill) {
                    Image(systemName: "xmark")
                        .font(.system(size: scaled(9), weight: .bold))
                        .foregroundStyle(theme.mutedForegroundColor.opacity(isHovered ? 0.92 : 0.72))
                        .frame(width: scaled(20), height: scaled(22))
                        .contentShape(RoundedRectangle(cornerRadius: theme.chromeRadius(5, zoomScale: zoomScale)))
                }
                .buttonStyle(.plain)
                .help("Kill Terminal")
                .accessibilityLabel("Kill \(tab.title)")
                .markprevPointerCursor()
                .padding(.trailing, scaled(3))
            }
        }
        .frame(minWidth: scaled(118), maxWidth: scaled(168), alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale)))
        .overlay {
            RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale))
                .strokeBorder(borderColor, lineWidth: 1)
        }
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
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        Image(systemName: "terminal")
            .font(.system(size: scaled(30), weight: .regular))
            .foregroundStyle(theme.mutedForegroundColor.opacity(0.54))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surfaceColor)
            .accessibilityLabel("No terminal session")
    }
}
