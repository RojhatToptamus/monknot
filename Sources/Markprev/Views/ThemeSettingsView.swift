import MarkprevCore
import SwiftUI

struct ThemeSettingsView: View {
    @AppStorage("Markprev.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
    @AppStorage("Markprev.lightThemeID") private var lightThemeID = AppTheme.codexLight.id
    @AppStorage("Markprev.darkThemeID") private var darkThemeID = AppTheme.codexDark.id
    @AppStorage("Markprev.zoomScale") private var zoomScale = 1.0
    @AppStorage("Markprev.uiFontSize") private var uiFontSize = 16.0
    @AppStorage("Markprev.codeFontSize") private var codeFontSize = 15.0
    @AppStorage("Markprev.usePointerCursors") private var usePointerCursors = false
    @AppStorage("Markprev.fontSmoothing") private var fontSmoothing = true

    private var themePreference: ThemePreference {
        get { ThemePreference(rawValue: themePreferenceRawValue) ?? .system }
        nonmutating set { themePreferenceRawValue = newValue.rawValue }
    }

    private var lightTheme: AppTheme {
        AppTheme.lightTheme(id: lightThemeID)
    }

    private var darkTheme: AppTheme {
        AppTheme.darkTheme(id: darkThemeID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Appearance")
                    .font(.system(size: 28, weight: .bold))
                    .padding(.bottom, 20)

                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Theme")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Use light, dark, or match your system")
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Picker("Theme", selection: Binding(
                            get: { themePreference },
                            set: { themePreference = $0 }
                        )) {
                            ForEach(ThemePreference.allCases) { theme in
                                Label(theme.title, systemImage: theme.systemImage).tag(theme)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 282)
                    }
                    .padding(14)

                    Divider()

                    CodePreviewCard(lightTheme: lightTheme, darkTheme: darkTheme)
                        .padding(8)

                    ThemePresetPanel(
                        title: "Light theme",
                        selectedThemeID: $lightThemeID,
                        themes: AppTheme.lightThemes,
                        theme: lightTheme,
                        contrast: 45
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)

                    ThemePresetPanel(
                        title: "Dark theme",
                        selectedThemeID: $darkThemeID,
                        themes: AppTheme.darkThemes,
                        theme: darkTheme,
                        contrast: 60
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)

                    SettingsToggleRow(
                        title: "Use pointer cursors",
                        detail: "Change the cursor to a pointer when hovering over interactive elements",
                        isOn: $usePointerCursors
                    )

                    SettingsStepperRow(
                        title: "UI font size",
                        detail: "Adjust the base size used for the Markprev UI",
                        value: $uiFontSize,
                        range: 12...22
                    )

                    SettingsStepperRow(
                        title: "Code font size",
                        detail: "Adjust the base size used for source and preview code",
                        value: $codeFontSize,
                        range: 11...24
                    )

                    SettingsToggleRow(
                        title: "Font Smoothing",
                        detail: "Use native macOS font anti-aliasing",
                        isOn: $fontSmoothing
                    )

                    SettingsStepperRow(
                        title: "Window zoom",
                        detail: "Adjust the application scale used by Command + and Command -",
                        value: $zoomScale,
                        range: 0.7...1.8,
                        step: 0.1,
                        suffix: "x"
                    )
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.separator)
                }
            }
            .padding(28)
        }
        .frame(width: 700, height: 760)
    }
}

private struct CodePreviewCard: View {
    let lightTheme: AppTheme
    let darkTheme: AppTheme

    var body: some View {
        HStack(spacing: 0) {
            codePane(theme: lightTheme, surface: "sidebar", contrast: "42")
            Divider()
            codePane(theme: darkTheme, surface: "sidebar-editor", contrast: "68")
        }
        .frame(height: 176)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator)
        }
    }

    private func codePane(theme: AppTheme, surface: String, contrast: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            codeLine(number: "1", text: "const themePreview: Theme = {", color: Color(hex: theme.codeKeyword), theme: theme)
            highlightedLine(theme: theme) {
                codeLine(number: "2", text: "  surface: \"\(surface)\",", color: Color(hex: theme.codeBuiltin), theme: theme)
            }
            highlightedLine(theme: theme) {
                codeLine(number: "3", text: "  accent: \"\(theme.accent)\",", color: Color(hex: theme.codeString), theme: theme)
            }
            highlightedLine(theme: theme) {
                codeLine(number: "4", text: "  contrast: \(contrast),", color: Color(hex: theme.codeNumber), theme: theme)
            }
            codeLine(number: "5", text: "};", color: theme.mutedForegroundColor, theme: theme)

            Spacer()

            Capsule()
                .fill(theme.foregroundColor.opacity(0.18))
                .frame(width: 200, height: 10)
                .padding(.leading, 8)
        }
        .font(.system(size: 16, weight: .regular, design: .monospaced))
        .padding(.vertical, 12)
        .background(theme.surfaceColor)
    }

    private func highlightedLine<Content: View>(theme: AppTheme, @ViewBuilder content: () -> Content) -> some View {
        content()
            .background(Color(hex: theme.selectionBackground).opacity(theme.isDark ? 0.42 : 0.32))
    }

    private func codeLine(number: String, text: String, color: Color, theme: AppTheme) -> some View {
        HStack(spacing: 12) {
            Text(number)
                .foregroundStyle(theme.mutedForegroundColor)
                .frame(width: 34, alignment: .trailing)
            Text(text)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ThemePresetPanel: View {
    let title: String
    @Binding var selectedThemeID: String
    let themes: [AppTheme]
    let theme: AppTheme
    let contrast: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button("Import") {}
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(true)

                Button("Copy theme") {}
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(true)

                Picker(title, selection: $selectedThemeID) {
                    ForEach(themes) { option in
                        Label(option.name, systemImage: "textformat")
                            .tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 230)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            ThemeValueRow(label: "Accent", value: theme.accent, chipColor: Color(hex: theme.accent), forceLightText: true)
            ThemeValueRow(label: "Background", value: theme.background, chipColor: Color(hex: theme.background))
            ThemeValueRow(label: "Foreground", value: theme.foreground, chipColor: Color(hex: theme.foreground))
            ThemeValueRow(label: "UI font", value: "-apple-system")
            ThemeValueRow(label: "Code font", value: "ui-monospace")

            HStack {
                Text("Contrast")
                Spacer()
                Slider(value: .constant(Double(contrast)), in: 0...100)
                    .frame(width: 190)
                Text("\(contrast)")
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator)
        }
    }
}

private struct ThemeValueRow: View {
    let label: String
    let value: String
    var chipColor: Color?
    var forceLightText = false

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: chipColor == nil ? .monospaced : .default))
                .foregroundStyle(forceLightText ? Color.white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(minWidth: 128, alignment: .leading)
                .background((chipColor ?? Color(nsColor: .controlBackgroundColor)), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) {
                    if chipColor != nil {
                        Circle()
                            .stroke(.white.opacity(0.35), lineWidth: 1)
                            .frame(width: 13, height: 13)
                            .padding(.leading, 10)
                    }
                }
                .padding(.leading, chipColor == nil ? 0 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(detail)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(14)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct SettingsStepperRow: View {
    let title: String
    let detail: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var suffix = "px"

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(detail)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Stepper(value: $value, in: range, step: step) {
                Text(displayValue)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .frame(width: 64)
            }
            Text(suffix)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var displayValue: String {
        if suffix == "x" {
            return String(format: "%.1f", value)
        }

        return "\(Int(value.rounded()))"
    }
}
