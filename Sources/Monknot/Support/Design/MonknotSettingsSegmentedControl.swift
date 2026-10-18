import MonknotCore
import SwiftUI

/// Settings' segmented control: the app's one segmented control with text cells, at the Settings
/// window's zoom (design.md §5.5, §12).
struct MonknotSettingsSegmentedControl: View {
    let options: [MonknotSettingsSegment]
    @Binding var selection: String
    let theme: AppTheme
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    var body: some View {
        MonknotSegmentedControl(
            options: options.map { MonknotSegmentOption(id: $0.id, title: $0.title) },
            selection: $selection,
            theme: theme,
            zoomScale: settingsZoomScale
        )
    }
}

struct MonknotSettingsSegment: Identifiable {
    let id: String
    let title: String
}

/// Settings' pop-up: the app's one pop-up button at the Settings window's zoom (design.md §5.3, §12).
struct MonknotSettingsMenuPicker: View {
    let title: String
    @Binding var selection: String
    let options: [(id: String, title: String)]
    let theme: AppTheme
    var previewsSelection = false
    var onPreviewSelection: ((String) -> Void)?
    var onCancelPreview: (() -> Void)?
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    var body: some View {
        MonknotPopUpButton(
            label: title,
            selection: $selection,
            items: options.map { MonknotPopUpItem(id: $0.id, title: $0.title) },
            theme: theme,
            zoomScale: settingsZoomScale,
            previewsSelection: previewsSelection,
            onPreviewSelection: onPreviewSelection,
            onCancelPreview: onCancelPreview
        )
    }
}
