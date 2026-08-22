import Foundation
import XCTest

final class SparkleReleaseContractTests: RepositoryContractTestCase {
    func testSparkleDependencyBundleConfigurationAndAppcastToolsStayPinned() throws {
        let root = repositoryRoot
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let resolved = try String(contentsOf: root.appendingPathComponent("Package.resolved"), encoding: .utf8)
        let buildScript = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let appcastScript = try String(contentsOf: root.appendingPathComponent("script/generate_appcast.sh"), encoding: .utf8)
        let verifier = try String(contentsOf: root.appendingPathComponent("script/verify_appcast.sh"), encoding: .utf8)
        let signatureVerifier = try String(
            contentsOf: root.appendingPathComponent("script/verify_appcast_signatures.swift"),
            encoding: .utf8
        )
        let vercel = try String(contentsOf: root.appendingPathComponent("website/vercel.json"), encoding: .utf8)

        XCTAssertTrue(package.contains(#".exact("2.9.5")"#))
        XCTAssertTrue(package.contains(#".product(name: "Sparkle", package: "Sparkle")"#))
        XCTAssertTrue(resolved.contains(#""version": "2.9.5""#))
        XCTAssertTrue(resolved.contains("79bc9e872948e47877e76f194cb0c8e0412b0b90"))
        XCTAssertTrue(buildScript.contains("https://monknot.app/updates/appcast.xml"))
        XCTAssertTrue(buildScript.contains("<key>SUPublicEDKey</key>"))
        XCTAssertTrue(buildScript.contains("<key>SURequireSignedFeed</key>"))
        XCTAssertTrue(buildScript.contains("<key>SUVerifyUpdateBeforeExtraction</key>"))
        XCTAssertFalse(buildScript.contains("<key>SUEnableSystemProfiling</key>"))
        XCTAssertTrue(buildScript.contains("rm -rf \"$SPARKLE_FRAMEWORK/Versions/B/XPCServices\""))
        XCTAssertTrue(buildScript.contains("thin_sparkle_binary"))
        XCTAssertTrue(appcastScript.contains("--ed-key-file -"))
        XCTAssertTrue(appcastScript.contains("--maximum-deltas 0"))
        XCTAssertTrue(appcastScript.contains("--maximum-versions 1"))
        XCTAssertFalse(appcastScript.contains("SPARKLE_ED25519_PRIVATE_KEY"))
        XCTAssertTrue(verifier.contains("appcast must not contain delta updates or Sparkle channels"))
        XCTAssertTrue(verifier.contains("appcast signed-feed block is missing or malformed"))
        XCTAssertTrue(verifier.contains("verify_appcast_signatures.swift"))
        XCTAssertTrue(signatureVerifier.contains("Curve25519.Signing.PublicKey"))
        XCTAssertTrue(signatureVerifier.contains("isValidSignature(feedSignature"))
        XCTAssertTrue(signatureVerifier.contains("isValidSignature(archiveSignature"))
        XCTAssertTrue(vercel.contains("/updates/appcast.xml"))
        XCTAssertTrue(vercel.contains("/releases/latest/download/appcast.xml"))
        XCTAssertTrue(vercel.contains(#""permanent": false"#))
    }
}
