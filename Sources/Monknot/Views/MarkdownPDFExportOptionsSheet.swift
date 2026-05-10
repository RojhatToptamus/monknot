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
                    Picker("", selection: $options.pageSize) {
                        ForEach(MarkdownPDFPageSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                }

                SettingsRow(theme: theme, title: "Margins", detail: "Control the rendered content density.") {
                    Picker("", selection: $options.marginPreset) {
                        ForEach(MarkdownPDFMarginPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
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
                    Picker("", selection: $options.themeMode) {
                        ForEach(MarkdownPDFThemeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                }
            }

            HStack {
                Spacer()
                SettingsOutlineButton(title: "Cancel", theme: theme, isDisabled: isExporting, action: cancel)
                Button(action: export) {
                    HStack(spacing: 8) {
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isExporting ? "Exporting..." : "Export...")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(theme.accentColor, in: RoundedRectangle(cornerRadius: theme.settingsControlCornerRadius))
                }
                .buttonStyle(.plain)
                .disabled(isExporting)
                .monknotPointerCursor(enabled: !isExporting)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(theme.surfaceColor)
    }
}
