import MonknotCore
import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var themeStore: ThemeSettingsStore
    let uiTheme: AppTheme
    @AppStorage("Monknot.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var lightDraft = ThemeConfiguration(theme: AppTheme.codexLight)
    @State private var darkDraft = ThemeConfiguration(theme: AppTheme.codexDark)
    @State private var editingSlot: ThemeSlot = .dark

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

    private var activeSlot: ThemeSlot {
        themeStore.activeSlot(
            themePreference: themePreference,
            systemAppearance: colorScheme == .dark ? .dark : .light
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                appearanceModeCard

                SettingsGroupCard(theme: uiTheme) {
                    CodePreviewCard(chromeTheme: uiTheme, lightTheme: draftLightTheme, darkTheme: draftDarkTheme)
                        .padding(12)
                }

                editorSlotCard

                selectedThemeEditor
            }
            .padding(20)
            .padding(.bottom, 10)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            reloadDrafts()
            editingSlot = activeSlot
        }
        .onChange(of: themePreferenceRawValue) { _, _ in
            editingSlot = activeSlot
        }
    }

    private func reloadDrafts() {
        lightDraft = themeStore.configuration(for: .light)
        darkDraft = themeStore.configuration(for: .dark)
    }

    private var appearanceModeCard: some View {
        SettingsGroupCard(theme: uiTheme) {
            SettingsRow(theme: uiTheme, title: "Theme", detail: "Use light, dark, or match your system", showsDivider: false) {
                MonknotSettingsSegmentedControl(
                    options: ThemePreference.allCases.map { pref in
                        MonknotSettingsSegment(id: pref.rawValue, title: pref.title)
                    },
                    selection: Binding(
                        get: { themePreference.rawValue },
                        set: { raw in
                            themePreference = ThemePreference(rawValue: raw) ?? .system
                        }
                    ),
                    theme: uiTheme
                )
                .frame(maxWidth: 268)
            }
        }
    }

    private var editorSlotCard: some View {
        SettingsGroupCard(theme: uiTheme) {
            SettingsRow(theme: uiTheme, title: "Customize", detail: "Choose the light or dark theme slot to edit", showsDivider: false) {
                MonknotSettingsSegmentedControl(
                    options: ThemeSlot.allCases.map { slot in
                        MonknotSettingsSegment(
                            id: slot.rawValue,
                            title: slot.title.replacingOccurrences(of: " theme", with: "")
                        )
                    },
                    selection: Binding(
                        get: { editingSlot.rawValue },
                        set: { raw in
                            if let slot = ThemeSlot(rawValue: raw) {
                                editingSlot = slot
                            }
                        }
                    ),
                    theme: uiTheme
                )
                .frame(maxWidth: 180)
            }
        }
    }

    @ViewBuilder
    private var selectedThemeEditor: some View {
        switch editingSlot {
        case .light:
            ThemeEditorSection(slot: .light, themeStore: themeStore, draft: $lightDraft, uiTheme: uiTheme)
        case .dark:
            ThemeEditorSection(slot: .dark, themeStore: themeStore, draft: $darkDraft, uiTheme: uiTheme)
        }
    }
}

// MARK: - Theme Editing

private struct ThemeEditorSection: View {
    let slot: ThemeSlot
    @ObservedObject var themeStore: ThemeSettingsStore
    @Binding var draft: ThemeConfiguration
    let uiTheme: AppTheme

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
        SettingsGroupCard(theme: uiTheme) {
            VStack(alignment: .leading, spacing: 0) {
                header

                EditableThemeColorRow(theme: uiTheme, label: "Accent", hex: $draft.accent)
                EditableThemeColorRow(theme: uiTheme, label: "Background", hex: $draft.background)
                EditableThemeColorRow(theme: uiTheme, label: "Foreground", hex: $draft.foreground)

                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Quiet sidebar",
                    detail: "Make sidebar text and icons 20% more subdued",
                    isOn: $draft.quietSidebar
                )

                SettingsStepperRow(
                    theme: uiTheme,
                    title: "UI font size",
                    detail: "Base text size for Monknot controls using this theme",
                    value: $draft.uiFontSize,
                    range: 12...24
                )

                SettingsStepperRow(
                    theme: uiTheme,
                    title: "Code font size",
                    detail: "Base text size for source and Markdown preview code",
                    value: $draft.codeFontSize,
                    range: 11...28
                )

                SettingsSliderRow(
                    theme: uiTheme,
                    title: "Contrast",
                    showsDivider: false,
                    value: $draft.contrast,
                    range: 0...100
                )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(slot.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(uiTheme.foregroundColor)

                if hasUnsavedChanges {
                    Text("Unsaved changes")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(uiTheme.mutedForegroundColor)
                }
            }

            Spacer(minLength: 12)

            SettingsOutlineButton(title: "Reset", theme: uiTheme, isDisabled: !canReset) {
                themeStore.reset(slot)
                draft = themeStore.configuration(for: slot)
            }
            .fixedSize()

            MonknotAccentButton(
                title: "Save",
                theme: uiTheme,
                isDisabled: !hasUnsavedChanges
            ) {
                themeStore.save(draft, for: slot)
                draft = themeStore.configuration(for: slot)
            }

            MonknotSettingsMenuPicker(
                title: "Theme preset",
                selection: selectedThemeID,
                options: slot.themes.map { ($0.id, $0.name) },
                theme: uiTheme
            )
            .frame(minWidth: 160)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(uiTheme.borderColor)
                .frame(height: 1)
                .padding(.leading, 18)
        }
    }
}

// MARK: - Code Preview

private struct CodePreviewCard: View {
    let chromeTheme: AppTheme
    let lightTheme: AppTheme
    let darkTheme: AppTheme

    var body: some View {
        HStack(spacing: 0) {
            codePane(theme: lightTheme, surface: "sidebar", contrast: lightTheme.contrast)
            Rectangle()
                .fill(chromeTheme.borderColor)
                .frame(width: 1)
            codePane(theme: darkTheme, surface: "sidebar-editor", contrast: darkTheme.contrast)
        }
        .frame(height: 176)
        .clipShape(RoundedRectangle(cornerRadius: chromeTheme.settingsControlCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: chromeTheme.settingsControlCornerRadius)
                .strokeBorder(chromeTheme.borderColor.opacity(0.92), lineWidth: 1)
        )
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
        .font(.system(size: 13, weight: .regular, design: .monospaced))
        .lineSpacing(1)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor)
    }

    private func highlightedLine<Content: View>(theme: AppTheme, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.vertical, 1)
            .background(Color(hex: theme.selectionBackground).opacity(theme.isDark ? 0.38 : 0.28))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func codeLine(n: String, text: String, color: Color, theme: AppTheme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(n)
                .foregroundStyle(theme.mutedForegroundColor)
                .frame(width: 18, alignment: .trailing)
            Text(text)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
