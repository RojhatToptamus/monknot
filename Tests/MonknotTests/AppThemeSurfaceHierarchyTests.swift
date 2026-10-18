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

    func testTerminalCardSharesTheDocumentCanvasInBothModes() {
        XCTAssertEqual(AppTheme.defaultDark.terminalSurfaceHex, AppTheme.defaultDark.background)
        XCTAssertEqual(AppTheme.defaultLight.terminalSurfaceHex, AppTheme.defaultLight.background)
    }

    func testChromeToneIsDistinctFromTheCards() {
        for theme in [AppTheme.defaultDark, AppTheme.defaultLight] {
            XCTAssertNotEqual(theme.sidebarSurfaceHex, theme.background)
            XCTAssertNotEqual(theme.sidebarSurfaceHex, theme.terminalSurfaceHex)
        }
    }

    func testDarkChromeSitsBelowTheCanvas() {
        for theme in [AppTheme.defaultDark, AppTheme.darkTheme(id: "catppuccin-mocha")] {
            // Darker than the canvas, so the card reads as lifted, but a step rather than a well.
            XCTAssertLessThan(luminance(theme.sidebarSurfaceHex), luminance(theme.background), theme.name)
            XCTAssertLessThan(channelDelta(theme.sidebarSurfaceHex, theme.background), 0.1, theme.name)
        }
    }

    func testLightChromeRecessesTowardInkVisiblyOnTintedCanvases() {
        for theme in [AppTheme.defaultLight, AppTheme.lightTheme(id: "catppuccin-latte")] {
            XCTAssertLessThan(luminance(theme.sidebarSurfaceHex), luminance(theme.background), theme.name)
            // Enough to see on a tinted canvas, never a grey panel.
            XCTAssertGreaterThan(channelDelta(theme.sidebarSurfaceHex, theme.background), 0.025, theme.name)
            XCTAssertLessThan(channelDelta(theme.sidebarSurfaceHex, theme.background), 0.06, theme.name)
        }
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
