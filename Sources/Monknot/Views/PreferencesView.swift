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

    var body: some View {
        VStack(spacing: 0) {
            header

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
        .frame(width: 760, height: 660)
        .background(panelTheme.surfaceColor)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Text("Settings")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(panelTheme.foregroundColor)

            Spacer(minLength: 12)

            Picker("Settings Section", selection: $selectedSection) {
                ForEach(Section.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .frame(width: 260)
            .monknotPointerCursor()
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .background(panelTheme.surfaceColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(panelTheme.borderColor)
                .frame(height: 1)
        }
    }
}
