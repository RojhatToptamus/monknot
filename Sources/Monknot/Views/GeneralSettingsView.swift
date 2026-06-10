import MonknotCore
import SwiftUI

struct GeneralSettingsView: View {
    let uiTheme: AppTheme
    @AppStorage("Monknot.zoomScale") private var zoomScale = 1.0
    @AppStorage("Monknot.previewWidthPercent") private var previewWidthPercent = 88.0
    @AppStorage("Monknot.usePointerCursors") private var usePointerCursors = false
    @AppStorage("Monknot.fontSmoothing") private var fontSmoothing = true
    @State private var betaFeedback = ""
    @State private var betaFeedbackNotice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsGroupCard(theme: uiTheme) {
                    SettingsToggleRow(
                        theme: uiTheme,
                        title: "Use pointer cursors",
                        detail: "Change the cursor to a pointer when hovering over interactive elements",
                        isOn: $usePointerCursors
                    )

                    SettingsToggleRow(
                        theme: uiTheme,
                        title: "Font Smoothing",
                        detail: "Use native macOS font anti-aliasing",
                        isOn: $fontSmoothing
                    )

                    SettingsStepperRow(
                        theme: uiTheme,
                        title: "Window zoom",
                        detail: "Adjust the application scale used by ⌘+ and ⌘−",
                        value: $zoomScale,
                        range: 0.7...3.0,
                        step: 0.1,
                        suffix: "x"
                    )

                    SettingsSliderRow(
                        theme: uiTheme,
                        title: "Preview width",
                        detail: "Set Markdown preview max width as a percentage of the editor pane",
                        value: $previewWidthPercent,
                        range: 55...100,
                        suffix: "%"
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Beta feedback")
                            .font(MonknotTypography.settingsRowTitle(theme: uiTheme))
                            .foregroundStyle(uiTheme.foregroundColor)
                        Text("Saved locally on this Mac only. No network calls.")
                            .font(MonknotTypography.settingsRowDetail(theme: uiTheme))
                            .foregroundStyle(uiTheme.mutedForegroundColor)

                        TextField("What should improve?", text: $betaFeedback, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)

                        HStack(spacing: 12) {
                            MonknotAccentButton(title: "Save feedback", theme: uiTheme, isDisabled: betaFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                                saveBetaFeedback()
                            }

                            if let betaFeedbackNotice {
                                Text(betaFeedbackNotice)
                                    .font(MonknotTypography.settingsRowDetail(theme: uiTheme))
                                    .foregroundStyle(uiTheme.mutedForegroundColor)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)
            .padding(.bottom, 10)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    private func saveBetaFeedback() {
        do {
            _ = try BetaFeedbackRecorder().append(message: betaFeedback)
            betaFeedback = ""
            betaFeedbackNotice = "Saved locally."
        } catch {
            betaFeedbackNotice = error.localizedDescription
        }
    }
}
