import Foundation
import MarkprevCore
import SwiftUI

struct TerminalDrawerView: View {
    @ObservedObject var session: TerminalSessionStore
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
            session.startOrRestartIfNeeded(in: workingDirectory)
        }
    }

    private var terminalTopBar: some View {
        HStack(spacing: scaled(4)) {
            terminalTab

            ChromeBarButton(
                systemImage: "plus",
                label: "Restart Terminal",
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                action: {
                    session.restart(in: workingDirectory)
                }
            )

            Spacer(minLength: 0)

            ChromeBarButton(
                systemImage: "xmark",
                label: "Close Terminal",
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

    private var terminalTab: some View {
        HStack(spacing: scaled(7)) {
            Image(systemName: "terminal")
                .font(.system(size: scaled(12), weight: .regular))
                .foregroundStyle(theme.mutedForegroundColor)

            Text("markprev")
                .font(.system(size: scaled(12), weight: .medium))
                .foregroundStyle(theme.foregroundColor)
        }
        .padding(.horizontal, scaled(10))
        .frame(height: scaled(26))
        .background(
            RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale))
                .fill(theme.controlTrackFillColor)
        )
        .accessibilityLabel("Terminal session: markprev")
    }

    private var terminalSurface: some View {
        TerminalWebView(
            session: session,
            theme: theme,
            fontSize: scaled(13.5),
            usePointerCursors: usePointerCursors,
            fontSmoothing: fontSmoothing
        )
    }
}
