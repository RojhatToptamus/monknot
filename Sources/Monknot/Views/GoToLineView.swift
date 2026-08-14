import MonknotCore
import SwiftUI

struct GoToLineView: View {
    let theme: AppTheme
    let zoomScale: Double
    let close: () -> Void
    let go: (String) -> String?

    @State private var input = ""
    @State private var errorMessage: String?
    @FocusState private var isInputFocused: Bool

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        MonknotCommandOverlay(
            theme: theme,
            zoomScale: zoomScale,
            panelHeight: scaled(errorMessage == nil ? 54 : 94),
            close: close
        ) {
            VStack(spacing: 0) {
                HStack(spacing: scaled(8)) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: scaled(14), weight: .medium))
                        .foregroundStyle(theme.mutedForegroundColor)
                        .accessibilityHidden(true)

                    TextField("Line or line:column", text: $input)
                        .textFieldStyle(.plain)
                        .focused($isInputFocused)
                        .font(.system(size: scaled(14)))
                        .foregroundStyle(theme.foregroundColor)
                        .onSubmit(submit)
                        .accessibilityLabel("Line or line and column")
                        .accessibilityHint("Line and column numbers start at 1")

                    MonknotActionButton(
                        title: "Go",
                        role: .primary,
                        theme: theme,
                        zoomScale: zoomScale,
                        isDisabled: input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        action: submit
                    )

                    MonknotCommandOverlayEscapeButton(
                        theme: theme,
                        zoomScale: zoomScale,
                        close: close
                    )
                }
                .padding(.horizontal, scaled(14))
                .frame(height: scaled(54))

                if let errorMessage {
                    Divider()
                        .overlay(theme.separatorColor)

                    Text(errorMessage)
                        .font(.system(size: scaled(11.5)))
                        .foregroundStyle(Color(hex: theme.semanticColors.diffRemoved))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, scaled(14))
                        .frame(height: scaled(39))
                        .accessibilityLabel("Go to line error: \(errorMessage)")
                }
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                isInputFocused = true
            }
        }
    }

    private func submit() {
        errorMessage = go(input)
    }
}
