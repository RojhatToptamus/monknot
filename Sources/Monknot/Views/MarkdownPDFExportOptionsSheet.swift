import MonknotCore
import SwiftUI

/// File › Export PDF: the sheet layout around the same rows and controls as Settings › Export, at the
/// workspace zoom.
struct MarkdownPDFExportOptionsSheet: View {
    let document: WorkspaceDocument
    let theme: AppTheme
    var zoomScale: Double = 1
    @Binding var options: MarkdownPDFExportOptions
    let isExporting: Bool
    let cancel: () -> Void
    let export: () -> Void

    var body: some View {
        MonknotSheetLayout(title: "Export PDF", message: document.displayName, theme: theme, zoomScale: zoomScale, width: 520) {
            SettingsGroupCard(theme: theme) {
                popUpRow(
                    title: "Page size",
                    detail: "Paper size for this export",
                    selection: Binding(
                        get: { options.pageSize.rawValue },
                        set: { options.pageSize = MarkdownPDFPageSize(rawValue: $0) ?? options.pageSize }
                    ),
                    options: MarkdownPDFPageSize.allCases.map { ($0.rawValue, $0.title) }
                )

                popUpRow(
                    title: "Margins",
                    detail: "White space around each page",
                    selection: Binding(
                        get: { options.marginPreset.rawValue },
                        set: { options.marginPreset = MarkdownPDFMarginPreset(rawValue: $0) ?? options.marginPreset }
                    ),
                    options: MarkdownPDFMarginPreset.allCases.map { ($0.rawValue, $0.title) }
                )

                popUpRow(
                    title: "Theme",
                    detail: "The current view, or a light or dark PDF",
                    selection: Binding(
                        get: { options.themeMode.rawValue },
                        set: { options.themeMode = MarkdownPDFThemeMode(rawValue: $0) ?? options.themeMode }
                    ),
                    options: MarkdownPDFThemeMode.allCases.map { ($0.rawValue, $0.title) }
                )

                SettingsSliderRow(
                    theme: theme,
                    title: "Scale",
                    detail: "Scale the content before it is paginated",
                    value: Binding(
                        get: { options.scalePercent },
                        set: { options.scalePercent = min(130, max(70, $0)) }
                    ),
                    range: 70...130,
                    suffix: "%"
                )

                SettingsSliderRow(
                    theme: theme,
                    title: "Text size",
                    detail: "Base body text size in points",
                    value: Binding(
                        get: { options.textSizePoints },
                        set: { options.textSizePoints = min(18, max(10, $0)) }
                    ),
                    range: 10...18,
                    suffix: " pt"
                )

                SettingsSliderRow(
                    theme: theme,
                    title: "Content width",
                    detail: "Share of the printable page used by content",
                    showsDivider: false,
                    value: Binding(
                        get: { options.contentWidthPercent },
                        set: { options.contentWidthPercent = min(100, max(65, $0)) }
                    ),
                    range: 65...100,
                    suffix: "%"
                )
            }
        } buttons: {
            MonknotActionButton(title: "Cancel", role: .secondary, theme: theme, zoomScale: zoomScale, isDisabled: isExporting, action: cancel)
                .keyboardShortcut(.cancelAction)
            MonknotActionButton(
                title: isExporting ? "Exporting…" : "Export…",
                role: .primary,
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: isExporting,
                action: export
            )
            .keyboardShortcut(.defaultAction)
        }
        // The Settings rows read their zoom from the environment.
        .environment(\.monknotSettingsZoomScale, zoomScale)
    }

    private func popUpRow(
        title: String,
        detail: String,
        selection: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        SettingsRow(theme: theme, title: title, detail: detail) {
            MonknotSettingsMenuPicker(
                title: title,
                selection: selection,
                options: options,
                theme: theme
            )
        }
    }
}
