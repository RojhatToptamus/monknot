import Combine
import Foundation
import MarkprevCore
import SwiftUI

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
    var uiFontSize: Double
    var codeFontSize: Double
    var contrast: Double

    init(theme: AppTheme) {
        self.accent = theme.accent
        self.background = theme.background
        self.foreground = theme.foreground
        self.uiFontSize = theme.uiFontSize
        self.codeFontSize = theme.codeFontSize
        self.contrast = theme.contrast
    }

    func applied(to theme: AppTheme) -> AppTheme {
        let sanitized = sanitized(for: theme)
        return theme.replacing(
            background: sanitized.background,
            foreground: sanitized.foreground,
            accent: sanitized.accent,
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
            uiFontSize: Self.clamped(uiFontSize, range: 12...24),
            codeFontSize: Self.clamped(codeFontSize, range: 11...28),
            contrast: Self.clamped(contrast, range: 0...100)
        )
    }

    private init(
        accent: String,
        background: String,
        foreground: String,
        uiFontSize: Double,
        codeFontSize: Double,
        contrast: Double
    ) {
        self.accent = accent
        self.background = background
        self.foreground = foreground
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
        return configuration(for: slot).applied(to: preset)
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

        if sanitized == ThemeConfiguration(theme: preset) {
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

    func activeTheme(themePreference: ThemePreference, systemColorScheme: ColorScheme) -> AppTheme {
        effectiveTheme(for: activeSlot(themePreference: themePreference, systemColorScheme: systemColorScheme))
    }

    func activeSlot(themePreference: ThemePreference, systemColorScheme: ColorScheme) -> ThemeSlot {
        switch themePreference {
        case .system:
            return systemColorScheme == .dark ? .dark : .light
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
        static let lightThemeID = "Markprev.lightThemeID"
        static let darkThemeID = "Markprev.darkThemeID"
        static let customizations = "Markprev.themeCustomizations"
    }
}
