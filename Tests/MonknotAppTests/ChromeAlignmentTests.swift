import AppKit
import MonknotCore
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class ChromeAlignmentTests: XCTestCase {
    func testDisabledWindowNavigationAvoidsDoubleAttenuation() {
        let size = MonknotIconButton.IconButtonSize.windowNavigation

        XCTAssertEqual(size.disabledIconOpacity, 1)
        XCTAssertGreaterThanOrEqual(
            size.disabledControlOpacity * size.disabledIconOpacity,
            0.7,
            "Disabled Back and Forward controls must remain visibly identifiable"
        )
    }

    func testWindowNavigationUsesSharedChromeMetricsAcrossSupportedZooms() {
        let theme = AppTheme.codexDark
        let navigationSize = MonknotIconButton.IconButtonSize.windowNavigation
        let chromeSize = MonknotIconButton.IconButtonSize.chrome

        for zoomStep in 7...30 {
            let zoomScale = Double(zoomStep) / 10

            XCTAssertEqual(
                navigationSize.dimension(theme: theme, zoomScale: zoomScale),
                chromeSize.dimension(theme: theme, zoomScale: zoomScale),
                accuracy: 0.001
            )
            XCTAssertEqual(
                navigationSize.iconSize(theme: theme, zoomScale: zoomScale),
                chromeSize.iconSize(theme: theme, zoomScale: zoomScale),
                accuracy: 0.001
            )
            XCTAssertEqual(
                navigationSize.cornerRadius(theme: theme, zoomScale: zoomScale),
                chromeSize.cornerRadius(theme: theme, zoomScale: zoomScale),
                accuracy: 0.001
            )
        }
    }

    func testWindowNavigationHoverIsMoreProminentThanStandardChromeHover() {
        let navigationSize = MonknotIconButton.IconButtonSize.windowNavigation
        let chromeSize = MonknotIconButton.IconButtonSize.chrome

        for isDark in [false, true] {
            XCTAssertGreaterThan(
                navigationSize.hoverBackgroundOpacity(isDark: isDark),
                chromeSize.hoverBackgroundOpacity(isDark: isDark)
            )
        }
    }

    func testNativeWindowButtonsCenterInSharedChromeAtEverySupportedZoom() {
        let theme = AppTheme.codexDark
        let contentTopY: CGFloat = 800
        let standardButtonHeight: CGFloat = 14

        for zoomStep in 7...30 {
            let zoomScale = Double(zoomStep) / 10
            let chromeHeight = MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
            let nonFlippedOriginY = NativeWindowChromeGeometry.centeredButtonOriginY(
                buttonHeight: standardButtonHeight,
                chromeHeight: chromeHeight,
                contentTopY: contentTopY,
                isFlipped: false
            )
            let flippedOriginY = NativeWindowChromeGeometry.centeredButtonOriginY(
                buttonHeight: standardButtonHeight,
                chromeHeight: chromeHeight,
                contentTopY: 0,
                isFlipped: true
            )

            XCTAssertEqual(
                nonFlippedOriginY + standardButtonHeight / 2,
                contentTopY - chromeHeight / 2,
                accuracy: 0.001,
                "Native window controls drifted at zoom \(zoomScale)"
            )
            XCTAssertEqual(
                flippedOriginY + standardButtonHeight / 2,
                chromeHeight / 2,
                accuracy: 0.001,
                "Flipped native window controls drifted at zoom \(zoomScale)"
            )
        }
    }

    func testWindowNavigationControlsUseSharedChromeHeightAtEverySupportedZoom() {
        let theme = AppTheme.codexDark

        for zoomStep in 7...30 {
            let zoomScale = Double(zoomStep) / 10
            let controls = WindowNavigationControls(
                navigateBack: {},
                navigateForward: {},
                canNavigateBack: true,
                canNavigateForward: true,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: theme.uiFontSize
            )
            let host = NSHostingView(rootView: controls)

            XCTAssertEqual(
                host.fittingSize.height,
                MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale),
                accuracy: 0.01,
                "Window navigation chrome height drifted at zoom \(zoomScale)"
            )
        }
    }

    func testWindowNavigationReserveContainsControlsAtEverySupportedZoom() {
        let theme = AppTheme.codexDark

        for zoomStep in 7...30 {
            let zoomScale = Double(zoomStep) / 10
            let buttonWidth = MonknotMetrics.windowNavigationButtonDimension(
                theme: theme,
                zoomScale: zoomScale
            )
            let controlsTrailingEdge = MonknotMetrics.trafficLightReserveBase
                + MonknotMetrics.windowNavigationLeadingGap(theme: theme, zoomScale: zoomScale)
                + buttonWidth * 2
                + MonknotMetrics.scale(2, theme: theme, zoomScale: zoomScale)

            XCTAssertGreaterThan(
                MonknotMetrics.windowChromeLeadingReservedWidth(theme: theme, zoomScale: zoomScale),
                controlsTrailingEdge,
                "Window chrome reserve overlapped navigation controls at zoom \(zoomScale)"
            )
        }
    }

    func testTopNavigationControlsUseSharedChromeHeightAcrossSidebarStatesAndZooms() {
        let theme = AppTheme.codexDark

        for zoomStep in 7...30 {
            let zoomScale = Double(zoomStep) / 10

            for isSidebarVisible in [false, true] {
                let topBar = TopNavigationBar(
                    editorMode: .constant(.source),
                    isSplitViewEnabled: .constant(false),
                    emptyStateTitle: "Monknot",
                    selectedDocument: nil,
                    isBusy: false,
                    isDocumentLoading: false,
                    isSaving: false,
                    theme: theme,
                    zoomScale: zoomScale,
                    isTerminalPresented: true,
                    isSidebarVisible: isSidebarVisible,
                    toggleTerminal: {},
                    toggleSidebar: {},
                    outlineItems: [],
                    selectOutlineItem: { _ in },
                    toggleSplitView: {},
                    canToggleSplitView: false,
                    documentSearch: .constant(DocumentSearchState()),
                    tabs: [],
                    activeTabID: nil,
                    missingTabIDs: [],
                    saveState: { _ in .clean },
                    selectTab: { _ in },
                    closeTab: { _ in },
                    togglePinTab: { _ in },
                    reorderTab: { _, _ in },
                    typingAssistantAvailable: false,
                    typingAssistantEnabled: false,
                    toggleTypingAssistant: {}
                )
                let host = NSHostingView(rootView: topBar.frame(width: 2_000))

                XCTAssertEqual(
                    host.fittingSize.height,
                    MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale),
                    accuracy: 0.01,
                    "Top bar height drifted at zoom \(zoomScale), sidebar visible: \(isSidebarVisible)"
                )
            }
        }
    }

    func testDocumentTabsUseSharedChromeHeightAtEverySupportedZoom() {
        let theme = AppTheme.codexDark

        for zoomStep in 7...30 {
            let zoomScale = Double(zoomStep) / 10
            let tabBar = DocumentTabBar(
                tabs: [
                    WorkspaceTabItem(
                        documentID: "/README.md",
                        displayName: "README.md",
                        relativePath: "README.md",
                        kind: .markdown
                    )
                ],
                selectedDocumentID: "/README.md",
                missingDocumentIDs: [],
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: theme.uiFontSize,
                isDisabled: false,
                saveState: { _ in .clean },
                selectTab: { _ in },
                closeTab: { _ in },
                togglePin: { _ in },
                reorderTab: { _, _ in }
            )
            let host = NSHostingView(rootView: tabBar.frame(width: 600))

            XCTAssertEqual(
                host.fittingSize.height,
                MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale),
                accuracy: 0.01,
                "Tab chrome height drifted at zoom \(zoomScale)"
            )
        }
    }

    func testTerminalUsesCompactTopPaddingBelowItsChrome() {
        let html = TerminalWebView.html(
            theme: .codexDark,
            fontSize: 13.5,
            usePointerCursors: true,
            fontSmoothing: true
        )

        XCTAssertTrue(html.contains("padding: 12px 20px;"))
        XCTAssertFalse(html.contains("padding: 18px 20px;"))
    }
}
