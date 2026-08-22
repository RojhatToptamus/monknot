import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

@MainActor
final class ThemeSettingsMigrationTests: XCTestCase {
    func testThemeEditComparisonIgnoresHexLetterCase() {
        var lowercase = ThemeConfiguration(theme: AppTheme.defaultLight)
        lowercase.accent = lowercase.accent.lowercased()
        var uppercase = lowercase
        uppercase.accent = uppercase.accent.uppercased()

        XCTAssertEqual(
            lowercase.sanitized(for: AppTheme.defaultLight),
            uppercase.sanitized(for: AppTheme.defaultLight),
            "Focusing a hex field must not create a false edited state solely from case normalization"
        )
    }

    func testThemeSettingsUsesHarborDefaultsAndMigratesFormerAliases() throws {
        let suiteName = "MonknotTests.ThemeMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("codex-light", forKey: "Monknot.lightThemeID")
        defaults.set("codex-dark", forKey: "Monknot.darkThemeID")
        var customizedLightTheme = ThemeConfiguration(theme: AppTheme.lightTheme(id: "harbor-light"))
        customizedLightTheme.accent = "#AABBCC"
        defaults.set(
            try JSONEncoder().encode(["codex-light": customizedLightTheme]),
            forKey: "Monknot.themeCustomizations"
        )

        let store = ThemeSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lightThemeID, "harbor-light")
        XCTAssertEqual(store.darkThemeID, "harbor-dark")
        XCTAssertEqual(store.configuration(for: .light).accent, "#AABBCC")
        XCTAssertEqual(defaults.string(forKey: "Monknot.lightThemeID"), "harbor-light")
        XCTAssertEqual(defaults.string(forKey: "Monknot.darkThemeID"), "harbor-dark")

        let data = try XCTUnwrap(defaults.data(forKey: "Monknot.themeCustomizations"))
        let customizations = try JSONDecoder().decode([String: ThemeConfiguration].self, from: data)
        XCTAssertNil(customizations["codex-light"])
        XCTAssertEqual(customizations["harbor-light"]?.accent, "#AABBCC")
    }

    func testEveryLegacyThemeIDMigratesSelectionAndCustomizationIdempotently() throws {
        let mappings: [(legacy: String, current: String, slot: ThemeSlot)] = [
            ("monknot-light", "harbor-light", .light),
            ("monknot-dark", "harbor-dark", .dark),
            ("codex-light", "harbor-light", .light),
            ("codex-dark", "harbor-dark", .dark),
            ("codex-blue-light", "harbor-light", .light),
            ("monknot-blue-light", "harbor-light", .light),
            ("absolutely-light", "parchment-light", .light),
            ("absolutely-dark", "parchment-dark", .dark),
            ("brass-monkey-light", "brasspants-light", .light),
            ("brass-monkey-dark", "brasspants-dark", .dark),
            ("catppuccin-light", "catppuccin-latte", .light),
            ("catppuccin-dark", "catppuccin-mocha", .dark),
            ("code-monkey-light", "codechimp-light", .light),
            ("code-monkey-dark", "codechimp-dark", .dark),
            ("github-light", "forge-light", .light),
            ("github-dark", "forge-dark", .dark),
            ("grease-monkey-light", "greaseball-light", .light),
            ("grease-monkey-dark", "greaseball-dark", .dark),
            ("linear-light", "axis-light", .light),
            ("linear-dark", "axis-dark", .dark),
            ("material-dark", "lagoon-dark", .dark),
            ("matrix-dark", "phosphor-dark", .dark),
            ("monokai-dark", "citrus-dark", .dark),
            ("notion-light", "paper-light", .light),
            ("notion-dark", "paper-dark", .dark),
            ("oscurange-dark", "oscura-dark", .dark),
            ("raycast-light", "signal-light", .light),
            ("raycast-dark", "signal-dark", .dark),
            ("rose-pine-light", "rose-pine-dawn", .light),
            ("rose-pine-dark", "rose-pine-moon", .dark),
            ("sentry-dark", "watchtower-dark", .dark),
            ("sock-monkey-light", "sockpuppet-light", .light),
            ("sock-monkey-dark", "sockpuppet-dark", .dark),
            ("vercel-light", "monolith-light", .light),
            ("vercel-dark", "monolith-dark", .dark),
            ("vscode-plus-light", "workbench-light", .light),
            ("vscode-plus-dark", "workbench-dark", .dark),
            ("xcode-light", "blueprint-light", .light),
            ("xcode-dark", "blueprint-dark", .dark),
        ]

        for mapping in mappings {
            let suiteName = "MonknotTests.ThemeIDMigration.\(mapping.legacy).\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let preset = mapping.slot.preset(id: mapping.current)
            var customization = ThemeConfiguration(theme: preset)
            customization.accent = "#AABBCC"
            customization.background = "#102030"
            customization.foreground = "#F0E0D0"
            customization.uiFontSize = 22
            customization.codeFontSize = 18
            customization.contrast = 37
            defaults.set(
                try JSONEncoder().encode([mapping.legacy: customization]),
                forKey: "Monknot.themeCustomizations"
            )
            switch mapping.slot {
            case .light:
                defaults.set(mapping.legacy, forKey: "Monknot.lightThemeID")
            case .dark:
                defaults.set(mapping.legacy, forKey: "Monknot.darkThemeID")
            }
            defaults.set(true, forKey: "Monknot.quietSidebar")

            let store = ThemeSettingsStore(defaults: defaults)
            XCTAssertEqual(store.selectedThemeID(for: mapping.slot), mapping.current, mapping.legacy)
            XCTAssertEqual(store.configuration(for: mapping.slot).accent, "#AABBCC", mapping.legacy)
            XCTAssertEqual(store.configuration(for: mapping.slot).background, "#102030", mapping.legacy)
            XCTAssertEqual(store.configuration(for: mapping.slot).foreground, "#F0E0D0", mapping.legacy)
            XCTAssertEqual(store.configuration(for: mapping.slot).contrast, 37, mapping.legacy)
            XCTAssertEqual(store.uiFontSize, 22, mapping.legacy)
            XCTAssertEqual(store.codeFontSize, 18, mapping.legacy)
            XCTAssertTrue(store.quietSidebar, mapping.legacy)

            let data = try XCTUnwrap(defaults.data(forKey: "Monknot.themeCustomizations"))
            let persisted = try JSONDecoder().decode([String: ThemeConfiguration].self, from: data)
            XCTAssertNil(persisted[mapping.legacy], mapping.legacy)
            XCTAssertEqual(persisted[mapping.current]?.accent, "#AABBCC", mapping.legacy)

            let reloaded = ThemeSettingsStore(defaults: defaults)
            XCTAssertEqual(reloaded.selectedThemeID(for: mapping.slot), mapping.current, mapping.legacy)
            XCTAssertEqual(reloaded.configuration(for: mapping.slot).accent, "#AABBCC", mapping.legacy)
        }
    }

    func testThemeSettingsUsesHarborForFreshDefaults() throws {
        let suiteName = "MonknotTests.ThemeDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThemeSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lightThemeID, "harbor-light")
        XCTAssertEqual(store.darkThemeID, "harbor-dark")
        XCTAssertTrue(ThemeSlot.light.themes.contains { $0.name == "Harbor" })
        XCTAssertTrue(ThemeSlot.dark.themes.contains { $0.name == "Harbor" })
    }

    func testThemeSettingsPreservesAnExistingValidDarkThemeChoice() throws {
        let suiteName = "MonknotTests.SavedDarkTheme.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let savedThemeID = try XCTUnwrap(
            AppTheme.darkThemes.first { $0.id != AppTheme.defaultDark.id }?.id
        )
        defaults.set(savedThemeID, forKey: "Monknot.darkThemeID")

        let store = ThemeSettingsStore(defaults: defaults)

        XCTAssertEqual(store.darkThemeID, savedThemeID)
        XCTAssertEqual(defaults.string(forKey: "Monknot.darkThemeID"), savedThemeID)
    }

    func testRemovedThemeSelectionAndCustomizationFallBackToHarbor() throws {
        let suiteName = "MonknotTests.RemovedTheme.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("gruvbox-light", forKey: "Monknot.lightThemeID")
        defaults.set("gruvbox-dark", forKey: "Monknot.darkThemeID")
        let removedConfiguration = ThemeConfiguration(theme: AppTheme.defaultLight)
        defaults.set(
            try JSONEncoder().encode(["gruvbox-light": removedConfiguration]),
            forKey: "Monknot.themeCustomizations"
        )

        let store = ThemeSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lightThemeID, "harbor-light")
        XCTAssertEqual(store.darkThemeID, "harbor-dark")
        XCTAssertEqual(defaults.string(forKey: "Monknot.lightThemeID"), "harbor-light")
        XCTAssertEqual(defaults.string(forKey: "Monknot.darkThemeID"), "harbor-dark")
        let data = try XCTUnwrap(defaults.data(forKey: "Monknot.themeCustomizations"))
        let customizations = try JSONDecoder().decode([String: ThemeConfiguration].self, from: data)
        XCTAssertNil(customizations["gruvbox-light"])
    }

    func testThemePreviewDoesNotPersistAndCancelRestoresCommittedTheme() throws {
        let suiteName = "MonknotTests.ThemePreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThemeSettingsStore(defaults: defaults)
        store.previewThemeID("monolith-light", for: .light)

        XCTAssertEqual(store.selectedThemeID(for: .light), "harbor-light")
        XCTAssertEqual(store.effectiveTheme(for: .light).id, "monolith-light")
        XCTAssertNil(defaults.string(forKey: "Monknot.lightThemeID"))

        store.cancelThemePreview(for: .light)

        XCTAssertEqual(store.effectiveTheme(for: .light).id, "harbor-light")
        XCTAssertNil(defaults.string(forKey: "Monknot.lightThemeID"))

        store.previewThemeID("monolith-light", for: .light)
        store.setSelectedThemeID("monolith-light", for: .light)
        XCTAssertEqual(store.effectiveTheme(for: .light).id, "monolith-light")
        XCTAssertEqual(defaults.string(forKey: "Monknot.lightThemeID"), "monolith-light")
    }

    func testRemovedLightPresetTokensNormalizeToHarborAndMigrateGlobalQuietSidebar() throws {
        let suiteName = "MonknotTests.RemovedThemeTokens.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("monknot-light", forKey: "Monknot.lightThemeID")
        var removedPreset = ThemeConfiguration(theme: AppTheme.defaultLight)
        removedPreset.accent = "#339CFF"
        removedPreset.background = "#FFFFFF"
        removedPreset.foreground = "#1A1C1F"
        let encoded = try JSONEncoder().encode(["monknot-light": removedPreset])
        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: [String: Any]]
        )
        legacyJSON["monknot-light"]?["quietSidebar"] = true
        defaults.set(try JSONSerialization.data(withJSONObject: legacyJSON), forKey: "Monknot.themeCustomizations")

        let store = ThemeSettingsStore(defaults: defaults)
        let configuration = store.configuration(for: .light)

        XCTAssertEqual(configuration.accent, "#0a52a3")
        XCTAssertEqual(configuration.background, "#fdfdfe")
        XCTAssertEqual(configuration.foreground, "#1c1e22")
        XCTAssertEqual(configuration.contrast, 40)
        XCTAssertTrue(store.quietSidebar)
        XCTAssertTrue(store.effectiveTheme(for: .light).quietSidebar)
        XCTAssertTrue(store.effectiveTheme(for: .dark).quietSidebar)
        XCTAssertTrue(defaults.bool(forKey: "Monknot.quietSidebar"))

        let persistedData = try XCTUnwrap(defaults.data(forKey: "Monknot.themeCustomizations"))
        let persistedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persistedData) as? [String: [String: Any]]
        )
        XCTAssertNil(persistedJSON["harbor-light"]?["quietSidebar"])
    }

    func testPreviousHarborBaseCustomizationMovesToReplacementPalette() throws {
        let suiteName = "MonknotTests.PreviousHarborPalette.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var previous = ThemeConfiguration(theme: AppTheme.defaultLight)
        previous.accent = "#0169CC"
        previous.background = "#FFFFFF"
        previous.foreground = "#0D0D0D"
        previous.contrast = 45
        defaults.set(
            try JSONEncoder().encode(["harbor-light": previous]),
            forKey: "Monknot.themeCustomizations"
        )

        let configuration = ThemeSettingsStore(defaults: defaults).configuration(for: .light)

        XCTAssertEqual(configuration.accent, "#0a52a3")
        XCTAssertEqual(configuration.background, "#fdfdfe")
        XCTAssertEqual(configuration.foreground, "#1c1e22")
        XCTAssertEqual(configuration.contrast, 40)
    }

    func testQuietSidebarIsGlobalAcrossThemeSelectionAndPreview() throws {
        let suiteName = "MonknotTests.GlobalQuietSidebar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThemeSettingsStore(defaults: defaults)
        store.setQuietSidebar(true)
        store.setSelectedThemeID("greaseball-light", for: .light)
        store.setSelectedThemeID("brasspants-dark", for: .dark)

        XCTAssertTrue(store.effectiveTheme(for: .light).quietSidebar)
        XCTAssertTrue(store.effectiveTheme(for: .dark).quietSidebar)
        XCTAssertTrue(defaults.bool(forKey: "Monknot.quietSidebar"))

        store.previewThemeID("sockpuppet-light", for: .light)
        XCTAssertTrue(store.effectiveTheme(for: .light).quietSidebar)
        store.cancelThemePreview(for: .light)
        XCTAssertTrue(store.effectiveTheme(for: .light).quietSidebar)

        store.setQuietSidebar(false)
        XCTAssertFalse(store.effectiveTheme(for: .light).quietSidebar)
        XCTAssertFalse(store.effectiveTheme(for: .dark).quietSidebar)
    }

    func testLegacyQuietSidebarFieldIsRemovedFromRetainedColorCustomization() throws {
        let suiteName = "MonknotTests.QuietSidebarCleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var configuration = ThemeConfiguration(theme: AppTheme.defaultLight)
        configuration.accent = "#AABBCC"
        let encoded = try JSONEncoder().encode(["harbor-light": configuration])
        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: [String: Any]]
        )
        legacyJSON["harbor-light"]?["quietSidebar"] = true
        defaults.set(try JSONSerialization.data(withJSONObject: legacyJSON), forKey: "Monknot.themeCustomizations")

        let store = ThemeSettingsStore(defaults: defaults)

        XCTAssertTrue(store.quietSidebar)
        XCTAssertEqual(store.configuration(for: .light).accent, "#AABBCC")
        let persistedData = try XCTUnwrap(defaults.data(forKey: "Monknot.themeCustomizations"))
        let persistedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persistedData) as? [String: [String: Any]]
        )
        XCTAssertNil(persistedJSON["harbor-light"]?["quietSidebar"])
    }

    func testThemeSelectionKeepsOneGlobalTypographyAtEveryAppearance() throws {
        let suiteName = "MonknotTests.GlobalTypography.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThemeSettingsStore(defaults: defaults)
        var typography = store.configuration(for: .light)
        typography.uiFontSize = 22
        typography.codeFontSize = 18
        store.save(typography, for: .light)

        store.setSelectedThemeID("monolith-light", for: .light)
        store.setSelectedThemeID("phosphor-dark", for: .dark)

        let lightTheme = store.activeTheme(themePreference: .system, systemAppearance: .light)
        let darkTheme = store.activeTheme(themePreference: .system, systemAppearance: .dark)
        XCTAssertEqual(lightTheme.uiFontSize, 22)
        XCTAssertEqual(lightTheme.codeFontSize, 18)
        XCTAssertEqual(darkTheme.uiFontSize, 22)
        XCTAssertEqual(darkTheme.codeFontSize, 18)
        XCTAssertEqual(defaults.double(forKey: "Monknot.uiFontSize"), 22)
        XCTAssertEqual(defaults.double(forKey: "Monknot.codeFontSize"), 18)
    }

    func testThemeColorSaveCannotRestoreStalePerThemeTypography() throws {
        let suiteName = "MonknotTests.ColorSaveTypography.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThemeSettingsStore(defaults: defaults)
        store.setSelectedThemeID("phosphor-dark", for: .dark)
        store.setTypography(uiFontSize: 20, codeFontSize: 17)

        var staleDraft = ThemeConfiguration(theme: AppTheme.darkTheme(id: "phosphor-dark"))
        staleDraft.accent = "#22FF66"
        staleDraft.uiFontSize = 12
        staleDraft.codeFontSize = 11
        store.saveThemeCustomization(staleDraft, for: .dark)

        XCTAssertEqual(store.uiFontSize, 20)
        XCTAssertEqual(store.codeFontSize, 17)
        XCTAssertEqual(store.effectiveTheme(for: .light).uiFontSize, 20)
        XCTAssertEqual(store.effectiveTheme(for: .dark).codeFontSize, 17)
        XCTAssertEqual(store.configuration(for: .dark).accent, "#22FF66")
    }

    func testLegacyPerThemeTypographyMigratesToTheGlobalOwner() throws {
        let suiteName = "MonknotTests.TypographyMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("matrix-dark", forKey: "Monknot.darkThemeID")
        defaults.set(ThemePreference.dark.rawValue, forKey: "Monknot.themePreference")
        var legacyConfiguration = ThemeConfiguration(theme: AppTheme.darkTheme(id: "phosphor-dark"))
        legacyConfiguration.uiFontSize = 21
        legacyConfiguration.codeFontSize = 17
        defaults.set(
            try JSONEncoder().encode(["matrix-dark": legacyConfiguration]),
            forKey: "Monknot.themeCustomizations"
        )

        let store = ThemeSettingsStore(defaults: defaults)

        XCTAssertEqual(store.effectiveTheme(for: .light).uiFontSize, 21)
        XCTAssertEqual(store.effectiveTheme(for: .dark).uiFontSize, 21)
        XCTAssertEqual(store.effectiveTheme(for: .light).codeFontSize, 17)
        XCTAssertEqual(store.effectiveTheme(for: .dark).codeFontSize, 17)

        let data = try XCTUnwrap(defaults.data(forKey: "Monknot.themeCustomizations"))
        let customizations = try JSONDecoder().decode([String: ThemeConfiguration].self, from: data)
        XCTAssertNil(customizations["matrix-dark"])
        XCTAssertNil(customizations["phosphor-dark"])
    }

    func testQuietSidebarSecondaryInkStaysLegibleWithoutDoubleOpacity() {
        for baseTheme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            let standard = baseTheme.sidebarMutedOpacity(prominence: 0.68)
            let quietTheme = baseTheme.replacing(quietSidebar: true)
            let quiet = quietTheme.sidebarMutedOpacity(prominence: 0.68)

            XCTAssertLessThan(quiet, standard)
            XCTAssertGreaterThanOrEqual(quiet, baseTheme.isDark ? 0.48 : 0.52)
        }
    }

    func testInterfaceGlyphsNeverOutgrowTextAcrossSupportedZoomsAndThemes() {
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                XCTAssertLessThanOrEqual(
                    theme.interfaceGlyphScale(zoomScale: zoomScale),
                    theme.interfaceTextScale(zoomScale: zoomScale),
                    "Symbols outgrew adjacent text at zoom \(zoomScale)"
                )
            }
        }
    }
}
