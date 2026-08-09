import Foundation

public enum ThemePreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    public static let defaultValue: Self = .dark

    public var id: String { rawValue }

    public static func resolved(rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? defaultValue
    }
}

public enum RenderTheme: String, Codable, Sendable {
    case light
    case dark
}
