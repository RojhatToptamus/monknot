import Foundation
import XCTest

final class WorkflowPolicyTests: RepositoryContractTestCase {
    func testReleaseWorkflowPublishesAtomicSparkleUpdates() throws {
        let root = repositoryRoot
        let workflowURL = root.appendingPathComponent(".github/workflows/release.yml")
        let workflow = try String(contentsOf: workflowURL, encoding: .utf8)

        XCTAssertTrue(workflow.contains("tags:"))
        XCTAssertTrue(workflow.contains("- \"v*\""))
        XCTAssertTrue(workflow.contains("workflow_dispatch:"))
        XCTAssertTrue(workflow.contains("release tag must point to a commit reachable from origin/main"))
        XCTAssertTrue(workflow.contains("manual release dry-runs must use the main branch"))
        XCTAssertTrue(workflow.contains("manual release dry-run commit must equal the current origin/main tip"))
        XCTAssertTrue(workflow.contains("macos-15"))
        XCTAssertFalse(workflow.contains("macos-15-intel"))
        XCTAssertTrue(workflow.contains("test \"$(uname -m)\" = \"arm64\""))
        XCTAssertFalse(workflow.contains("x86_64"))
        XCTAssertTrue(workflow.contains("environment: release"))
        XCTAssertTrue(workflow.contains("timeout-minutes: 360"))
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
        XCTAssertTrue(workflow.contains("script/release_preflight.sh --allow-missing-identity"))
        XCTAssertTrue(workflow.contains("MACOS_CERTIFICATE_P12"))
        XCTAssertTrue(workflow.contains("MACOS_CERTIFICATE_PASSWORD"))
        XCTAssertTrue(workflow.contains("APPLE_API_KEY_P8"))
        XCTAssertTrue(workflow.contains("APPLE_API_KEY_ID"))
        XCTAssertTrue(workflow.contains("APPLE_API_ISSUER_ID"))
        XCTAssertTrue(workflow.contains("security create-keychain"))
        XCTAssertTrue(workflow.contains("security delete-keychain"))
        XCTAssertTrue(workflow.contains("security set-key-partition-list"))
        XCTAssertTrue(workflow.contains("xcrun notarytool submit"))
        XCTAssertTrue(workflow.contains("--no-wait"))
        XCTAssertTrue(workflow.contains("xcrun notarytool wait"))
        XCTAssertTrue(workflow.contains("--timeout 330m"))
        XCTAssertTrue(workflow.contains("notary_status\" != \"Accepted"))
        XCTAssertTrue(workflow.contains("plutil -extract id raw"))
        XCTAssertTrue(workflow.contains("submission_id=$notary_id"))
        XCTAssertTrue(workflow.contains("xcrun stapler staple"))
        XCTAssertTrue(workflow.contains("xcrun stapler validate"))
        XCTAssertTrue(workflow.contains("spctl --assess"))
        XCTAssertTrue(workflow.contains("gh release create"))
        XCTAssertTrue(workflow.contains("inputs.publish_prerelease"))
        XCTAssertTrue(workflow.contains("BUILD_NUMBER must increase exactly once"))
        XCTAssertTrue(workflow.contains("No tag or GitHub Release was created."))
        XCTAssertTrue(workflow.contains("SPARKLE_ED25519_PRIVATE_KEY: ${{ secrets.SPARKLE_ED25519_PRIVATE_KEY }}"))
        XCTAssertTrue(workflow.contains("script/generate_appcast.sh"))
        XCTAssertTrue(workflow.contains("script/verify_appcast.sh"))
        XCTAssertTrue(workflow.contains("RELEASE_APPCAST: dist/appcast.xml"))
        XCTAssertTrue(workflow.contains("--notes-file"))
        XCTAssertFalse(workflow.contains("--generate-notes"))
        XCTAssertTrue(workflow.contains("Monknot-${{ needs.metadata.outputs.release_version }}-arm64.dmg"))
        XCTAssertTrue(workflow.contains("--draft"))
        XCTAssertFalse(workflow.contains("--adhoc"))
        XCTAssertTrue(workflow.contains("gh release download"))
        XCTAssertTrue(workflow.contains("cmp \"$RELEASE_APPCAST\""))
        XCTAssertTrue(workflow.contains("gh release edit \"$tag\" --draft=false --latest"))
        XCTAssertTrue(workflow.contains("actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"))
        XCTAssertTrue(workflow.contains("actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093"))
        XCTAssertTrue(workflow.contains("persist-credentials: false"))

        let publishMarker = "\n  publish:\n"
        let publishRange = try XCTUnwrap(workflow.range(of: publishMarker))
        let signingWorkflow = String(workflow[..<publishRange.lowerBound])
        let publishWorkflow = String(workflow[publishRange.lowerBound...])
        let certificateImport = try XCTUnwrap(signingWorkflow.range(of: "security import \"$certificate_path\""))
        let certificateCleanup = try XCTUnwrap(
            signingWorkflow.range(of: "rm -f \"$certificate_path\"\n          unset MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD")
        )
        let releasePackaging = try XCTUnwrap(signingWorkflow.range(of: "script/release_package.sh"))
        XCTAssertLessThan(certificateImport.lowerBound, certificateCleanup.lowerBound)
        XCTAssertLessThan(certificateCleanup.lowerBound, releasePackaging.lowerBound)
        XCTAssertTrue(signingWorkflow.contains("contents: read"))
        XCTAssertFalse(signingWorkflow.contains("contents: write"))
        XCTAssertTrue(signingWorkflow.contains("SPARKLE_ED25519_PRIVATE_KEY"))
        XCTAssertTrue(publishWorkflow.contains("contents: write"))
        XCTAssertTrue(publishWorkflow.contains("sha256sum --check"))
        XCTAssertFalse(publishWorkflow.contains("environment: release"))
        XCTAssertFalse(publishWorkflow.contains("MACOS_CERTIFICATE_P12"))
        XCTAssertFalse(publishWorkflow.contains("MACOS_CERTIFICATE_PASSWORD"))
        XCTAssertFalse(publishWorkflow.contains("APPLE_API_KEY_P8"))
        XCTAssertFalse(publishWorkflow.contains("APPLE_API_KEY_ID"))
        XCTAssertFalse(publishWorkflow.contains("APPLE_API_ISSUER_ID"))
        XCTAssertFalse(publishWorkflow.contains("SPARKLE_ED25519_PRIVATE_KEY"))
        XCTAssertFalse(workflow.contains("actions/checkout@v"))
    }

    func testContinuousIntegrationRunsFullSuiteOnArm64() throws {
        let root = repositoryRoot
        let workflowURL = root.appendingPathComponent(".github/workflows/ci.yml")
        let workflow = try String(contentsOf: workflowURL, encoding: .utf8)

        XCTAssertTrue(workflow.contains("pull_request:"))
        XCTAssertTrue(workflow.contains("push:"))
        XCTAssertTrue(workflow.contains("- main"))
        XCTAssertTrue(workflow.contains("macos-15"))
        XCTAssertFalse(workflow.contains("macos-15-intel"))
        XCTAssertTrue(workflow.contains("test \"$(uname -m)\" = \"arm64\""))
        XCTAssertFalse(workflow.contains("x86_64"))
        XCTAssertTrue(workflow.contains("Xcode_26.3.app"))
        XCTAssertTrue(workflow.contains("macOS 26 SDK or newer is required"))
        XCTAssertFalse(workflow.contains("Xcode_16.4.app"))
        XCTAssertTrue(workflow.contains("swift build -c release --product monknot-export"))
        XCTAssertTrue(workflow.contains("swift build -c release --product monknot-capture"))
        XCTAssertTrue(workflow.contains("swift test"))
        XCTAssertTrue(workflow.contains("swift run MonknotSmokeTests"))
        XCTAssertTrue(workflow.contains("swift run MonknotStoreSmokeTests"))
        XCTAssertTrue(workflow.contains("swift run monknot-export --help"))
        XCTAssertTrue(workflow.contains("swift run monknot-capture --help"))
        XCTAssertFalse(workflow.contains("actions/checkout@v"))
    }

    func testDependabotMaintainsPinnedGitHubActions() throws {
        let root = repositoryRoot
        let configurationURL = root.appendingPathComponent(".github/dependabot.yml")
        let configuration = try String(contentsOf: configurationURL, encoding: .utf8)

        XCTAssertTrue(configuration.contains("package-ecosystem: github-actions"))
        XCTAssertTrue(configuration.contains("package-ecosystem: swift"))
        XCTAssertTrue(configuration.contains("interval: weekly"))
    }

    func testGitHubActionsUseImmutableCommitPins() throws {
        let root = repositoryRoot
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
}
