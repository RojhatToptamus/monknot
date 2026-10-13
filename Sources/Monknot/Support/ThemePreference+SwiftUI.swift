import AppKit
import MonknotCore

extension ThemePreference {
    /// The appearance the app adopts; nil follows macOS.
    var appAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
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
