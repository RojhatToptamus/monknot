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
            return AppTheme.defaultLight.id
        case .dark:
            return AppTheme.defaultDark.id
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

    private enum CodingKeys: String, CodingKey {
        case accent
        case background
        case foreground
        case uiFontSize
        case codeFontSize
        case contrast
    }

    init(theme: AppTheme) {
        self.accent = theme.accent
        self.background = theme.background
        self.foreground = theme.foreground
        self.uiFontSize = theme.uiFontSize
        self.codeFontSize = theme.codeFontSize
        self.contrast = theme.contrast
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accent = try container.decode(String.self, forKey: .accent)
        background = try container.decode(String.self, forKey: .background)
        foreground = try container.decode(String.self, forKey: .foreground)
        uiFontSize = try container.decode(Double.self, forKey: .uiFontSize)
        codeFontSize = try container.decode(Double.self, forKey: .codeFontSize)
        contrast = try container.decode(Double.self, forKey: .contrast)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accent, forKey: .accent)
        try container.encode(background, forKey: .background)
        try container.encode(foreground, forKey: .foreground)
        try container.encode(uiFontSize, forKey: .uiFontSize)
        try container.encode(codeFontSize, forKey: .codeFontSize)
        try container.encode(contrast, forKey: .contrast)
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

    @Published private(set) var quietSidebar: Bool
    @Published private(set) var uiFontSize: Double
    @Published private(set) var codeFontSize: Double
    @Published private(set) var customizations: [String: ThemeConfiguration]
    @Published private var previewThemeIDs: [ThemeSlot: String] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        let storedLightThemeID = defaults.string(forKey: Keys.lightThemeID)
        let storedDarkThemeID = defaults.string(forKey: Keys.darkThemeID)
        let storedCustomizations = Self.loadCustomizations(from: defaults)
        let migratedLightThemeID = Self.migratedThemeID(storedLightThemeID) ?? AppTheme.defaultLight.id
        let migratedDarkThemeID = Self.migratedThemeID(storedDarkThemeID) ?? AppTheme.defaultDark.id
        let migratedCustomizations = Self.migratedCustomizations(storedCustomizations)
        let quietSidebarState = Self.loadQuietSidebar(from: defaults)
        let typography = Self.loadTypography(
            from: defaults,
            lightThemeID: migratedLightThemeID,
            darkThemeID: migratedDarkThemeID,
            customizations: migratedCustomizations
        )
        let normalizedCustomizations = Self.removingPerThemeTypography(from: migratedCustomizations)

        self.defaults = defaults
        self.lightThemeID = migratedLightThemeID
        self.darkThemeID = migratedDarkThemeID
        self.quietSidebar = quietSidebarState.value
        self.uiFontSize = typography.uiFontSize
        self.codeFontSize = typography.codeFontSize
        self.customizations = normalizedCustomizations

        if storedLightThemeID != nil, storedLightThemeID != migratedLightThemeID {
            defaults.set(migratedLightThemeID, forKey: Keys.lightThemeID)
        }
        if storedDarkThemeID != nil, storedDarkThemeID != migratedDarkThemeID {
            defaults.set(migratedDarkThemeID, forKey: Keys.darkThemeID)
        }
        if storedCustomizations != normalizedCustomizations || quietSidebarState.hadLegacyValue {
            Self.persistCustomizations(normalizedCustomizations, to: defaults)
        }
        defaults.set(quietSidebarState.value, forKey: Keys.quietSidebar)
        defaults.set(typography.uiFontSize, forKey: Keys.uiFontSize)
        defaults.set(typography.codeFontSize, forKey: Keys.codeFontSize)
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
        previewThemeIDs.removeValue(forKey: slot)
        switch slot {
        case .light:
            lightThemeID = id
        case .dark:
            darkThemeID = id
        }
    }

    func previewThemeID(_ id: String, for slot: ThemeSlot) {
        guard slot.themes.contains(where: { $0.id == id }) else { return }
        previewThemeIDs[slot] = id
    }

    func cancelThemePreview(for slot: ThemeSlot) {
        previewThemeIDs.removeValue(forKey: slot)
    }

    private func displayedThemeID(for slot: ThemeSlot) -> String {
        previewThemeIDs[slot] ?? selectedThemeID(for: slot)
    }

    func presetTheme(for slot: ThemeSlot) -> AppTheme {
        slot.preset(id: displayedThemeID(for: slot))
    }

    func effectiveTheme(for slot: ThemeSlot) -> AppTheme {
        let preset = presetTheme(for: slot)
        let colorTheme = customizations[preset.id]?.applied(to: preset) ?? preset
        return colorTheme.replacing(
            quietSidebar: quietSidebar,
            uiFontSize: uiFontSize,
            codeFontSize: codeFontSize
        )
    }

    func configuration(for slot: ThemeSlot) -> ThemeConfiguration {
        let preset = presetTheme(for: slot)
        var configuration = customizations[preset.id] ?? ThemeConfiguration(theme: preset)
        configuration.uiFontSize = uiFontSize
        configuration.codeFontSize = codeFontSize
        return configuration
    }

    func hasCustomization(for slot: ThemeSlot) -> Bool {
        customizations[presetTheme(for: slot).id] != nil
    }

    func save(_ configuration: ThemeConfiguration, for slot: ThemeSlot) {
        let preset = presetTheme(for: slot)
        let sanitized = configuration.sanitized(for: preset)
        setTypography(uiFontSize: sanitized.uiFontSize, codeFontSize: sanitized.codeFontSize)
        saveThemeCustomization(sanitized, for: slot)
    }

    func saveThemeCustomization(_ configuration: ThemeConfiguration, for slot: ThemeSlot) {
        let preset = presetTheme(for: slot)
        let sanitized = configuration.sanitized(for: preset)
        let presetConfiguration = ThemeConfiguration(theme: preset).sanitized(for: preset)

        var themeCustomization = sanitized
        themeCustomization.uiFontSize = presetConfiguration.uiFontSize
        themeCustomization.codeFontSize = presetConfiguration.codeFontSize

        if themeCustomization == presetConfiguration {
            customizations.removeValue(forKey: preset.id)
        } else {
            customizations[preset.id] = themeCustomization
        }

        persistCustomizations()
    }

    func setTypography(uiFontSize: Double, codeFontSize: Double) {
        let sanitizedUI = min(24, max(12, uiFontSize))
        let sanitizedCode = min(28, max(11, codeFontSize))
        guard self.uiFontSize != sanitizedUI || self.codeFontSize != sanitizedCode else { return }

        self.uiFontSize = sanitizedUI
        self.codeFontSize = sanitizedCode
        defaults.set(sanitizedUI, forKey: Keys.uiFontSize)
        defaults.set(sanitizedCode, forKey: Keys.codeFontSize)
    }

    func setQuietSidebar(_ isEnabled: Bool) {
        guard quietSidebar != isEnabled else { return }
        quietSidebar = isEnabled
        defaults.set(isEnabled, forKey: Keys.quietSidebar)
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
        Self.persistCustomizations(customizations, to: defaults)
    }

    private static func persistCustomizations(
        _ customizations: [String: ThemeConfiguration],
        to defaults: UserDefaults
    ) {
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

    private struct LegacyThemeConfiguration: Decodable {
        let quietSidebar: Bool?
    }

    private static func loadQuietSidebar(
        from defaults: UserDefaults
    ) -> (value: Bool, hadLegacyValue: Bool) {
        let legacyCustomizations: [String: LegacyThemeConfiguration]
        if let data = defaults.data(forKey: Keys.customizations),
           let decoded = try? JSONDecoder().decode(
               [String: LegacyThemeConfiguration].self,
               from: data
           ) {
            legacyCustomizations = decoded
        } else {
            legacyCustomizations = [:]
        }

        let hadLegacyValue = legacyCustomizations.values.contains { $0.quietSidebar != nil }
        if defaults.object(forKey: Keys.quietSidebar) != nil {
            return (defaults.bool(forKey: Keys.quietSidebar), hadLegacyValue)
        }

        return (
            legacyCustomizations.values.contains { $0.quietSidebar == true },
            hadLegacyValue
        )
    }

    private static func loadTypography(
        from defaults: UserDefaults,
        lightThemeID: String,
        darkThemeID: String,
        customizations: [String: ThemeConfiguration]
    ) -> (uiFontSize: Double, codeFontSize: Double) {
        if defaults.object(forKey: Keys.uiFontSize) != nil,
           defaults.object(forKey: Keys.codeFontSize) != nil {
            return (
                min(24, max(12, defaults.double(forKey: Keys.uiFontSize))),
                min(28, max(11, defaults.double(forKey: Keys.codeFontSize)))
            )
        }

        let lightTheme = AppTheme.lightTheme(id: lightThemeID)
        let darkTheme = AppTheme.darkTheme(id: darkThemeID)
        let lightConfiguration = (customizations[lightTheme.id] ?? ThemeConfiguration(theme: lightTheme))
            .sanitized(for: lightTheme)
        let darkConfiguration = (customizations[darkTheme.id] ?? ThemeConfiguration(theme: darkTheme))
            .sanitized(for: darkTheme)
        let defaultUI = AppTheme.defaultLight.uiFontSize
        let defaultCode = AppTheme.defaultLight.codeFontSize
        let lightIsCustomized = lightConfiguration.uiFontSize != defaultUI
            || lightConfiguration.codeFontSize != defaultCode
        let darkIsCustomized = darkConfiguration.uiFontSize != defaultUI
            || darkConfiguration.codeFontSize != defaultCode

        if darkIsCustomized && !lightIsCustomized {
            return (darkConfiguration.uiFontSize, darkConfiguration.codeFontSize)
        }
        if defaults.string(forKey: Keys.themePreference) == ThemePreference.dark.rawValue {
            return (darkConfiguration.uiFontSize, darkConfiguration.codeFontSize)
        }
        return (lightConfiguration.uiFontSize, lightConfiguration.codeFontSize)
    }

    private static func removingPerThemeTypography(
        from customizations: [String: ThemeConfiguration]
    ) -> [String: ThemeConfiguration] {
        let presetsByID = Dictionary(
            uniqueKeysWithValues: (AppTheme.lightThemes + AppTheme.darkThemes).map { ($0.id, $0) }
        )
        var normalized: [String: ThemeConfiguration] = [:]

        for (id, configuration) in customizations {
            guard let preset = presetsByID[id] else {
                normalized[id] = configuration
                continue
            }

            let presetConfiguration = ThemeConfiguration(theme: preset).sanitized(for: preset)
            var themeCustomization = configuration.sanitized(for: preset)
            themeCustomization.uiFontSize = presetConfiguration.uiFontSize
            themeCustomization.codeFontSize = presetConfiguration.codeFontSize
            if themeCustomization != presetConfiguration {
                normalized[id] = themeCustomization
            }
        }

        return normalized
    }

    private static func migratedThemeID(_ id: String?) -> String? {
        guard let id else { return nil }
        if id == "gruvbox-light" { return AppTheme.defaultLight.id }
        if id == "gruvbox-dark" { return AppTheme.defaultDark.id }
        return legacyThemeIDPairs.first { $0.legacy == id }?.current ?? id
    }

    private static func migratedCustomizations(
        _ customizations: [String: ThemeConfiguration]
    ) -> [String: ThemeConfiguration] {
        var migrated = customizations
        migrated.removeValue(forKey: "gruvbox-light")
        migrated.removeValue(forKey: "gruvbox-dark")
        for (legacyID, currentID) in legacyThemeIDPairs {
            guard let configuration = migrated.removeValue(forKey: legacyID) else { continue }
            if migrated[currentID] == nil {
                migrated[currentID] = configuration
            }
        }
        normalizeSupersededHarborLightTokens(in: &migrated)
        return migrated
    }

    private static func normalizeSupersededHarborLightTokens(
        in customizations: inout [String: ThemeConfiguration]
    ) {
        guard var configuration = customizations["harbor-light"] else {
            return
        }
        let matchesRemovedPreset =
            configuration.accent.caseInsensitiveCompare("#339CFF") == .orderedSame
            && configuration.background.caseInsensitiveCompare("#FFFFFF") == .orderedSame
            && configuration.foreground.caseInsensitiveCompare("#1A1C1F") == .orderedSame
        let matchesPreviousHousePalette =
            configuration.accent.caseInsensitiveCompare("#0169CC") == .orderedSame
            && configuration.background.caseInsensitiveCompare("#FFFFFF") == .orderedSame
            && configuration.foreground.caseInsensitiveCompare("#0D0D0D") == .orderedSame
        guard matchesRemovedPreset || matchesPreviousHousePalette else { return }

        configuration.accent = AppTheme.defaultLight.accent
        configuration.background = AppTheme.defaultLight.background
        configuration.foreground = AppTheme.defaultLight.foreground
        configuration.contrast = AppTheme.defaultLight.contrast
        customizations["harbor-light"] = configuration
    }

    // Ordered so that the most recent prior canonical ID wins deterministically
    // if several aliases are present in one old preferences payload.
    private static let legacyThemeIDPairs: [(legacy: String, current: String)] = [
        ("monknot-light", "harbor-light"),
        ("monknot-dark", "harbor-dark"),
        ("codex-light", "harbor-light"),
        ("codex-dark", "harbor-dark"),
        ("codex-blue-light", "harbor-light"),
        ("monknot-blue-light", "harbor-light"),
        ("absolutely-light", "parchment-light"),
        ("absolutely-dark", "parchment-dark"),
        ("brass-monkey-light", "brasspants-light"),
        ("brass-monkey-dark", "brasspants-dark"),
        ("catppuccin-light", "catppuccin-latte"),
        ("catppuccin-dark", "catppuccin-mocha"),
        ("code-monkey-light", "codechimp-light"),
        ("code-monkey-dark", "codechimp-dark"),
        ("github-light", "forge-light"),
        ("github-dark", "forge-dark"),
        ("grease-monkey-light", "greaseball-light"),
        ("grease-monkey-dark", "greaseball-dark"),
        ("linear-light", "axis-light"),
        ("linear-dark", "axis-dark"),
        ("material-dark", "lagoon-dark"),
        ("matrix-dark", "phosphor-dark"),
        ("monokai-dark", "citrus-dark"),
        ("notion-light", "paper-light"),
        ("notion-dark", "paper-dark"),
        ("oscurange-dark", "oscura-dark"),
        ("raycast-light", "signal-light"),
        ("raycast-dark", "signal-dark"),
        ("rose-pine-light", "rose-pine-dawn"),
        ("rose-pine-dark", "rose-pine-moon"),
        ("sentry-dark", "watchtower-dark"),
        ("sock-monkey-light", "sockpuppet-light"),
        ("sock-monkey-dark", "sockpuppet-dark"),
        ("vercel-light", "monolith-light"),
        ("vercel-dark", "monolith-dark"),
        ("vscode-plus-light", "workbench-light"),
        ("vscode-plus-dark", "workbench-dark"),
        ("xcode-light", "blueprint-light"),
        ("xcode-dark", "blueprint-dark"),
    ]

    private enum Keys {
        static let lightThemeID = "Monknot.lightThemeID"
        static let darkThemeID = "Monknot.darkThemeID"
        static let customizations = "Monknot.themeCustomizations"
        static let quietSidebar = "Monknot.quietSidebar"
        static let uiFontSize = "Monknot.uiFontSize"
        static let codeFontSize = "Monknot.codeFontSize"
        static let themePreference = "Monknot.themePreference"
    }
}
