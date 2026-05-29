import Foundation

/// Visual treatment for navigation chrome (sidebar, top bar, drawer headers).
public enum MonknotChromeSurfaceStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case solid
    case translucent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .solid:
            return "Solid"
        case .translucent:
            return "Translucent"
        }
    }

    public var detail: String {
        switch self {
        case .solid:
            return "Opaque theme surface on chrome regions"
        case .translucent:
            return "Tinted macOS material behind chrome"
        }
    }

    /// Maps legacy `opaqueWindows` / translucent sidebar toggles.
    public static func fromLegacy(translucentSidebar: Bool) -> MonknotChromeSurfaceStyle {
        translucentSidebar ? .translucent : .solid
    }

    public var usesOpaqueWindows: Bool {
        self == .solid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = MonknotChromeSurfaceStyle(rawValue: rawValue) ?? .translucent
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
