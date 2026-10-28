import MonknotCore
import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var themeStore: ThemeSettingsStore
    let uiTheme: AppTheme
    let zoomScale: Double
    @AppStorage("Monknot.themePreference") private var themePreferenceRawValue = ThemePreference.defaultValue.rawValue
    @AppStorage(PDFPageAppearance.preferenceKey) private var pdfPageAppearance = PDFPageAppearance.original
    @ObservedObject private var systemAppearance = SystemAppearanceMonitor.shared
    @State private var lightDraft = ThemeConfiguration(theme: AppTheme.defaultLight)
    @State private var darkDraft = ThemeConfiguration(theme: AppTheme.defaultDark)
    @State private var lightBaseline = ThemeEditBaseline(themeID: AppTheme.defaultLight.id, configuration: ThemeConfiguration(theme: AppTheme.defaultLight))
    @State private var darkBaseline = ThemeEditBaseline(themeID: AppTheme.defaultDark.id, configuration: ThemeConfiguration(theme: AppTheme.defaultDark))

    private var themePreference: ThemePreference {
        get { ThemePreference.resolved(rawValue: themePreferenceRawValue) }
        nonmutating set { themePreferenceRawValue = newValue.rawValue }
    }

    private var activeSlot: ThemeSlot {
        themeStore.activeSlot(
            themePreference: themePreference,
            systemAppearance: systemAppearance.appearance
        )
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: uiTheme, zoomScale: zoomScale)
    }

    var body: some View {
        SettingsPage(theme: uiTheme, zoomScale: zoomScale) {
            SettingsGroupCard(theme: uiTheme, zoomScale: zoomScale) {
                SettingsRow(
                    theme: uiTheme,
                    zoomScale: zoomScale,
                    title: "Appearance"
                ) {
                    MonknotSegmentedControl(
                        options: ThemePreference.allCases.map { preference in
                            MonknotSegmentOption(id: preference.rawValue, title: preference.title)
                        },
                        selection: Binding(
                            get: { themePreference.rawValue },
                            set: { themePreference = ThemePreference.resolved(rawValue: $0) }
                        ),
                        theme: uiTheme,
                        zoomScale: zoomScale
                    )
                }
                SettingsRow(
                    theme: uiTheme,
                    zoomScale: zoomScale,
                    title: "PDF pages",
                    detail: "Never changes the file",
                    showsDivider: false
                ) {
                    MonknotSegmentedControl(
                        options: PDFPageAppearance.allCases.map { appearance in
                            MonknotSegmentOption(id: appearance.rawValue, title: appearance.title)
                        },
                        selection: Binding(
                            get: { pdfPageAppearance.rawValue },
                            set: { pdfPageAppearance = PDFPageAppearance(rawValue: $0) ?? .original }
                        ),
                        theme: uiTheme,
                        zoomScale: zoomScale
                    )
                }
            }

            themeEditorHeader

            selectedThemeEditor

            SettingsSectionHeader(theme: uiTheme, zoomScale: zoomScale, title: "Live preview")
            ThemeLivePreview(
                theme: draft(for: activeSlot)
                    .applied(to: themeStore.presetTheme(for: activeSlot))
                    .replacing(
                        quietSidebar: themeStore.quietSidebar,
                        uiFontSize: themeStore.uiFontSize,
                        codeFontSize: themeStore.codeFontSize
                    ),
                chromeTheme: uiTheme,
                zoomScale: zoomScale
            )

            SettingsSectionHeader(theme: uiTheme, zoomScale: zoomScale, title: "Typography")
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

    /// The slot's group header; Revert appears on it while the slot has edits, without moving it.
    private var themeEditorHeader: some View {
        let isEdited = hasEdits(for: activeSlot)

        return SettingsSectionHeader(theme: uiTheme, zoomScale: zoomScale, title: activeSlot.title) {
            HStack(spacing: scaled(10)) {
                Text("Edited")
                    .font(MonknotTypography.rowDetail(theme: uiTheme, zoomScale: zoomScale))
                    .foregroundStyle(uiTheme.tertiaryForegroundColor)

                MonknotActionButton(
                    title: "Revert",
                    role: .secondary,
                    theme: uiTheme,
                    zoomScale: zoomScale,
                    size: .bar
                ) {
                    revert(activeSlot)
                }
            }
            .opacity(isEdited ? 1 : 0)
            .allowsHitTesting(isEdited)
            .accessibilityHidden(!isEdited)
        }
    }

    @ViewBuilder
    private var selectedThemeEditor: some View {
        switch activeSlot {
        case .light:
            ThemeEditorSection(slot: .light, themeStore: themeStore, draft: $lightDraft, uiTheme: uiTheme, zoomScale: zoomScale)
        case .dark:
            ThemeEditorSection(slot: .dark, themeStore: themeStore, draft: $darkDraft, uiTheme: uiTheme, zoomScale: zoomScale)
        }
    }

    @ViewBuilder
    private var typographyControls: some View {
        switch activeSlot {
        case .light:
            ThemeTypographySettings(themeStore: themeStore, draft: $lightDraft, uiTheme: uiTheme, zoomScale: zoomScale)
        case .dark:
            ThemeTypographySettings(themeStore: themeStore, draft: $darkDraft, uiTheme: uiTheme, zoomScale: zoomScale)
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
            || themeStore.uiFontSize != baseline.configuration.uiFontSize
            || themeStore.codeFontSize != baseline.configuration.codeFontSize
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
        themeStore.saveThemeCustomization(configuration, for: slot)
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
    let zoomScale: Double

    private var selectedThemeID: Binding<String> {
        Binding(
            get: { themeStore.selectedThemeID(for: slot) },
            set: { id in
                themeStore.setSelectedThemeID(id, for: slot)
                draft = themeStore.configuration(for: slot)
            }
        )
    }

    private var quietSidebar: Binding<Bool> {
        Binding(
            get: { themeStore.quietSidebar },
            set: { themeStore.setQuietSidebar($0) }
        )
    }

    var body: some View {
        SettingsGroupCard(theme: uiTheme, zoomScale: zoomScale) {
            SettingsRow(theme: uiTheme, zoomScale: zoomScale, title: "Theme preset") {
                MonknotPopUpButton(
                    label: "Theme preset",
                    selection: selectedThemeID,
                    items: slot.themes.map { MonknotPopUpItem(id: $0.id, title: $0.name) },
                    theme: uiTheme,
                    zoomScale: zoomScale,
                    previewsSelection: true,
                    onPreviewSelection: { id in
                        themeStore.previewThemeID(id, for: slot)
                        draft = themeStore.configuration(for: slot)
                    },
                    onCancelPreview: {
                        themeStore.cancelThemePreview(for: slot)
                        draft = themeStore.configuration(for: slot)
                    }
                )
            }

            EditableThemeColorRow(theme: uiTheme, zoomScale: zoomScale, label: "Accent", hex: $draft.accent)
            EditableThemeColorRow(theme: uiTheme, zoomScale: zoomScale, label: "Background", hex: $draft.background)
            EditableThemeColorRow(theme: uiTheme, zoomScale: zoomScale, label: "Foreground", hex: $draft.foreground)

            SettingsToggleRow(
                theme: uiTheme,
                zoomScale: zoomScale,
                title: "Quiet sidebar",
                detail: "Subdue sidebar text and icons",
                showsDivider: false,
                isOn: quietSidebar
            )
        }
    }
}

private struct ThemeTypographySettings: View {
    @ObservedObject var themeStore: ThemeSettingsStore
    @Binding var draft: ThemeConfiguration
    let uiTheme: AppTheme
    let zoomScale: Double

    private var uiFontSize: Binding<Double> {
        Binding(
            get: { themeStore.uiFontSize },
            set: { themeStore.setTypography(uiFontSize: $0, codeFontSize: themeStore.codeFontSize) }
        )
    }

    private var codeFontSize: Binding<Double> {
        Binding(
            get: { themeStore.codeFontSize },
            set: { themeStore.setTypography(uiFontSize: themeStore.uiFontSize, codeFontSize: $0) }
        )
    }

    var body: some View {
        SettingsGroupCard(theme: uiTheme, zoomScale: zoomScale) {
            SettingsStepperRow(
                theme: uiTheme,
                zoomScale: zoomScale,
                title: "UI font size",
                detail: "Base text size for Monknot controls",
                value: uiFontSize,
                range: 12...24
            )

            SettingsStepperRow(
                theme: uiTheme,
                zoomScale: zoomScale,
                title: "Code font size",
                detail: "Base text size for source and preview code",
                value: codeFontSize,
                range: 11...28
            )

            SettingsSliderRow(
                theme: uiTheme,
                zoomScale: zoomScale,
                title: "Contrast",
                showsDivider: false,
                value: $draft.contrast,
                range: 0...100
            )
        }
    }
}

/// A miniature of the window in the draft theme (design.md §12): the sidebar's rows, one selected,
/// beside a note, at their real sizes, in a group's rounded box.
private struct ThemeLivePreview: View {
    let theme: AppTheme
    let chromeTheme: AppTheme
    let zoomScale: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: chromeTheme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: scaled(MonknotMetrics.rowGapBase)) {
                previewRow("Weekly review.md", isSelected: true)
                previewRow("Ideas.md", isSelected: false)
            }
            .padding(scaled(MonknotMetrics.menuListInsetBase + 2))
            .frame(width: scaled(184), alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(theme.chromeSurfaceColor)

            VStack(alignment: .leading, spacing: scaled(6)) {
                Text("Weekly review")
                    .font(.system(
                        size: MonknotMetrics.interfaceText(15, theme: chromeTheme, zoomScale: zoomScale),
                        weight: .semibold
                    ))
                    .foregroundStyle(theme.foregroundColor)
                Text("Draft the outline, then link the project.")
                    .font(MonknotTypography.rowDetail(theme: chromeTheme, zoomScale: zoomScale))
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, scaled(16))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(theme.surfaceColor)
        }
        .frame(height: scaled(76))
        .clipShape(RoundedRectangle(cornerRadius: chromeTheme.chromeRadius(MonknotMetrics.cardCornerRadius, zoomScale: zoomScale)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live preview of the theme")
    }

    private func previewRow(_ title: String, isSelected: Bool) -> some View {
        MonknotListRowLabel(
            leading: .kind(systemImage: "doc.text"),
            title: title,
            isSelected: isSelected,
            theme: theme,
            zoomScale: zoomScale
        )
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale))
                    .fill(theme.chromeSelectedFillColor)
            }
        }
    }
}
