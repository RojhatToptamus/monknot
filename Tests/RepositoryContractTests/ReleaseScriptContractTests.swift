import Foundation
import XCTest

final class ReleaseScriptContractTests: RepositoryContractTestCase {
    func testManualBundleHasReleaseMetadataAndConfigurableDevelopmentSignature() throws {
        let root = repositoryRoot
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

    func testReleasePreflightChecksAdHocAndDeveloperIDRequirements() throws {
        let root = repositoryRoot
        let scriptURL = root.appendingPathComponent("script/release_preflight.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.hasPrefix("#!/usr/bin/env bash"))
        XCTAssertTrue(script.contains("Developer ID Application"))
        XCTAssertTrue(script.contains("--adhoc"))
        XCTAssertTrue(script.contains("--allow-missing-identity"))
        XCTAssertTrue(script.contains("Signature=adhoc"))
        XCTAssertTrue(script.contains("Developer ID Application: rojhat toptamus (ZD35XP4V7D)"))
        XCTAssertTrue(script.contains("CFBundleShortVersionString"))
        XCTAssertTrue(script.contains("SECRET_PATTERN"))
        XCTAssertTrue(script.contains("git ls-files --others --exclude-standard -z"))
        XCTAssertTrue(script.contains("git rev-list --all"))
        XCTAssertTrue(script.contains("reachable Git history"))
        XCTAssertTrue(script.contains("Legal/THIRD_PARTY_NOTICES.md"))
        XCTAssertTrue(script.contains("xcrun vtool -show-build"))
        XCTAssertTrue(script.contains("third-party resource hash"))
        XCTAssertTrue(script.contains("bundle contains no code-signing entitlements"))
        XCTAssertTrue(script.contains("bundle contains no provisioning profile"))
        XCTAssertTrue(script.contains("bundle signature has a secure timestamp"))
        XCTAssertTrue(script.contains("Mach-O signature has a secure timestamp"))
        XCTAssertFalse(script.contains("RELEASE_COMPLIANCE_BLOCKER"))
        XCTAssertTrue(script.contains("theme-tokyo-night-MIT.txt"))
        XCTAssertTrue(script.contains("Sparkle framework version is $SPARKLE_VERSION"))
        XCTAssertTrue(script.contains("unused Sparkle XPC services are absent"))
        XCTAssertTrue(script.contains("SUVerifyUpdateBeforeExtraction"))
    }

    func testReleasePackageSupportsAdHocAndNotarizedDMGs() throws {
        let root = repositoryRoot
        let scriptURL = root.appendingPathComponent("script/release_package.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.hasPrefix("#!/usr/bin/env bash"))
        XCTAssertTrue(script.contains("script/build_and_run.sh\" --build"))
        XCTAssertTrue(script.contains("MONKNOT_SIGNING_MODE=adhoc"))
        XCTAssertTrue(script.contains("Developer ID Application"))
        XCTAssertTrue(script.contains("codesign --force --options runtime --timestamp --sign"))
        XCTAssertTrue(script.contains("application signature is missing a secure timestamp"))
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
        XCTAssertTrue(script.contains("sign_code \"$SPARKLE_AUTOUPDATE\""))
        XCTAssertTrue(script.contains("sign_code \"$SPARKLE_UPDATER_APP\""))
        XCTAssertTrue(script.contains("sign_code \"$SPARKLE_FRAMEWORK\""))
        XCTAssertTrue(script.contains("sign_code \"$MONKNOT_CORE\""))
        XCTAssertTrue(script.contains("sign_code \"$APP_BUNDLE\""))
        XCTAssertTrue(script.contains("run ditto \"$APP_BUNDLE\""))
        XCTAssertTrue(script.contains("Monknot-$RELEASE_VERSION-$TARGET_ARCH.dmg"))
        XCTAssertFalse(script.contains("RELEASE_COMPLIANCE_BLOCKER"))
    }

    func testReleaseArtifactVerifierChecksMountedDistribution() throws {
        let root = repositoryRoot
        let scriptURL = root.appendingPathComponent("script/verify_release_artifact.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.hasPrefix("#!/usr/bin/env bash"))
        XCTAssertTrue(script.contains("hdiutil verify"))
        XCTAssertTrue(script.contains("hdiutil attach -readonly -nobrowse"))
        XCTAssertTrue(script.contains("shasum -a 256 -c"))
        XCTAssertTrue(script.contains("Contents/Resources"))
        XCTAssertTrue(script.contains("Legal/ThirdParty/xterm-MIT.txt"))
        XCTAssertTrue(script.contains("Legal/ThirdParty/xterm-addon-fit-MIT.txt"))
        XCTAssertTrue(script.contains("Legal/ThirdParty/xterm-addon-search-MIT.txt"))
        XCTAssertTrue(script.contains("Legal/ThirdParty/sparkle-MIT.txt"))
        XCTAssertTrue(script.contains("theme-ayu-MIT.txt"))
        XCTAssertTrue(script.contains("theme-tokyo-night-MIT.txt"))
        XCTAssertTrue(script.contains("Developer ID Application: rojhat toptamus (ZD35XP4V7D)"))
        XCTAssertTrue(script.contains("spctl --assess --type execute -vv"))
        XCTAssertTrue(script.contains("unexpectedly contains code-signing entitlements"))
        XCTAssertTrue(script.contains("DMG signature is missing a secure timestamp"))
        XCTAssertTrue(script.contains("Mach-O file is missing a secure timestamp"))
        XCTAssertFalse(script.contains("RELEASE_COMPLIANCE_BLOCKER"))
        XCTAssertTrue(script.contains("xcrun vtool -show-build"))
        XCTAssertTrue(script.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(script.contains("CFFIXED_USER_HOME"))
        XCTAssertTrue(script.contains("unexpected top-level DMG item"))
        XCTAssertTrue(script.contains("Sparkle framework version"))
        XCTAssertTrue(script.contains("unused Sparkle XPC services"))
        XCTAssertTrue(script.contains("@rpath/Sparkle.framework/Versions/B/Sparkle"))
    }
}
