import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceChromeMetricsTests: XCTestCase {
    func testComposedWorkspaceSplitKeepsEveryPrimaryChromeColumnOnOneCenterline() {
        for chromeHeight in [
            MonknotMetrics.chromeHeight(theme: .defaultDark, zoomScale: 1),
            MonknotMetrics.chromeHeight(theme: .defaultDark, zoomScale: WorkspaceZoomPolicy.maximum),
        ] {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true

            let host = NSHostingView(rootView: ChromeColumnOriginFixture(chromeHeight: chromeHeight))
            window.contentView = host
            host.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1_200, height: 760)
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()

            let centers = ["sidebar", "detail", "navigation"].compactMap { identifier -> (String, CGFloat)? in
                guard let view = host.allDescendantsForTesting().first(where: {
                    $0.identifier?.rawValue == "Monknot.Test.Chrome.\(identifier)"
                }) else {
                    XCTFail("Missing composed chrome marker: \(identifier)")
                    return nil
                }
                return (identifier, view.convert(
                    NSPoint(x: view.bounds.midX, y: view.bounds.midY),
                    to: host
                ).y)
            }

            XCTAssertEqual(centers.count, 3)
            let centerValues = centers.map(\.1)
            if let minimum = centerValues.min(), let maximum = centerValues.max() {
                XCTAssertEqual(
                    maximum,
                    minimum,
                    accuracy: 1,
                    "The composed workspace split introduced a second chrome y-origin at height \(chromeHeight): \(centers)"
                )
            }
        }
    }

    func testSettingsMenuSelectionTransactionPreviewsThenCancelsOrCommits() {
        var cancelled = SettingsMenuSelectionTransaction(initialSelection: "harbor-light")
        cancelled.preview("forge-light")
        XCTAssertEqual(cancelled.previewedSelection, "forge-light")
        XCTAssertEqual(cancelled.selectionAfterClose, "harbor-light")

        var committed = SettingsMenuSelectionTransaction(initialSelection: "harbor-light")
        committed.preview("forge-light")
        committed.commit("monolith-light")
        XCTAssertEqual(committed.previewedSelection, "monolith-light")
        XCTAssertEqual(committed.selectionAfterClose, "monolith-light")
    }

    func testWorkspaceChromeZoomUsesTheExactDiscreteFactor() {
        let theme = AppTheme.defaultDark
        let compact = theme.layoutScale(zoomScale: WorkspaceZoomPolicy.minimum)
        let normal = theme.layoutScale(zoomScale: 1)
        let enlarged = theme.layoutScale(zoomScale: 1.7)
        let maximum = theme.layoutScale(zoomScale: WorkspaceZoomPolicy.maximum)

        XCTAssertLessThan(compact, normal)
        XCTAssertGreaterThan(enlarged, normal)
        XCTAssertGreaterThan(maximum, enlarged)
        XCTAssertEqual(compact, 0.8, accuracy: 0.001)
        XCTAssertEqual(enlarged, 1.7, accuracy: 0.001)
        XCTAssertEqual(maximum, 2.0, accuracy: 0.001)
    }

    func testWorkspaceZoomPolicyUsesTheSpecifiedDiscreteLadder() {
        XCTAssertEqual(
            WorkspaceZoomPolicy.supportedLevels,
            [0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
        )
        for (rawZoom, documentScale) in zip(
            WorkspaceZoomPolicy.supportedLevels,
            WorkspaceZoomPolicy.shortcutDocumentScales
        ) {
            XCTAssertEqual(
                WorkspaceZoomPolicy.documentScale(rawZoom),
                documentScale,
                accuracy: 0.001
            )
        }
        XCTAssertEqual(
            WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.stepped(1, by: 0.1)),
            1.1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.stepped(1, by: -0.1)),
            0.9,
            accuracy: 0.001
        )
        XCTAssertEqual(WorkspaceZoomPolicy.stepped(1.9, by: 0.1), 2.0)
        XCTAssertEqual(WorkspaceZoomPolicy.stepped(2.0, by: 0.1), 2.0)
        XCTAssertEqual(WorkspaceZoomPolicy.stepped(0.8, by: -0.1), 0.8)
        XCTAssertEqual(WorkspaceZoomPolicy.stepped(1.3, by: 0), 1.3)
        XCTAssertEqual(WorkspaceZoomPolicy.clamp(.nan), WorkspaceZoomPolicy.defaultValue)
        XCTAssertEqual(WorkspaceZoomPolicy.clamp(.infinity), WorkspaceZoomPolicy.maximum)
        XCTAssertEqual(WorkspaceZoomPolicy.clamp(-.infinity), WorkspaceZoomPolicy.minimum)
        XCTAssertEqual(WorkspaceZoomPolicy.stepped(.infinity, by: 0.1), WorkspaceZoomPolicy.maximum)
        XCTAssertEqual(WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.minimum), 0.8, accuracy: 0.001)
        XCTAssertEqual(WorkspaceZoomPolicy.documentScale(1), 1, accuracy: 0.001)
        XCTAssertEqual(WorkspaceZoomPolicy.documentScale(2), 2, accuracy: 0.001)
        XCTAssertEqual(WorkspaceZoomPolicy.documentScale(WorkspaceZoomPolicy.maximum), 2, accuracy: 0.001)
        for documentScale in WorkspaceZoomPolicy.shortcutDocumentScales {
            XCTAssertEqual(
                WorkspaceZoomPolicy.documentScale(
                    WorkspaceZoomPolicy.rawZoom(forDocumentScale: documentScale)
                ),
                documentScale,
                accuracy: 0.001
            )
        }
    }

    func testCombinedFontAndZoomExtremesKeepOneWorkspaceFactor() {
        var largestConfiguration = ThemeConfiguration(theme: .defaultDark)
        largestConfiguration.uiFontSize = 24
        let largestTheme = largestConfiguration.applied(to: .defaultDark)
        var smallestConfiguration = ThemeConfiguration(theme: .defaultDark)
        smallestConfiguration.uiFontSize = 12
        let smallestTheme = smallestConfiguration.applied(to: .defaultDark)

        XCTAssertEqual(
            largestTheme.layoutScale(zoomScale: WorkspaceZoomPolicy.maximum),
            2.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            smallestTheme.layoutScale(zoomScale: WorkspaceZoomPolicy.minimum),
            0.8,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(
            MonknotMetrics.chromeButtonDimension(
                theme: smallestTheme,
                zoomScale: WorkspaceZoomPolicy.minimum
            ),
            22
        )

        XCTAssertEqual(
            largestTheme.interfaceTextScale(zoomScale: WorkspaceZoomPolicy.maximum),
            2.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            largestTheme.interfaceControlScale(zoomScale: WorkspaceZoomPolicy.maximum),
            2.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            largestTheme.interfaceRowScale(zoomScale: WorkspaceZoomPolicy.maximum),
            2.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            largestTheme.interfaceDensityScale(zoomScale: WorkspaceZoomPolicy.maximum),
            2.0,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(
            smallestTheme.interfaceTextScale(zoomScale: WorkspaceZoomPolicy.minimum),
            0.70
        )
    }

    func testHighDocumentZoomKeepsChromeIconsProportionalToAdjacentText() {
        let theme = AppTheme.defaultDark
        let normalIconSize = MonknotIconButton.IconButtonSize.chrome.iconSize(
            theme: theme,
            zoomScale: 1
        )
        let maximumIconSize = MonknotIconButton.IconButtonSize.chrome.iconSize(
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum
        )

        XCTAssertEqual(normalIconSize, 17, accuracy: 0.001)
        XCTAssertEqual(maximumIconSize, normalIconSize * 2, accuracy: 0.001)
        XCTAssertEqual(
            theme.interfaceGlyphScale(zoomScale: WorkspaceZoomPolicy.maximum),
            theme.interfaceTextScale(zoomScale: WorkspaceZoomPolicy.maximum),
            accuracy: 0.001
        )
    }

    func testSettingsRowsScaleTheirCompleteLayoutWithInterfaceZoom() {
        func fittingHeight(zoomScale: Double) -> CGFloat {
            let row = SettingsRow(
                theme: .defaultDark,
                title: "Workspace zoom",
                detail: "Scale typography, controls, padding, and spacing together",
                showsDivider: false
            ) {
                Text("100%")
            }
            .environment(\.monknotSettingsZoomScale, zoomScale)
            .frame(width: 520)

            return NSHostingView(rootView: row).fittingSize.height
        }

        let normalHeight = fittingHeight(zoomScale: 1)
        let maximumHeight = fittingHeight(zoomScale: 2)

        XCTAssertGreaterThan(maximumHeight, normalHeight * 1.75)
    }

    func testPrimaryChromeHeightPreservesTheProvenAdaptiveSpacingCurve() {
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let height = MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
                XCTAssertEqual(
                    height,
                    (MonknotMetrics.chromeHeightBase * theme.interfaceRowScale(zoomScale: zoomScale)).rounded()
                )
            }
        }
    }

    func testInterfaceTokensUseOneCoherentZoomFactor() {
        let theme = AppTheme.defaultDark
        let normal = 1.0

        XCTAssertEqual(theme.interfaceTextScale(zoomScale: normal), 1, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceGlyphScale(zoomScale: normal), 1, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceControlScale(zoomScale: normal), 1, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceRowScale(zoomScale: normal), 1, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceDensityScale(zoomScale: normal), 1, accuracy: 0.001)

        let compactScales = interfaceScales(theme: theme, zoomScale: WorkspaceZoomPolicy.minimum)
        let enlargedScales = interfaceScales(theme: theme, zoomScale: 2)
        let maximumScales = interfaceScales(theme: theme, zoomScale: WorkspaceZoomPolicy.maximum)

        for index in compactScales.indices {
            XCTAssertLessThan(compactScales[index], 1)
            XCTAssertGreaterThan(enlargedScales[index], 1)
            XCTAssertGreaterThanOrEqual(maximumScales[index], enlargedScales[index])
        }

        for scale in maximumScales {
            XCTAssertEqual(scale, 2, accuracy: 0.001)
        }
    }

    func testSidebarRowIconsStayTwoPointsLargerThanAdjacentLabels() {
        XCTAssertEqual(MonknotMetrics.sidebarIconPointSizeBase, 15)
        XCTAssertEqual(MonknotMetrics.rowIconColumnWidthBase, 18)

        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let iconSize = MonknotMetrics.interfaceGlyph(
                    MonknotMetrics.sidebarIconPointSizeBase,
                    theme: theme,
                    zoomScale: zoomScale
                )
                let labelSize = MonknotMetrics.interfaceText(
                    13,
                    theme: theme,
                    zoomScale: zoomScale
                )

                XCTAssertEqual(
                    iconSize - labelSize,
                    MonknotMetrics.interfaceGlyph(2, theme: theme, zoomScale: zoomScale),
                    accuracy: 0.5,
                    "Sidebar symbols outgrew their labels at zoom \(zoomScale)"
                )
            }
        }
    }

    func testVisuallyExpansiveSymbolsShareTheOpticalPointSizeCeiling() {
        let expansiveSymbols = [
            "magnifyingglass",
            "doc.text",
            "doc.richtext",
            "arrow.up.left.and.arrow.down.right",
            "arrow.down.right.and.arrow.up.left",
        ]

        for systemImage in expansiveSymbols {
            XCTAssertEqual(
                MonknotSymbolOptics.pointSizeBase(for: systemImage, nominal: 16),
                14,
                "\(systemImage) escaped the shared optical-size policy"
            )
        }
        XCTAssertEqual(MonknotSymbolOptics.pointSizeBase(for: "plus", nominal: 16), 16)
        XCTAssertEqual(MonknotSymbolOptics.pointSizeBase(for: "xmark", nominal: 16), 16)
        XCTAssertEqual(MonknotSymbolOptics.pointSizeBase(for: "doc.text", nominal: 12), 12)
    }

    func testSharedChromeOpticalProfilesCoverMeasuredOutliersOnly() {
        let measuredCeilings: [String: CGFloat] = [
            "character.cursor.ibeam": 12.5,
            "curlybraces": 13,
            "link": 13,
            "magnifyingglass": 14,
            "doc.text": 14,
            "doc.richtext": 14,
            "checklist": 14,
            "text.quote": 14,
            "photo": 12,
            "arrow.up.left.and.arrow.down.right": 14,
            "arrow.down.right.and.arrow.up.left": 14,
            "sidebar.left": 15,
            "sidebar.right": 15,
        ]

        for (systemImage, expectedCeiling) in measuredCeilings {
            XCTAssertEqual(
                MonknotSymbolOptics.maximumPointSizeBase(for: systemImage),
                expectedCeiling,
                "\(systemImage) lost its measured optical ceiling"
            )
        }

        for systemImage in ["bold", "italic", "list.bullet", "plus", "xmark"] {
            XCTAssertNil(
                MonknotSymbolOptics.maximumPointSizeBase(for: systemImage),
                "\(systemImage) should retain its nominal point size"
            )
        }
    }

    func testSearchOpticalCorrectionPreservesTheControlGeometry() {
        XCTAssertEqual(MonknotSymbolOptics.horizontalOffsetBase(for: "magnifyingglass"), -0.5)
        XCTAssertEqual(MonknotSymbolOptics.horizontalOffsetBase(for: "plus"), 0)

        let size = MonknotIconButton.IconButtonSize.sidebarHeader
        XCTAssertEqual(size.iconPointSizeBase, 16)
        XCTAssertEqual(
            MonknotSymbolOptics.pointSizeBase(
                for: MonknotWorkspaceIcons.searchWorkspace,
                nominal: size.iconPointSizeBase
            ),
            14
        )
        XCTAssertEqual(
            size.dimension(theme: .defaultDark, zoomScale: 1),
            22,
            "Optical symbol sizing must not shrink the action target"
        )
    }

    func testSidebarHeaderActionsShareRowSymbolStyleWithoutShrinkingHitTargets() {
        let size = MonknotIconButton.IconButtonSize.sidebarHeader

        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                XCTAssertEqual(
                    size.iconSize(theme: theme, zoomScale: zoomScale),
                    MonknotMetrics.interfaceGlyph(16, theme: theme, zoomScale: zoomScale),
                    accuracy: 0.001
                )
                XCTAssertEqual(
                    size.dimension(theme: theme, zoomScale: zoomScale),
                    MonknotMetrics.interfaceControl(22, theme: theme, zoomScale: zoomScale),
                    accuracy: 0.001
                )
            }
        }
    }

    func testTopNavigationOnlyShowsSourceAndPreviewModeButtons() {
        XCTAssertEqual(
            TopNavigationBar.markdownViewModeOptions.map(\.id),
            [EditorMode.source.rawValue, EditorMode.preview.rawValue]
        )
        XCTAssertFalse(
            TopNavigationBar.markdownViewModeOptions.contains { $0.accessibilityLabel == "Split" }
        )
    }

    func testReducedMotionDisablesSidebarAndDrawerMovement() {
        XCTAssertNil(MonknotMotion.paneTransition(reduceMotion: true))
        XCTAssertNotNil(MonknotMotion.paneTransition(reduceMotion: false))
    }

    func testPrimaryAndSecondaryChromePreserveTheirDistinctReferenceBands() {
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let primaryHeight = MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
                let secondaryHeight = MonknotMetrics.chromeSecondaryHeight(
                    theme: theme,
                    zoomScale: zoomScale
                )
                let tabChipHeight = MonknotMetrics.interfaceControl(
                    30,
                    theme: theme,
                    zoomScale: zoomScale
                )

                XCTAssertGreaterThan(
                    primaryHeight,
                    secondaryHeight,
                    "The 44pt titlebar and 34pt formatting row must remain distinct"
                )
                XCTAssertGreaterThanOrEqual(
                    primaryHeight,
                    tabChipHeight,
                    "The active 30pt file chip must fit inside the titlebar"
                )
            }
        }

        XCTAssertEqual(MonknotMetrics.chromeHeight(theme: .defaultDark, zoomScale: 1), 44)
        XCTAssertEqual(MonknotMetrics.chromeSecondaryHeight(theme: .defaultDark, zoomScale: 1), 34)
    }

    func testSegmentButtonsUseReferenceWidthAndShorterReferenceHeight() {
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let segment = MonknotSegmentButton(
                    systemImage: "text.alignleft",
                    accessibilityLabel: "Write",
                    isSelected: true,
                    theme: theme,
                    zoomScale: zoomScale,
                    action: {}
                )
                let toolbarButton = MonknotIconButton(
                    systemImage: "sidebar.right",
                    label: "Show Right Drawer",
                    theme: theme,
                    zoomScale: zoomScale,
                    action: {}
                )
                let segmentHost = NSHostingView(rootView: segment)
                let toolbarButtonHost = NSHostingView(rootView: toolbarButton)

                XCTAssertEqual(
                    segmentHost.fittingSize.width,
                    toolbarButtonHost.fittingSize.width,
                    accuracy: 0.01,
                    "Segment width diverged from toolbar buttons at zoom \(zoomScale)"
                )
                XCTAssertLessThan(
                    segmentHost.fittingSize.height,
                    toolbarButtonHost.fittingSize.height,
                    "Reference segments must remain 24pt high inside the 28pt shell"
                )
            }
        }
    }

    func testIconButtonsFillOnlyWhileEnabledAndPressedReplacesHover() {
        func fill(active: Bool = false, drawsActive: Bool = true, hovered: Bool = false, pressed: Bool = false, disabled: Bool = false) -> MonknotIconButton.Fill? {
            MonknotIconButton.fill(
                isActive: active,
                drawsActiveBackground: drawsActive,
                isHovered: hovered,
                isPressed: pressed,
                isDisabled: disabled
            )
        }

        XCTAssertNil(fill(), "Idle controls must not create a background")
        XCTAssertNil(fill(hovered: true, pressed: true, disabled: true), "Disabled controls never fill")
        XCTAssertEqual(fill(hovered: true), .hover)
        // design.md §5.1: pressed is its own fill, replacing hover rather than stacking on it.
        XCTAssertEqual(fill(hovered: true, pressed: true), .pressed)
        XCTAssertEqual(fill(active: true), .accentSoft, "An open panel's toggle uses accsoft")
        XCTAssertEqual(fill(active: true, pressed: true), .pressed)
    }

    func testSearchOptionButtonsUseAccentOnlyActiveAppearance() {
        XCTAssertNil(
            MonknotIconButton.fill(isActive: true, drawsActiveBackground: false, isHovered: false, isPressed: false, isDisabled: false),
            "An active search option must remain unfilled at rest"
        )
        XCTAssertEqual(
            MonknotIconButton.fill(isActive: true, drawsActiveBackground: false, isHovered: true, isPressed: false, isDisabled: false),
            .hover,
            "An active search option must use the standard hover surface"
        )
    }

    func testStateFillsComeFromTheDesignTokens() {
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            XCTAssertEqual(MonknotIconButton.Fill.hover.color(theme), theme.hoverFillColor)
            XCTAssertEqual(MonknotIconButton.Fill.pressed.color(theme), theme.pressedFillColor)
            XCTAssertEqual(MonknotIconButton.Fill.accentSoft.color(theme), theme.accentSoftFillColor)
            // design.md §1.2: hover ink 6 / 5.5 %, press ink 11 / 10 %, accsoft accent 18 / 14 %.
            XCTAssertEqual(theme.hoverFillColor, theme.foregroundColor.opacity(theme.isDark ? 0.06 : 0.055))
            XCTAssertEqual(theme.pressedFillColor, theme.foregroundColor.opacity(theme.isDark ? 0.11 : 0.10))
            XCTAssertEqual(theme.accentSoftFillColor, theme.accentColor.opacity(theme.isDark ? 0.18 : 0.14))
        }
    }

    func testSearchOptionButtonsUseTheStandardSharedMetrics() {
        let size = MonknotIconButton.IconButtonSize.findBar

        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            XCTAssertEqual(size.dimension(theme: theme, zoomScale: 1), 28)
            XCTAssertEqual(size.height(theme: theme, zoomScale: 1), 28)
            XCTAssertEqual(size.iconSize(theme: theme, zoomScale: 1), 17)
        }
    }

    func testSharedShortcutLabelKeepsModifierClustersAtOneReadableHeight() {
        let shortcuts = ["⇧⌘F", "⌘,", "⌃⌘T"]

        XCTAssertEqual(MonknotShortcutLabel.fontSizeBase, 12)
        XCTAssertEqual(MonknotShortcutLabel.fontWeight, .regular)
        XCTAssertEqual(MonknotShortcutLabel.fontDesign, .rounded)

        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in [1.0, WorkspaceZoomPolicy.maximum] {
                let heights = shortcuts.map { shortcut in
                    NSHostingView(rootView: MonknotShortcutLabel(
                        shortcut: shortcut,
                        theme: theme,
                        zoomScale: zoomScale
                    )).fittingSize.height
                }
                let minimumHeight = MonknotMetrics.interfaceText(
                    MonknotShortcutLabel.fontSizeBase,
                    theme: theme,
                    zoomScale: zoomScale
                )

                XCTAssertEqual(
                    heights.max() ?? 0,
                    heights.min() ?? 0,
                    accuracy: 0.01
                )
                XCTAssertGreaterThanOrEqual(heights[0], minimumHeight)
            }
        }
    }

    func testShortcutReferenceKeyCapAddsOnlyTheSharedInsetGeometry() {
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            let hint = NSHostingView(rootView: MonknotShortcutLabel(
                shortcut: "⇧⌘F",
                theme: theme,
                zoomScale: 1
            )).fittingSize
            let keyCap = NSHostingView(rootView: MonknotShortcutLabel(
                shortcut: "⇧⌘F",
                theme: theme,
                zoomScale: 1,
                presentation: .keyCap
            )).fittingSize

            XCTAssertEqual(
                keyCap.width,
                hint.width + 2 * MonknotShortcutLabel.keyCapHorizontalPaddingBase,
                accuracy: 0.01
            )
            XCTAssertEqual(
                keyCap.height,
                hint.height + 2 * MonknotShortcutLabel.keyCapVerticalPaddingBase,
                accuracy: 0.01
            )
        }
    }

    func testCommandOverlayCloseIsTheStandardCompactCloseButton() {
        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            let size = NSHostingView(rootView: MonknotCommandOverlayCloseButton(
                theme: theme,
                zoomScale: 1,
                close: {}
            )).fittingSize

            XCTAssertEqual(size.width, 26, accuracy: 0.01)
            XCTAssertEqual(size.height, 26, accuracy: 0.01)
        }
    }

    func testCommandOverlayPanelFitsItsRowsHeaderAndFooter() {
        let theme = AppTheme.defaultDark
        // 44 header + 1 rule + three 34 rows with 2 between + 12 list padding + 1 rule + 30 footer.
        let threeRows: CGFloat = 44 + 1 + 118 + 31
        XCTAssertEqual(
            MonknotCommandOverlayMetrics.panelHeight(rows: 3, hasFooter: true, theme: theme, zoomScale: 1),
            threeRows,
            accuracy: 0.01
        )
        // At most eight rows show (8 × 34 + 7 × 2 + 12); the rest scroll.
        let eightRows: CGFloat = 44 + 1 + 298
        XCTAssertEqual(
            MonknotCommandOverlayMetrics.panelHeight(rows: 20, hasFooter: false, theme: theme, zoomScale: 1),
            eightRows,
            accuracy: 0.01
        )
    }

    func testSegmentedIconButtonsScaleFromTheThirtyPointEditorReferenceBox() {
        let size = MonknotIconButton.IconButtonSize.segmented

        for theme in [AppTheme.defaultLight, AppTheme.defaultDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                XCTAssertEqual(
                    size.dimension(theme: theme, zoomScale: zoomScale),
                    MonknotMetrics.interfaceControl(30, theme: theme, zoomScale: zoomScale),
                    accuracy: 0.001
                )
            }
        }
    }

    func testTopNavigationControlsUseSharedChromeHeightAcrossSidebarStatesAndZooms() {
        let theme = AppTheme.defaultDark

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {

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
                    toggleSplitView: {},
                    documentSearch: .constant(DocumentSearchState()),
                    searchOptions: .constant(MonknotSearchOptions()),
                    dismissDocumentSearch: {},
                    documentSearchFocusChanged: { _ in },
                    tabs: [],
                    activeTabID: nil,
                    missingTabIDs: [],
                    saveState: { _ in .clean },
                    selectTab: { _ in },
                    closeTab: { _ in },
                    togglePinTab: { _ in },
                    reorderTab: { _, _ in }
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
}
