import Foundation
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
        case workspaces = "Workspaces"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .workspaces: return "folder"
            case .appearance: return "circle.lefthalf.filled"
            case .editor: return "text.alignleft"
            case .export: return "square.and.arrow.up"
            case .shortcuts: return "keyboard"
            }
        }
    }

    @ObservedObject var themeStore: ThemeSettingsStore
    @ObservedObject var workspaceLibrary: WorkspaceLibraryStore
    let updater: SPUUpdater
    @AppStorage("Monknot.themePreference") private var themePreferenceRawValue = ThemePreference.defaultValue.rawValue
    @AppStorage("Monknot.settingsSection") private var selectedSectionRawValue = Section.general.rawValue
    @AppStorage("Monknot.zoomScale") private var persistedZoomScale = WorkspaceZoomPolicy.defaultValue
    @ObservedObject private var systemAppearance = SystemAppearanceMonitor.shared
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
            systemAppearance: systemAppearance.appearance
        )
    }

    private var settingsZoomScale: Double {
        WorkspaceZoomPolicy.clamp(persistedZoomScale)
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: panelTheme, zoomScale: settingsZoomScale)
    }

    /// The height the Settings window's title bar adds to its content.
    private static let titlebarHeight = NSWindow.frameRect(
        forContentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
        styleMask: [.titled, .closable]
    ).height - 100

    private var windowSize: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? .zero
        let titlebarHeight = Self.titlebarHeight
        return CGSize(
            width: min(scaled(MonknotMetrics.settingsWindowWidth), visible.width > 0 ? visible.width : .infinity),
            height: min(
                scaled(MonknotMetrics.settingsWindowContentHeight),
                visible.height > titlebarHeight ? visible.height - titlebarHeight : .infinity
            )
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            // The page sits on a card in the window's chrome, as the document does (design.md §10.0).
            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(panelTheme.contentSurfaceColor)
                .clipShape(RoundedRectangle(cornerRadius: MonknotMetrics.cardCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MonknotMetrics.cardCornerRadius, style: .continuous)
                        .strokeBorder(panelTheme.cardRingColor, lineWidth: 1)
                }
                .padding(.trailing, WorkspaceSplitMetrics.dividerThickness)
                .padding(.bottom, WorkspaceSplitMetrics.dividerThickness)
        }
        // Settings zooms with the workspace, but the window never grows past the screen; its pages
        // scroll inside it.
        .frame(width: windowSize.width, height: windowSize.height)
        .background(panelTheme.sidebarSurfaceColor.ignoresSafeArea())
        .background(
            WindowChromeConfigurator(
                surfaceColor: panelTheme.sidebarSurfaceColor,
                isDark: panelTheme.isDark,
                windowTitle: selectedSection.rawValue,
                enablesStandardWindowControls: true
            )
        )
        .environment(\.monknotSettingsZoomScale, settingsZoomScale)
    }

    /// Settings' pages as the main window's sidebar rows (design.md §10.4, §12), inside the 10 list inset.
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: scaled(MonknotMetrics.rowGapBase)) {
            ForEach(Section.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    MonknotListRowLabel(
                        leading: .kind(systemImage: section.systemImage),
                        title: section.rawValue,
                        isSelected: selectedSection == section,
                        theme: panelTheme,
                        zoomScale: settingsZoomScale
                    )
                    .monknotFocusRing(
                        isVisible: focusedSection == section,
                        cornerRadius: panelTheme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: settingsZoomScale),
                        theme: panelTheme
                    )
                }
                .buttonStyle(MonknotListRowButtonStyle(
                    theme: panelTheme,
                    zoomScale: settingsZoomScale,
                    isSelected: selectedSection == section
                ))
                .focusable(NSApp.isFullKeyboardAccessEnabled)
                .focused($focusedSection, equals: section)
                .focusEffectDisabled()
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }

            Spacer()
        }
        .padding(.horizontal, scaled(MonknotMetrics.listGutterBase))
        .padding(.top, scaled(12))
        .frame(width: scaled(MonknotMetrics.settingsSidebarWidth))
        .background(panelTheme.sidebarSurfaceColor)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .general:
            GeneralSettingsView(uiTheme: panelTheme, updater: updater)
        case .workspaces:
            WorkspacesSettingsView(workspaceLibrary: workspaceLibrary, uiTheme: panelTheme)
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

private struct WorkspacesSettingsView: View {
    @ObservedObject var workspaceLibrary: WorkspaceLibraryStore
    let uiTheme: AppTheme
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale
    @State private var originalEntries: [SavedWorkspaceEntry]?
    @State private var revertSerial: UInt = 0

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: uiTheme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        SettingsPage(theme: uiTheme) {
            SettingsSectionHeader(theme: uiTheme, title: "Workspaces", isFirst: true) {
                MonknotActionButton(
                    title: "Revert",
                    role: .secondary,
                    theme: uiTheme,
                    zoomScale: settingsZoomScale,
                    size: .bar,
                    isDisabled: originalEntries == nil || originalEntries == workspaceLibrary.entries
                ) {
                    if let originalEntries {
                        workspaceLibrary.replaceEntries(originalEntries)
                        revertSerial &+= 1
                    }
                }
            }

            SettingsGroupCard(theme: uiTheme) {
                if workspaceLibrary.entries.isEmpty {
                    SettingsRow(
                        theme: uiTheme,
                        title: "No saved workspaces",
                        detail: "Add a workspace from the sidebar header.",
                        showsDivider: false
                    ) {
                        EmptyView()
                    }
                } else {
                    ForEach(Array(workspaceLibrary.entries.enumerated()), id: \.element.id) { index, entry in
                        WorkspaceSettingsRow(
                            workspaceLibrary: workspaceLibrary,
                            entryID: entry.id,
                            index: index,
                            count: workspaceLibrary.entries.count,
                            revertSerial: revertSerial,
                            theme: uiTheme,
                            showsDivider: index < workspaceLibrary.entries.count - 1
                        )
                    }
                }
            }
        }
        .onAppear {
            if originalEntries == nil {
                originalEntries = workspaceLibrary.entries
            }
        }
    }
}

private struct WorkspaceSettingsRow: View {
    @ObservedObject var workspaceLibrary: WorkspaceLibraryStore
    let entryID: UUID
    let index: Int
    let count: Int
    let revertSerial: UInt
    let theme: AppTheme
    let showsDivider: Bool
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale
    @FocusState private var isNameFocused: Bool
    @State private var draftName = ""

    private var entry: SavedWorkspaceEntry? {
        workspaceLibrary.entries.first { $0.id == entryID }
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(MonknotMetrics.rowGlyphGapBase)) {
            MonknotFileKindGlyph(systemImage: "folder", theme: theme, zoomScale: settingsZoomScale)
                .foregroundStyle(theme.tertiaryForegroundColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: scaled(3)) {
                TextField("Display name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($isNameFocused)
                    .font(MonknotTypography.rowTitle(theme: theme, zoomScale: settingsZoomScale))
                    .foregroundStyle(theme.foregroundColor)
                    .monknotField(isFocused: isNameFocused, theme: theme, zoomScale: settingsZoomScale)

                Text(((entry?.path ?? "") as NSString).abbreviatingWithTildeInPath)
                    .font(MonknotTypography.rowDetail(theme: theme, zoomScale: settingsZoomScale))
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: scaled(MonknotMetrics.barItemGapBase)) {
                workspaceMoveButton(
                    systemImage: "chevron.up",
                    label: "Move workspace up",
                    isDisabled: index == 0
                ) {
                    workspaceLibrary.move(id: entryID, to: index - 1)
                }

                workspaceMoveButton(
                    systemImage: "chevron.down",
                    label: "Move workspace down",
                    isDisabled: index >= count - 1
                ) {
                    workspaceLibrary.move(id: entryID, to: index + 1)
                }
            }
        }
        .padding(.horizontal, scaled(SettingsRow<EmptyView>.horizontalPaddingBase))
        .padding(.vertical, scaled(SettingsRow<EmptyView>.verticalPaddingBase))
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(theme.separatorColor)
                    .frame(height: 1)
                    .padding(.leading, scaled(SettingsRow<EmptyView>.horizontalPaddingBase))
            }
        }
        .onAppear {
            draftName = entry?.displayName ?? ""
        }
        .onChange(of: draftName) { _, name in
            workspaceLibrary.rename(id: entryID, to: name)
        }
        .onChange(of: entry?.customName) { _, _ in
            if !isNameFocused {
                draftName = entry?.displayName ?? ""
            }
        }
        .onChange(of: revertSerial) { _, _ in
            isNameFocused = false
            draftName = entry?.displayName ?? ""
        }
        .onChange(of: isNameFocused) { _, isFocused in
            if !isFocused,
               draftName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                draftName = entry?.displayName ?? ""
            }
        }
    }

    private func workspaceMoveButton(
        systemImage: String,
        label: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        MonknotIconButton(
            systemImage: systemImage,
            label: label,
            theme: theme,
            zoomScale: settingsZoomScale,
            isDisabled: isDisabled,
            size: .small,
            action: action
        )
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
    @AppStorage(EditorTextCheckingOptions.onDeviceProseCompletionsPreferenceKey)
    private var onDeviceProseCompletions = EditorTextCheckingOptions.defaultOnDeviceProseCompletions

    var body: some View {
        SettingsPage(theme: uiTheme) {
            SettingsSectionHeader(theme: uiTheme, title: "Editor", isFirst: true)
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

                if #available(macOS 26.0, *) {
                    SettingsToggleRow(
                        theme: uiTheme,
                        title: "On-device writing assistance (Beta)",
                        detail: "Use Apple Intelligence for uncertain sentence repairs and, when inline predictions are on, short continuations",
                        isOn: $onDeviceProseCompletions
                    )
                }

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
            SettingsSectionHeader(theme: uiTheme, title: "PDF defaults", isFirst: true)
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
            ForEach(Array(MonknotKeyboardShortcutCatalog.sections.enumerated()), id: \.element.title) { index, section in
                SettingsSectionHeader(theme: uiTheme, title: section.title, isFirst: index == 0)
                SettingsGroupCard(theme: uiTheme) {
                    ForEach(Array(section.entries.enumerated()), id: \.element.title) { index, entry in
                        SettingsRow(
                            theme: uiTheme,
                            title: entry.title,
                            showsDivider: index < section.entries.count - 1
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
}

struct SettingsPage<Content: View>: View {
    let theme: AppTheme
    @ViewBuilder let content: () -> Content
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        MonknotScrollView(theme: theme) {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, scaled(20))
            .padding(.top, scaled(16))
            .padding(.bottom, scaled(24))
            .frame(maxWidth: scaled(680))
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(theme.contentSurfaceColor)
    }
}

/// Workspace zoom in Settings: the shared stepper through the supported zoom levels.
private struct SettingsWorkspaceZoomRow: View {
    let theme: AppTheme
    let title: String
    let detail: String
    var showsDivider = true
    @Binding var value: Double
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    var body: some View {
        SettingsRow(
            theme: theme,
            title: title,
            detail: detail,
            showsDivider: showsDivider
        ) {
            // The stepper counts in zoom levels; each step moves to the next supported level, as ⌘+
            // and ⌘− do.
            MonknotStepper(
                title: title,
                value: Binding(
                    get: { levelIndex },
                    set: { index in
                        value = WorkspaceZoomPolicy.stepped(value, by: index > levelIndex ? 1 : -1)
                    }
                ),
                range: 0...Double(WorkspaceZoomPolicy.supportedLevels.count - 1),
                displayValue: "\(Int((WorkspaceZoomPolicy.clamp(value) * 100).rounded()))%",
                theme: theme,
                zoomScale: settingsZoomScale
            )
            .accessibilityHint(detail)
        }
    }

    /// The current zoom's place among the supported levels; a zoom between levels counts as the next.
    private var levelIndex: Double {
        let current = WorkspaceZoomPolicy.clamp(value)
        let levels = WorkspaceZoomPolicy.supportedLevels
        return Double(levels.firstIndex { $0 >= current - 0.000_001 } ?? levels.count - 1)
    }
}
