import Foundation

/// Visual treatment for navigation chrome (sidebar, top bar, drawer headers).
public enum MonknotChromeSurfaceStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case solid
    case translucent
    case liquidGlass

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .solid:
            return "Solid"
        case .translucent:
            return "Translucent"
        case .liquidGlass:
            return "Liquid Glass"
        }
    }

    public var detail: String {
        switch self {
        case .solid:
            return "Opaque theme surface on chrome regions"
        case .translucent:
            return "Tinted macOS material behind chrome"
        case .liquidGlass:
            return "System Liquid Glass on chrome when available"
        }
    }

    /// Maps legacy `opaqueWindows` / translucent sidebar toggles.
    public static func fromLegacy(translucentSidebar: Bool) -> MonknotChromeSurfaceStyle {
        translucentSidebar ? .translucent : .solid
    }

    public var usesOpaqueWindows: Bool {
        self == .solid
    }
}
