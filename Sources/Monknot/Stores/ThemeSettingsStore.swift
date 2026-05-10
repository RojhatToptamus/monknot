import Combine
import Foundation
import MonknotCore

enum SystemAppearance {
    case light
    case dark
}

enum ThemeSlot: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light:
            return "Light theme"
        case .dark:
            return "Dark theme"
        }
    }

    var themes: [AppTheme] {
        switch self {
        case .light:
            return AppTheme.lightThemes
        case .dark:
            return AppTheme.darkThemes
        }
    }

    var defaultThemeID: String {
        switch self {
        case .light:
            return AppTheme.codexLight.id
        case .dark:
            return AppTheme.codexDark.id
        }
    }

    func preset(id: String) -> AppTheme {
        switch self {
        case .light:
            return AppTheme.lightTheme(id: id)
        case .dark:
            return AppTheme.darkTheme(id: id)
        }
    }
}

struct ThemeConfiguration: Codable, Equatable, Sendable {
    var accent: String
    var background: String
    var foreground: String
    var translucentSidebar: Bool
    var quietSidebar: Bool
    var uiFontSize: Double
    var codeFontSize: Double
    var contrast: Double

    private enum CodingKeys: String, CodingKey {
        case accent
        case background
        case foreground
        case translucentSidebar
        case quietSidebar
        case uiFontSize
        case codeFontSize
        case contrast
    }

    init(theme: AppTheme) {
        self.accent = theme.accent
        self.background = theme.background
        self.foreground = theme.foreground
        self.translucentSidebar = !theme.opaqueWindows
        self.quietSidebar = theme.quietSidebar
        self.uiFontSize = theme.uiFontSize
        self.codeFontSize = theme.codeFontSize
        self.contrast = theme.contrast
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accent = try container.decode(String.self, forKey: .accent)
        background = try container.decode(String.self, forKey: .background)
        foreground = try container.decode(String.self, forKey: .foreground)
        translucentSidebar = try container.decodeIfPresent(Bool.self, forKey: .translucentSidebar) ?? true
        quietSidebar = try container.decodeIfPresent(Bool.self, forKey: .quietSidebar) ?? false
        uiFontSize = try container.decode(Double.self, forKey: .uiFontSize)
        codeFontSize = try container.decode(Double.self, forKey: .codeFontSize)
        contrast = try container.decode(Double.self, forKey: .contrast)
    }

    func applied(to theme: AppTheme) -> AppTheme {
        let sanitized = sanitized(for: theme)
        return theme.replacing(
            background: sanitized.background,
            foreground: sanitized.foreground,
            accent: sanitized.accent,
            opaqueWindows: !sanitized.translucentSidebar,
            quietSidebar: sanitized.quietSidebar,
            uiFontSize: sanitized.uiFontSize,
            codeFontSize: sanitized.codeFontSize,
            contrast: sanitized.contrast
        )
    }

    func sanitized(for theme: AppTheme) -> ThemeConfiguration {
        ThemeConfiguration(
            accent: Self.normalizedHex(accent, fallback: theme.accent),
            background: Self.normalizedHex(background, fallback: theme.background),
            foreground: Self.normalizedHex(foreground, fallback: theme.foreground),
            translucentSidebar: translucentSidebar,
            quietSidebar: quietSidebar,
            uiFontSize: Self.clamped(uiFontSize, range: 12...24),
            codeFontSize: Self.clamped(codeFontSize, range: 11...28),
            contrast: Self.clamped(contrast, range: 0...100)
        )
    }

    private init(
        accent: String,
        background: String,
        foreground: String,
        translucentSidebar: Bool,
        quietSidebar: Bool,
        uiFontSize: Double,
        codeFontSize: Double,
        contrast: Double
    ) {
        self.accent = accent
        self.background = background
        self.foreground = foreground
        self.translucentSidebar = translucentSidebar
        self.quietSidebar = quietSidebar
        self.uiFontSize = uiFontSize
        self.codeFontSize = codeFontSize
        self.contrast = contrast
    }

    private static func clamped(_ value: Double, range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private static func normalizedHex(_ value: String, fallback: String) -> String {
        guard let rgb = RGBHex(value) ?? RGBHex(fallback) else {
            return "#339CFF"
        }

        return String(
            format: "#%02X%02X%02X",
            Int((rgb.red * 255).rounded()),
            Int((rgb.green * 255).rounded()),
            Int((rgb.blue * 255).rounded())
        )
    }
}

@MainActor
final class ThemeSettingsStore: ObservableObject {
    @Published var lightThemeID: String {
        didSet {
            guard lightThemeID != oldValue else { return }
            defaults.set(lightThemeID, forKey: Keys.lightThemeID)
        }
    }

    @Published var darkThemeID: String {
        didSet {
            guard darkThemeID != oldValue else { return }
            defaults.set(darkThemeID, forKey: Keys.darkThemeID)
        }
    }

    @Published private(set) var customizations: [String: ThemeConfiguration]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.lightThemeID = defaults.string(forKey: Keys.lightThemeID) ?? AppTheme.codexLight.id
        self.darkThemeID = defaults.string(forKey: Keys.darkThemeID) ?? AppTheme.codexDark.id
        self.customizations = Self.loadCustomizations(from: defaults)
    }

    func selectedThemeID(for slot: ThemeSlot) -> String {
        switch slot {
        case .light:
            return lightThemeID
        case .dark:
            return darkThemeID
        }
    }

    func setSelectedThemeID(_ id: String, for slot: ThemeSlot) {
        switch slot {
        case .light:
            lightThemeID = id
        case .dark:
            darkThemeID = id
        }
    }

    func presetTheme(for slot: ThemeSlot) -> AppTheme {
        slot.preset(id: selectedThemeID(for: slot))
    }

    func effectiveTheme(for slot: ThemeSlot) -> AppTheme {
        let preset = presetTheme(for: slot)
        guard let customization = customizations[preset.id] else {
            return preset
        }

        return customization.applied(to: preset)
    }

    func configuration(for slot: ThemeSlot) -> ThemeConfiguration {
        let preset = presetTheme(for: slot)
        return customizations[preset.id] ?? ThemeConfiguration(theme: preset)
    }

    func hasCustomization(for slot: ThemeSlot) -> Bool {
        customizations[presetTheme(for: slot).id] != nil
    }

    func save(_ configuration: ThemeConfiguration, for slot: ThemeSlot) {
        let preset = presetTheme(for: slot)
        let sanitized = configuration.sanitized(for: preset)
        let presetConfiguration = ThemeConfiguration(theme: preset).sanitized(for: preset)

        if sanitized == presetConfiguration {
            customizations.removeValue(forKey: preset.id)
        } else {
            customizations[preset.id] = sanitized
        }

        persistCustomizations()
    }

    func reset(_ slot: ThemeSlot) {
        customizations.removeValue(forKey: presetTheme(for: slot).id)
        persistCustomizations()
    }

    func activeTheme(themePreference: ThemePreference, systemAppearance: SystemAppearance) -> AppTheme {
        effectiveTheme(for: activeSlot(themePreference: themePreference, systemAppearance: systemAppearance))
    }

    func activeSlot(themePreference: ThemePreference, systemAppearance: SystemAppearance) -> ThemeSlot {
        switch themePreference {
        case .system:
            return systemAppearance == .dark ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private func persistCustomizations() {
        guard let data = try? JSONEncoder().encode(customizations) else { return }
        defaults.set(data, forKey: Keys.customizations)
    }

    private static func loadCustomizations(from defaults: UserDefaults) -> [String: ThemeConfiguration] {
        guard
            let data = defaults.data(forKey: Keys.customizations),
            let customizations = try? JSONDecoder().decode([String: ThemeConfiguration].self, from: data)
        else {
            return [:]
        }

        return customizations
    }

    private enum Keys {
        static let lightThemeID = "Monknot.lightThemeID"
        static let darkThemeID = "Monknot.darkThemeID"
        static let customizations = "Monknot.themeCustomizations"
    }
}
