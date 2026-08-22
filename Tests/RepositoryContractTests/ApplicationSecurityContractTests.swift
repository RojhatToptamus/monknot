import Foundation
import XCTest

final class ApplicationSecurityContractTests: RepositoryContractTestCase {
    func testAppStorePackagingAndSandboxEntitlementsAreRemoved() throws {
        let root = repositoryRoot
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("script/app_store_package.sh").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config/MonknotAppStore.entitlements").path))

        let workflow = try String(contentsOf: root.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        let releaseGuide = try String(contentsOf: root.appendingPathComponent("docs/RELEASE.md"), encoding: .utf8)
        XCTAssertFalse(workflow.contains("app-sandbox"))
        XCTAssertFalse(workflow.contains("productbuild"))
        XCTAssertFalse(workflow.contains("Transporter"))
        XCTAssertTrue(releaseGuide.contains("does not use App Sandbox"))
    }

    func testHTMLPreviewDisablesWorkspaceAuthoredJavaScript() throws {
        let root = repositoryRoot
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Monknot/Views/HTMLPreviewView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("defaultWebpagePreferences.allowsContentJavaScript = false"))
        XCTAssertTrue(source.contains("addUserScript(Coordinator.previewBehaviorScript)"))
    }
}
