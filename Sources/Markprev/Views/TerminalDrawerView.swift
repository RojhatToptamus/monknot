import Foundation
import MarkprevCore
import SwiftUI

struct TerminalDrawerView: View {
    @ObservedObject var session: TerminalSessionStore
    let theme: AppTheme
    let close: () -> Void
    @State private var command = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            terminalTopBar

            Divider()
                .overlay(theme.borderColor)

            terminalSurface
        }
        .background {
            ZStack {
                Rectangle()
                    .fill(.regularMaterial)
                theme.surfaceColor
                    .opacity(theme.isDark ? 0.82 : 0.92)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.borderColor)
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(theme.isDark ? 0.34 : 0.16), radius: 24, x: -10, y: 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal sidebar")
        .onAppear {
            isInputFocused = true
        }
        .onChange(of: session.completionCount) {
            focusPrompt()
        }
    }

    private var terminalSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            promptLine
                .padding(.horizontal, 22)
                .padding(.top, 24)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(session.lines) { line in
                        Text(line.text)
                            .font(.system(size: 12.5, weight: line.kind == .command ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if session.isRunning {
                        Text("running...")
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(theme.mutedForegroundColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.elevatedSurfaceColor.opacity(theme.isDark ? 0.72 : 0.56))
    }

    private var terminalTopBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "terminal")
                    .font(.system(size: 13, weight: .semibold))
                Text("markprev")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
            }
            .foregroundStyle(theme.foregroundColor)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(theme.foregroundColor.opacity(theme.isDark ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 10))

            Button {
                command = ""
                isInputFocused = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .frame(width: 30, height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("New prompt")
            .accessibilityLabel("New prompt")

            Spacer()

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.foregroundColor.opacity(0.78))
                    .frame(width: 30, height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .focusable(true)
            .keyboardShortcut(.cancelAction)
            .help("Close Terminal")
            .accessibilityLabel("Close Terminal")
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var promptLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(session.prompt)
                .font(.system(size: 21, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(0)

            TextField("", text: $command)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.foregroundColor)
                .focused($isInputFocused)
                .onSubmit(submitCommand)
                .disabled(session.isRunning)
                .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
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
