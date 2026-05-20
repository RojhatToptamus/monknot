import MonknotCore
import SwiftUI

struct MarkdownPDFExportOptionsSheet: View {
    let document: WorkspaceDocument
    let theme: AppTheme
    @Binding var options: MarkdownPDFExportOptions
    let isExporting: Bool
    let cancel: () -> Void
    let export: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export PDF")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.foregroundColor)
                Text(document.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            SettingsGroupCard(theme: theme) {
                SettingsRow(theme: theme, title: "Page size", detail: "Choose the export page format.") {
                    MonknotSettingsSegmentedControl(
                        options: MarkdownPDFPageSize.allCases.map {
                            MonknotSettingsSegment(id: $0.rawValue, title: $0.title)
                        },
                        selection: Binding(
                            get: { options.pageSize.rawValue },
                            set: { raw in
                                if let value = MarkdownPDFPageSize(rawValue: raw) {
                                    options.pageSize = value
                                }
                            }
                        ),
                        theme: theme
                    )
                    .frame(maxWidth: 230)
                }

                SettingsRow(theme: theme, title: "Margins", detail: "Control the rendered content density.") {
                    MonknotSettingsSegmentedControl(
                        options: MarkdownPDFMarginPreset.allCases.map {
                            MonknotSettingsSegment(id: $0.rawValue, title: $0.title)
                        },
                        selection: Binding(
                            get: { options.marginPreset.rawValue },
                            set: { raw in
                                if let value = MarkdownPDFMarginPreset(rawValue: raw) {
                                    options.marginPreset = value
                                }
                            }
                        ),
                        theme: theme
                    )
                    .frame(maxWidth: 180)
                }

                SettingsSliderRow(
                    theme: theme,
                    title: "Scale",
                    detail: "Set the PDF render scale explicitly.",
                    value: Binding(
                        get: { options.scalePercent },
                        set: { options.scalePercent = min(180, max(70, $0)) }
                    ),
                    range: 70...180,
                    suffix: "%"
                )

                SettingsRow(theme: theme, title: "Theme", detail: "Use the current view or force a light/dark PDF.", showsDivider: false) {
                    MonknotSettingsSegmentedControl(
                        options: MarkdownPDFThemeMode.allCases.map {
                            MonknotSettingsSegment(id: $0.rawValue, title: $0.title)
                        },
                        selection: Binding(
                            get: { options.themeMode.rawValue },
                            set: { raw in
                                if let value = MarkdownPDFThemeMode(rawValue: raw) {
                                    options.themeMode = value
                                }
                            }
                        ),
                        theme: theme
                    )
                    .frame(maxWidth: 230)
                }
            }

            HStack {
                Spacer()
                SettingsOutlineButton(title: "Cancel", theme: theme, isDisabled: isExporting, action: cancel)
                MonknotAccentButton(
                    title: isExporting ? "Exporting..." : "Export...",
                    theme: theme,
                    isDisabled: isExporting,
                    action: export
                )
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(theme.surfaceColor)
    }
}
