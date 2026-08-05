import Foundation
import XCTest

final class BuildScriptSyncTests: XCTestCase {
    func testManualBuildScriptListsAllSwiftSources() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
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
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)

        let requiredResources = [
            "Sources/MonknotCore/Resources/preview.css",
            "Sources/MonknotCore/Resources/renderer.js",
            "Sources/Monknot/Resources/xterm.css",
            "Sources/Monknot/Resources/xterm.js",
            "Sources/Monknot/Resources/xterm-addon-fit.js",
            "LICENSE",
            "THIRD_PARTY_NOTICES.md",
            "ThirdPartyLicenses/xterm-MIT.txt",
            "ThirdPartyLicenses/xterm-addon-fit-MIT.txt"
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

    func testProjectLicenseIsProprietaryAndThirdPartyMITNoticesRemainSeparate() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let projectLicense = try String(contentsOf: root.appendingPathComponent("LICENSE"), encoding: .utf8)
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let notices = try String(contentsOf: root.appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
        let audit = try String(contentsOf: root.appendingPathComponent("LICENSE_AUDIT.md"), encoding: .utf8)
        let xtermLicense = try String(
            contentsOf: root.appendingPathComponent("ThirdPartyLicenses/xterm-MIT.txt"),
            encoding: .utf8
        )
        let addonLicense = try String(
            contentsOf: root.appendingPathComponent("ThirdPartyLicenses/xterm-addon-fit-MIT.txt"),
            encoding: .utf8
        )
        let buildScript = try String(
            contentsOf: root.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
        let themeCatalog = try String(
            contentsOf: root.appendingPathComponent("Sources/MonknotCore/Models/MonknotThemeCatalog.swift"),
            encoding: .utf8
        )

        let expectedProjectLicense = """
        Copyright © 2026 Rojhat Toptamuş. All rights reserved.

        The source code and associated documentation contained in this repository are proprietary and confidential.

        No part of this software may be copied, modified, distributed, published, sublicensed, sold, or used to create derivative works without the prior written permission of the copyright holder, except where permitted under a separate written agreement or required by applicable law.

        Third-party software included in or used by this project remains subject to its respective license terms.
        """

        XCTAssertEqual(projectLicense.trimmingCharacters(in: .whitespacesAndNewlines), expectedProjectLicense)
        XCTAssertFalse(projectLicense.contains("MIT License"))
        XCTAssertTrue(readme.contains("Monknot is proprietary software."))
        XCTAssertFalse(readme.contains("Monknot is available under"))
        XCTAssertTrue(
            readme.contains(
                """
                ## License

                Monknot is proprietary software.

                Copyright © 2026 Rojhat Toptamuş. All rights reserved.

                Third-party components remain subject to their respective license terms.
                """
            )
        )
        XCTAssertTrue(notices.contains("@xterm/xterm` 5.5.0"))
        XCTAssertTrue(notices.contains("@xterm/addon-fit` 0.10.0"))
        XCTAssertTrue(notices.contains("9ba6c00a195c95fcf8292a2b9084d91450e5daae"))
        XCTAssertTrue(xtermLicense.contains("Permission is hereby granted, free of charge"))
        XCTAssertTrue(addonLicense.contains("Permission is hereby granted, free of charge"))
        XCTAssertTrue(audit.contains("Not cleared for production or Mac App Store release."))
        XCTAssertTrue(audit.contains("Owner-provided replacement palettes"))
        XCTAssertTrue(audit.contains("Cleared by project-owner representation"))
        XCTAssertTrue(audit.contains("Original authorship confirmation pending"))
        XCTAssertTrue(audit.contains("App icon PNG set"))
        XCTAssertTrue(buildScript.contains("Copyright © 2026 Rojhat Toptamuş. All rights reserved."))
        XCTAssertTrue(buildScript.contains("verify_plist_value NSHumanReadableCopyright"))

        let presetNamePattern = try NSRegularExpression(pattern: #"name: "([^"]+)""#)
        let themeRange = NSRange(themeCatalog.startIndex..<themeCatalog.endIndex, in: themeCatalog)
        let presetNames = Set<String>(presetNamePattern.matches(in: themeCatalog, range: themeRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: themeCatalog) else { return nil }
            return String(themeCatalog[range])
        })
        XCTAssertFalse(presetNames.isEmpty)
        for presetName in presetNames {
            XCTAssertTrue(audit.contains(presetName), "LICENSE_AUDIT.md must classify the \(presetName) theme")
        }
    }

    func testManualBuildScriptCompilesTargetScopedAppIconAssetCatalog() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("Sources/Monknot/Resources/Assets.xcassets"))
        XCTAssertTrue(script.contains("xcrun actool"))
        XCTAssertTrue(script.contains("--app-icon \"$APP_ICON_NAME\""))
        XCTAssertTrue(script.contains("cp \"$APP_ICON_ASSETS_CAR\" \"$APP_RESOURCES/Assets.car\""))
        XCTAssertTrue(script.contains("<key>CFBundleIconName</key>"))
        XCTAssertFalse(script.contains("iconutil"))
    }

    func testManualBundleDeclaresOpenableFilesAndFolders() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("<key>CFBundleURLTypes</key>"))
        XCTAssertTrue(script.contains("<string>monknot</string>"))
        XCTAssertTrue(script.contains("<key>CFBundleDocumentTypes</key>"))
        XCTAssertTrue(script.contains("<string>public.folder</string>"))
        XCTAssertTrue(script.contains("<string>public.data</string>"))
        XCTAssertTrue(script.contains("<key>LSSupportsOpeningDocumentsInPlace</key>"))
    }

    func testManualBundleHasReleaseMetadataAndConfigurableDevelopmentSignature() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("com.monknot.app"))
        XCTAssertTrue(script.contains("<key>CFBundleShortVersionString</key>"))
        XCTAssertTrue(script.contains("<key>CFBundleVersion</key>"))
        XCTAssertTrue(script.contains("<key>CFBundleName</key>"))
        XCTAssertTrue(script.contains("<key>CFBundleDisplayName</key>"))
        XCTAssertTrue(script.contains("<key>CFBundleExecutable</key>"))
        XCTAssertTrue(script.contains("<key>CFBundlePackageType</key>"))
        XCTAssertTrue(script.contains("<key>LSMinimumSystemVersion</key>"))
        XCTAssertTrue(script.contains("<key>LSApplicationCategoryType</key>"))
        XCTAssertTrue(script.contains("-target \"$TARGET_TRIPLE\""))
        XCTAssertTrue(script.contains("-O"))
        XCTAssertTrue(script.contains("xcrun vtool -show-build"))
        XCTAssertTrue(script.contains("MONKNOT_SIGNING_MODE"))
        XCTAssertTrue(script.contains("MONKNOT_DEVELOPMENT_IDENTITY"))
        XCTAssertTrue(script.contains("MONKNOT_DEVELOPMENT_TEAM_ID"))
        XCTAssertTrue(script.contains("ZD35XP4V7D"))
        XCTAssertTrue(script.contains("security find-identity -v -p codesigning"))
        XCTAssertTrue(script.contains("codesign --force --sign \"$SIGN_IDENTITY\""))
        XCTAssertTrue(script.contains("rm -f \"$APP_CONTENTS/embedded.provisionprofile\""))
        XCTAssertTrue(script.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(script.contains("APP_LEGAL_RESOURCES"))
    }

    func testAppStorePackagingUsesDedicatedSandboxedSigningFlow() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(
            contentsOf: root.appendingPathComponent("script/app_store_package.sh"),
            encoding: .utf8
        )
        let entitlements = try String(
            contentsOf: root.appendingPathComponent("config/MonknotAppStore.entitlements"),
            encoding: .utf8
        )

        XCTAssertTrue(script.hasPrefix("#!/usr/bin/env bash"))
        XCTAssertTrue(script.contains("MONKNOT_APP_STORE_APP_IDENTITY"))
        XCTAssertTrue(script.contains("MONKNOT_APP_STORE_INSTALLER_IDENTITY"))
        XCTAssertTrue(script.contains("MONKNOT_APP_STORE_PROVISIONING_PROFILE"))
        XCTAssertTrue(script.contains("MONKNOT_SIGNING_MODE=adhoc"))
        XCTAssertTrue(script.contains("codesign --force --sign \"$APP_IDENTITY\" \"$FRAMEWORK\""))
        XCTAssertTrue(script.contains("--entitlements \"$ENTITLEMENTS\""))
        XCTAssertTrue(script.contains("productbuild"))
        XCTAssertTrue(script.contains("pkgutil --check-signature"))
        XCTAssertTrue(script.contains("pkgutil --payload-files"))
        XCTAssertTrue(script.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(script.contains("TEAM_ID=\"ZD35XP4V7D\""))
        XCTAssertTrue(script.contains("BUNDLE_ID=\"com.monknot.app\""))
        XCTAssertTrue(script.contains("APPLICATION_IDENTIFIER=\"$TEAM_ID.$BUNDLE_ID\""))
        XCTAssertTrue(script.contains("RELEASE_COMPLIANCE_BLOCKER"))

        XCTAssertTrue(entitlements.contains("com.apple.application-identifier"))
        XCTAssertTrue(entitlements.contains("ZD35XP4V7D.com.monknot.app"))
        XCTAssertTrue(entitlements.contains("com.apple.developer.team-identifier"))
        XCTAssertTrue(entitlements.contains("com.apple.security.app-sandbox"))
        XCTAssertTrue(entitlements.contains("com.apple.security.files.user-selected.read-write"))
        XCTAssertTrue(entitlements.contains("com.apple.security.files.bookmarks.app-scope"))
        XCTAssertFalse(entitlements.contains("com.apple.security.network.client"))
    }

    func testHTMLPreviewDisablesWorkspaceAuthoredJavaScript() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Monknot/Views/HTMLPreviewView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("defaultWebpagePreferences.allowsContentJavaScript = false"))
        XCTAssertTrue(source.contains("addUserScript(Coordinator.previewBehaviorScript)"))
    }

    func testRunActionUsesManualBuildScript() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let environment = try String(
            contentsOf: root.appendingPathComponent(".codex/environments/environment.toml"),
            encoding: .utf8
        )

        XCTAssertTrue(environment.contains("name = \"Run\""))
        XCTAssertTrue(environment.contains("icon = \"run\""))
        XCTAssertTrue(environment.contains("command = \"./script/build_and_run.sh\""))
    }

    func testReleasePreflightChecksAdHocAndDeveloperIDRequirements() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let scriptURL = root.appendingPathComponent("script/release_preflight.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.hasPrefix("#!/usr/bin/env bash"))
        XCTAssertTrue(script.contains("Developer ID Application"))
        XCTAssertTrue(script.contains("--adhoc"))
        XCTAssertTrue(script.contains("--allow-missing-identity"))
        XCTAssertTrue(script.contains("Signature=adhoc"))
        XCTAssertTrue(script.contains("Authority=Developer ID Application"))
        XCTAssertTrue(script.contains("CFBundleShortVersionString"))
        XCTAssertTrue(script.contains("SECRET_PATTERN"))
        XCTAssertTrue(script.contains("git ls-files --others --exclude-standard -z"))
        XCTAssertTrue(script.contains("git rev-list --all"))
        XCTAssertTrue(script.contains("reachable Git history"))
        XCTAssertTrue(script.contains("Legal/THIRD_PARTY_NOTICES.md"))
        XCTAssertTrue(script.contains("xcrun vtool -show-build"))
        XCTAssertTrue(script.contains("third-party resource hash"))
        XCTAssertTrue(script.contains("RELEASE_COMPLIANCE_BLOCKER"))
        XCTAssertTrue(script.contains("theme-tokyo-night-MIT.txt"))
    }

    func testReleasePackageSupportsAdHocAndNotarizedDMGs() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let scriptURL = root.appendingPathComponent("script/release_package.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.hasPrefix("#!/usr/bin/env bash"))
        XCTAssertTrue(script.contains("script/build_and_run.sh\" --build"))
        XCTAssertTrue(script.contains("MONKNOT_SIGNING_MODE=adhoc"))
        XCTAssertTrue(script.contains("Developer ID Application"))
        XCTAssertTrue(script.contains("codesign --force --options runtime --timestamp --sign"))
        XCTAssertTrue(script.contains("hdiutil create -volname Monknot"))
        XCTAssertTrue(script.contains("xcrun notarytool submit"))
        XCTAssertTrue(script.contains("xcrun stapler staple"))
        XCTAssertTrue(script.contains("spctl --assess"))
        XCTAssertTrue(script.contains("--adhoc"))
        XCTAssertTrue(script.contains("--skip-notarize"))
        XCTAssertTrue(script.contains("--dry-run"))
        XCTAssertTrue(script.contains("ln -s /Applications"))
        XCTAssertTrue(script.contains("shasum -a 256"))
        XCTAssertTrue(script.contains("MONKNOT_TARGET_TRIPLE"))
        XCTAssertTrue(script.contains("VERSION"))
        XCTAssertTrue(script.contains("RELEASE_COMPLIANCE_BLOCKER"))
    }

    func testReleaseArtifactVerifierChecksMountedDistribution() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let scriptURL = root.appendingPathComponent("script/verify_release_artifact.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.hasPrefix("#!/usr/bin/env bash"))
        XCTAssertTrue(script.contains("hdiutil verify"))
        XCTAssertTrue(script.contains("hdiutil attach -readonly -nobrowse"))
        XCTAssertTrue(script.contains("shasum -a 256 -c"))
        XCTAssertTrue(script.contains("Contents/Resources"))
        XCTAssertTrue(script.contains("Legal/ThirdParty/xterm-MIT.txt"))
        XCTAssertTrue(script.contains("Legal/ThirdParty/xterm-addon-fit-MIT.txt"))
        XCTAssertTrue(script.contains("theme-ayu-MIT.txt"))
        XCTAssertTrue(script.contains("theme-tokyo-night-MIT.txt"))
        XCTAssertTrue(script.contains("RELEASE_COMPLIANCE_BLOCKER"))
        XCTAssertTrue(script.contains("xcrun vtool -show-build"))
        XCTAssertTrue(script.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(script.contains("CFFIXED_USER_HOME"))
        XCTAssertTrue(script.contains("unexpected top-level DMG item"))
    }

    func testTagReleaseWorkflowBuildsBothArchitecturesAndCreatesDraft() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let workflowURL = root.appendingPathComponent(".github/workflows/release.yml")
        let workflow = try String(contentsOf: workflowURL, encoding: .utf8)

        XCTAssertTrue(workflow.contains("tags:"))
        XCTAssertTrue(workflow.contains("- \"v*\""))
        XCTAssertTrue(workflow.contains("release tag must point to a commit reachable from origin/main"))
        XCTAssertTrue(workflow.contains("macos-15"))
        XCTAssertTrue(workflow.contains("macos-15-intel"))
        XCTAssertTrue(workflow.contains("arch: arm64"))
        XCTAssertTrue(workflow.contains("arch: x86_64"))
        XCTAssertTrue(workflow.contains("Xcode_26.3.app"))
        XCTAssertTrue(workflow.contains("macOS 26 SDK or newer is required"))
        XCTAssertFalse(workflow.contains("Xcode_16.4.app"))
        XCTAssertTrue(workflow.contains("swift build -c release --product monknot-export"))
        XCTAssertTrue(workflow.contains("swift build -c release --product monknot-capture"))
        XCTAssertTrue(workflow.contains("swift test"))
        XCTAssertTrue(workflow.contains("swift run monknot-export --help"))
        XCTAssertTrue(workflow.contains("swift run monknot-capture --help"))
        XCTAssertTrue(workflow.contains("script/release_package.sh"))
        XCTAssertTrue(workflow.contains("script/verify_release_artifact.sh"))
        XCTAssertTrue(workflow.contains("--draft"))
        XCTAssertTrue(workflow.contains("SHA256SUMS-macOS.txt"))
        XCTAssertTrue(workflow.contains("shasum -a 256 -c"))
        XCTAssertNotNil(
            workflow.range(
                of: #"actions/attest@[0-9a-f]{40} # v4"#,
                options: .regularExpression
            )
        )
        XCTAssertFalse(workflow.contains("actions/checkout@v"))
        XCTAssertFalse(workflow.contains("actions/upload-artifact@v"))
        XCTAssertFalse(workflow.contains("actions/download-artifact@v"))
        XCTAssertFalse(workflow.contains("actions/attest@v"))
    }

    func testContinuousIntegrationRunsFullSuiteOnBothArchitectures() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let workflowURL = root.appendingPathComponent(".github/workflows/ci.yml")
        let workflow = try String(contentsOf: workflowURL, encoding: .utf8)

        XCTAssertTrue(workflow.contains("pull_request:"))
        XCTAssertTrue(workflow.contains("push:"))
        XCTAssertTrue(workflow.contains("- main"))
        XCTAssertTrue(workflow.contains("macos-15"))
        XCTAssertTrue(workflow.contains("macos-15-intel"))
        XCTAssertTrue(workflow.contains("arch: arm64"))
        XCTAssertTrue(workflow.contains("arch: x86_64"))
        XCTAssertTrue(workflow.contains("Xcode_26.3.app"))
        XCTAssertTrue(workflow.contains("macOS 26 SDK or newer is required"))
        XCTAssertFalse(workflow.contains("Xcode_16.4.app"))
        XCTAssertTrue(workflow.contains("swift build -c release --product monknot-export"))
        XCTAssertTrue(workflow.contains("swift build -c release --product monknot-capture"))
        XCTAssertTrue(workflow.contains("swift test"))
        XCTAssertTrue(workflow.contains("swift run MonknotSmokeTests"))
        XCTAssertTrue(workflow.contains("swift run MonknotStoreSmokeTests"))
        XCTAssertTrue(workflow.contains("swift run MonknotRecentWorkspaceSmokeTests"))
        XCTAssertTrue(workflow.contains("swift run MonknotShortcutSmokeTests"))
        XCTAssertTrue(workflow.contains("swift run MonknotWorkspaceExport"))
        XCTAssertTrue(workflow.contains("swift run monknot-export --help"))
        XCTAssertTrue(workflow.contains("swift run monknot-capture --help"))
        XCTAssertFalse(workflow.contains("actions/checkout@v"))
    }

    func testDependabotMaintainsPinnedGitHubActions() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let configurationURL = root.appendingPathComponent(".github/dependabot.yml")
        let configuration = try String(contentsOf: configurationURL, encoding: .utf8)

        XCTAssertTrue(configuration.contains("package-ecosystem: github-actions"))
        XCTAssertTrue(configuration.contains("interval: weekly"))
    }

    func testGitHubActionsUseImmutableCommitPins() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let workflowDirectory = root.appendingPathComponent(".github/workflows", isDirectory: true)
        let workflows = try FileManager.default.contentsOfDirectory(
            at: workflowDirectory,
            includingPropertiesForKeys: nil
        ).filter { ["yml", "yaml"].contains($0.pathExtension) }

        XCTAssertFalse(workflows.isEmpty)
        for workflowURL in workflows {
            let workflow = try String(contentsOf: workflowURL, encoding: .utf8)
            for line in workflow.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("uses:") else { continue }
                XCTAssertNotNil(
                    trimmed.range(
                        of: #"^uses:\s+[^@\s]+@[0-9a-f]{40}(?:\s+#.*)?$"#,
                        options: .regularExpression
                    ),
                    "\(workflowURL.lastPathComponent) contains a mutable or malformed action reference: \(trimmed)"
                )
            }
        }
    }

    private func sourceEntries(named arrayName: String, in script: String) throws -> Set<String> {
        guard let startRange = script.range(of: "\(arrayName)=(") else {
            throw NSError(domain: "BuildScriptSyncTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(arrayName) array"])
        }
        guard let endRange = script[startRange.upperBound...].range(of: "\n)") else {
            throw NSError(domain: "BuildScriptSyncTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing \(arrayName) terminator"])
        }

        let section = script[startRange.upperBound..<endRange.lowerBound]
        return Set(section
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { line -> String? in
                guard line.hasPrefix("\""), line.hasSuffix("\"") else { return nil }
                return String(line.dropFirst().dropLast())
            })
    }

    private func swiftSources(under directory: URL) throws -> Set<String> {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sources: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relativePath = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            sources.insert(relativePath)
        }
        return sources
    }
}
