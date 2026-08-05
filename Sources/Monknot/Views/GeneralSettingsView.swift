import MonknotCore
import SwiftUI

struct GeneralSettingsView: View {
    let uiTheme: AppTheme
    @AppStorage("Monknot.usePointerCursors") private var usePointerCursors = false
    @AppStorage("Monknot.reopenLastWorkspace") private var reopenLastWorkspace = true
    @AppStorage("Monknot.fontSmoothing") private var fontSmoothing = true
    @AppStorage("Monknot.previewWidthPercent") private var previewWidthPercent = 88.0
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: uiTheme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        SettingsPage(theme: uiTheme) {
            SettingsSectionHeader(theme: uiTheme, title: "Behavior")
            SettingsGroupCard(theme: uiTheme) {
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
                .padding(.top, scaled(22))
            SettingsGroupCard(theme: uiTheme) {
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
                    HStack(spacing: scaled(8)) {
                        Text("Workspace root")
                            .font(.system(size: MonknotMetrics.interfaceText(12, theme: uiTheme, zoomScale: settingsZoomScale)))
                            .foregroundStyle(uiTheme.foregroundColor)

                        Image(systemName: "chevron.down")
                            .font(.system(
                                size: MonknotMetrics.interfaceGlyph(9, theme: uiTheme, zoomScale: settingsZoomScale),
                                weight: .semibold
                            ))
                            .foregroundStyle(uiTheme.tertiaryForegroundColor)
                    }
                    .padding(.horizontal, scaled(9))
                    .frame(height: scaled(24))
                    .background(
                        uiTheme.insetFillColor,
                        in: RoundedRectangle(cornerRadius: uiTheme.chromeRadius(uiTheme.settingsControlCornerRadius, zoomScale: settingsZoomScale))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: uiTheme.chromeRadius(uiTheme.settingsControlCornerRadius, zoomScale: settingsZoomScale))
                            .strokeBorder(uiTheme.borderColor, lineWidth: 1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
