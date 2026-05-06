import Foundation

public enum ThemePreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
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

public enum RenderTheme: String, Codable, Sendable {
    case light
    case dark
}
