import MonknotCore
import SwiftUI

struct GeneralSettingsView: View {
    let uiTheme: AppTheme
    @AppStorage("Monknot.usePointerCursors") private var usePointerCursors = false
    @AppStorage("Monknot.reopenLastWorkspace") private var reopenLastWorkspace = true
    @AppStorage("Monknot.fontSmoothing") private var fontSmoothing = true
    @AppStorage("Monknot.previewWidthPercent") private var previewWidthPercent = 88.0

    var body: some View {
        SettingsPage(theme: uiTheme) {
            SettingsSectionHeader(theme: uiTheme, title: "Behavior")
            SettingsGroupCard(theme: uiTheme, showsBorder: false) {
                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Pointer cursor on controls",
                    detail: "Non-standard on macOS; off by default",
                    isOn: $usePointerCursors
                )

                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Reopen last workspace on launch",
                    isOn: $reopenLastWorkspace
                )

                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Font smoothing",
                    detail: "Use native macOS anti-aliasing",
                    showsDivider: false,
                    isOn: $fontSmoothing
                )
            }

            SettingsSectionHeader(theme: uiTheme, title: "Reading")
                .padding(.top, 22)
            SettingsGroupCard(theme: uiTheme, showsBorder: false) {
                SettingsSliderRow(
                    theme: uiTheme,
                    title: "Preview width",
                    detail: "Share of the editor pane",
                    value: $previewWidthPercent,
                    range: 55...100,
                    suffix: "%"
                )

                SettingsRow(
                    theme: uiTheme,
                    title: "Terminal working directory",
                    showsDivider: false
                ) {
                    HStack(spacing: 8) {
                        Text("Workspace root")
                            .font(.system(size: 12))
                            .foregroundStyle(uiTheme.foregroundColor)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(uiTheme.tertiaryForegroundColor)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(
                        uiTheme.insetFillColor,
                        in: RoundedRectangle(cornerRadius: uiTheme.settingsControlCornerRadius)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: uiTheme.settingsControlCornerRadius)
                            .strokeBorder(uiTheme.borderColor, lineWidth: 1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
