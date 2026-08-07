import AppKit
import MonknotCore
import ObjectiveC.runtime
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class ChromeAlignmentTests: XCTestCase {
    func testComposedWorkspaceSplitKeepsEveryPrimaryChromeColumnOnOneCenterline() {
        for chromeHeight in [
            MonknotMetrics.chromeHeight(theme: .defaultDark, zoomScale: 1),
            MonknotMetrics.chromeHeight(theme: .defaultDark, zoomScale: WorkspaceZoomPolicy.maximum),
        ] {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true

            let host = NSHostingView(rootView: ChromeColumnOriginFixture(chromeHeight: chromeHeight))
            window.contentView = host
            host.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1_200, height: 760)
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()

            let centers = ["sidebar", "detail", "navigation"].compactMap { identifier -> (String, CGFloat)? in
                guard let view = host.allDescendantsForTesting().first(where: {
                    $0.identifier?.rawValue == "Monknot.Test.Chrome.\(identifier)"
                }) else {
                    XCTFail("Missing composed chrome marker: \(identifier)")
                    return nil
                }
                return (identifier, view.convert(
                    NSPoint(x: view.bounds.midX, y: view.bounds.midY),
                    to: host
                ).y)
            }

            XCTAssertEqual(centers.count, 3)
            let centerValues = centers.map(\.1)
            if let minimum = centerValues.min(), let maximum = centerValues.max() {
                XCTAssertEqual(
                    maximum,
                    minimum,
                    accuracy: 1,
                    "The composed workspace split introduced a second chrome y-origin at height \(chromeHeight): \(centers)"
                )
            }
        }
    }

    func testTerminalFocusRestorerReturnsKeyboardFocusToTheDocument() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let terminalResponder = NSTextView(frame: NSRect(x: 320, y: 0, width: 320, height: 480))
        window.contentView?.addSubview(documentEditor)
        window.contentView?.addSubview(terminalResponder)
        XCTAssertTrue(window.makeFirstResponder(documentEditor))

        let restorer = TerminalFocusRestorer()
        restorer.capture(from: window)
        XCTAssertTrue(window.makeFirstResponder(terminalResponder))

        restorer.restore()
        await Task.yield()

        XCTAssertTrue(window.firstResponder === documentEditor)
    }

    func testTerminalFocusRestorerSurvivesRapidCloseAndReopen() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let terminalResponder = NSTextView(frame: NSRect(x: 320, y: 0, width: 320, height: 480))
        window.contentView?.addSubview(documentEditor)
        window.contentView?.addSubview(terminalResponder)
        XCTAssertTrue(window.makeFirstResponder(documentEditor))

        let restorer = TerminalFocusRestorer()
        restorer.capture(from: window)
        XCTAssertTrue(window.makeFirstResponder(terminalResponder))
        restorer.restore()

        restorer.capture(from: window)
        XCTAssertTrue(window.firstResponder === terminalResponder)
        restorer.restore()
        await Task.yield()

        XCTAssertTrue(window.firstResponder === documentEditor)
    }

    func testTerminalFocusRestorerUsesSourceFirstRegisteredTargetAfterMenuFocusLoss() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let documentEditor = NSTextView(frame: documentScrollView.bounds)
        documentEditor.identifier = .monknotDocumentFocusTarget
        documentScrollView.documentView = documentEditor
        let documentPreview = NSTextView(frame: NSRect(x: 160, y: 0, width: 160, height: 480))
        documentPreview.identifier = .monknotDocumentFocusTarget
        let terminalResponder = NSTextView(frame: NSRect(x: 320, y: 0, width: 320, height: 480))
        window.contentView?.addSubview(documentScrollView)
        window.contentView?.addSubview(documentPreview)
        window.contentView?.addSubview(terminalResponder)
        XCTAssertTrue(window.makeFirstResponder(documentEditor))
        XCTAssertTrue(window.makeFirstResponder(nil))

        let restorer = TerminalFocusRestorer()
        restorer.capture(from: window)
        XCTAssertTrue(window.makeFirstResponder(terminalResponder))
        restorer.restore(fallbackFrom: window)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === documentEditor)
    }

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

    func testSettingsMenuSelectionTransactionPreviewsThenCancelsOrCommits() {
        var cancelled = SettingsMenuSelectionTransaction(initialSelection: "harbor-light")
        cancelled.preview("forge-light")
        XCTAssertEqual(cancelled.previewedSelection, "forge-light")
        XCTAssertEqual(cancelled.selectionAfterClose, "harbor-light")

        var committed = SettingsMenuSelectionTransaction(initialSelection: "harbor-light")
        committed.preview("forge-light")
        committed.commit("monolith-light")
        XCTAssertEqual(committed.previewedSelection, "monolith-light")
        XCTAssertEqual(committed.selectionAfterClose, "monolith-light")
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

    func testWorkspaceChromeZoomUsesTheExactDiscreteFactor() {
        let theme = AppTheme.defaultDark
        let compact = theme.layoutScale(zoomScale: WorkspaceZoomPolicy.minimum)
        let normal = theme.layoutScale(zoomScale: 1)
        let enlarged = theme.layoutScale(zoomScale: 1.7)
        let maximum = theme.layoutScale(zoomScale: WorkspaceZoomPolicy.maximum)

        XCTAssertLessThan(compact, normal)
        XCTAssertGreaterThan(enlarged, normal)
        XCTAssertGreaterThan(maximum, enlarged)
        XCTAssertEqual(compact, 0.8, accuracy: 0.001)
        XCTAssertEqual(enlarged, 1.7, accuracy: 0.001)
        XCTAssertEqual(maximum, 2.0, accuracy: 0.001)
    }

    func testWorkspaceZoomPolicyUsesTheSpecifiedDiscreteLadder() {
        XCTAssertEqual(
            WorkspaceZoomPolicy.supportedLevels,
            [0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
        )
        for (rawZoom, documentScale) in zip(
            WorkspaceZoomPolicy.supportedLevels,
            WorkspaceZoomPolicy.shortcutDocumentScales
        ) {
            XCTAssertEqual(
                WorkspaceZoomPolicy.documentScale(rawZoom),
                documentScale,
                accuracy: 0.001
            )
        }
        XCTAssertEqual(
            WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.stepped(1, by: 0.1)),
            1.1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.stepped(1, by: -0.1)),
            0.9,
            accuracy: 0.001
        )
        XCTAssertEqual(WorkspaceZoomPolicy.stepped(1.9, by: 0.1), 2.0)
        XCTAssertEqual(WorkspaceZoomPolicy.stepped(2.0, by: 0.1), 2.0)
        XCTAssertEqual(WorkspaceZoomPolicy.stepped(0.8, by: -0.1), 0.8)
        XCTAssertEqual(WorkspaceZoomPolicy.stepped(1.3, by: 0), 1.3)
        XCTAssertEqual(WorkspaceZoomPolicy.clamp(.nan), WorkspaceZoomPolicy.defaultValue)
        XCTAssertEqual(WorkspaceZoomPolicy.clamp(.infinity), WorkspaceZoomPolicy.maximum)
        XCTAssertEqual(WorkspaceZoomPolicy.clamp(-.infinity), WorkspaceZoomPolicy.minimum)
        XCTAssertEqual(WorkspaceZoomPolicy.stepped(.infinity, by: 0.1), WorkspaceZoomPolicy.maximum)
        XCTAssertEqual(WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.minimum), 0.8, accuracy: 0.001)
        XCTAssertEqual(WorkspaceZoomPolicy.documentScale(1), 1, accuracy: 0.001)
        XCTAssertEqual(WorkspaceZoomPolicy.documentScale(2), 2, accuracy: 0.001)
        XCTAssertEqual(WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.maximum), 2, accuracy: 0.001)
        for documentScale in WorkspaceZoomPolicy.shortcutDocumentScales {
            XCTAssertEqual(
                WorkspaceZoomPolicy.documentScale(
                    WorkspaceZoomPolicy.rawZoom(forDocumentScale: documentScale)
                ),
                documentScale,
                accuracy: 0.001
            )
        }
    }

    func testWideMarkdownToolbarPreservesCompleteFormattingActionOrder() {
        XCTAssertEqual(
            MarkdownSourceToolbar.regularActionGroups.map { $0.map(\.label) },
            [
                ["Bold", "Italic", "Quote", "Inline Code", "Link"],
                ["Bullet List", "Numbered List", "Task List"],
                ["Image", "Horizontal Rule"],
            ]
        )
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

    func testCombinedFontAndZoomExtremesKeepOneWorkspaceFactor() {
        var largestConfiguration = ThemeConfiguration(theme: .defaultDark)
        largestConfiguration.uiFontSize = 24
        let largestTheme = largestConfiguration.applied(to: .defaultDark)
        var smallestConfiguration = ThemeConfiguration(theme: .defaultDark)
        smallestConfiguration.uiFontSize = 12
        let smallestTheme = smallestConfiguration.applied(to: .defaultDark)

        XCTAssertEqual(
            largestTheme.layoutScale(zoomScale: WorkspaceZoomPolicy.maximum),
            2.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            smallestTheme.layoutScale(zoomScale: WorkspaceZoomPolicy.minimum),
            0.8,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(
            MonknotMetrics.chromeButtonDimension(
                theme: smallestTheme,
                zoomScale: WorkspaceZoomPolicy.minimum
            ),
            22
        )

        XCTAssertEqual(
            largestTheme.interfaceTextScale(zoomScale: WorkspaceZoomPolicy.maximum),
            2.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            largestTheme.interfaceControlScale(zoomScale: WorkspaceZoomPolicy.maximum),
            2.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            largestTheme.interfaceRowScale(zoomScale: WorkspaceZoomPolicy.maximum),
            2.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            largestTheme.interfaceDensityScale(zoomScale: WorkspaceZoomPolicy.maximum),
            2.0,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(
            smallestTheme.interfaceTextScale(zoomScale: WorkspaceZoomPolicy.minimum),
            0.70
        )
    }

    func testHighDocumentZoomKeepsChromeIconsProportionalToAdjacentText() {
        let theme = AppTheme.defaultDark
        let normalIconSize = MonknotIconButton.IconButtonSize.chrome.iconSize(
            theme: theme,
            zoomScale: 1
        )
        let maximumIconSize = MonknotIconButton.IconButtonSize.chrome.iconSize(
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum
        )

        XCTAssertEqual(normalIconSize, 17, accuracy: 0.001)
        XCTAssertEqual(maximumIconSize, normalIconSize * 2, accuracy: 0.001)
        XCTAssertEqual(
            theme.interfaceGlyphScale(zoomScale: WorkspaceZoomPolicy.maximum),
            theme.interfaceTextScale(zoomScale: WorkspaceZoomPolicy.maximum),
            accuracy: 0.001
        )
    }

    func testWorkspaceWindowChromePreservesNativeWindowControlsAndToolbarOwnership() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let toolbar = NSToolbar(identifier: "MonknotChromeRegressionToolbar")
        window.toolbar = toolbar

        let coordinator = WindowBackgroundDragEnabler.Coordinator(suppressToolbarButton: true)
        coordinator.configureWindowChrome(in: window)

        XCTAssertTrue(
            window.toolbar === toolbar,
            "Window chrome support must not dismantle AppKit-owned title-bar infrastructure"
        )
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertNotNil(window.standardWindowButton(.zoomButton))
    }

    func testSettingsChromeEnablesEveryNativeWindowControl() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let coordinator = WindowBackgroundDragEnabler.Coordinator(
            suppressToolbarButton: true,
            enablesStandardWindowControls: true
        )
        coordinator.configureWindowChrome(in: window)

        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isEnabled, true)
        XCTAssertEqual(window.standardWindowButton(.miniaturizeButton)?.isEnabled, true)
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled, true)
    }

    func testSettingsRowsScaleTheirCompleteLayoutWithInterfaceZoom() {
        func fittingHeight(zoomScale: Double) -> CGFloat {
            let row = SettingsRow(
                theme: .defaultDark,
                title: "Workspace zoom",
                detail: "Scale typography, controls, padding, and spacing together",
                showsDivider: false
            ) {
                Text("100%")
            }
            .environment(\.monknotSettingsZoomScale, zoomScale)
            .frame(width: 520)

            return NSHostingView(rootView: row).fittingSize.height
        }

        let normalHeight = fittingHeight(zoomScale: 1)
        let maximumHeight = fittingHeight(zoomScale: 2)

        XCTAssertGreaterThan(maximumHeight, normalHeight * 1.75)
    }

    func testNativeTrafficLightsCenterVerticallyInTheAdaptiveWorkspaceChromeBand() {
        for chromeHeight in [
            MonknotMetrics.chromeHeight(theme: .defaultLight, zoomScale: WorkspaceZoomPolicy.minimum),
            MonknotMetrics.chromeHeight(theme: .defaultLight, zoomScale: 1),
            MonknotMetrics.chromeHeight(theme: .defaultLight, zoomScale: WorkspaceZoomPolicy.maximum),
        ] {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true

            let coordinator = WindowBackgroundDragEnabler.Coordinator(
                suppressToolbarButton: true,
                trafficLightRowHeight: chromeHeight
            )
            coordinator.configureWindowChrome(in: window)
            window.layoutIfNeeded()

            XCTAssertNil(
                window.toolbar,
                "A second native toolbar would cover the custom workspace row"
            )

            guard let closeButton = window.standardWindowButton(.closeButton),
                  let titlebarContainer = closeButton.superview
            else {
                XCTFail("Missing AppKit-owned native close button")
                continue
            }

            let buttons = [
                window.standardWindowButton(.closeButton),
                window.standardWindowButton(.miniaturizeButton),
                window.standardWindowButton(.zoomButton),
            ].compactMap { $0 }

            for button in buttons {
                XCTAssertTrue(button.superview === titlebarContainer)
                let centerFromTop = titlebarContainer.isFlipped
                    ? button.frame.midY - titlebarContainer.bounds.minY
                    : titlebarContainer.bounds.maxY - button.frame.midY
                XCTAssertEqual(
                    centerFromTop,
                    chromeHeight / 2,
                    accuracy: 0.001,
                    "Every native traffic light must share Monknot's primary chrome centerline"
                )
            }
            XCTAssertFalse(
                titlebarContainer.clipsToBounds,
                "The native controls must remain visible when adaptive chrome extends below AppKit's titlebar container"
            )
        }
    }

    func testNativeTrafficLightAlignmentReappliesAfterWindowLayoutChange() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        let chromeHeight = MonknotMetrics.chromeHeight(
            theme: .defaultLight,
            zoomScale: WorkspaceZoomPolicy.maximum
        )
        let coordinator = WindowBackgroundDragEnabler.Coordinator(
            suppressToolbarButton: true,
            trafficLightRowHeight: chromeHeight
        )
        coordinator.observeWindow(window)
        coordinator.configureWindowChrome(in: window)

        guard let closeButton = window.standardWindowButton(.closeButton),
              let titlebarContainer = closeButton.superview
        else {
            return XCTFail("Missing AppKit-owned native close button")
        }

        closeButton.setFrameOrigin(NSPoint(x: closeButton.frame.minX, y: 9))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)

        let centerFromTop = titlebarContainer.isFlipped
            ? closeButton.frame.midY - titlebarContainer.bounds.minY
            : titlebarContainer.bounds.maxY - closeButton.frame.midY
        XCTAssertEqual(
            centerFromTop,
            chromeHeight / 2,
            accuracy: 0.001,
            "Resize and state transitions must restore the native controls to Monknot's centerline"
        )
    }

    func testPrimaryChromeHeightPreservesTheProvenAdaptiveSpacingCurve() {
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let height = MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
                XCTAssertEqual(
                    height,
                    (MonknotMetrics.chromeHeightBase * theme.interfaceRowScale(zoomScale: zoomScale)).rounded()
                )
            }
        }
    }

    func testInterfaceTokensUseOneCoherentZoomFactor() {
        let theme = AppTheme.defaultDark
        let normal = 1.0

        XCTAssertEqual(theme.interfaceTextScale(zoomScale: normal), 1, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceGlyphScale(zoomScale: normal), 1, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceControlScale(zoomScale: normal), 1, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceRowScale(zoomScale: normal), 1, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceDensityScale(zoomScale: normal), 1, accuracy: 0.001)

        let compactScales = interfaceScales(theme: theme, zoomScale: WorkspaceZoomPolicy.minimum)
        let enlargedScales = interfaceScales(theme: theme, zoomScale: 2)
        let maximumScales = interfaceScales(theme: theme, zoomScale: WorkspaceZoomPolicy.maximum)

        for index in compactScales.indices {
            XCTAssertLessThan(compactScales[index], 1)
            XCTAssertGreaterThan(enlargedScales[index], 1)
            XCTAssertGreaterThanOrEqual(maximumScales[index], enlargedScales[index])
        }

        for scale in maximumScales {
            XCTAssertEqual(scale, 2, accuracy: 0.001)
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

    func testSidebarRowIconsStayTwoPointsLargerThanAdjacentLabels() {
        XCTAssertEqual(MonknotMetrics.sidebarIconPointSizeBase, 15)
        XCTAssertEqual(MonknotMetrics.sidebarIconWeight, .regular)

        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let iconSize = MonknotMetrics.interfaceGlyph(
                    MonknotMetrics.sidebarIconPointSizeBase,
                    theme: theme,
                    zoomScale: zoomScale
                )
                let labelSize = MonknotMetrics.interfaceText(
                    13,
                    theme: theme,
                    zoomScale: zoomScale
                )

                XCTAssertEqual(
                    iconSize - labelSize,
                    MonknotMetrics.interfaceGlyph(2, theme: theme, zoomScale: zoomScale),
                    accuracy: 0.5,
                    "Sidebar symbols outgrew their labels at zoom \(zoomScale)"
                )
            }
        }
    }

    func testSidebarHeaderActionsShareRowSymbolStyleWithoutShrinkingHitTargets() {
        let size = MonknotIconButton.IconButtonSize.sidebarHeader

        XCTAssertEqual(size.iconWeight, MonknotMetrics.sidebarIconWeight)
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                XCTAssertEqual(
                    size.iconSize(theme: theme, zoomScale: zoomScale),
                    MonknotMetrics.interfaceGlyph(16, theme: theme, zoomScale: zoomScale),
                    accuracy: 0.001
                )
                XCTAssertEqual(
                    size.dimension(theme: theme, zoomScale: zoomScale),
                    MonknotMetrics.interfaceControl(22, theme: theme, zoomScale: zoomScale),
                    accuracy: 0.001
                )
            }
        }
    }

    func testTopNavigationOnlyShowsSourceAndPreviewModeButtons() {
        XCTAssertEqual(
            TopNavigationBar.markdownViewModeOptions.map(\.id),
            [EditorMode.source.rawValue, EditorMode.preview.rawValue]
        )
        XCTAssertFalse(
            TopNavigationBar.markdownViewModeOptions.contains { $0.accessibilityLabel == "Split" }
        )
    }

    func testReducedMotionDisablesSidebarAndDrawerMovement() {
        XCTAssertNil(MonknotMotion.sidebarTransition(reduceMotion: true))
        XCTAssertNotNil(MonknotMotion.sidebarTransition(reduceMotion: false))
    }

    func testLongTabTitlesUseAStableCappedWidth() {
        let theme = AppTheme.defaultDark
        let shortWidth = DocumentTabWidthPolicy.preferredWidth(
            title: "README.md",
            isPinned: false,
            theme: theme,
            zoomScale: 1
        )
        let longWidth = DocumentTabWidthPolicy.preferredWidth(
            title: String(repeating: "Remote_Objects_", count: 40) + ".pdf",
            isPinned: false,
            theme: theme,
            zoomScale: 1
        )

        XCTAssertGreaterThan(longWidth, shortWidth)
        XCTAssertLessThanOrEqual(longWidth - shortWidth, MonknotMetrics.tabMaxWidthBase)
    }

    func testTerminalDrawerUsesFullDetailTakeoverBelowReadableSplitWidth() {
        let threshold = MonknotMetrics.editorMinimumReadableWidth
            + MonknotMetrics.terminalDrawerMinWidth
        for availableWidth in [CGFloat(557), threshold - 1] {
            let layout = TerminalDrawerLayoutPolicy.resolve(
                availableWidth: availableWidth,
                preferredDrawerWidth: 600
            )

            XCTAssertEqual(layout.presentation, .takeover)
            XCTAssertEqual(layout.drawerWidth, availableWidth, accuracy: 0.001)
            XCTAssertEqual(layout.maximumDrawerWidth, availableWidth, accuracy: 0.001)
            XCTAssertFalse(layout.isResizable)
        }
    }

    func testDocumentTabsSizeToTheirMeasuredTitles() {
        let theme = AppTheme.defaultDark
        let short = DocumentTabWidthPolicy.preferredWidth(
            title: "a.json",
            isPinned: false,
            theme: theme,
            zoomScale: 1
        )
        let long = DocumentTabWidthPolicy.preferredWidth(
            title: "02-sockets-claude.md",
            isPinned: false,
            theme: theme,
            zoomScale: 1
        )

        XCTAssertGreaterThan(long, short + 40)
        XCTAssertGreaterThanOrEqual(short, MonknotMetrics.tabMinWidthBase)
        XCTAssertLessThanOrEqual(long, MonknotMetrics.tabMaxWidthBase)
    }

    func testPinnedTabsRetainTheirTitleAndPinAffordanceWidth() {
        let theme = AppTheme.defaultDark
        let short = DocumentTabWidthPolicy.preferredWidth(
            title: "a.md",
            isPinned: true,
            theme: theme,
            zoomScale: 1
        )
        let readme = DocumentTabWidthPolicy.preferredWidth(
            title: "README.md",
            isPinned: true,
            theme: theme,
            zoomScale: 1
        )

        XCTAssertGreaterThan(readme, short)
        XCTAssertGreaterThanOrEqual(short, MonknotMetrics.tabMinWidthBase)
        XCTAssertLessThanOrEqual(readme, MonknotMetrics.tabMaxWidthBase)
    }

    func testTabCloseButtonsScaleWithTheSixteenPointTrailingSlot() {
        let theme = AppTheme.defaultDark
        for zoomScale in WorkspaceZoomPolicy.supportedLevels {
            XCTAssertEqual(
                MonknotTabCloseButton.dimension(theme: theme, zoomScale: zoomScale),
                MonknotMetrics.interfaceControl(16, theme: theme, zoomScale: zoomScale),
                accuracy: 0.001
            )
        }
    }

    func testTerminalDrawerSideBySideLayoutProtectsEditorAndPanelMinimums() {
        let threshold = MonknotMetrics.editorMinimumReadableWidth
            + MonknotMetrics.terminalDrawerMinWidth
        let thresholdLayout = TerminalDrawerLayoutPolicy.resolve(
            availableWidth: threshold,
            preferredDrawerWidth: 420
        )
        let preferredLayout = TerminalDrawerLayoutPolicy.resolve(
            availableWidth: 1_000,
            preferredDrawerWidth: 420
        )
        let maximumLayout = TerminalDrawerLayoutPolicy.resolve(
            availableWidth: 1_240,
            preferredDrawerWidth: 900
        )

        XCTAssertEqual(thresholdLayout.presentation, .sideBySide)
        XCTAssertEqual(
            thresholdLayout.drawerWidth,
            MonknotMetrics.terminalDrawerMinWidth,
            accuracy: 0.001
        )
        XCTAssertFalse(thresholdLayout.isResizable)
        XCTAssertEqual(preferredLayout.drawerWidth, 420, accuracy: 0.001)
        XCTAssertTrue(preferredLayout.isResizable)
        XCTAssertEqual(
            maximumLayout.drawerWidth,
            MonknotMetrics.terminalDrawerMaxWidth,
            accuracy: 0.001
        )
    }

    func testDisabledWindowNavigationAvoidsDoubleAttenuation() {
        let size = MonknotIconButton.IconButtonSize.windowNavigation

        XCTAssertEqual(size.disabledControlOpacity, 0.24, accuracy: 0.001)
    }

    func testWindowNavigationUsesReferenceSegmentGeometryAcrossSupportedZooms() {
        let theme = AppTheme.defaultDark
        let navigationSize = MonknotIconButton.IconButtonSize.windowNavigation
        let chromeSize = MonknotIconButton.IconButtonSize.chrome

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {

            XCTAssertEqual(
                navigationSize.dimension(theme: theme, zoomScale: zoomScale),
                chromeSize.dimension(theme: theme, zoomScale: zoomScale),
                accuracy: 0.001
            )
            XCTAssertLessThan(
                navigationSize.height(theme: theme, zoomScale: zoomScale),
                chromeSize.height(theme: theme, zoomScale: zoomScale)
            )
            XCTAssertEqual(
                navigationSize.iconSize(theme: theme, zoomScale: zoomScale),
                MonknotMetrics.interfaceGlyph(16, theme: theme, zoomScale: zoomScale),
                accuracy: 0.001,
                "Navigation chevrons use their specified optical size"
            )
        }
    }

    func testPrimaryAndSecondaryChromePreserveTheirDistinctReferenceBands() {
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let primaryHeight = MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
                let secondaryHeight = MonknotMetrics.chromeSecondaryHeight(
                    theme: theme,
                    zoomScale: zoomScale
                )
                let tabChipHeight = MonknotMetrics.interfaceControl(
                    30,
                    theme: theme,
                    zoomScale: zoomScale
                )

                XCTAssertGreaterThan(
                    primaryHeight,
                    secondaryHeight,
                    "The 44pt titlebar and 34pt formatting row must remain distinct"
                )
                XCTAssertGreaterThanOrEqual(
                    primaryHeight,
                    tabChipHeight,
                    "The active 30pt file chip must fit inside the titlebar"
                )
            }
        }

        XCTAssertEqual(MonknotMetrics.chromeHeight(theme: .defaultDark, zoomScale: 1), 44)
        XCTAssertEqual(MonknotMetrics.chromeSecondaryHeight(theme: .defaultDark, zoomScale: 1), 34)
    }

    func testSegmentButtonsUseReferenceWidthAndShorterReferenceHeight() {
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let segment = MonknotSegmentButton(
                    systemImage: "text.alignleft",
                    accessibilityLabel: "Write",
                    isSelected: true,
                    theme: theme,
                    zoomScale: zoomScale,
                    action: {}
                )
                let toolbarButton = MonknotIconButton(
                    systemImage: "sidebar.right",
                    label: "Show Right Drawer",
                    theme: theme,
                    zoomScale: zoomScale,
                    action: {}
                )
                let segmentHost = NSHostingView(rootView: segment)
                let toolbarButtonHost = NSHostingView(rootView: toolbarButton)

                XCTAssertEqual(
                    segmentHost.fittingSize.width,
                    toolbarButtonHost.fittingSize.width,
                    accuracy: 0.01,
                    "Segment width diverged from toolbar buttons at zoom \(zoomScale)"
                )
                XCTAssertLessThan(
                    segmentHost.fittingSize.height,
                    toolbarButtonHost.fittingSize.height,
                    "Reference segments must remain 24pt high inside the 28pt shell"
                )
            }
        }
    }

    func testWindowNavigationUsesTheSharedReferenceHoverFill() {
        let navigationSize = MonknotIconButton.IconButtonSize.windowNavigation
        let chromeSize = MonknotIconButton.IconButtonSize.chrome

        for isDark in [false, true] {
            XCTAssertEqual(
                navigationSize.hoverBackgroundOpacity(isDark: isDark),
                chromeSize.hoverBackgroundOpacity(isDark: isDark)
            )
        }
    }

    func testChromeButtonsOnlyDrawBackgroundWhileEnabledAndHovered() {
        for size in [
            MonknotIconButton.IconButtonSize.chrome,
            .windowNavigation,
            .sidebarHeader,
            .compact,
            .editorToolbar,
            .findBar,
            .segmented
        ] {
            for isDark in [false, true] {
                XCTAssertNil(
                    size.backgroundOpacity(isHovered: false, isDisabled: false, isDark: isDark),
                    "Idle controls must not create a background"
                )
                XCTAssertNil(
                    size.backgroundOpacity(isHovered: true, isDisabled: true, isDark: isDark),
                    "Disabled controls must not create a hover background"
                )
                XCTAssertNotNil(
                    size.backgroundOpacity(isHovered: true, isDisabled: false, isDark: isDark),
                    "Enabled controls should retain a hover affordance"
                )
            }
        }
    }

    func testSegmentedIconButtonsScaleFromTheThirtyPointEditorReferenceBox() {
        let size = MonknotIconButton.IconButtonSize.segmented

        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                XCTAssertEqual(
                    size.dimension(theme: theme, zoomScale: zoomScale),
                    MonknotMetrics.interfaceControl(30, theme: theme, zoomScale: zoomScale),
                    accuracy: 0.001
                )
            }
        }
    }

    func testOpenPanelButtonsUseTheSharedReferenceHoverSurface() {
        let size = MonknotIconButton.IconButtonSize.chrome

        for isDark in [false, true] {
            XCTAssertEqual(size.activeBackgroundOpacity(isDark: isDark), isDark ? 0.18 : 0.14)
        }
    }

    func testStandardZoomKeysCanRouteToFocusedPDFKit() {
        XCTAssertEqual(
            MonknotNativePDFZoomCommand.action(for: keyEvent("=", modifiers: [.command])),
            .zoomIn
        )
        XCTAssertEqual(
            MonknotNativePDFZoomCommand.action(for: keyEvent("+", modifiers: [.command, .shift])),
            .zoomIn
        )
        XCTAssertEqual(
            MonknotNativePDFZoomCommand.action(for: keyEvent("-", modifiers: [.command])),
            .zoomOut
        )
        XCTAssertEqual(
            MonknotNativePDFZoomCommand.action(for: keyEvent("0", modifiers: [.command])),
            .actualSize
        )
        XCTAssertNil(MonknotNativePDFZoomCommand.action(for: keyEvent("=", modifiers: [])))
        XCTAssertNil(MonknotNativePDFZoomCommand.action(for: keyEvent("=", modifiers: [.command, .option])))
    }

    func testCloseGuardPreservesExistingWindowDelegateCallbacks() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let originalDelegate = StandardFrameWindowDelegate()
        window.delegate = originalDelegate
        let coordinator = WindowCloseGuard.Coordinator(shouldClose: { true })
        coordinator.install(on: window)

        let proposedFrame = NSRect(x: 20, y: 30, width: 800, height: 600)
        let resolvedFrame = window.delegate?.windowWillUseStandardFrame?(
            window,
            defaultFrame: proposedFrame
        )

        XCTAssertEqual(originalDelegate.standardFrameCallCount, 1)
        XCTAssertEqual(resolvedFrame, proposedFrame.insetBy(dx: 12, dy: 12))
    }

    func testExplicitTitleBarGapIsMovableWithoutCustomDoubleClickHandling() {
        let dragView = WindowTitleBarDragArea.NativeTitleBarDragView(frame: .zero)
        let selector = #selector(NSView.mouseDown(with:))
        let nativeImplementation = class_getMethodImplementation(NSView.self, selector)
        let dragImplementation = class_getMethodImplementation(
            WindowTitleBarDragArea.NativeTitleBarDragView.self,
            selector
        )

        XCTAssertTrue(dragView.mouseDownCanMoveWindow)
        XCTAssertEqual(
            nativeImplementation,
            dragImplementation,
            "The drag view must leave double-click interpretation to AppKit"
        )
    }

    func testWindowNavigationControlsUseSharedChromeHeightAtEverySupportedZoom() {
        let theme = AppTheme.defaultDark

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {
            let controls = WindowNavigationControls(
                navigateBack: {},
                navigateForward: {},
                canNavigateBack: true,
                canNavigateForward: true,
                theme: theme,
                zoomScale: zoomScale
            )
            let host = NSHostingView(rootView: controls)

            XCTAssertEqual(
                host.fittingSize.height,
                MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale),
                accuracy: 0.01,
                "Window navigation chrome height drifted at zoom \(zoomScale)"
            )
        }
    }

    func testTerminalPanelRowUsesItsSubordinateThirtySixPointHeader() {
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            let sessions = TerminalSessionCollectionStore()

            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let terminalRow = TerminalDrawerChromeRow(
                    sessions: sessions,
                    workingDirectory: nil,
                    theme: theme,
                    zoomScale: zoomScale,
                    close: {}
                )
                let terminalHost = NSHostingView(rootView: terminalRow.frame(width: 420))
                let expectedHeight = MonknotMetrics.interfaceControl(36, theme: theme, zoomScale: zoomScale)

                XCTAssertEqual(terminalHost.fittingSize.height, expectedHeight, accuracy: 0.01)
            }
        }
    }

    func testTerminalPanelKeepsTabsInAHorizontalScrollContainer() {
        let theme = AppTheme.defaultDark
        let sessions = TerminalSessionCollectionStore()
        XCTAssertNotNil(sessions.createTerminal(in: FileManager.default.temporaryDirectory))
        defer { sessions.stopAll() }

        let drawerHost = NSHostingView(rootView: TerminalDrawerChromeRow(
            sessions: sessions,
            workingDirectory: nil,
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum,
            close: {}
        ))
        drawerHost.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            drawerHost.allDescendantsForTesting().contains { $0 is NSScrollView },
            "The terminal panel must keep excess tabs in a bounded horizontal scroller"
        )
    }

    func testWindowNavigationReserveContainsControlsAtEverySupportedZoom() {
        let theme = AppTheme.defaultDark

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {
            let buttonWidth = MonknotMetrics.windowNavigationButtonDimension(
                theme: theme,
                zoomScale: zoomScale
            )
            let controlsTrailingEdge = MonknotMetrics.trafficLightReserveBase
                + MonknotMetrics.windowNavigationLeadingGap(theme: theme, zoomScale: zoomScale)
                + buttonWidth * 2
                + MonknotMetrics.scale(2, theme: theme, zoomScale: zoomScale)

            XCTAssertGreaterThan(
                MonknotMetrics.windowChromeLeadingReservedWidth(theme: theme, zoomScale: zoomScale),
                controlsTrailingEdge,
                "Window chrome reserve overlapped navigation controls at zoom \(zoomScale)"
            )
        }
    }

    func testTopNavigationControlsUseSharedChromeHeightAcrossSidebarStatesAndZooms() {
        let theme = AppTheme.defaultDark

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {

            for isSidebarVisible in [false, true] {
                let topBar = TopNavigationBar(
                    editorMode: .constant(.source),
                    isSplitViewEnabled: .constant(false),
                    emptyStateTitle: "Monknot",
                    selectedDocument: nil,
                    isBusy: false,
                    isDocumentLoading: false,
                    isSaving: false,
                    theme: theme,
                    zoomScale: zoomScale,
                    isTerminalPresented: true,
                    isSidebarVisible: isSidebarVisible,
                    toggleTerminal: {},
                    toggleSidebar: {},
                    toggleSplitView: {},
                    documentSearch: .constant(DocumentSearchState()),
                    tabs: [],
                    activeTabID: nil,
                    missingTabIDs: [],
                    saveState: { _ in .clean },
                    selectTab: { _ in },
                    closeTab: { _ in },
                    togglePinTab: { _ in },
                    reorderTab: { _, _ in }
                )
                let host = NSHostingView(rootView: topBar.frame(width: 2_000))

                XCTAssertEqual(
                    host.fittingSize.height,
                    MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale),
                    accuracy: 0.01,
                    "Top bar height drifted at zoom \(zoomScale), sidebar visible: \(isSidebarVisible)"
                )
            }
        }
    }

    func testDocumentSearchKeepsScrollableFileTabsMountedInThePrimaryRow() {
        let theme = AppTheme.defaultDark
        var search = DocumentSearchState()
        search.present()
        let tab = WorkspaceTabItem(
            documentID: "/README.md",
            displayName: "README.md",
            relativePath: "README.md",
            kind: .markdown
        )
        let topBar = TopNavigationBar(
            editorMode: .constant(.source),
            isSplitViewEnabled: .constant(false),
            emptyStateTitle: "Monknot",
            selectedDocument: nil,
            isBusy: false,
            isDocumentLoading: false,
            isSaving: false,
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum,
            isTerminalPresented: false,
            isSidebarVisible: true,
            toggleTerminal: {},
            toggleSidebar: {},
            toggleSplitView: {},
            documentSearch: .constant(search),
            tabs: [tab],
            activeTabID: tab.documentID,
            missingTabIDs: [],
            saveState: { _ in .clean },
            selectTab: { _ in },
            closeTab: { _ in },
            togglePinTab: { _ in },
            reorderTab: { _, _ in }
        )
        let host = NSHostingView(rootView: topBar.frame(width: 920))
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.allDescendantsForTesting().contains { $0 is NSScrollView },
            "File tabs must retain horizontal scrolling while document search is visible"
        )
        XCTAssertTrue(
            host.allDescendantsForTesting().contains { $0 is NSTextField },
            "The search field and file tabs should coexist in the same primary row"
        )
        XCTAssertEqual(
            host.fittingSize.height,
            MonknotMetrics.chromeHeight(theme: theme, zoomScale: WorkspaceZoomPolicy.maximum),
            accuracy: 0.01
        )
    }

    func testOutlineRailTracksTheVisibleHeadingAndClampsNestedIndentation() {
        let items = [
            MarkdownOutlineItem(
                id: "a", title: "A", level: 1, location: .init(line: 1, offset: 0)
            ),
            MarkdownOutlineItem(
                id: "b", title: "B", level: 2, location: .init(line: 3, offset: 8)
            ),
        ]

        XCTAssertEqual(
            MarkdownOutlineRailLayout.activeIndex(forVisibleLine: 1, items: items),
            0
        )
        XCTAssertEqual(
            MarkdownOutlineRailLayout.activeIndex(forVisibleLine: 10, items: items),
            1
        )
        XCTAssertNil(MarkdownOutlineRailLayout.activeIndex(forVisibleLine: 1, items: []))
        XCTAssertEqual(MarkdownOutlineRailLayout.leadingIndent(forHeadingLevel: 1), 0)
        XCTAssertEqual(MarkdownOutlineRailLayout.leadingIndent(forHeadingLevel: 3), 14)
        XCTAssertEqual(MarkdownOutlineRailLayout.leadingIndent(forHeadingLevel: 8), 35)
        XCTAssertEqual(MarkdownOutlineRailLayout.markerWidth(forHeadingLevel: 1), 24)
        XCTAssertEqual(MarkdownOutlineRailLayout.markerWidth(forHeadingLevel: 3), 16)
        XCTAssertEqual(MarkdownOutlineRailLayout.markerWidth(forHeadingLevel: 8), 8)
        XCTAssertNil(
            MarkdownOutlineRailLayout.revealAnchor,
            "Outline reveals should scroll only enough to make the heading visible"
        )
        XCTAssertNotNil(MonknotMotion.outlineAnimation(reduceMotion: false))
        XCTAssertNil(MonknotMotion.outlineAnimation(reduceMotion: true))
        XCTAssertEqual(
            MarkdownOutlineRailLayout.revealTargetID(
                hoveredItemID: "hovered",
                focusedItemID: "focused",
                activeItemID: "active"
            ),
            "hovered"
        )
        XCTAssertEqual(
            MarkdownOutlineRailLayout.revealTargetID(
                hoveredItemID: nil,
                focusedItemID: "focused",
                activeItemID: "active"
            ),
            "focused"
        )
        XCTAssertEqual(
            MarkdownOutlineRailLayout.revealTargetID(
                hoveredItemID: nil,
                focusedItemID: nil,
                activeItemID: "active"
            ),
            "active"
        )
    }

    func testMarkdownSyntaxTokenizerCoversEveryReferenceAccent() {
        let markdown = "# Heading\n> Quote\n**Strong** [[Wiki]] [Link](https://example.com) `code`"
        let styles = MarkdownSyntaxTokenizer.tokens(in: markdown).map(\.style)

        for expectedStyle in [
            MarkdownSyntaxStyle.heading,
            .quote,
            .strong,
            .wikilink,
            .link,
            .code,
        ] {
            XCTAssertTrue(styles.contains(expectedStyle))
        }
    }

    func testMarkdownEditorLineHeightTracksHighZoomFontSize() {
        XCTAssertEqual(MarkdownEditorLayout.lineHeight(forFontSize: 13), 22)
        XCTAssertEqual(MarkdownEditorLayout.lineHeight(forFontSize: 39), 57)
        XCTAssertEqual(MarkdownEditorLayout.lineHeight(forFontSize: 120), 174)
        XCTAssertGreaterThan(
            MarkdownEditorLayout.lineHeight(forFontSize: 39),
            39,
            "High-zoom Markdown lines must not overlap"
        )
    }

    func testDocumentTabsUseSharedChromeHeightAtEverySupportedZoom() {
        let theme = AppTheme.defaultDark

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {
            let tabBar = DocumentTabBar(
                tabs: [
                    WorkspaceTabItem(
                        documentID: "/README.md",
                        displayName: "README.md",
                        relativePath: "README.md",
                        kind: .markdown
                    )
                ],
                selectedDocumentID: "/README.md",
                missingDocumentIDs: [],
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: false,
                saveState: { _ in .clean },
                selectTab: { _ in },
                closeTab: { _ in },
                togglePin: { _ in },
                reorderTab: { _, _ in }
            )
            let host = NSHostingView(rootView: tabBar.frame(width: 600))

            XCTAssertEqual(
                host.fittingSize.height,
                MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale),
                accuracy: 0.01,
                "Tab chrome height drifted at zoom \(zoomScale)"
            )
        }
    }

    func testHorizontalTabOverflowStateReportsOnlyClippedTabsAndCorrectEdges() {
        let state = HorizontalTabOverflowState(
            frames: [
                "left": CGRect(x: -36, y: 0, width: 100, height: 44),
                "middle": CGRect(x: 64, y: 0, width: 100, height: 44),
                "right": CGRect(x: 164, y: 0, width: 100, height: 44),
            ],
            viewportWidth: 220
        )

        XCTAssertEqual(state.hiddenIDs, ["left", "right"])
        XCTAssertTrue(state.hasLeadingOverflow)
        XCTAssertTrue(state.hasTrailingOverflow)
        XCTAssertEqual(state.revealEdge(for: "left"), .leading)
        XCTAssertNil(state.revealEdge(for: "middle"))
        XCTAssertEqual(state.revealEdge(for: "right"), .trailing)
    }

    func testHorizontalTabOverflowStateStaysQuietWhenEveryTabFits() {
        let state = HorizontalTabOverflowState(
            frames: [
                "a": CGRect(x: 0, y: 0, width: 100, height: 44),
                "b": CGRect(x: 100, y: 0, width: 100, height: 44),
            ],
            viewportWidth: 200
        )

        XCTAssertTrue(state.hiddenIDs.isEmpty)
        XCTAssertFalse(state.hasLeadingOverflow)
        XCTAssertFalse(state.hasTrailingOverflow)
        XCTAssertNil(state.revealEdge(for: "a"))
        XCTAssertNil(state.revealEdge(for: "b"))
    }

    func testHorizontalTabRevealRequestIsOneShotSoManualScrollingRemainsAuthoritative() {
        var request = HorizontalTabRevealRequest()
        let frames = [
            "left": CGRect(x: -80, y: 0, width: 70, height: 28),
            "active": CGRect(x: 140, y: 0, width: 70, height: 28)
        ]

        request.request("active")
        let action = request.consume(frames: frames, viewportWidth: 180)

        XCTAssertEqual(action?.id, "active")
        XCTAssertEqual(action?.edge, .trailing)
        XCTAssertNil(request.pendingID)
        XCTAssertNil(request.consume(frames: frames, viewportWidth: 180))
    }

    func testHorizontalTabRevealRequestWaitsForMeasurementAndConsumesVisibleTabs() {
        var request = HorizontalTabRevealRequest()
        request.request("active")

        XCTAssertNil(request.consume(frames: [:], viewportWidth: 180))
        XCTAssertEqual(request.pendingID, "active")

        XCTAssertNil(request.consume(
            frames: ["active": CGRect(x: 40, y: 0, width: 70, height: 28)],
            viewportWidth: 180
        ))
        XCTAssertNil(request.pendingID)
    }

    func testMountedDocumentTabBarSupportsHorizontalScrolling() async {
        let theme = AppTheme.defaultDark
        let tabs = (0..<10).map { index in
            WorkspaceTabItem(
                documentID: "tab-\(index)",
                displayName: "Long production document \(index).md",
                relativePath: "Long production document \(index).md",
                kind: .markdown
            )
        }
        let chromeHeight = MonknotMetrics.chromeHeight(
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum
        )
        let host = NSHostingView(rootView: DocumentTabBar(
            tabs: tabs,
            selectedDocumentID: tabs[0].documentID,
            missingDocumentIDs: [],
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum,
            isDisabled: false,
            saveState: { _ in .clean },
            selectTab: { _ in },
            closeTab: { _ in },
            togglePin: { _ in },
            reorderTab: { _, _ in }
        ).frame(width: 320, height: chromeHeight))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: chromeHeight)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        try? await Task.sleep(nanoseconds: 150_000_000)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let horizontalScrollView = host.allDescendantsForTesting()
            .compactMap { $0 as? NSScrollView }
            .first { scrollView in
                guard let documentView = scrollView.documentView else { return false }
                return documentView.frame.width > scrollView.contentView.bounds.width + 1
            }

        guard let horizontalScrollView,
              let documentView = horizontalScrollView.documentView
        else {
            return XCTFail("Overflowing file tabs must remain available in a horizontal scroll strip")
        }
        XCTAssertGreaterThan(
            documentView.frame.width - horizontalScrollView.contentView.bounds.width,
            500,
            "The tab strip should retain its full content width instead of hiding excess tabs"
        )
    }

    func testMountedTerminalTabsKeepManualHorizontalScrollPosition() async {
        let theme = AppTheme.defaultDark
        let sessions = TerminalSessionCollectionStore()
        for _ in 0..<10 {
            XCTAssertNotNil(sessions.createTerminal(in: FileManager.default.temporaryDirectory))
        }
        defer { sessions.stopAll() }

        let chromeHeight = MonknotMetrics.chromeHeight(
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum
        )
        let host = NSHostingView(rootView: TerminalDrawerChromeRow(
            sessions: sessions,
            workingDirectory: FileManager.default.temporaryDirectory,
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum,
            close: {}
        ).frame(width: 180, height: chromeHeight))
        host.frame = NSRect(x: 0, y: 0, width: 180, height: chromeHeight)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        try? await Task.sleep(nanoseconds: 150_000_000)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let horizontalScrollView = host.allDescendantsForTesting()
            .compactMap { $0 as? NSScrollView }
            .first { scrollView in
                guard let documentView = scrollView.documentView else { return false }
                return documentView.frame.width > scrollView.contentView.bounds.width + 1
            }

        guard let horizontalScrollView,
              let documentView = horizontalScrollView.documentView
        else {
            return XCTFail("Mounted terminal overflow must expose a horizontal scroll container")
        }

        let maximumOffset = documentView.frame.width - horizontalScrollView.contentView.bounds.width
        XCTAssertGreaterThan(maximumOffset, 80)

        horizontalScrollView.contentView.scroll(to: NSPoint(x: 60, y: 0))
        horizontalScrollView.reflectScrolledClipView(horizontalScrollView.contentView)
        let manualOffset = horizontalScrollView.contentView.bounds.origin.x
        XCTAssertEqual(manualOffset, 60, accuracy: 1)

        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            horizontalScrollView.contentView.bounds.origin.x,
            manualOffset,
            accuracy: 1,
            "Manual terminal-tab scrolling was overridden by active-tab reveal"
        )
    }

    func testTerminalUsesCompactTopPaddingBelowItsChrome() {
        let theme = AppTheme.defaultDark
        let html = TerminalWebView.html(
            theme: theme,
            fontSize: 13.5,
            usePointerCursors: true,
            fontSmoothing: true
        )

        XCTAssertTrue(html.contains("padding: 10px 12px;"))
        XCTAssertFalse(html.contains("padding: 18px 20px;"))
        XCTAssertTrue(html.contains("new ResizeObserver"))
        XCTAssertTrue(html.contains("width: 12px;"))
        XCTAssertTrue(html.contains("--terminal-bg: \(theme.terminalSurfaceHex);"))
        XCTAssertTrue(html.contains("background: '\(theme.terminalSurfaceHex)'"))
        XCTAssertFalse(html.contains("background: '\(theme.background)'"))
    }

    func testTerminalFontUsesTheSameWorkspaceZoomAsDocumentContent() {
        let theme = AppTheme.defaultDark
        let minimum = TerminalDrawerView.terminalFontSize(
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.minimum
        )
        let normal = TerminalDrawerView.terminalFontSize(theme: theme, zoomScale: 1)
        let maximum = TerminalDrawerView.terminalFontSize(
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum
        )
        let maximumDocumentFont = TerminalDrawerView.fontSizeBase
            * WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.maximum)

        XCTAssertLessThan(minimum, normal)
        XCTAssertEqual(normal, TerminalDrawerView.fontSizeBase, accuracy: 0.001)
        XCTAssertEqual(maximum, 27, accuracy: 0.001)
        XCTAssertGreaterThan(maximum, normal)
        XCTAssertEqual(maximum, maximumDocumentFont, accuracy: 0.001)
    }
}

private func interfaceScales(theme: AppTheme, zoomScale: Double) -> [CGFloat] {
    [
        theme.interfaceTextScale(zoomScale: zoomScale),
        theme.interfaceGlyphScale(zoomScale: zoomScale),
        theme.interfaceControlScale(zoomScale: zoomScale),
        theme.interfaceRowScale(zoomScale: zoomScale),
        theme.interfaceDensityScale(zoomScale: zoomScale),
    ]
}

private enum TestViewRenderingError: Error {
    case missingBitmap
    case missingTIFFData
}

@MainActor
private func renderedTIFF(of view: NSView) throws -> Data {
    view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw TestViewRenderingError.missingBitmap
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.tiffRepresentation else {
        throw TestViewRenderingError.missingTIFFData
    }
    return data
}

private extension NSView {
    func allDescendantsForTesting() -> [NSView] {
        subviews + subviews.flatMap { $0.allDescendantsForTesting() }
    }

}

private struct ChromeColumnOriginFixture: View {
    let chromeHeight: CGFloat

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ChromeOriginMarker(identifier: "sidebar")
                    .frame(maxWidth: .infinity)
                    .frame(height: chromeHeight)
                Spacer(minLength: 0)
            }
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
                .ignoresSafeArea(.container, edges: .top)

            VStack(spacing: 0) {
                ChromeOriginMarker(identifier: "detail")
                    .frame(maxWidth: .infinity)
                    .frame(height: chromeHeight)
                Spacer(minLength: 0)
            }
                .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .topLeading) {
            ChromeOriginMarker(identifier: "navigation")
                .frame(width: 160, height: chromeHeight)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct ChromeOriginMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier("Monknot.Test.Chrome.\(identifier)")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private func keyEvent(
    _ characters: String,
    modifiers: NSEvent.ModifierFlags
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    )!
}

private final class StandardFrameWindowDelegate: NSObject, NSWindowDelegate {
    var standardFrameCallCount = 0

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        standardFrameCallCount += 1
        return newFrame.insetBy(dx: 12, dy: 12)
    }
}
