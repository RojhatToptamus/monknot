import MonknotCore
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
    @AppStorage("Monknot.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
    @AppStorage("Monknot.settingsSection") private var selectedSectionRawValue = Section.appearance.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredSection: Section?
    @FocusState private var focusedSection: Section?

    private var selectedSection: Section {
        get { Section(rawValue: selectedSectionRawValue) ?? .appearance }
        nonmutating set { selectedSectionRawValue = newValue.rawValue }
    }

    private var themePreference: ThemePreference {
        ThemePreference(rawValue: themePreferenceRawValue) ?? .system
    }

    private var panelTheme: AppTheme {
        themeStore.activeTheme(
            themePreference: themePreference,
            systemAppearance: colorScheme == .dark ? .dark : .light
        )
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
        .frame(width: 900, height: 680)
        .background(panelTheme.contentSurfaceColor)
        .background(
            WindowBackgroundDragEnabler(
                surfaceColor: panelTheme.sidebarSurfaceColor,
                suppressToolbarButton: true,
                usesDarkAppearance: panelTheme.isDark
            )
        )
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(selectedSection.rawValue)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(panelTheme.foregroundColor)
                    .frame(height: 50)
            }
        }
        .preferredColorScheme(themePreference.preferredColorScheme)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Section.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Label(section.rawValue, systemImage: section.systemImage)
                        .font(.system(size: 13, weight: selectedSection == section ? .medium : .regular))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(
                            selectedSection == section
                                ? panelTheme.foregroundColor
                                : panelTheme.mutedForegroundColor
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(
                            sidebarRowBackground(for: section),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .overlay {
                            if focusedSection == section {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(panelTheme.accentColor.opacity(0.9), lineWidth: 1.5)
                                    .padding(1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedSection, equals: section)
                .onHover { isHovered in
                    hoveredSection = isHovered ? section : nil
                }
                .monknotPointerCursor()
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .frame(width: 196)
        .background(panelTheme.sidebarSurfaceColor)
    }

    private func sidebarRowBackground(for section: Section) -> Color {
        if selectedSection == section {
            return panelTheme.insetFillColor
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
            GeneralSettingsView(uiTheme: panelTheme)
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
    @AppStorage("Monknot.zoomScale") private var zoomScale = 1.0
    @AppStorage("Monknot.previewWidthPercent") private var previewWidthPercent = 88.0

    var body: some View {
        SettingsPage(theme: uiTheme) {
            SettingsSectionHeader(theme: uiTheme, title: "Editor")
            SettingsGroupCard(theme: uiTheme, showsBorder: false) {
                SettingsStepperRow(
                    theme: uiTheme,
                    title: "Workspace zoom",
                    detail: "Scale document content and workspace text while keeping chrome compact",
                    value: $zoomScale,
                    range: WorkspaceZoomPolicy.minimum...WorkspaceZoomPolicy.maximum,
                    step: WorkspaceZoomPolicy.step,
                    suffix: "x"
                )

                SettingsSliderRow(
                    theme: uiTheme,
                    title: "Preview width",
                    detail: "Maximum Markdown preview width in the editor pane",
                    showsDivider: false,
                    value: $previewWidthPercent,
                    range: 55...100,
                    suffix: "%"
                )
            }
        }
    }
}

private struct ExportSettingsView: View {
    let uiTheme: AppTheme
    @State private var options = MarkdownPDFExportOptions.loadLastUsed()

    var body: some View {
        SettingsPage(theme: uiTheme) {
            SettingsSectionHeader(theme: uiTheme, title: "PDF defaults")
            SettingsGroupCard(theme: uiTheme, showsBorder: false) {
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
                .padding(.top, 6)
            SettingsGroupCard(theme: uiTheme, showsBorder: false) {
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
                    title: "Content width",
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
            .frame(minWidth: 132)
        }
    }
}

private struct ShortcutSettingsView: View {
    let uiTheme: AppTheme

    var body: some View {
        SettingsPage(theme: uiTheme) {
            SettingsSectionHeader(theme: uiTheme, title: "Keyboard shortcuts")
            SettingsGroupCard(theme: uiTheme, showsBorder: false) {
                ForEach(Array(MonknotKeyboardShortcutCatalog.entries.enumerated()), id: \.offset) { index, entry in
                    SettingsRow(
                        theme: uiTheme,
                        title: entry.title,
                        showsDivider: index < MonknotKeyboardShortcutCatalog.entries.count - 1
                    ) {
                        Text(entry.shortcut)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(uiTheme.mutedForegroundColor)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(uiTheme.insetFillColor, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }
}

struct SettingsPage<Content: View>: View {
    let theme: AppTheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        MonknotScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .padding(.bottom, 10)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(theme.contentSurfaceColor)
    }
}
