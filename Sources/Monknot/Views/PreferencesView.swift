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

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: scaled(2)) {
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
                                    : (hoveredSection == section
                                        ? panelTheme.foregroundColor
                                        : panelTheme.tertiaryForegroundColor)
                            )
                            .frame(width: glyphScaled(MonknotMetrics.rowIconColumnWidthBase))

                        Text(section.rawValue)
                            .font(.system(size: textScaled(13), weight: .regular))
                            .foregroundStyle(
                                selectedSection == section || hoveredSection == section
                                    ? panelTheme.foregroundColor
                                    : panelTheme.mutedForegroundColor
                            )
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, scaled(10))
                        .frame(height: scaled(28))
                        .background(
                            sidebarRowBackground(for: section),
                            in: RoundedRectangle(cornerRadius: panelTheme.chromeRadius(8, zoomScale: settingsZoomScale))
                        )
                        .monknotFocusRing(
                            isVisible: focusedSection == section,
                            cornerRadius: panelTheme.chromeRadius(8, zoomScale: settingsZoomScale),
                            theme: panelTheme
                        )
                }
                .buttonStyle(.plain)
                .focusable(NSApp.isFullKeyboardAccessEnabled)
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
        .frame(width: scaled(MonknotMetrics.settingsSidebarWidth))
        .background(panelTheme.sidebarSurfaceColor)
    }

    private func sidebarRowBackground(for section: Section) -> Color {
        if selectedSection == section {
            return panelTheme.selectedRowColor
        }
        // design.md §1.2: the one hover fill; keyboard focus shows the ring instead (§3).
        if hoveredSection == section {
            return panelTheme.hoverFillColor
        }
        return .clear
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
            HStack(alignment: .center) {
                SettingsSectionHeader(theme: uiTheme, title: "Workspaces")
                Spacer()
                SettingsOutlineButton(
                    title: "Revert",
                    theme: uiTheme,
                    isDisabled: originalEntries == nil || originalEntries == workspaceLibrary.entries
                ) {
                    if let originalEntries {
                        workspaceLibrary.replaceEntries(originalEntries)
                        revertSerial &+= 1
                    }
                }
                .padding(.bottom, scaled(7))
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
        HStack(spacing: scaled(12)) {
            MonknotSystemGlyph(
                systemImage: "folder",
                nominalPointSizeBase: 15,
                theme: theme,
                zoomScale: settingsZoomScale
            )
            .foregroundStyle(theme.tertiaryForegroundColor)
            .frame(width: scaled(18))

            VStack(alignment: .leading, spacing: scaled(3)) {
                TextField("Display name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($isNameFocused)
                    .font(MonknotTypography.settingsRowTitle(theme: theme, zoomScale: settingsZoomScale))
                    .foregroundStyle(theme.foregroundColor)
                    .padding(.horizontal, scaled(9))
                    .frame(height: scaled(28), alignment: .leading)
                    .background(theme.insetFillColor, in: RoundedRectangle(cornerRadius: scaled(8)))
                    .overlay {
                        RoundedRectangle(cornerRadius: scaled(8))
                            .strokeBorder(
                                isNameFocused ? theme.accentColor : theme.borderColor,
                                lineWidth: 1
                            )
                    }

                Text(((entry?.path ?? "") as NSString).abbreviatingWithTildeInPath)
                    .font(.system(
                        size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: settingsZoomScale),
                        weight: .regular,
                        design: .monospaced
                    ))
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
        .padding(.horizontal, scaled(14))
        .padding(.vertical, scaled(10))
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(theme.separatorColor)
                    .frame(height: 1)
                    .padding(.leading, scaled(14))
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
            size: .settings,
            drawsBorder: true,
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
            ForEach(MonknotKeyboardShortcutCatalog.sections, id: \.title) { section in
                SettingsSectionHeader(theme: uiTheme, title: section.title)
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
                SettingsZoomStepButton(systemImage: "minus", label: "Zoom out", theme: theme) {
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

                SettingsZoomStepButton(systemImage: "plus", label: "Zoom in", theme: theme) {
                    value = WorkspaceZoomPolicy.stepped(value, by: 1)
                }
            }
        }
    }
}

/// A Settings zoom step: inset fill and border at rest, with the shared hover and press fills, the glyph
/// one step up the ink ladder while hovered or held, and the standard focus ring (design.md §1.4, §5.1).
private struct SettingsZoomStepButton: View {
    let systemImage: String
    let label: String
    let theme: AppTheme
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false
    @FocusState private var isFocused: Bool
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: scaled(8))
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(
                    size: MonknotMetrics.interfaceGlyph(13, theme: theme, zoomScale: settingsZoomScale),
                    weight: .regular
                ))
                .foregroundStyle(isHovered || isPressed ? theme.foregroundColor : theme.mutedForegroundColor)
                .frame(width: scaled(26), height: scaled(26))
                .background {
                    shape.fill(theme.insetFillColor)
                    if isPressed {
                        shape.fill(theme.pressedFillColor)
                    } else if isHovered {
                        shape.fill(theme.hoverFillColor)
                    }
                }
                .overlay {
                    shape.strokeBorder(theme.borderColor, lineWidth: 1)
                }
                .monknotFocusRing(isVisible: isFocused, cornerRadius: scaled(8), theme: theme)
                .contentShape(shape)
        }
        .buttonStyle(MonknotPressTrackingButtonStyle(isPressed: $isPressed))
        .focusable(NSApp.isFullKeyboardAccessEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .animation(MonknotMotion.hoverAnimation, value: isHovered)
        .help(label)
        .accessibilityLabel(label)
        .monknotPointerCursor()
    }
}
