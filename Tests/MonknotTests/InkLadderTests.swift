import XCTest
@testable import MonknotCore

/// design.md §1.4: the ink ladder is derived per theme, so a soft theme ink still reads.
final class InkLadderTests: XCTestCase {
    private let themes = (MonknotThemeCatalog.lightPresets + MonknotThemeCatalog.darkPresets).map(\.theme)

    private func contrast(of theme: AppTheme, opacity: Double, over surface: String) throws -> Double {
        let blended = try XCTUnwrap(RGBHex(AppTheme.blendHex(surface, toward: theme.foreground, amount: opacity)))
        return blended.contrastRatio(with: try XCTUnwrap(RGBHex(surface)))
    }

    func testLabelsReadFourAndAHalfAndGlyphsThreeOnTheChromeAndTheCanvasOfEveryTheme() throws {
        for theme in themes {
            for surface in [theme.chromeSurfaceHex, theme.background] {
                let fullInk = try contrast(of: theme, opacity: 1, over: surface)
                XCTAssertGreaterThanOrEqual(
                    try contrast(of: theme, opacity: theme.labelInkOpacity, over: surface),
                    min(4.5, fullInk) - 0.0001,
                    "\(theme.name) label on \(surface)"
                )
                XCTAssertGreaterThanOrEqual(
                    try contrast(of: theme, opacity: theme.glyphInkOpacity, over: surface),
                    min(3.0, fullInk) - 0.0001,
                    "\(theme.name) glyph on \(surface)"
                )
            }
        }
    }

    func testTheLadderKeepsItsOrderAndFloors() {
        for theme in themes {
            XCTAssertGreaterThanOrEqual(theme.labelInkOpacity, (0.72 * theme.inkLadderContrastFactor * 100).rounded() / 100, theme.name)
            XCTAssertGreaterThanOrEqual(theme.glyphInkOpacity, (0.50 * theme.inkLadderContrastFactor * 100).rounded() / 100, theme.name)
            XCTAssertLessThan(theme.glyphInkOpacity, theme.labelInkOpacity, theme.name)
            XCTAssertLessThan(AppTheme.disabledInkOpacity, theme.glyphInkOpacity, theme.name)
        }
    }

    /// Each rung is the lowest that reads: a hundredth less fails somewhere, unless it sits on its floor.
    func testEachRungIsTheLowestOpacityThatReads() throws {
        for theme in themes {
            let surfaces = [theme.chromeSurfaceHex, theme.background]
            let factor = theme.inkLadderContrastFactor
            for (opacity, floor, ratio) in [
                (theme.labelInkOpacity, (0.72 * factor * 100).rounded() / 100, 4.5),
                (theme.glyphInkOpacity, (0.50 * factor * 100).rounded() / 100, 3.0),
            ] where opacity > floor + 0.001 && opacity < 1 {
                let lower = opacity - 0.01
                let readsEverywhere = try surfaces.allSatisfy { surface in
                    try contrast(of: theme, opacity: lower, over: surface) >= ratio
                }
                XCTAssertFalse(readsEverywhere, "\(theme.name) could use \(lower)")
            }
        }
    }

    func testCatppuccinLatteRaisesItsSoftInkWhileHarborKeepsTheFloors() throws {
        let latte = try theme("catppuccin-latte")
        XCTAssertEqual(latte.labelInkOpacity, 0.84, accuracy: 0.001)
        XCTAssertEqual(latte.glyphInkOpacity, 0.66, accuracy: 0.001)

        for id in ["harbor-light", "harbor-dark"] {
            let floorTheme = try theme(id)
            XCTAssertEqual(floorTheme.labelInkOpacity, 0.72, accuracy: 0.001, id)
            XCTAssertEqual(floorTheme.glyphInkOpacity, 0.50, accuracy: 0.001, id)
        }
    }

    /// design.md §14: `contrast` scales the floors; 40 is the ladder as specified.
    func testContrastRaisesAndLowersTheFloors() throws {
        let harbor = try theme("harbor-light")
        XCTAssertEqual(harbor.contrast, 40)
        XCTAssertEqual(harbor.inkLadderContrastFactor, 1, accuracy: 0.0001)

        let high = harbor.replacing(contrast: 100)
        XCTAssertEqual(high.labelInkOpacity, 0.88, accuracy: 0.001)
        XCTAssertEqual(high.glyphInkOpacity, 0.61, accuracy: 0.001)

        // Lower floors, but never below what reads: Harbor's near-black ink reads at the lower floor.
        let low = harbor.replacing(contrast: 0)
        XCTAssertEqual(low.labelInkOpacity, 0.62, accuracy: 0.011)
        XCTAssertLessThan(low.labelInkOpacity, harbor.labelInkOpacity)
        XCTAssertLessThan(low.glyphInkOpacity, harbor.glyphInkOpacity)

        // Catppuccin Mocha ships contrast 60, so its floors sit a little higher.
        let mocha = try theme("catppuccin-mocha")
        XCTAssertEqual(mocha.labelInkOpacity, 0.77, accuracy: 0.001)
        XCTAssertEqual(mocha.glyphInkOpacity, 0.54, accuracy: 0.001)
    }

    private func theme(_ id: String) throws -> AppTheme {
        try XCTUnwrap((MonknotThemeCatalog.lightPresets + MonknotThemeCatalog.darkPresets).first { $0.id == id }).theme
    }
}
