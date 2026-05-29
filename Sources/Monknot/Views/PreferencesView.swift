import MonknotCore
import SwiftUI

struct PreferencesView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Appearance"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            }
        }
    }

    @ObservedObject var themeStore: ThemeSettingsStore
    @AppStorage("Monknot.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSection: Section = .appearance

    private var themePreference: ThemePreference {
        ThemePreference(rawValue: themePreferenceRawValue) ?? .system
    }

    private var panelTheme: AppTheme {
        themeStore.activeTheme(
            themePreference: themePreference,
            systemAppearance: colorScheme == .dark ? .dark : .light
        )
    }

    private var settingsLayoutToken: String {
        "\(panelTheme.id)-\(themePreferenceRawValue)-\(colorScheme)"
    }

    var body: some View {
        preferencesRoot
    }

    private var preferencesRoot: some View {
        VStack(spacing: 0) {
            settingsChromeHeader

            Group {
                switch selectedSection {
                case .general:
                    GeneralSettingsView(uiTheme: panelTheme)
                case .appearance:
                    AppearanceSettingsView(themeStore: themeStore, uiTheme: panelTheme)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(panelTheme.surfaceColor)
        }
        .frame(width: 760, height: 660)
        .background(panelTheme.surfaceColor)
        .ignoresSafeArea(.container, edges: .top)
        .background(
            WindowBackgroundDragEnabler(
                surfaceColor: panelTheme.surfaceColor,
                layoutToken: settingsLayoutToken,
                suppressToolbarButton: false,
                usesDarkAppearance: panelTheme.isDark
            )
        )
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear
                    .frame(width: 0, height: MonknotMetrics.chromeHeight(theme: panelTheme, zoomScale: 1))
                    .accessibilityHidden(true)
            }
        }
        .preferredColorScheme(themePreference.preferredColorScheme)
    }

    private var settingsChromeHeader: some View {
        MonknotChromePanel(theme: panelTheme) {
            HStack(alignment: .center, spacing: 18) {
                Color.clear
                    .frame(
                        width: MonknotMetrics.scale(
                            MonknotMetrics.trafficLightReserveBase + 6,
                            theme: panelTheme,
                            zoomScale: 1
                        )
                    )
                    .accessibilityHidden(true)

                Text("Settings")
                    .font(MonknotTypography.panelTitle(theme: panelTheme))
                    .foregroundStyle(panelTheme.foregroundColor)

                WindowDoubleClickZoomArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)

                MonknotSettingsSegmentedControl(
                    options: Section.allCases.map { section in
                        MonknotSettingsSegment(id: section.rawValue, title: section.rawValue)
                    },
                    selection: Binding(
                        get: { selectedSection.rawValue },
                        set: { raw in
                            if let section = Section(rawValue: raw) {
                                selectedSection = section
                            }
                        }
                    ),
                    theme: panelTheme
                )
                .frame(maxWidth: 260)
            }
            .padding(.horizontal, MonknotMetrics.Spacing.windowMargin + 4)
            .padding(.vertical, MonknotMetrics.Spacing.l)
            .frame(minHeight: MonknotMetrics.chromeHeight(theme: panelTheme, zoomScale: 1))
        }
    }
}
