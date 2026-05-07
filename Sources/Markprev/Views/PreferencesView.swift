import SwiftUI

struct PreferencesView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Appearance"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .general:    return "gearshape"
            case .appearance: return "paintbrush"
            }
        }
    }

    @State private var selectedSection: Section = .general

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .font(.system(size: 14))
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            switch selectedSection {
            case .general:
                GeneralSettingsView()
            case .appearance:
                AppearanceSettingsView()
            }
        }
        .frame(width: 780, height: 640)
    }
}
