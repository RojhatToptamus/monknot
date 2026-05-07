import MarkprevCore
import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage("Markprev.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
    @AppStorage("Markprev.lightThemeID") private var lightThemeID = AppTheme.codexLight.id
    @AppStorage("Markprev.darkThemeID") private var darkThemeID = AppTheme.codexDark.id
    @AppStorage("Markprev.uiFontSize") private var uiFontSize = 16.0
    @AppStorage("Markprev.codeFontSize") private var codeFontSize = 15.0

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
            VStack(alignment: .leading, spacing: 0) {
                // --- Theme mode picker ---
                SettingsRow(title: "Theme", detail: "Use light, dark, or match your system") {
                    Picker("Theme", selection: Binding(
                        get: { themePreference },
                        set: { themePreference = $0 }
                    )) {
                        ForEach(ThemePreference.allCases) { pref in
                            Text(pref.title).tag(pref)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                // --- Code preview ---
                CodePreviewCard(lightTheme: lightTheme, darkTheme: darkTheme)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)

                Divider().padding(.leading, 20)

                // --- Light theme section ---
                themeSection(
                    title: "Light theme",
                    selectedThemeID: $lightThemeID,
                    themes: AppTheme.lightThemes,
                    theme: lightTheme,
                    contrast: 45
                )

                // --- Dark theme section ---
                themeSection(
                    title: "Dark theme",
                    selectedThemeID: $darkThemeID,
                    themes: AppTheme.darkThemes,
                    theme: darkTheme,
                    contrast: 60
                )

                // --- Font sizes ---
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
            }
            .padding(.vertical, 8)
        }
    }

    /// A theme section: header with picker, then flat value rows, then contrast slider.
    @ViewBuilder
    private func themeSection(
        title: String,
        selectedThemeID: Binding<String>,
        themes: [AppTheme],
        theme: AppTheme,
        contrast: Int
    ) -> some View {
        // Section header with picker
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            HStack(spacing: 12) {
                Button("Import") {}
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .disabled(true)

                Button("Copy theme") {}
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .disabled(true)

                Picker(title, selection: selectedThemeID) {
                    ForEach(themes) { t in
                        Text(t.name).tag(t.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 20)
        }

        // Theme values — flat rows
        ThemeValueRow(label: "Accent", value: theme.accent, chipColor: Color(hex: theme.accent))
        ThemeValueRow(label: "Background", value: theme.background, chipColor: Color(hex: theme.background))
        ThemeValueRow(label: "Foreground", value: theme.foreground, chipColor: Color(hex: theme.foreground))
        ThemeValueRow(label: "UI font", value: "-apple-system")
        ThemeValueRow(label: "Code font", value: "ui-monospace")
        SettingsSliderRow(title: "Contrast", value: .constant(Double(contrast)), range: 0...100)
    }
}

// MARK: - Code Preview

private struct CodePreviewCard: View {
    let lightTheme: AppTheme
    let darkTheme: AppTheme

    var body: some View {
        HStack(spacing: 0) {
            codePane(theme: lightTheme, surface: "sidebar", contrast: "42")
            codePane(theme: darkTheme, surface: "sidebar-editor", contrast: "68")
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func codePane(theme: AppTheme, surface: String, contrast: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            codeLine(n: "1", text: "const themePreview: Theme = {", color: Color(hex: theme.codeKeyword), theme: theme)
            highlightedLine(theme: theme) {
                codeLine(n: "2", text: "  surface: \"\(surface)\",", color: Color(hex: theme.codeBuiltin), theme: theme)
            }
            highlightedLine(theme: theme) {
                codeLine(n: "3", text: "  accent: \"\(theme.accent)\",", color: Color(hex: theme.codeString), theme: theme)
            }
            highlightedLine(theme: theme) {
                codeLine(n: "4", text: "  contrast: \(contrast),", color: Color(hex: theme.codeNumber), theme: theme)
            }
            codeLine(n: "5", text: "};", color: theme.mutedForegroundColor, theme: theme)
            Spacer()
        }
        .font(.system(size: 14, weight: .regular, design: .monospaced))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor)
    }

    private func highlightedLine<Content: View>(theme: AppTheme, @ViewBuilder content: () -> Content) -> some View {
        content()
            .background(Color(hex: theme.selectionBackground).opacity(theme.isDark ? 0.42 : 0.32))
    }

    private func codeLine(n: String, text: String, color: Color, theme: AppTheme) -> some View {
        HStack(spacing: 10) {
            Text(n)
                .foregroundStyle(theme.mutedForegroundColor)
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
