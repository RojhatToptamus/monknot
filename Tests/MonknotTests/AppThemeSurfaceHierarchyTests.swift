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

    func testDarkThemeToolPanelsRaiseTowardInk() {
        let theme = AppTheme.codexDark // background #111111, foreground #fcfcfc
        // Tool panels should be lighter than the (dark) content canvas.
        XCTAssertNotEqual(theme.sidebarSurfaceHex, theme.background)
        XCTAssertNotEqual(theme.terminalSurfaceHex, theme.background)
        XCTAssertGreaterThan(luminance(theme.sidebarSurfaceHex), luminance(theme.background))
        // Terminal is the deepest tool panel: one step further than the sidebar.
        XCTAssertGreaterThan(luminance(theme.terminalSurfaceHex), luminance(theme.sidebarSurfaceHex))
    }

    func testLightThemeToolPanelsRecessTowardInk() {
        let theme = AppTheme.codexLight // background #ffffff, foreground #1a1c1f
        // Tool panels should be darker (recessed gray) than the white content canvas.
        XCTAssertLessThan(luminance(theme.sidebarSurfaceHex), luminance(theme.background))
        XCTAssertLessThan(luminance(theme.terminalSurfaceHex), luminance(theme.sidebarSurfaceHex))
    }

    private func luminance(_ hex: String) -> Double {
        RGBHex(hex)?.relativeLuminance ?? -1
    }
}
