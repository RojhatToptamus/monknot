import MarkprevCore
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
    @AppStorage("Markprev.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
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

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(panelTheme.foregroundColor)
                    .listRowBackground(
                        selectedSection == section
                            ? panelTheme.elevatedSurfaceColor
                            : Color.clear
                    )
                    .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(panelTheme.insetFillColor)
            .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 240)
        } detail: {
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
        .tint(panelTheme.accentColor)
        .frame(width: 800, height: 660)
        .background(panelTheme.surfaceColor)
    }
}
