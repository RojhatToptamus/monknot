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
        MonknotScrollView {
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
                        title: "Font smoothing",
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

                    feedbackSection
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

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Beta feedback")
                    .font(MonknotTypography.settingsRowTitle(theme: uiTheme))
                    .foregroundStyle(uiTheme.foregroundColor)

                Text("Saved locally on this Mac only. No network calls.")
                    .font(MonknotTypography.settingsRowDetail(theme: uiTheme))
                    .foregroundStyle(uiTheme.mutedForegroundColor)
            }

            TextField("What should improve?", text: $betaFeedback, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(minHeight: 72, alignment: .topLeading)
                .background(
                    uiTheme.insetFillColor,
                    in: RoundedRectangle(cornerRadius: uiTheme.settingsControlCornerRadius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: uiTheme.settingsControlCornerRadius)
                        .strokeBorder(uiTheme.borderColor, lineWidth: 1)
                }

            HStack(spacing: 12) {
                MonknotAccentButton(
                    title: "Save feedback",
                    theme: uiTheme,
                    isDisabled: betaFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    saveBetaFeedback()
                }

                if let betaFeedbackNotice {
                    Text(betaFeedbackNotice)
                        .font(MonknotTypography.settingsRowDetail(theme: uiTheme))
                        .foregroundStyle(uiTheme.mutedForegroundColor)
                }
            }
        }
        .padding(.horizontal, MonknotMetrics.Spacing.settingsRowHorizontal)
        .padding(.vertical, MonknotMetrics.Spacing.settingsRowVertical)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(uiTheme.borderColor)
                .frame(height: 1)
                .padding(.leading, MonknotMetrics.Spacing.settingsRowHorizontal)
        }
    }
}
