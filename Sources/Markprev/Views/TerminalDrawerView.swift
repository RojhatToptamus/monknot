import Foundation
import MarkprevCore
import SwiftUI

struct TerminalDrawerView: View {
    @ObservedObject var session: TerminalSessionStore
    let theme: AppTheme
    let zoomScale: Double
    let close: () -> Void
    @State private var command = ""
    @FocusState private var isInputFocused: Bool

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
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.borderColor)
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal panel")
        .onAppear {
            isInputFocused = true
        }
        .onChange(of: session.completionCount) {
            focusPrompt()
        }
    }

    private var terminalTopBar: some View {
        HStack(spacing: scaled(4)) {
            terminalTab

            ChromeBarButton(
                systemImage: "plus",
                label: "New prompt",
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                action: {
                    command = ""
                    isInputFocused = true
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
            RoundedRectangle(cornerRadius: scaled(6))
                .fill(theme.foregroundColor.opacity(theme.isDark ? 0.07 : 0.05))
        )
        .accessibilityLabel("Terminal session: markprev")
    }

    private var terminalSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            promptLine
                .padding(.horizontal, scaled(20))
                .padding(.top, scaled(20))
                .padding(.bottom, scaled(14))

            ScrollView {
                VStack(alignment: .leading, spacing: scaled(6)) {
                    ForEach(session.lines) { line in
                        Text(line.text)
                            .font(.system(size: scaled(12.5), weight: line.kind == .command ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if session.isRunning {
                        Text("running...")
                            .font(.system(size: scaled(12.5), design: .monospaced))
                            .foregroundStyle(theme.mutedForegroundColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, scaled(20))
                .padding(.bottom, scaled(16))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var promptLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: scaled(8)) {
            Text(session.prompt)
                .font(.system(size: scaled(18), weight: .regular, design: .monospaced))
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(0)

            TextField("", text: $command)
                .textFieldStyle(.plain)
                .font(.system(size: scaled(18), weight: .regular, design: .monospaced))
                .foregroundStyle(theme.foregroundColor)
                .focused($isInputFocused)
                .onSubmit(submitCommand)
                .disabled(session.isRunning)
                .frame(minWidth: scaled(110), maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .accessibilityLabel("Terminal command")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submitCommand() {
        session.submit(command)
        command = ""
        focusPrompt()
    }

    private func color(for kind: TerminalLine.Kind) -> Color {
        switch kind {
        case .command:
            return theme.foregroundColor
        case .output:
            return theme.foregroundColor.opacity(0.86)
        case .status:
            return theme.mutedForegroundColor
        case .error:
            return Color(hex: theme.semanticColors.diffRemoved)
        }
    }

    private func focusPrompt() {
        DispatchQueue.main.async {
            isInputFocused = true
        }
    }
}
