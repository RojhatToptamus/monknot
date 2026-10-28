import XCTest
@testable import MonknotCore

final class PDFPageAppearanceTests: XCTestCase {
    func testTheStoredValuesAndTitlesStay() {
        // A renamed value would silently send everyone back to the original pages.
        XCTAssertEqual(PDFPageAppearance.preferenceKey, "Monknot.pdfPageAppearance")
        XCTAssertEqual(PDFPageAppearance.allCases.map(\.rawValue), ["original", "dim", "dark"])
        XCTAssertEqual(PDFPageAppearance.allCases.map(\.title), ["Original", "Dim", "Dark"])
    }

    func testOriginalShowsThePagesAsTheFileHasThem() {
        for theme in AppTheme.lightThemes + AppTheme.darkThemes {
            XCTAssertNil(PDFPageAppearance.original.colorTransform(in: theme))
        }
    }

    func testDimShowsEveryColourAtTheSameShareOfItsBrightness() throws {
        for theme in [AppTheme.defaultLight, .defaultDark] {
            let dim = try XCTUnwrap(PDFPageAppearance.dim.colorTransform(in: theme))
            assertColor(dim.apply([1, 1, 1]), [0.8, 0.8, 0.8], "White paper turns light grey")
            assertColor(dim.apply([0, 0, 0]), [0, 0, 0], "Black ink stays black")
            assertColor(dim.apply([1, 0.5, 0.25]), [0.8, 0.4, 0.2], "A picture keeps its colours")
        }
    }

    func testDarkPaperAndInkAreTheThemesOwnBaseColours() throws {
        for theme in AppTheme.darkThemes {
            let dark = try XCTUnwrap(PDFPageAppearance.dark.colorTransform(in: theme))
            assertColor(dark.apply([1, 1, 1]), try components(theme.background), "\(theme.name): paper")
            assertColor(dark.apply([0, 0, 0]), try components(theme.foreground), "\(theme.name): ink")
        }
        // A light theme's darker base colour is its text, so the paper takes that one.
        for theme in AppTheme.lightThemes {
            let dark = try XCTUnwrap(PDFPageAppearance.dark.colorTransform(in: theme))
            assertColor(dark.apply([1, 1, 1]), try components(theme.foreground), "\(theme.name): paper")
            assertColor(dark.apply([0, 0, 0]), try components(theme.background), "\(theme.name): ink")
        }
    }

    func testDarkFlipsALightnessAndKeepsTheHue() throws {
        let dark = PDFPageColorTransform(paper: try XCTUnwrap(RGBHex("#000000")), ink: try XCTUnwrap(RGBHex("#FFFFFF")))
        assertColor(dark.apply([0.5, 0.5, 0.5]), [0.5, 0.5, 0.5], "Mid grey stays")
        assertColor(dark.apply([0.9, 0.9, 0.9]), [0.1, 0.1, 0.1], "Light grey turns as dark")

        // A highlight's distance from grey stays, so its hue does; only its grey level flips.
        for color in [[1, 0.9, 0.2], [0.2, 0.45, 0.95], [0.85, 0.2, 0.3]] {
            let shown = dark.apply(color)
            assertColor(shown.map { $0 - mean(shown) }, color.map { $0 - mean(color) }, "\(color): hue")
            XCTAssertEqual(mean(shown), 1 - mean(color), accuracy: 1e-9, "\(color): lightness")
        }

        // Between a theme's paper and ink a mid grey lands half way, as the theme's own grey would.
        let theme = AppTheme.defaultDark
        let themed = try XCTUnwrap(PDFPageAppearance.dark.colorTransform(in: theme))
        let halfway = zip(try components(theme.background), try components(theme.foreground)).map { ($0 + $1) / 2 }
        assertColor(themed.apply([0.5, 0.5, 0.5]), halfway, "Mid grey on the theme")
    }

    private func components(_ hex: String) throws -> [Double] {
        let rgb = try XCTUnwrap(RGBHex(hex))
        return [rgb.red, rgb.green, rgb.blue]
    }

    private func mean(_ color: [Double]) -> Double {
        color.reduce(0, +) / Double(color.count)
    }

    private func assertColor(
        _ actual: [Double],
        _ expected: [Double],
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        for (value, target) in zip(actual, expected) {
            XCTAssertEqual(value, target, accuracy: 1e-9, "\(message): \(actual) is not \(expected)", file: file, line: line)
        }
    }
}

private extension PDFPageColorTransform {
    func apply(_ color: [Double]) -> [Double] {
        (0..<3).map { row in
            zip(matrix[row], color).map(*).reduce(bias[row], +)
        }
    }
}
