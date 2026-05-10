import MonknotCore
import SwiftUI

struct GeneralSettingsView: View {
    let uiTheme: AppTheme
    @AppStorage("Monknot.zoomScale") private var zoomScale = 1.0
    @AppStorage("Monknot.previewWidthPercent") private var previewWidthPercent = 88.0
    @AppStorage("Monknot.usePointerCursors") private var usePointerCursors = false
    @AppStorage("Monknot.fontSmoothing") private var fontSmoothing = true

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
                        range: 0.7...1.8,
                        step: 0.1,
                        suffix: "x"
                    )

                    SettingsSliderRow(
                        theme: uiTheme,
                        title: "Preview width",
                        detail: "Set Markdown preview max width as a percentage of the editor pane",
                        showsDivider: false,
                        value: $previewWidthPercent,
                        range: 55...100,
                        suffix: "%"
                    )
                }
            }
            .padding(20)
            .padding(.bottom, 10)
        }
    }
}
