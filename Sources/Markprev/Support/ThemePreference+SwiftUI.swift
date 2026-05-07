import MarkprevCore
import SwiftUI

extension ThemePreference {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            return "macwindow"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        }
    }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}
