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
            "Sources/MonknotCore/Resources/editor.css",
            "Sources/MonknotCore/Resources/editor.js",
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
        XCTAssertTrue(script.contains("<string>net.daringfireball.markdown</string>"))
        // A public.data claim makes LaunchServices treat the app as a wildcard handler, which keeps it
        // out of Finder's Open With menu for every specific file type.
        XCTAssertFalse(script.contains("<string>public.data</string>"))
        XCTAssertTrue(script.contains("<string>openInMonknot</string>"))
        XCTAssertTrue(script.contains("<key>LSSupportsOpeningDocumentsInPlace</key>"))

        // Video and audio open in the player, from Open With and from the Services menu alike. The
        // claims name the formats AVFoundation plays rather than public.movie or public.audio.
        XCTAssertTrue(script.contains("<string>Video or Audio</string>"))
        XCTAssertFalse(script.contains("<string>public.movie</string>"))
        XCTAssertFalse(script.contains("<string>public.audio</string>"))
        for mediaType in [
            "com.apple.quicktime-movie", "public.mpeg-4", "com.apple.m4v-video", "public.mpeg",
            "public.mp3", "com.apple.m4a-audio", "public.aac-audio", "com.microsoft.waveform-audio",
            "public.aiff-audio", "com.apple.coreaudio-format", "org.xiph.flac",
        ] {
            XCTAssertEqual(
                script.components(separatedBy: "<string>\(mediaType)</string>").count - 1,
                2,
                "\(mediaType) must be both an openable document type and a Services file type"
            )
        }
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
