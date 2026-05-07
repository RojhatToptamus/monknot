import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("Markprev.zoomScale") private var zoomScale = 1.0
    @AppStorage("Markprev.usePointerCursors") private var usePointerCursors = false
    @AppStorage("Markprev.fontSmoothing") private var fontSmoothing = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsToggleRow(
                    title: "Use pointer cursors",
                    detail: "Change the cursor to a pointer when hovering over interactive elements",
                    isOn: $usePointerCursors
                )

                SettingsToggleRow(
                    title: "Font Smoothing",
                    detail: "Use native macOS font anti-aliasing",
                    isOn: $fontSmoothing
                )

                SettingsStepperRow(
                    title: "Window zoom",
                    detail: "Adjust the application scale used by ⌘+ and ⌘−",
                    value: $zoomScale,
                    range: 0.7...1.8,
                    step: 0.1,
                    suffix: "x"
                )
            }
            .padding(.vertical, 8)
        }
    }
}
