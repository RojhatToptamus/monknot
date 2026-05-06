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

    func renderTheme(systemColorScheme: ColorScheme) -> RenderTheme {
        switch self {
        case .system:
            return systemColorScheme == .dark ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    func appTheme(systemColorScheme: ColorScheme, lightThemeID: String, darkThemeID: String) -> AppTheme {
        switch self {
        case .system:
            return systemColorScheme == .dark ? AppTheme.darkTheme(id: darkThemeID) : AppTheme.lightTheme(id: lightThemeID)
        case .light:
            return AppTheme.lightTheme(id: lightThemeID)
        case .dark:
            return AppTheme.darkTheme(id: darkThemeID)
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
}
