import MarkprevCore
import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var themeStore: ThemeSettingsStore
    @AppStorage("Markprev.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
    @State private var lightDraft = ThemeConfiguration(theme: AppTheme.codexLight)
    @State private var darkDraft = ThemeConfiguration(theme: AppTheme.codexDark)

    private var themePreference: ThemePreference {
        get { ThemePreference(rawValue: themePreferenceRawValue) ?? .system }
        nonmutating set { themePreferenceRawValue = newValue.rawValue }
    }

    private var draftLightTheme: AppTheme {
        lightDraft.applied(to: themeStore.presetTheme(for: .light))
    }

    private var draftDarkTheme: AppTheme {
        darkDraft.applied(to: themeStore.presetTheme(for: .dark))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(title: "Theme", detail: "Use light, dark, or match your system") {
                    Picker("Theme", selection: Binding(
                        get: { themePreference },
                        set: { themePreference = $0 }
                    )) {
                        ForEach(ThemePreference.allCases) { pref in
                            Label(pref.title, systemImage: pref.systemImage)
                                .tag(pref)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }

                CodePreviewCard(lightTheme: draftLightTheme, darkTheme: draftDarkTheme)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)

                ThemeEditorSection(slot: .light, themeStore: themeStore, draft: $lightDraft)
                ThemeEditorSection(slot: .dark, themeStore: themeStore, draft: $darkDraft)
            }
            .padding(.vertical, 8)
        }
        .onAppear(perform: reloadDrafts)
    }

    private func reloadDrafts() {
        lightDraft = themeStore.configuration(for: .light)
        darkDraft = themeStore.configuration(for: .dark)
    }
}

// MARK: - Theme Editing

private struct ThemeEditorSection: View {
    let slot: ThemeSlot
    @ObservedObject var themeStore: ThemeSettingsStore
    @Binding var draft: ThemeConfiguration

    private var preset: AppTheme {
        themeStore.presetTheme(for: slot)
    }

    private var savedConfiguration: ThemeConfiguration {
        themeStore.configuration(for: slot).sanitized(for: preset)
    }

    private var sanitizedDraft: ThemeConfiguration {
        draft.sanitized(for: preset)
    }

    private var hasUnsavedChanges: Bool {
        sanitizedDraft != savedConfiguration
    }

    private var canReset: Bool {
        hasUnsavedChanges || themeStore.hasCustomization(for: slot)
    }

    private var selectedThemeID: Binding<String> {
        Binding(
            get: { themeStore.selectedThemeID(for: slot) },
            set: { id in
                themeStore.setSelectedThemeID(id, for: slot)
                draft = themeStore.configuration(for: slot)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            EditableThemeColorRow(label: "Accent", hex: $draft.accent)
            EditableThemeColorRow(label: "Background", hex: $draft.background)
            EditableThemeColorRow(label: "Foreground", hex: $draft.foreground)

            SettingsStepperRow(
                title: "UI font size",
                detail: "Base text size for Markprev controls using this theme",
                value: $draft.uiFontSize,
                range: 12...24
            )

            SettingsStepperRow(
                title: "Code font size",
                detail: "Base text size for source and Markdown preview code",
                value: $draft.codeFontSize,
                range: 11...28
            )

            SettingsSliderRow(title: "Contrast", value: $draft.contrast, range: 0...100)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title)
                    .font(.system(size: 15, weight: .semibold))

                if hasUnsavedChanges {
                    Text("Unsaved changes")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 16)

            Button("Reset") {
                themeStore.reset(slot)
                draft = themeStore.configuration(for: slot)
            }
            .disabled(!canReset)

            Button("Save") {
                themeStore.save(draft, for: slot)
                draft = themeStore.configuration(for: slot)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasUnsavedChanges)

            Picker(slot.title, selection: selectedThemeID) {
                ForEach(slot.themes) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 200)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 20)
        }
    }
}

// MARK: - Code Preview

private struct CodePreviewCard: View {
    let lightTheme: AppTheme
    let darkTheme: AppTheme

    var body: some View {
        HStack(spacing: 0) {
            codePane(theme: lightTheme, surface: "sidebar", contrast: lightTheme.contrast)
            codePane(theme: darkTheme, surface: "sidebar-editor", contrast: darkTheme.contrast)
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func codePane(theme: AppTheme, surface: String, contrast: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            codeLine(n: "1", text: "const themePreview: Theme = {", color: Color(hex: theme.codeKeyword), theme: theme)
            highlightedLine(theme: theme) {
                codeLine(n: "2", text: "  surface: \"\(surface)\",", color: Color(hex: theme.codeBuiltin), theme: theme)
            }
            highlightedLine(theme: theme) {
                codeLine(n: "3", text: "  accent: \"\(theme.accent)\",", color: Color(hex: theme.codeString), theme: theme)
            }
            highlightedLine(theme: theme) {
                codeLine(n: "4", text: "  contrast: \(Int(contrast.rounded())),", color: Color(hex: theme.codeNumber), theme: theme)
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
