import Foundation

public enum ThemePreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }
}

public enum RenderTheme: String, Codable, Sendable {
    case light
    case dark
}
