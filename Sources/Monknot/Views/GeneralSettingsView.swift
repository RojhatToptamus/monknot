import AppKit
import MonknotCore
import SwiftUI

struct GeneralSettingsView: View {
    let uiTheme: AppTheme
    @AppStorage("Monknot.usePointerCursors") private var usePointerCursors = false
    @AppStorage("Monknot.fontSmoothing") private var fontSmoothing = true
    @State private var betaFeedback = ""
    @State private var betaFeedbackNotice: String?
    @State private var betaFeedbackNoticeIsError = false
    @FocusState private var isFeedbackFocused: Bool

    var body: some View {
        SettingsPage(theme: uiTheme) {
            SettingsSectionHeader(theme: uiTheme, title: "Behavior")
            SettingsGroupCard(theme: uiTheme, showsBorder: false) {
                    SettingsToggleRow(
                        theme: uiTheme,
                        title: "Use pointer cursors",
                        detail: "Non-standard on macOS; off by default",
                        isOn: $usePointerCursors
                    )

                    SettingsToggleRow(
                        theme: uiTheme,
                        title: "Font smoothing",
                        detail: "Use native macOS anti-aliasing",
                        showsDivider: false,
                        isOn: $fontSmoothing
                    )
            }

            SettingsSectionHeader(theme: uiTheme, title: "Beta")
                .padding(.top, 22)
            SettingsGroupCard(theme: uiTheme, showsBorder: false) {
                feedbackSection
            }
        }
    }

    private func saveBetaFeedback() {
        do {
            _ = try BetaFeedbackRecorder().append(message: betaFeedback)
            betaFeedback = ""
            betaFeedbackNoticeIsError = false
            betaFeedbackNotice = "Saved locally."
            announce("Feedback saved locally")
        } catch {
            betaFeedbackNoticeIsError = true
            betaFeedbackNotice = error.localizedDescription
            announce("Could not save feedback: \(error.localizedDescription)")
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
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
                .focused($isFeedbackFocused)
                .accessibilityLabel("Beta feedback")
                .accessibilityHint("Saved locally on this Mac only")
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
                        .strokeBorder(
                            isFeedbackFocused ? uiTheme.accentColor.opacity(0.9) : uiTheme.borderColor,
                            lineWidth: isFeedbackFocused ? 1.5 : 1
                        )
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
                        .foregroundStyle(
                            betaFeedbackNoticeIsError
                                ? Color(hex: uiTheme.semanticColors.diffRemoved)
                                : uiTheme.mutedForegroundColor
                        )
                        .accessibilityLabel(
                            betaFeedbackNoticeIsError
                                ? "Could not save feedback: \(betaFeedbackNotice)"
                                : betaFeedbackNotice
                        )
                }
            }
        }
        .padding(.horizontal, MonknotMetrics.Spacing.settingsRowHorizontal)
        .padding(.vertical, MonknotMetrics.Spacing.settingsRowVertical)
    }
}
