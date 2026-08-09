import Combine
import Foundation
import Sparkle
import XCTest
@testable import MonknotApp

@MainActor
final class SparkleUpdateSettingsTests: XCTestCase {
    private let sparklePreferenceKeys = [
        "SUEnableAutomaticChecks",
        "SUAutomaticallyUpdate",
        "SUScheduledCheckInterval",
    ]

    func testSettingsReadAndWriteTheSparkleUpdaterDirectly() {
        withIsolatedSparklePreferences { updater, defaults in
            let monknotUpdateKeysBefore = monknotUpdatePreferenceKeys(in: defaults)
            let sparklePreferencesBeforeReading = sparklePreferences(in: defaults)
            let settings = SparkleUpdateSettings(updater: updater)

            XCTAssertTrue(settings.automaticallyChecksForUpdates)
            XCTAssertFalse(settings.automaticallyDownloadsUpdates)
            XCTAssertTrue(settings.canChangeAutomaticallyDownloadsUpdates)
            XCTAssertEqual(
                sparklePreferences(in: defaults),
                sparklePreferencesBeforeReading,
                "Reading Settings must not replace Sparkle's preferences with Monknot defaults"
            )

            settings.automaticallyDownloadsUpdates = true
            XCTAssertTrue(updater.automaticallyDownloadsUpdates)
            XCTAssertEqual(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool, true)

            settings.automaticallyChecksForUpdates = false
            XCTAssertFalse(updater.automaticallyChecksForUpdates)
            XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false)
            XCTAssertEqual(
                monknotUpdatePreferenceKeys(in: defaults),
                monknotUpdateKeysBefore,
                "Update controls must not create a second Monknot preference owner"
            )
        }
    }

    func testTurningChecksOffDisablesDownloadsWithoutDiscardingSparklesChoice() {
        withIsolatedSparklePreferences { updater, defaults in
            updater.automaticallyDownloadsUpdates = true
            let settings = SparkleUpdateSettings(updater: updater)

            settings.automaticallyChecksForUpdates = false

            XCTAssertFalse(settings.automaticallyChecksForUpdates)
            XCTAssertFalse(settings.automaticallyDownloadsUpdates)
            XCTAssertFalse(settings.canChangeAutomaticallyDownloadsUpdates)
            XCTAssertEqual(
                defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool,
                true,
                "Disabling checks must not overwrite Sparkle's saved download choice"
            )

            settings.automaticallyChecksForUpdates = true

            XCTAssertTrue(settings.canChangeAutomaticallyDownloadsUpdates)
            XCTAssertTrue(settings.automaticallyDownloadsUpdates)
        }
    }

    func testExternalSparkleChangesInvalidateTheDirectBindings() {
        withIsolatedSparklePreferences { updater, _ in
            let settings = SparkleUpdateSettings(updater: updater)
            var invalidationCount = 0
            let observation = settings.objectWillChange.sink {
                invalidationCount += 1
            }

            updater.automaticallyDownloadsUpdates = true

            XCTAssertGreaterThan(invalidationCount, 0)
            XCTAssertTrue(settings.automaticallyDownloadsUpdates)
            withExtendedLifetime(observation) {}
        }
    }

    private func withIsolatedSparklePreferences(
        _ body: (SPUUpdater, UserDefaults) -> Void
    ) {
        let defaults = UserDefaults.standard
        let previousValues = sparklePreferenceKeys.map { key in
            (key, defaults.object(forKey: key))
        }
        defer {
            for (key, value) in previousValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        defaults.set(false, forKey: "SUAutomaticallyUpdate")
        defaults.set(3_600.0, forKey: "SUScheduledCheckInterval")

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        body(controller.updater, defaults)
        withExtendedLifetime(controller) {}
    }

    private func sparklePreferences(in defaults: UserDefaults) -> [String: AnyHashable] {
        Dictionary(uniqueKeysWithValues: sparklePreferenceKeys.compactMap { key in
            guard let value = defaults.object(forKey: key) as? AnyHashable else { return nil }
            return (key, value)
        })
    }

    private func monknotUpdatePreferenceKeys(in defaults: UserDefaults) -> Set<String> {
        Set(defaults.dictionaryRepresentation().keys.filter { key in
            key.hasPrefix("Monknot.") && key.localizedCaseInsensitiveContains("update")
        })
    }
}
