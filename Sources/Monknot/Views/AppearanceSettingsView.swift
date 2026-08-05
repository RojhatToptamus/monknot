import MonknotCore
import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var themeStore: ThemeSettingsStore
    let uiTheme: AppTheme
    @AppStorage("Monknot.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale
    @State private var lightDraft = ThemeConfiguration(theme: AppTheme.monknotLight)
    @State private var darkDraft = ThemeConfiguration(theme: AppTheme.monknotDark)
    @State private var lightBaseline = ThemeEditBaseline(themeID: AppTheme.monknotLight.id, configuration: ThemeConfiguration(theme: AppTheme.monknotLight))
    @State private var darkBaseline = ThemeEditBaseline(themeID: AppTheme.monknotDark.id, configuration: ThemeConfiguration(theme: AppTheme.monknotDark))

    private var themePreference: ThemePreference {
        get { ThemePreference(rawValue: themePreferenceRawValue) ?? .system }
        nonmutating set { themePreferenceRawValue = newValue.rawValue }
    }

    private var activeSlot: ThemeSlot {
        themeStore.activeSlot(
            themePreference: themePreference,
            systemAppearance: colorScheme == .dark ? .dark : .light
        )
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: uiTheme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        SettingsPage(theme: uiTheme) {
            SettingsGroupCard(theme: uiTheme) {
                SettingsRow(
                    theme: uiTheme,
                    title: "Appearance",
                    showsDivider: false
                ) {
                    MonknotSettingsSegmentedControl(
                        options: ThemePreference.allCases.map { preference in
                            MonknotSettingsSegment(id: preference.rawValue, title: preference.title)
                        },
                        selection: Binding(
                            get: { themePreference.rawValue },
                            set: { themePreference = ThemePreference(rawValue: $0) ?? .system }
                        ),
                        theme: uiTheme
                    )
                    .frame(width: scaled(246))
                }
            }

            themeEditorHeader
                .padding(.top, scaled(24))

            selectedThemeEditor

            ThemeLivePreview(
                theme: draft(for: activeSlot).applied(to: themeStore.presetTheme(for: activeSlot)),
                chromeTheme: uiTheme
            )
            .padding(.top, scaled(22))

            SettingsSectionHeader(theme: uiTheme, title: "Typography")
                .padding(.top, scaled(24))
            typographyControls
        }
        .onAppear(perform: reloadDraftsAndBaselines)
        .onChange(of: lightDraft) { _, draft in
            saveIfValid(draft, for: .light)
        }
        .onChange(of: darkDraft) { _, draft in
            saveIfValid(draft, for: .dark)
        }
    }

    private var themeEditorHeader: some View {
        HStack(spacing: scaled(10)) {
            SettingsSectionHeader(theme: uiTheme, title: activeSlot.title)

            Spacer()

            if hasEdits(for: activeSlot) {
                Text("Edited")
                    .font(.system(size: MonknotMetrics.interfaceText(11, theme: uiTheme, zoomScale: settingsZoomScale)))
                    .foregroundStyle(uiTheme.mutedForegroundColor)

                SettingsOutlineButton(title: "Revert", theme: uiTheme) {
                    revert(activeSlot)
                }
            }

        }
    }

    @ViewBuilder
    private var selectedThemeEditor: some View {
        switch activeSlot {
        case .light:
            ThemeEditorSection(slot: .light, themeStore: themeStore, draft: $lightDraft, uiTheme: uiTheme)
        case .dark:
            ThemeEditorSection(slot: .dark, themeStore: themeStore, draft: $darkDraft, uiTheme: uiTheme)
        }
    }

    @ViewBuilder
    private var typographyControls: some View {
        switch activeSlot {
        case .light:
            ThemeTypographySettings(draft: $lightDraft, uiTheme: uiTheme)
        case .dark:
            ThemeTypographySettings(draft: $darkDraft, uiTheme: uiTheme)
        }
    }

    private func draft(for slot: ThemeSlot) -> ThemeConfiguration {
        slot == .light ? lightDraft : darkDraft
    }

    private func baseline(for slot: ThemeSlot) -> ThemeEditBaseline {
        slot == .light ? lightBaseline : darkBaseline
    }

    private func reloadDraftsAndBaselines() {
        lightDraft = themeStore.configuration(for: .light)
        darkDraft = themeStore.configuration(for: .dark)
        lightBaseline = ThemeEditBaseline(
            themeID: themeStore.selectedThemeID(for: .light),
            configuration: lightDraft
        )
        darkBaseline = ThemeEditBaseline(
            themeID: themeStore.selectedThemeID(for: .dark),
            configuration: darkDraft
        )
    }

    private func hasEdits(for slot: ThemeSlot) -> Bool {
        let baseline = baseline(for: slot)
        let preset = themeStore.presetTheme(for: slot)
        return themeStore.selectedThemeID(for: slot) != baseline.themeID
            || draft(for: slot).sanitized(for: preset)
                != baseline.configuration.sanitized(for: preset)
    }

    private func revert(_ slot: ThemeSlot) {
        let baseline = baseline(for: slot)
        themeStore.setSelectedThemeID(baseline.themeID, for: slot)
        themeStore.save(baseline.configuration, for: slot)
        switch slot {
        case .light: lightDraft = baseline.configuration
        case .dark: darkDraft = baseline.configuration
        }
    }

    private func saveIfValid(_ configuration: ThemeConfiguration, for slot: ThemeSlot) {
        guard RGBHex(configuration.accent) != nil,
              RGBHex(configuration.background) != nil,
              RGBHex(configuration.foreground) != nil else {
            return
        }
        themeStore.save(configuration, for: slot)
    }
}

private struct ThemeEditBaseline {
    let themeID: String
    let configuration: ThemeConfiguration
}

private struct ThemeEditorSection: View {
    let slot: ThemeSlot
    @ObservedObject var themeStore: ThemeSettingsStore
    @Binding var draft: ThemeConfiguration
    let uiTheme: AppTheme
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

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
            SettingsRow(theme: uiTheme, title: "Theme preset") {
                MonknotSettingsMenuPicker(
                    title: "Theme preset",
                    selection: selectedThemeID,
                    options: slot.themes.map { ($0.id, $0.name) },
                    theme: uiTheme
                )
                .frame(minWidth: MonknotMetrics.interfaceDensity(160, theme: uiTheme, zoomScale: settingsZoomScale))
            }

            EditableThemeColorRow(theme: uiTheme, label: "Accent", hex: $draft.accent)
            EditableThemeColorRow(theme: uiTheme, label: "Background", hex: $draft.background)
            EditableThemeColorRow(theme: uiTheme, label: "Foreground", hex: $draft.foreground)

            SettingsToggleRow(
                theme: uiTheme,
                title: "Quiet sidebar",
                detail: "Subdue sidebar text and icons by 20%",
                showsDivider: false,
                isOn: $draft.quietSidebar
            )
        }
    }
}

private struct ThemeTypographySettings: View {
    @Binding var draft: ThemeConfiguration
    let uiTheme: AppTheme

    var body: some View {
        SettingsGroupCard(theme: uiTheme) {
            SettingsStepperRow(
                theme: uiTheme,
                title: "UI font size",
                detail: "Base text size for Monknot controls",
                value: $draft.uiFontSize,
                range: 12...24
            )

            SettingsStepperRow(
                theme: uiTheme,
                title: "Code font size",
                detail: "Base text size for source and preview code",
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

private struct ThemeLivePreview: View {
    let theme: AppTheme
    let chromeTheme: AppTheme
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: chromeTheme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LIVE PREVIEW")
                .font(.system(
                    size: MonknotMetrics.interfaceText(10, theme: chromeTheme, zoomScale: settingsZoomScale),
                    weight: .semibold
                ))
                .tracking(scaled(1.1))
                .foregroundStyle(chromeTheme.mutedForegroundColor)
                .padding(.horizontal, scaled(14))
                .frame(height: scaled(28))

            HStack(spacing: 0) {
                VStack(spacing: scaled(8)) {
                    RoundedRectangle(cornerRadius: scaled(4))
                        .fill(theme.accentColor.opacity(0.34))
                        .frame(height: scaled(14))
                    RoundedRectangle(cornerRadius: scaled(4))
                        .fill(theme.mutedForegroundColor.opacity(0.22))
                        .frame(height: scaled(14))
                }
                .padding(scaled(10))
                .frame(width: scaled(132))
                .background(theme.sidebarSurfaceColor)

                VStack(alignment: .leading, spacing: scaled(5)) {
                    Text("Aurora Project")
                        .font(.system(
                            size: MonknotMetrics.interfaceText(13, theme: chromeTheme, zoomScale: settingsZoomScale),
                            weight: .semibold
                        ))
                        .foregroundStyle(theme.foregroundColor)
                    Text("Calm writing environment.")
                        .font(.system(size: MonknotMetrics.interfaceText(11, theme: chromeTheme, zoomScale: settingsZoomScale)))
                        .foregroundStyle(theme.mutedForegroundColor)
                }
                .padding(.horizontal, scaled(14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(theme.contentSurfaceColor)
            }
            .frame(height: scaled(70))
            .overlay(alignment: .top) {
                Rectangle().fill(chromeTheme.separatorColor).frame(height: 1)
            }
        }
        .background(chromeTheme.elevatedSurfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: chromeTheme.chromeRadius(chromeTheme.settingsCardCornerRadius, zoomScale: settingsZoomScale)))
        .overlay {
            RoundedRectangle(cornerRadius: chromeTheme.chromeRadius(chromeTheme.settingsCardCornerRadius, zoomScale: settingsZoomScale))
                .strokeBorder(chromeTheme.borderColor, lineWidth: 1)
        }
    }
}
