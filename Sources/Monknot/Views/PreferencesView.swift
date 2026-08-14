import MonknotCore
import Sparkle
import SwiftUI

struct PreferencesView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Appearance"
        case editor = "Editor"
        case export = "Export"
        case shortcuts = "Shortcuts"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "circle.lefthalf.filled"
            case .editor: return "text.alignleft"
            case .export: return "square.and.arrow.up"
            case .shortcuts: return "keyboard"
            }
        }
    }

    @ObservedObject var themeStore: ThemeSettingsStore
    let updater: SPUUpdater
    @AppStorage("Monknot.themePreference") private var themePreferenceRawValue = ThemePreference.defaultValue.rawValue
    @AppStorage("Monknot.settingsSection") private var selectedSectionRawValue = Section.general.rawValue
    @AppStorage("Monknot.zoomScale") private var persistedZoomScale = WorkspaceZoomPolicy.defaultValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredSection: Section?
    @FocusState private var focusedSection: Section?

    private var selectedSection: Section {
        get { Section(rawValue: selectedSectionRawValue) ?? .general }
        nonmutating set { selectedSectionRawValue = newValue.rawValue }
    }

    private var themePreference: ThemePreference {
        ThemePreference.resolved(rawValue: themePreferenceRawValue)
    }

    private var panelTheme: AppTheme {
        themeStore.activeTheme(
            themePreference: themePreference,
            systemAppearance: colorScheme == .dark ? .dark : .light
        )
    }

    private var settingsZoomScale: Double {
        WorkspaceZoomPolicy.clamp(persistedZoomScale)
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: panelTheme, zoomScale: settingsZoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: panelTheme, zoomScale: settingsZoomScale)
    }

    private func glyphScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceGlyph(base, theme: panelTheme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Rectangle()
                .fill(panelTheme.separatorColor)
                .frame(width: 1)

            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(panelTheme.contentSurfaceColor)
        }
        .frame(
            width: scaled(MonknotMetrics.settingsWindowWidth),
            height: scaled(MonknotMetrics.settingsWindowContentHeight)
        )
        .background(panelTheme.sidebarSurfaceColor.ignoresSafeArea())
        .background(
            WindowBackgroundDragEnabler(
                surfaceColor: panelTheme.sidebarSurfaceColor,
                suppressToolbarButton: true,
                usesDarkAppearance: panelTheme.isDark,
                windowTitle: selectedSection.rawValue,
                enablesStandardWindowControls: true
            )
        )
        .environment(\.monknotSettingsZoomScale, settingsZoomScale)
        .preferredColorScheme(themePreference.preferredColorScheme)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: scaled(4)) {
            ForEach(Section.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: scaled(8)) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: glyphScaled(15), weight: .regular))
                            .foregroundStyle(
                                selectedSection == section
                                    ? panelTheme.accentColor
                                    : panelTheme.tertiaryForegroundColor
                            )
                            .frame(width: glyphScaled(16))

                        Text(section.rawValue)
                            .font(.system(size: textScaled(13), weight: .regular))
                            .foregroundStyle(
                                selectedSection == section
                                    ? panelTheme.foregroundColor
                                    : panelTheme.mutedForegroundColor
                            )
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, scaled(10))
                        .frame(height: scaled(28))
                        .background(
                            sidebarRowBackground(for: section),
                            in: RoundedRectangle(cornerRadius: scaled(8))
                        )
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedSection, equals: section)
                .focusEffectDisabled()
                .onHover { isHovered in
                    hoveredSection = isHovered ? section : nil
                }
                .monknotPointerCursor()
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }

            Spacer()
        }
        .padding(.horizontal, scaled(8))
        .padding(.top, scaled(18))
        .frame(width: scaled(168))
        .background(panelTheme.sidebarSurfaceColor)
    }

    private func sidebarRowBackground(for section: Section) -> Color {
        if selectedSection == section {
            return panelTheme.selectedRowColor
        }
        if hoveredSection == section || focusedSection == section {
            return panelTheme.foregroundColor.opacity(panelTheme.isDark ? 0.055 : 0.04)
        }
        return .clear
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .general:
            GeneralSettingsView(uiTheme: panelTheme, updater: updater)
        case .appearance:
            AppearanceSettingsView(themeStore: themeStore, uiTheme: panelTheme)
        case .editor:
            EditorSettingsView(uiTheme: panelTheme)
        case .export:
            ExportSettingsView(uiTheme: panelTheme)
        case .shortcuts:
            ShortcutSettingsView(uiTheme: panelTheme)
        }
    }
}

private struct EditorSettingsView: View {
    let uiTheme: AppTheme
    @AppStorage("Monknot.zoomScale") private var persistedZoomScale = WorkspaceZoomPolicy.defaultValue
    @AppStorage("Monknot.showDocumentOutline") private var showContentMapper = true
    @AppStorage(EditorTextCheckingOptions.spellingPreferenceKey)
    private var checksSpelling = EditorTextCheckingOptions.defaultChecksSpelling
    @AppStorage(EditorTextCheckingOptions.grammarPreferenceKey)
    private var checksGrammar = EditorTextCheckingOptions.defaultChecksGrammar
    @AppStorage(EditorTextCheckingOptions.inlinePredictionsPreferenceKey)
    private var inlinePredictions = EditorTextCheckingOptions.defaultInlinePredictions

    var body: some View {
        SettingsPage(theme: uiTheme) {
            SettingsSectionHeader(theme: uiTheme, title: "Editor")
            SettingsGroupCard(theme: uiTheme) {
                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Content mapper",
                    detail: "Show heading markers in Markdown",
                    isOn: $showContentMapper
                )

                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Check spelling while typing",
                    detail: "Underline possible mistakes using macOS",
                    isOn: $checksSpelling
                )

                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Check grammar while typing",
                    detail: "Use native language-aware grammar checking",
                    isOn: $checksGrammar
                )

                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Inline predictions",
                    detail: "Show system predictive text from macOS",
                    isOn: $inlinePredictions
                )

                SettingsWorkspaceZoomRow(
                    theme: uiTheme,
                    title: "Workspace zoom",
                    detail: "Scale the complete workspace from 80% to 200% in verified steps",
                    showsDivider: false,
                    value: $persistedZoomScale
                )
            }
        }
    }
}

private struct ExportSettingsView: View {
    let uiTheme: AppTheme
    @State private var options = MarkdownPDFExportOptions.loadLastUsed()
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: uiTheme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        SettingsPage(theme: uiTheme) {
            SettingsSectionHeader(theme: uiTheme, title: "PDF defaults")
            SettingsGroupCard(theme: uiTheme) {
                menuRow(
                    title: "Page size",
                    detail: "Paper size for Markdown PDF exports",
                    selection: Binding(
                        get: { options.pageSize.rawValue },
                        set: { options.pageSize = MarkdownPDFPageSize(rawValue: $0) ?? .automatic }
                    ),
                    options: MarkdownPDFPageSize.allCases.map { ($0.rawValue, $0.title) }
                )

                menuRow(
                    title: "Margins",
                    detail: "Default white space around each page",
                    selection: Binding(
                        get: { options.marginPreset.rawValue },
                        set: { options.marginPreset = MarkdownPDFMarginPreset(rawValue: $0) ?? .normal }
                    ),
                    options: MarkdownPDFMarginPreset.allCases.map { ($0.rawValue, $0.title) }
                )

                menuRow(
                    title: "Theme",
                    detail: "Appearance used for exported pages",
                    selection: Binding(
                        get: { options.themeMode.rawValue },
                        set: { options.themeMode = MarkdownPDFThemeMode(rawValue: $0) ?? .current }
                    ),
                    options: MarkdownPDFThemeMode.allCases.map { ($0.rawValue, $0.title) },
                    showsDivider: false
                )
            }

            SettingsSectionHeader(theme: uiTheme, title: "Layout")
                .padding(.top, scaled(6))
            SettingsGroupCard(theme: uiTheme) {
                SettingsSliderRow(
                    theme: uiTheme,
                    title: "Scale",
                    detail: "Scale the rendered Markdown content",
                    value: $options.scalePercent,
                    range: 70...130,
                    suffix: "%"
                )

                SettingsSliderRow(
                    theme: uiTheme,
                    title: "Text size",
                    detail: "Base body text size in points",
                    value: $options.textSizePoints,
                    range: 10...18,
                    suffix: " pt"
                )

                SettingsSliderRow(
                    theme: uiTheme,
                    title: "Content Width",
                    detail: "Share of the printable page used by content",
                    showsDivider: false,
                    value: $options.contentWidthPercent,
                    range: 65...100,
                    suffix: "%"
                )
            }
        }
        .onChange(of: options) { _, newValue in
            newValue.saveLastUsed()
        }
    }

    private func menuRow(
        title: String,
        detail: String,
        selection: Binding<String>,
        options: [(String, String)],
        showsDivider: Bool = true
    ) -> some View {
        SettingsRow(theme: uiTheme, title: title, detail: detail, showsDivider: showsDivider) {
            MonknotSettingsMenuPicker(
                title: title,
                selection: selection,
                options: options,
                theme: uiTheme
            )
            .frame(minWidth: scaled(132))
        }
    }
}

private struct ShortcutSettingsView: View {
    let uiTheme: AppTheme
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: uiTheme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        SettingsPage(theme: uiTheme) {
            SettingsSectionHeader(theme: uiTheme, title: "Keyboard shortcuts")
            SettingsGroupCard(theme: uiTheme) {
                ForEach(Array(MonknotKeyboardShortcutCatalog.entries.enumerated()), id: \.offset) { index, entry in
                    SettingsRow(
                        theme: uiTheme,
                        title: entry.title,
                        showsDivider: index < MonknotKeyboardShortcutCatalog.entries.count - 1
                    ) {
                        MonknotShortcutLabel(
                            shortcut: entry.shortcut,
                            theme: uiTheme,
                            zoomScale: settingsZoomScale,
                            presentation: .keyCap
                        )
                    }
                }
            }
        }
    }
}

struct SettingsPage<Content: View>: View {
    let theme: AppTheme
    @ViewBuilder let content: () -> Content
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        MonknotScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, scaled(20))
            .padding(.vertical, scaled(18))
            .padding(.bottom, scaled(10))
            .frame(maxWidth: scaled(680))
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(theme.contentSurfaceColor)
    }
}

private struct SettingsWorkspaceZoomRow: View {
    let theme: AppTheme
    let title: String
    let detail: String
    var showsDivider = true
    @Binding var value: Double
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        SettingsRow(
            theme: theme,
            title: title,
            detail: detail,
            showsDivider: showsDivider
        ) {
            HStack(spacing: scaled(8)) {
                zoomButton(systemImage: "minus", label: "Zoom out") {
                    value = WorkspaceZoomPolicy.stepped(value, by: -1)
                }

                Text("\(Int((WorkspaceZoomPolicy.clamp(value) * 100).rounded()))%")
                    .font(.system(
                        size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: settingsZoomScale),
                        weight: .regular,
                        design: .monospaced
                    ))
                    .foregroundStyle(theme.foregroundColor)
                    .frame(width: scaled(48))

                zoomButton(systemImage: "plus", label: "Zoom in") {
                    value = WorkspaceZoomPolicy.stepped(value, by: 1)
                }
            }
        }
    }

    private func zoomButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(
                    size: MonknotMetrics.interfaceGlyph(13, theme: theme, zoomScale: settingsZoomScale),
                    weight: .regular
                ))
                .foregroundStyle(theme.mutedForegroundColor)
                .frame(width: scaled(26), height: scaled(26))
                .background(theme.insetFillColor, in: RoundedRectangle(cornerRadius: scaled(8)))
                .overlay {
                    RoundedRectangle(cornerRadius: scaled(8))
                        .strokeBorder(theme.borderColor, lineWidth: 1)
                }
        }
        .buttonStyle(MonknotControlPressStyle())
        .focusEffectDisabled()
        .help(label)
        .accessibilityLabel(label)
        .monknotPointerCursor()
    }
}
