import XCTest
@testable import MonknotCore

final class AppThemeSurfaceHierarchyTests: XCTestCase {
    func testBlendHexInterpolatesTowardTarget() {
        XCTAssertEqual(AppTheme.blendHex("#000000", toward: "#FFFFFF", amount: 0.5), "#808080")
        XCTAssertEqual(AppTheme.blendHex("#000000", toward: "#FFFFFF", amount: 0), "#000000")
        XCTAssertEqual(AppTheme.blendHex("#000000", toward: "#FFFFFF", amount: 1), "#FFFFFF")
    }

    func testBlendHexClampsAmountAndKeepsHue() {
        // Clamps above 1 and below 0.
        XCTAssertEqual(AppTheme.blendHex("#112233", toward: "#AABBCC", amount: 5), "#AABBCC")
        XCTAssertEqual(AppTheme.blendHex("#112233", toward: "#AABBCC", amount: -2), "#112233")
    }

    func testBlendHexReturnsBaseForInvalidInput() {
        XCTAssertEqual(AppTheme.blendHex("not-a-color", toward: "#FFFFFF", amount: 0.5), "not-a-color")
    }

    func testTerminalSharesContentCanvasInBothModes() {
        // In the two-tier model the terminal is the content canvas, not a
        // separate surface tier, so its surface is exactly the theme background.
        XCTAssertEqual(AppTheme.codexDark.terminalSurfaceHex, AppTheme.codexDark.background)
        XCTAssertEqual(AppTheme.codexLight.terminalSurfaceHex, AppTheme.codexLight.background)
    }

    func testSidebarIsTheOnlyDistinctTier() {
        // The sidebar is the single tool-panel tier and must differ from the
        // canvas, while the terminal must match it.
        for theme in [AppTheme.codexDark, AppTheme.codexLight] {
            XCTAssertNotEqual(theme.sidebarSurfaceHex, theme.background)
            XCTAssertNotEqual(theme.sidebarSurfaceHex, theme.terminalSurfaceHex)
        }
    }

    func testDarkSidebarRaisesSubtlyTowardInk() {
        let theme = AppTheme.codexDark // background #111111, foreground #fcfcfc
        // Lighter than the dark canvas, but a subtle offset (not a heavy panel).
        XCTAssertGreaterThan(luminance(theme.sidebarSurfaceHex), luminance(theme.background))
        XCTAssertLessThan(channelDelta(theme.sidebarSurfaceHex, theme.background), 0.16)
    }

    func testLightSidebarRecessesSubtlyTowardInk() {
        let theme = AppTheme.codexLight // background #ffffff, foreground #1a1c1f
        // A hair darker than the white canvas, and very subtle in light themes.
        XCTAssertLessThan(luminance(theme.sidebarSurfaceHex), luminance(theme.background))
        XCTAssertLessThan(channelDelta(theme.sidebarSurfaceHex, theme.background), 0.06)
    }

    private func luminance(_ hex: String) -> Double {
        RGBHex(hex)?.relativeLuminance ?? -1
    }

    /// Largest absolute per-channel difference (0...1) between two hex colors.
    private func channelDelta(_ lhs: String, _ rhs: String) -> Double {
        guard let a = RGBHex(lhs), let b = RGBHex(rhs) else { return .infinity }
        return max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
    }
}
