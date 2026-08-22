import Foundation
import XCTest

final class ManualBuildContractTests: RepositoryContractTestCase {
    func testManualBuildScriptListsAllSwiftSources() throws {
        let root = repositoryRoot
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)

        let coreSources = try sourceEntries(named: "CORE_SOURCES", in: script)
        let appSources = try sourceEntries(named: "APP_SOURCES", in: script)

        XCTAssertEqual(
            coreSources,
            try swiftSources(under: root.appendingPathComponent("Sources/MonknotCore")),
            "script/build_and_run.sh CORE_SOURCES must stay in sync with Sources/MonknotCore"
        )
        XCTAssertEqual(
            appSources,
            try swiftSources(under: root.appendingPathComponent("Sources/Monknot")),
            "script/build_and_run.sh APP_SOURCES must stay in sync with Sources/Monknot"
        )
    }

    func testManualBuildScriptCopiesRuntimeResources() throws {
        let root = repositoryRoot
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)

        let requiredResources = [
            "Sources/MonknotCore/Resources/preview.css",
            "Sources/MonknotCore/Resources/renderer.js",
            "Sources/Monknot/Resources/xterm.css",
            "Sources/Monknot/Resources/xterm.js",
            "Sources/Monknot/Resources/xterm-addon-fit.js",
            "Sources/Monknot/Resources/xterm-addon-search.js",
            "LICENSE",
            "THIRD_PARTY_NOTICES.md",
            "ThirdPartyLicenses/xterm-MIT.txt",
            "ThirdPartyLicenses/xterm-addon-fit-MIT.txt",
            "ThirdPartyLicenses/xterm-addon-search-MIT.txt",
            "ThirdPartyLicenses/sparkle-MIT.txt",
        ]
        let themeLicenseFiles = [
            "theme-ayu-MIT.txt", "theme-catppuccin-MIT.txt", "theme-dracula-MIT.txt",
            "theme-everforest-MIT.txt", "theme-night-owl-MIT.txt", "theme-nord-MIT.txt",
            "theme-one-dark-MIT.txt", "theme-one-light-MIT.txt", "theme-oscura-MIT.txt",
            "theme-rose-pine-MIT.txt", "theme-solarized-MIT.txt", "theme-tokyo-night-MIT.txt",
        ]

        for resource in requiredResources {
            XCTAssertTrue(
                script.contains(resource),
                "script/build_and_run.sh must copy \(resource)"
            )
        }
        for licenseFile in themeLicenseFiles {
            XCTAssertTrue(script.contains(licenseFile), "manual build must list \(licenseFile)")
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("ThirdPartyLicenses/\(licenseFile)").path
                ),
                "missing theme license \(licenseFile)"
            )
        }
    }

    func testManualBuildScriptCompilesTargetScopedAppIconAssetCatalog() throws {
        let root = repositoryRoot
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("Sources/Monknot/Resources/Assets.xcassets"))
        XCTAssertTrue(script.contains("xcrun actool"))
        XCTAssertTrue(script.contains("--app-icon \"$APP_ICON_NAME\""))
        XCTAssertTrue(script.contains("cp \"$APP_ICON_ASSETS_CAR\" \"$APP_RESOURCES/Assets.car\""))
        XCTAssertTrue(script.contains("<key>CFBundleIconName</key>"))
        XCTAssertFalse(script.contains("iconutil"))
    }

    func testManualBundleDeclaresOpenableFilesAndFolders() throws {
        let root = repositoryRoot
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("<key>CFBundleURLTypes</key>"))
        XCTAssertTrue(script.contains("<string>monknot</string>"))
        XCTAssertTrue(script.contains("<key>CFBundleDocumentTypes</key>"))
        XCTAssertTrue(script.contains("<string>public.folder</string>"))
        XCTAssertTrue(script.contains("<string>public.data</string>"))
        XCTAssertTrue(script.contains("<key>LSSupportsOpeningDocumentsInPlace</key>"))
    }

    func testRunActionUsesManualBuildScript() throws {
        let root = repositoryRoot
        let environment = try String(
            contentsOf: root.appendingPathComponent(".codex/environments/environment.toml"),
            encoding: .utf8
        )

        XCTAssertTrue(environment.contains("name = \"Run\""))
        XCTAssertTrue(environment.contains("icon = \"run\""))
        XCTAssertTrue(environment.contains("command = \"./script/build_and_run.sh\""))
    }

    func testManualAppBuildSupportsAppleSiliconOnly() throws {
        let root = repositoryRoot
        let script = try String(
            contentsOf: root.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains(#"if [[ "$TARGET_ARCH" != "arm64" ]]; then"#))
        XCTAssertFalse(script.contains("arm64|x86_64"))
    }
}
