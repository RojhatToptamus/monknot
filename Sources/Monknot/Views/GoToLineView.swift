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
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    /// Return goes; the footer says so, and an error takes the footer's place.
    var body: some View {
        MonknotCommandOverlay(
            theme: theme,
            zoomScale: zoomScale,
            panelHeight: scaled(
                MonknotCommandOverlayMetrics.headerHeightBase + MonknotCommandOverlayMetrics.footerHeightBase
            ),
            close: close
        ) {
            VStack(spacing: 0) {
                MonknotCommandOverlayField(
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    placeholder: "Line or line:column",
                    text: $input,
                    isFocused: $isInputFocused,
                    theme: theme,
                    zoomScale: zoomScale,
                    accessibilityHint: "Line and column numbers start at 1",
                    submit: submit,
                    close: close
                )

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale)))
                        .foregroundStyle(Color(hex: theme.semanticColors.diffRemoved))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, scaled(16))
                        .frame(height: scaled(MonknotCommandOverlayMetrics.footerHeightBase))
                        .overlay(alignment: .top) {
                            Rectangle().fill(theme.separatorColor).frame(height: 1)
                        }
                        .accessibilityLabel("Go to line error: \(errorMessage)")
                } else {
                    MonknotCommandOverlayFooter(
                        hints: [
                            .init(keys: "↩", action: "Go"),
                            .init(keys: "Esc", action: "Close"),
                        ],
                        theme: theme,
                        zoomScale: zoomScale
                    )
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
