import XCTest
@testable import MonknotCore

final class MarkdownPDFExportOptionsTests: XCTestCase {
    func testScaleIsClampedAndResolved() throws {
        XCTAssertEqual(MarkdownPDFExportOptions(scalePercent: 40).scalePercent, 70)
        XCTAssertEqual(MarkdownPDFExportOptions(scalePercent: 250).scalePercent, 180)
        XCTAssertEqual(MarkdownPDFExportOptions(scalePercent: 125).resolvedScale, 1.25)
    }

    func testMissingScaleDecodesToDefault() throws {
        let data = #"{"pageSize":"a4","marginPreset":"compact","themeMode":"dark"}"#.data(using: .utf8)!
        let options = try JSONDecoder().decode(MarkdownPDFExportOptions.self, from: data)

        XCTAssertEqual(options.pageSize, .a4)
        XCTAssertEqual(options.marginPreset, .compact)
        XCTAssertEqual(options.themeMode, .dark)
        XCTAssertEqual(options.scalePercent, 100)
    }

    func testOptionsPersistToInjectedDefaults() throws {
        let suiteName = makeDefaultsSuiteName()
        let defaults = try makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let options = MarkdownPDFExportOptions(
            pageSize: .letter,
            marginPreset: .compact,
            themeMode: .dark,
            scalePercent: 125
        )

        options.saveLastUsed(defaults: defaults)
        let restored = MarkdownPDFExportOptions.loadLastUsed(defaults: defaults)

        XCTAssertEqual(restored, options)
    }

    func testCorruptPersistedOptionsFallBackToDefaults() throws {
        let suiteName = makeDefaultsSuiteName()
        let defaults = try makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not-json".utf8), forKey: lastUsedOptionsKey)

        XCTAssertEqual(MarkdownPDFExportOptions.loadLastUsed(defaults: defaults), MarkdownPDFExportOptions())
    }

    func testAutomaticPageSizeFollowsLocaleRegion() {
        XCTAssertEqual(MarkdownPDFPageSize.automatic.resolved(locale: Locale(identifier: "en_US")), MarkdownPDFPageSize.letter.resolved())
        XCTAssertEqual(MarkdownPDFPageSize.automatic.resolved(locale: Locale(identifier: "en_AT")), MarkdownPDFPageSize.a4.resolved())
    }

    private func makeDefaultsSuiteName() -> String {
        "MonknotTests.MarkdownPDFExportOptions.\(UUID().uuidString)"
    }

    private var lastUsedOptionsKey: String {
        "Monknot.markdownPDFExportOptions"
    }

    private func makeDefaults(suiteName: String) throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "MonknotTests", code: 1)
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
