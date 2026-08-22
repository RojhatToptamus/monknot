import Foundation
import XCTest

final class LicenseContractTests: RepositoryContractTestCase {
    func testProjectAndFirstPartyAssetsUseMITWhileThirdPartyNoticesRemainSeparate() throws {
        let root = repositoryRoot
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
        let searchAddonLicense = try String(
            contentsOf: root.appendingPathComponent("ThirdPartyLicenses/xterm-addon-search-MIT.txt"),
            encoding: .utf8
        )
        let sparkleLicense = try String(
            contentsOf: root.appendingPathComponent("ThirdPartyLicenses/sparkle-MIT.txt"),
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

        XCTAssertTrue(projectLicense.hasPrefix("MIT License\n\nCopyright (c) 2026 Rojhat Toptamuş"))
        XCTAssertTrue(projectLicense.contains("Permission is hereby granted, free of charge"))
        XCTAssertTrue(projectLicense.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
        XCTAssertFalse(projectLicense.lowercased().contains("proprietary"))
        XCTAssertTrue(readme.contains("Monknot is available under the [MIT License](LICENSE)."))
        XCTAssertTrue(readme.contains("Third-party components"))
        XCTAssertTrue(readme.contains("[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)"))
        XCTAssertTrue(notices.contains("@xterm/xterm` 5.5.0"))
        XCTAssertTrue(notices.contains("@xterm/addon-fit` 0.10.0"))
        XCTAssertTrue(notices.contains("@xterm/addon-search` 0.15.0"))
        XCTAssertTrue(notices.contains("Sparkle 2.9.5"))
        XCTAssertTrue(notices.contains("79bc9e872948e47877e76f194cb0c8e0412b0b90"))
        XCTAssertTrue(notices.contains("9ba6c00a195c95fcf8292a2b9084d91450e5daae"))
        XCTAssertTrue(xtermLicense.contains("Permission is hereby granted, free of charge"))
        XCTAssertTrue(addonLicense.contains("Permission is hereby granted, free of charge"))
        XCTAssertTrue(searchAddonLicense.contains("Permission is hereby granted, free of charge"))
        XCTAssertTrue(sparkleLicense.contains("Copyright (c) 2006-2013 Andy Matuschak"))
        XCTAssertTrue(sparkleLicense.contains("EXTERNAL LICENSES"))
        XCTAssertTrue(audit.contains("Cleared for the direct-distribution application bundle"))
        XCTAssertTrue(audit.contains("Owner-provided replacement palettes"))
        XCTAssertTrue(audit.contains("Cleared by project-owner representation"))
        XCTAssertTrue(audit.contains("Owner-authored custom palettes"))
        XCTAssertTrue(audit.contains("App icon/logo PNG set"))
        XCTAssertTrue(audit.contains("Gruvbox Light and Gruvbox Dark were removed"))
        XCTAssertFalse(themeCatalog.contains("Gruvbox"))
        XCTAssertTrue(buildScript.contains("Copyright © 2026 Rojhat Toptamuş"))
        XCTAssertFalse(buildScript.contains("All rights reserved"))
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
}
