import XCTest
@testable import MonknotCore

final class MarkdownPDFExportOptionsTests: XCTestCase {
    func testScaleIsClampedAndResolved() throws {
        XCTAssertEqual(MarkdownPDFExportOptions(scalePercent: 40).scalePercent, 70)
        XCTAssertEqual(MarkdownPDFExportOptions(scalePercent: 250).scalePercent, 130)
        XCTAssertEqual(MarkdownPDFExportOptions(scalePercent: 125).resolvedScale, 1.25)
    }

    func testTypographyAndContentWidthAreClamped() throws {
        let low = MarkdownPDFExportOptions(textSizePoints: 6, contentWidthPercent: 40)
        let high = MarkdownPDFExportOptions(textSizePoints: 30, contentWidthPercent: 140)

        XCTAssertEqual(low.textSizePoints, 10)
        XCTAssertEqual(high.textSizePoints, 18)
        XCTAssertEqual(low.contentWidthPercent, 65)
        XCTAssertEqual(high.contentWidthPercent, 100)
    }

    func testMissingNewExportSettingsDecodeToDefaults() throws {
        let data = #"{"pageSize":"a4","marginPreset":"compact","themeMode":"dark"}"#.data(using: .utf8)!
        let options = try JSONDecoder().decode(MarkdownPDFExportOptions.self, from: data)

        XCTAssertEqual(options.pageSize, .a4)
        XCTAssertEqual(options.marginPreset, .compact)
        XCTAssertEqual(options.themeMode, .dark)
        XCTAssertEqual(options.scalePercent, 100)
        XCTAssertEqual(options.textSizePoints, 13)
        XCTAssertEqual(options.contentWidthPercent, 100)
    }

    func testOptionsPersistToInjectedDefaults() throws {
        let suiteName = makeDefaultsSuiteName()
        let defaults = try makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let options = MarkdownPDFExportOptions(
            pageSize: .letter,
            marginPreset: .compact,
            themeMode: .dark,
            scalePercent: 125,
            textSizePoints: 14,
            contentWidthPercent: 82
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
