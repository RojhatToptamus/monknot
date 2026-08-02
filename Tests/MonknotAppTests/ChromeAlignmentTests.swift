import AppKit
import MonknotCore
import ObjectiveC.runtime
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class ChromeAlignmentTests: XCTestCase {
    func testComposedWorkspaceSplitKeepsEveryPrimaryChromeColumnOnOneCenterline() {
        for chromeHeight in [
            MonknotMetrics.chromeHeight(theme: .codexDark, zoomScale: 1),
            MonknotMetrics.chromeHeight(theme: .codexDark, zoomScale: WorkspaceZoomPolicy.maximum),
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

    func testTerminalFocusRestorerReturnsKeyboardFocusToTheDocument() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let terminalResponder = NSTextView(frame: NSRect(x: 320, y: 0, width: 320, height: 480))
        window.contentView?.addSubview(documentEditor)
        window.contentView?.addSubview(terminalResponder)
        XCTAssertTrue(window.makeFirstResponder(documentEditor))

        let restorer = TerminalFocusRestorer()
        restorer.capture(from: window)
        XCTAssertTrue(window.makeFirstResponder(terminalResponder))

        restorer.restore()
        await Task.yield()

        XCTAssertTrue(window.firstResponder === documentEditor)
    }

    func testTerminalFocusRestorerSurvivesRapidCloseAndReopen() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let terminalResponder = NSTextView(frame: NSRect(x: 320, y: 0, width: 320, height: 480))
        window.contentView?.addSubview(documentEditor)
        window.contentView?.addSubview(terminalResponder)
        XCTAssertTrue(window.makeFirstResponder(documentEditor))

        let restorer = TerminalFocusRestorer()
        restorer.capture(from: window)
        XCTAssertTrue(window.makeFirstResponder(terminalResponder))
        restorer.restore()

        restorer.capture(from: window)
        XCTAssertTrue(window.firstResponder === terminalResponder)
        restorer.restore()
        await Task.yield()

        XCTAssertTrue(window.firstResponder === documentEditor)
    }

    func testTerminalFocusRestorerUsesSourceFirstRegisteredTargetAfterMenuFocusLoss() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let documentEditor = NSTextView(frame: documentScrollView.bounds)
        documentEditor.identifier = .monknotDocumentFocusTarget
        documentScrollView.documentView = documentEditor
        let documentPreview = NSTextView(frame: NSRect(x: 160, y: 0, width: 160, height: 480))
        documentPreview.identifier = .monknotDocumentFocusTarget
        let terminalResponder = NSTextView(frame: NSRect(x: 320, y: 0, width: 320, height: 480))
        window.contentView?.addSubview(documentScrollView)
        window.contentView?.addSubview(documentPreview)
        window.contentView?.addSubview(terminalResponder)
        XCTAssertTrue(window.makeFirstResponder(documentEditor))
        XCTAssertTrue(window.makeFirstResponder(nil))

        let restorer = TerminalFocusRestorer()
        restorer.capture(from: window)
        XCTAssertTrue(window.makeFirstResponder(terminalResponder))
        restorer.restore(fallbackFrom: window)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === documentEditor)
    }

    func testThemeEditComparisonIgnoresHexLetterCase() {
        var lowercase = ThemeConfiguration(theme: AppTheme.codexLight)
        lowercase.accent = lowercase.accent.lowercased()
        var uppercase = lowercase
        uppercase.accent = uppercase.accent.uppercased()

        XCTAssertEqual(
            lowercase.sanitized(for: AppTheme.codexLight),
            uppercase.sanitized(for: AppTheme.codexLight),
            "Focusing a hex field must not create a false edited state solely from case normalization"
        )
    }

    func testWorkspaceChromeZoomIsBoundedAndMonotonic() {
        let theme = AppTheme.codexDark
        let compact = theme.layoutScale(zoomScale: 0.7)
        let normal = theme.layoutScale(zoomScale: 1)
        let enlarged = theme.layoutScale(zoomScale: 1.7)
        let maximum = theme.layoutScale(zoomScale: WorkspaceZoomPolicy.maximum)

        XCTAssertLessThan(compact, normal)
        XCTAssertGreaterThan(enlarged, normal)
        XCTAssertGreaterThan(maximum, enlarged)
        XCTAssertGreaterThanOrEqual(compact, 0.85)
        XCTAssertLessThanOrEqual(enlarged, 1.2)
        XCTAssertEqual(maximum, 1.2, accuracy: 0.001)
    }

    func testWorkspaceZoomPolicyAddsAStableExtendedRange() {
        XCTAssertEqual(WorkspaceZoomPolicy.supportedLevels.first, 0.7)
        XCTAssertEqual(WorkspaceZoomPolicy.supportedLevels.last, 5.0)
        XCTAssertEqual(WorkspaceZoomPolicy.supportedLevels.count, 44)
        XCTAssertEqual(WorkspaceZoomPolicy.stepped(4.9, by: 0.1), 5.0)
        XCTAssertEqual(WorkspaceZoomPolicy.stepped(5.0, by: 0.1), 5.0)
        XCTAssertEqual(WorkspaceZoomPolicy.stepped(0.7, by: -0.1), 0.7)
    }

    func testTerminalContentZoomRemainsReadableAcrossTheWorkspaceRange() {
        var previous = WorkspaceZoomPolicy.terminalContentScale(WorkspaceZoomPolicy.minimum)

        for zoomScale in WorkspaceZoomPolicy.supportedLevels.dropFirst() {
            let current = WorkspaceZoomPolicy.terminalContentScale(zoomScale)
            XCTAssertGreaterThanOrEqual(current, previous)
            XCTAssertLessThanOrEqual(current, WorkspaceZoomPolicy.maximumTerminalContentScale)
            previous = current
        }

        XCTAssertEqual(WorkspaceZoomPolicy.terminalContentScale(2.4), 2.4)
        XCTAssertEqual(WorkspaceZoomPolicy.terminalContentScale(5), 2.5)
    }

    func testQuietSidebarSecondaryInkStaysLegibleWithoutDoubleOpacity() {
        for baseTheme in [AppTheme.codexLight, AppTheme.codexDark] {
            var configuration = ThemeConfiguration(theme: baseTheme)
            let standard = baseTheme.sidebarMutedOpacity(prominence: 0.68)
            configuration.quietSidebar = true
            let quietTheme = configuration.applied(to: baseTheme)
            let quiet = quietTheme.sidebarMutedOpacity(prominence: 0.68)

            XCTAssertLessThan(quiet, standard)
            XCTAssertGreaterThanOrEqual(quiet, baseTheme.isDark ? 0.48 : 0.52)
        }
    }

    func testCombinedFontAndZoomExtremesKeepChromeWithinNativeBounds() {
        var largestConfiguration = ThemeConfiguration(theme: .codexDark)
        largestConfiguration.uiFontSize = 24
        let largestTheme = largestConfiguration.applied(to: .codexDark)
        var smallestConfiguration = ThemeConfiguration(theme: .codexDark)
        smallestConfiguration.uiFontSize = 12
        let smallestTheme = smallestConfiguration.applied(to: .codexDark)

        XCTAssertEqual(
            largestTheme.layoutScale(zoomScale: WorkspaceZoomPolicy.maximum),
            1.35,
            accuracy: 0.001
        )
        XCTAssertEqual(
            smallestTheme.layoutScale(zoomScale: WorkspaceZoomPolicy.minimum),
            0.875,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(
            MonknotMetrics.chromeButtonDimension(
                theme: smallestTheme,
                zoomScale: WorkspaceZoomPolicy.minimum
            ),
            24
        )

        XCTAssertEqual(
            largestTheme.interfaceTextScale(zoomScale: WorkspaceZoomPolicy.maximum),
            1.55,
            accuracy: 0.001
        )
        XCTAssertEqual(
            largestTheme.interfaceControlScale(zoomScale: WorkspaceZoomPolicy.maximum),
            1.45,
            accuracy: 0.001
        )
        XCTAssertEqual(
            largestTheme.interfaceRowScale(zoomScale: WorkspaceZoomPolicy.maximum),
            1.40,
            accuracy: 0.001
        )
        XCTAssertEqual(
            largestTheme.interfaceDensityScale(zoomScale: WorkspaceZoomPolicy.maximum),
            1.18,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(
            smallestTheme.interfaceTextScale(zoomScale: WorkspaceZoomPolicy.minimum),
            0.84
        )
    }

    func testHighDocumentZoomKeepsChromeIconsVisuallyProportionate() {
        let theme = AppTheme.codexDark
        let normalIconSize = MonknotIconButton.IconButtonSize.chrome.iconSize(
            theme: theme,
            zoomScale: 1
        )
        let maximumIconSize = MonknotIconButton.IconButtonSize.chrome.iconSize(
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum
        )

        XCTAssertEqual(normalIconSize, 13, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(maximumIconSize, 20)
        XCTAssertLessThanOrEqual(maximumIconSize, 21)
    }

    func testWorkspaceWindowChromePreservesNativeWindowControlsAndToolbarOwnership() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let toolbar = NSToolbar(identifier: "MonknotChromeRegressionToolbar")
        window.toolbar = toolbar

        let coordinator = WindowBackgroundDragEnabler.Coordinator(suppressToolbarButton: true)
        coordinator.configureWindowChrome(in: window)

        XCTAssertTrue(
            window.toolbar === toolbar,
            "Window chrome support must not dismantle AppKit-owned title-bar infrastructure"
        )
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertNotNil(window.standardWindowButton(.zoomButton))
    }

    func testNativeTrafficLightsCenterVerticallyInTheAdaptiveWorkspaceChromeBand() {
        for chromeHeight in [
            MonknotMetrics.chromeHeight(theme: .codexLight, zoomScale: WorkspaceZoomPolicy.minimum),
            MonknotMetrics.chromeHeight(theme: .codexLight, zoomScale: 1),
            MonknotMetrics.chromeHeight(theme: .codexLight, zoomScale: WorkspaceZoomPolicy.maximum),
        ] {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true

            let coordinator = WindowBackgroundDragEnabler.Coordinator(
                suppressToolbarButton: true,
                trafficLightRowHeight: chromeHeight
            )
            coordinator.configureWindowChrome(in: window)
            window.layoutIfNeeded()

            XCTAssertNil(
                window.toolbar,
                "A second native toolbar would cover the custom workspace row"
            )

            guard let closeButton = window.standardWindowButton(.closeButton),
                  let titlebarContainer = closeButton.superview
            else {
                XCTFail("Missing AppKit-owned native close button")
                continue
            }

            let buttons = [
                window.standardWindowButton(.closeButton),
                window.standardWindowButton(.miniaturizeButton),
                window.standardWindowButton(.zoomButton),
            ].compactMap { $0 }
            let largestHalfHeight = (buttons.map(\.frame.height).max() ?? 0) / 2
            let expectedCenterFromTop = min(
                max(chromeHeight / 2, largestHalfHeight),
                titlebarContainer.bounds.height - largestHalfHeight
            )

            for button in buttons {
                XCTAssertTrue(button.superview === titlebarContainer)
                XCTAssertEqual(
                    titlebarContainer.bounds.maxY - button.frame.midY,
                    expectedCenterFromTop,
                    accuracy: 0.001,
                    "Every native traffic light must share Monknot's primary chrome centerline"
                )
            }
        }
    }

    func testNativeTrafficLightAlignmentReappliesAfterWindowLayoutChange() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        let chromeHeight = MonknotMetrics.chromeHeight(
            theme: .codexLight,
            zoomScale: 1
        )
        let coordinator = WindowBackgroundDragEnabler.Coordinator(
            suppressToolbarButton: true,
            trafficLightRowHeight: chromeHeight
        )
        coordinator.observeWindow(window)
        coordinator.configureWindowChrome(in: window)

        guard let closeButton = window.standardWindowButton(.closeButton),
              let titlebarContainer = closeButton.superview
        else {
            return XCTFail("Missing AppKit-owned native close button")
        }

        closeButton.setFrameOrigin(NSPoint(x: closeButton.frame.minX, y: 9))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)

        XCTAssertEqual(
            titlebarContainer.bounds.maxY - closeButton.frame.midY,
            chromeHeight / 2,
            accuracy: 0.001,
            "Resize and state transitions must restore the native controls to Monknot's centerline"
        )
    }

    func testPrimaryChromeHeightPreservesTheProvenAdaptiveSpacingCurve() {
        for theme in [AppTheme.codexLight, AppTheme.codexDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let height = MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
                XCTAssertEqual(
                    height,
                    (MonknotMetrics.chromeHeightBase * theme.interfaceRowScale(zoomScale: zoomScale)).rounded()
                )
            }
        }
    }

    func testInterfaceTokensStayMonotonicAndIndependentlyBounded() {
        let theme = AppTheme.codexDark
        let normal = 1.0
        let maximum = WorkspaceZoomPolicy.maximum

        XCTAssertEqual(theme.interfaceTextScale(zoomScale: normal), 1, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceGlyphScale(zoomScale: normal), 1, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceControlScale(zoomScale: normal), 1, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceRowScale(zoomScale: normal), 1, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceDensityScale(zoomScale: normal), 1, accuracy: 0.001)

        XCTAssertEqual(theme.interfaceTextScale(zoomScale: maximum), 1.35, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceGlyphScale(zoomScale: maximum), 1.55, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceControlScale(zoomScale: maximum), 1.40, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceRowScale(zoomScale: maximum), 1.35, accuracy: 0.001)
        XCTAssertEqual(theme.interfaceDensityScale(zoomScale: maximum), 1.15, accuracy: 0.001)

        var previousText = theme.interfaceTextScale(zoomScale: WorkspaceZoomPolicy.minimum)
        var previousGlyph = theme.interfaceGlyphScale(zoomScale: WorkspaceZoomPolicy.minimum)
        var previousControl = theme.interfaceControlScale(zoomScale: WorkspaceZoomPolicy.minimum)
        var previousRow = theme.interfaceRowScale(zoomScale: WorkspaceZoomPolicy.minimum)
        var previousDensity = theme.interfaceDensityScale(zoomScale: WorkspaceZoomPolicy.minimum)

        for zoomScale in WorkspaceZoomPolicy.supportedLevels.dropFirst() {
            let text = theme.interfaceTextScale(zoomScale: zoomScale)
            let glyph = theme.interfaceGlyphScale(zoomScale: zoomScale)
            let control = theme.interfaceControlScale(zoomScale: zoomScale)
            let row = theme.interfaceRowScale(zoomScale: zoomScale)
            let density = theme.interfaceDensityScale(zoomScale: zoomScale)

            XCTAssertGreaterThanOrEqual(text, previousText)
            XCTAssertGreaterThanOrEqual(glyph, previousGlyph)
            XCTAssertGreaterThanOrEqual(control, previousControl)
            XCTAssertGreaterThanOrEqual(row, previousRow)
            XCTAssertGreaterThanOrEqual(density, previousDensity)

            previousText = text
            previousGlyph = glyph
            previousControl = control
            previousRow = row
            previousDensity = density
        }
    }

    func testTopBarCollapsesSecondaryActionsByEffectiveWidth() {
        let theme = AppTheme.codexDark

        XCTAssertEqual(
            MonknotMetrics.topBarLayoutMode(availableWidth: 700, theme: theme, zoomScale: 1),
            .regular
        )
        XCTAssertEqual(
            MonknotMetrics.topBarLayoutMode(availableWidth: 500, theme: theme, zoomScale: 1),
            .compact
        )
        XCTAssertEqual(
            MonknotMetrics.topBarLayoutMode(availableWidth: 320, theme: theme, zoomScale: 1),
            .minimal
        )

        XCTAssertEqual(
            MonknotMetrics.topBarLayoutMode(
                availableWidth: 690,
                theme: theme,
                zoomScale: WorkspaceZoomPolicy.maximum
            ),
            .regular
        )
        XCTAssertEqual(
            MonknotMetrics.topBarLayoutMode(
                availableWidth: 600,
                theme: theme,
                zoomScale: WorkspaceZoomPolicy.maximum
            ),
            .compact
        )
        XCTAssertEqual(
            MonknotMetrics.topBarLayoutMode(
                availableWidth: 400,
                theme: theme,
                zoomScale: WorkspaceZoomPolicy.maximum
            ),
            .minimal
        )
        XCTAssertEqual(
            MonknotMetrics.topBarLayoutMode(
                availableWidth: 480,
                theme: theme.replacing(uiFontSize: 24),
                zoomScale: WorkspaceZoomPolicy.maximum
            ),
            .minimal,
            "The narrowest high-zoom detail width must preserve useful space for the active tab"
        )
    }

    func testTerminalDrawerUsesFullDetailTakeoverBelowReadableSplitWidth() {
        for availableWidth in [CGFloat(557), 759] {
            let layout = TerminalDrawerLayoutPolicy.resolve(
                availableWidth: availableWidth,
                preferredDrawerWidth: 600
            )

            XCTAssertEqual(layout.presentation, .takeover)
            XCTAssertEqual(layout.drawerWidth, availableWidth, accuracy: 0.001)
            XCTAssertEqual(layout.maximumDrawerWidth, availableWidth, accuracy: 0.001)
            XCTAssertFalse(layout.isResizable)
        }
    }

    func testTerminalDrawerSideBySideLayoutProtectsEditorAndDrawerMinimums() {
        let threshold = MonknotMetrics.editorMinimumReadableWidth
            + MonknotMetrics.terminalDrawerMinWidth
        let thresholdLayout = TerminalDrawerLayoutPolicy.resolve(
            availableWidth: threshold,
            preferredDrawerWidth: 420
        )
        let preferredLayout = TerminalDrawerLayoutPolicy.resolve(
            availableWidth: 900,
            preferredDrawerWidth: 420
        )
        let maximumLayout = TerminalDrawerLayoutPolicy.resolve(
            availableWidth: 1_200,
            preferredDrawerWidth: 900
        )
        let minimumLayout = TerminalDrawerLayoutPolicy.resolve(
            availableWidth: 900,
            preferredDrawerWidth: 100
        )

        XCTAssertEqual(thresholdLayout.presentation, .sideBySide)
        XCTAssertEqual(
            thresholdLayout.drawerWidth,
            MonknotMetrics.terminalDrawerMinWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            threshold - thresholdLayout.drawerWidth,
            MonknotMetrics.editorMinimumReadableWidth,
            accuracy: 0.001
        )
        XCTAssertFalse(thresholdLayout.isResizable)

        XCTAssertEqual(preferredLayout.drawerWidth, 420, accuracy: 0.001)
        XCTAssertTrue(preferredLayout.isResizable)
        XCTAssertGreaterThanOrEqual(
            900 - preferredLayout.drawerWidth,
            MonknotMetrics.editorMinimumReadableWidth
        )

        XCTAssertEqual(
            maximumLayout.drawerWidth,
            MonknotMetrics.terminalDrawerMaxWidth,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(
            1_200 - maximumLayout.drawerWidth,
            MonknotMetrics.editorMinimumReadableWidth
        )

        XCTAssertEqual(
            minimumLayout.drawerWidth,
            MonknotMetrics.terminalDrawerMinWidth,
            accuracy: 0.001
        )
    }

    func testReducedMotionDisablesSidebarAndDrawerMovement() {
        XCTAssertNil(MonknotMotion.sidebarTransition(reduceMotion: true))
        XCTAssertNotNil(MonknotMotion.sidebarTransition(reduceMotion: false))
    }

    func testDisabledWindowNavigationAvoidsDoubleAttenuation() {
        let size = MonknotIconButton.IconButtonSize.windowNavigation

        XCTAssertGreaterThanOrEqual(
            size.disabledControlOpacity,
            0.7,
            "Disabled Back and Forward controls must remain visibly identifiable"
        )
    }

    func testWindowNavigationUsesSharedChromeMetricsAcrossSupportedZooms() {
        let theme = AppTheme.codexDark
        let navigationSize = MonknotIconButton.IconButtonSize.windowNavigation
        let chromeSize = MonknotIconButton.IconButtonSize.chrome

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {

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

    func testPrimaryChromeKeepsCompactBalancedInsetsAcrossThemesAndZooms() {
        for theme in [AppTheme.codexLight, AppTheme.codexDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let chromeHeight = MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
                let buttonDimension = MonknotMetrics.chromeButtonDimension(
                    theme: theme,
                    zoomScale: zoomScale
                )
                let verticalInset = (chromeHeight - buttonDimension) / 2

                XCTAssertEqual(
                    chromeHeight,
                    MonknotMetrics.chromeSecondaryHeight(theme: theme, zoomScale: zoomScale),
                    accuracy: 0.001,
                    "Primary and secondary chrome drifted at zoom \(zoomScale)"
                )
                XCTAssertGreaterThanOrEqual(
                    verticalInset,
                    5,
                    "Primary chrome lost the expanded top/bottom breathing room required by the design"
                )
                XCTAssertLessThanOrEqual(
                    verticalInset,
                    MonknotMetrics.scale(
                        MonknotMetrics.Spacing.xs,
                        theme: theme,
                        zoomScale: zoomScale
                    ) + 0.5,
                    "Primary chrome regained excessive vertical padding at zoom \(zoomScale)"
                )
            }
        }
    }

    func testSegmentButtonsMatchSharedToolbarButtonSizeAcrossThemesAndZooms() {
        for theme in [AppTheme.codexLight, AppTheme.codexDark] {
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
                XCTAssertEqual(
                    segmentHost.fittingSize.height,
                    toolbarButtonHost.fittingSize.height,
                    accuracy: 0.01,
                    "Segment height diverged from toolbar buttons at zoom \(zoomScale)"
                )
            }
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

    func testChromeButtonsOnlyDrawBackgroundWhileEnabledAndHovered() {
        for size in [
            MonknotIconButton.IconButtonSize.chrome,
            .windowNavigation,
            .compact,
            .findBar,
            .segmented
        ] {
            for isDark in [false, true] {
                XCTAssertNil(
                    size.backgroundOpacity(isHovered: false, isDisabled: false, isDark: isDark),
                    "Idle controls must not create a background"
                )
                XCTAssertNil(
                    size.backgroundOpacity(isHovered: true, isDisabled: true, isDark: isDark),
                    "Disabled controls must not create a hover background"
                )
                XCTAssertNotNil(
                    size.backgroundOpacity(isHovered: true, isDisabled: false, isDark: isDark),
                    "Enabled controls should retain a hover affordance"
                )
            }
        }
    }

    func testSegmentedIconButtonsKeepAKeyboardFriendlyMinimumTarget() {
        let size = MonknotIconButton.IconButtonSize.segmented

        for theme in [AppTheme.codexLight, AppTheme.codexDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                XCTAssertGreaterThanOrEqual(
                    size.dimension(theme: theme, zoomScale: zoomScale),
                    28
                )
            }
        }
    }

    func testActiveChromeButtonsHaveAStableSelectedSurface() {
        let size = MonknotIconButton.IconButtonSize.chrome

        for isDark in [false, true] {
            XCTAssertGreaterThan(
                size.activeBackgroundOpacity(isDark: isDark),
                size.hoverBackgroundOpacity(isDark: isDark),
                "A selected toggle must remain more visible than a transient hover"
            )
        }
    }

    func testStandardZoomKeysCanRouteToFocusedPDFKit() {
        XCTAssertEqual(
            MonknotNativePDFZoomCommand.action(for: keyEvent("=", modifiers: [.command])),
            .zoomIn
        )
        XCTAssertEqual(
            MonknotNativePDFZoomCommand.action(for: keyEvent("+", modifiers: [.command, .shift])),
            .zoomIn
        )
        XCTAssertEqual(
            MonknotNativePDFZoomCommand.action(for: keyEvent("-", modifiers: [.command])),
            .zoomOut
        )
        XCTAssertEqual(
            MonknotNativePDFZoomCommand.action(for: keyEvent("0", modifiers: [.command])),
            .actualSize
        )
        XCTAssertNil(MonknotNativePDFZoomCommand.action(for: keyEvent("=", modifiers: [])))
        XCTAssertNil(MonknotNativePDFZoomCommand.action(for: keyEvent("=", modifiers: [.command, .option])))
    }

    func testCloseGuardPreservesExistingWindowDelegateCallbacks() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let originalDelegate = StandardFrameWindowDelegate()
        window.delegate = originalDelegate
        let coordinator = WindowCloseGuard.Coordinator(shouldClose: { true })
        coordinator.install(on: window)

        let proposedFrame = NSRect(x: 20, y: 30, width: 800, height: 600)
        let resolvedFrame = window.delegate?.windowWillUseStandardFrame?(
            window,
            defaultFrame: proposedFrame
        )

        XCTAssertEqual(originalDelegate.standardFrameCallCount, 1)
        XCTAssertEqual(resolvedFrame, proposedFrame.insetBy(dx: 12, dy: 12))
    }

    func testExplicitTitleBarGapIsMovableWithoutCustomDoubleClickHandling() {
        let dragView = WindowTitleBarDragArea.NativeTitleBarDragView(frame: .zero)
        let selector = #selector(NSView.mouseDown(with:))
        let nativeImplementation = class_getMethodImplementation(NSView.self, selector)
        let dragImplementation = class_getMethodImplementation(
            WindowTitleBarDragArea.NativeTitleBarDragView.self,
            selector
        )

        XCTAssertTrue(dragView.mouseDownCanMoveWindow)
        XCTAssertEqual(
            nativeImplementation,
            dragImplementation,
            "The drag view must leave double-click interpretation to AppKit"
        )
    }

    func testWindowNavigationControlsUseSharedChromeHeightAtEverySupportedZoom() {
        let theme = AppTheme.codexDark

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {
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

    func testSidebarAndTerminalPrimaryRowsUseSharedChromeHeightAtEverySupportedZoom() {
        for theme in [AppTheme.codexLight, AppTheme.codexDark] {
            let sessions = TerminalSessionCollectionStore()

            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let sidebarRow = SidebarChromeRow(
                    openFolder: {},
                    createMarkdown: {},
                    canCreateMarkdown: true,
                    isBusy: false,
                    theme: theme,
                    zoomScale: zoomScale,
                    uiFontSize: theme.uiFontSize
                )
                let terminalRow = TerminalDrawerChromeRow(
                    sessions: sessions,
                    workingDirectory: nil,
                    theme: theme,
                    zoomScale: zoomScale,
                    uiFontSize: theme.uiFontSize,
                    close: {}
                )
                let sidebarHost = NSHostingView(rootView: sidebarRow.frame(width: 420))
                let terminalHost = NSHostingView(rootView: terminalRow.frame(width: 420))
                let expectedHeight = MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)

                XCTAssertEqual(sidebarHost.fittingSize.height, expectedHeight, accuracy: 0.01)
                XCTAssertEqual(terminalHost.fittingSize.height, expectedHeight, accuracy: 0.01)
            }
        }
    }

    func testTerminalPrimaryRowsKeepTabsInHorizontalScrollContainers() {
        let theme = AppTheme.codexDark
        let sessions = TerminalSessionCollectionStore()
        XCTAssertNotNil(sessions.createTerminal(in: FileManager.default.temporaryDirectory))
        defer { sessions.stopAll() }

        let takeoverHost = NSHostingView(rootView: TerminalDrawerTakeoverSegment(
            sessions: sessions,
            workingDirectory: nil,
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum,
            uiFontSize: theme.uiFontSize,
            close: {}
        ))
        let drawerHost = NSHostingView(rootView: TerminalDrawerChromeRow(
            sessions: sessions,
            workingDirectory: nil,
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum,
            uiFontSize: theme.uiFontSize,
            close: {}
        ))
        takeoverHost.layoutSubtreeIfNeeded()
        drawerHost.layoutSubtreeIfNeeded()

        for host in [takeoverHost, drawerHost] {
            XCTAssertTrue(
                host.allDescendantsForTesting().contains { $0 is NSScrollView },
                "Every terminal presentation must keep excess tabs in a bounded horizontal scroller"
            )
        }
        XCTAssertEqual(
            takeoverHost.fittingSize.height,
            MonknotMetrics.chromeHeight(
                theme: theme,
                zoomScale: WorkspaceZoomPolicy.maximum
            ),
            accuracy: 0.01
        )
    }

    func testWindowNavigationReserveContainsControlsAtEverySupportedZoom() {
        let theme = AppTheme.codexDark

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {
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

    func testDocumentSearchKeepsTheFileTabScrollerMountedInThePrimaryRow() {
        let theme = AppTheme.codexDark
        var search = DocumentSearchState()
        search.present()
        let tab = WorkspaceTabItem(
            documentID: "/README.md",
            displayName: "README.md",
            relativePath: "README.md",
            kind: .markdown
        )
        let topBar = TopNavigationBar(
            editorMode: .constant(.source),
            isSplitViewEnabled: .constant(false),
            emptyStateTitle: "Monknot",
            selectedDocument: nil,
            isBusy: false,
            isDocumentLoading: false,
            isSaving: false,
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum,
            isTerminalPresented: false,
            isSidebarVisible: true,
            toggleTerminal: {},
            toggleSidebar: {},
            outlineItems: [],
            selectOutlineItem: { _ in },
            toggleSplitView: {},
            canToggleSplitView: false,
            documentSearch: .constant(search),
            tabs: [tab],
            activeTabID: tab.documentID,
            missingTabIDs: [],
            saveState: { _ in .clean },
            selectTab: { _ in },
            closeTab: { _ in },
            togglePinTab: { _ in },
            reorderTab: { _, _ in }
        )
        let host = NSHostingView(rootView: topBar.frame(width: 920))
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.allDescendantsForTesting().contains { $0 is NSScrollView },
            "Presenting document search must not unmount or replace the file-tab strip"
        )
        XCTAssertTrue(
            host.allDescendantsForTesting().contains { $0 is NSTextField },
            "The search field and file tabs should coexist in the same primary row"
        )
        XCTAssertEqual(
            host.fittingSize.height,
            MonknotMetrics.chromeHeight(theme: theme, zoomScale: WorkspaceZoomPolicy.maximum),
            accuracy: 0.01
        )
    }

    func testDocumentTabsUseSharedChromeHeightAtEverySupportedZoom() {
        let theme = AppTheme.codexDark

        for zoomScale in WorkspaceZoomPolicy.supportedLevels {
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

    func testHorizontalTabOverflowStateReportsOnlyClippedTabsAndCorrectEdges() {
        let state = HorizontalTabOverflowState(
            frames: [
                "left": CGRect(x: -36, y: 0, width: 100, height: 44),
                "middle": CGRect(x: 64, y: 0, width: 100, height: 44),
                "right": CGRect(x: 164, y: 0, width: 100, height: 44),
            ],
            viewportWidth: 220
        )

        XCTAssertEqual(state.hiddenIDs, ["left", "right"])
        XCTAssertTrue(state.hasLeadingOverflow)
        XCTAssertTrue(state.hasTrailingOverflow)
        XCTAssertEqual(state.revealEdge(for: "left"), .leading)
        XCTAssertNil(state.revealEdge(for: "middle"))
        XCTAssertEqual(state.revealEdge(for: "right"), .trailing)
    }

    func testHorizontalTabOverflowStateStaysQuietWhenEveryTabFits() {
        let state = HorizontalTabOverflowState(
            frames: [
                "a": CGRect(x: 0, y: 0, width: 100, height: 44),
                "b": CGRect(x: 100, y: 0, width: 100, height: 44),
            ],
            viewportWidth: 200
        )

        XCTAssertTrue(state.hiddenIDs.isEmpty)
        XCTAssertFalse(state.hasLeadingOverflow)
        XCTAssertFalse(state.hasTrailingOverflow)
        XCTAssertNil(state.revealEdge(for: "a"))
        XCTAssertNil(state.revealEdge(for: "b"))
    }

    func testHorizontalTabRevealRequestIsOneShotSoManualScrollingRemainsAuthoritative() {
        var request = HorizontalTabRevealRequest()
        let frames = [
            "left": CGRect(x: -80, y: 0, width: 70, height: 28),
            "active": CGRect(x: 140, y: 0, width: 70, height: 28)
        ]

        request.request("active")
        let action = request.consume(frames: frames, viewportWidth: 180)

        XCTAssertEqual(action?.id, "active")
        XCTAssertEqual(action?.edge, .trailing)
        XCTAssertNil(request.pendingID)
        XCTAssertNil(request.consume(frames: frames, viewportWidth: 180))
    }

    func testHorizontalTabRevealRequestWaitsForMeasurementAndConsumesVisibleTabs() {
        var request = HorizontalTabRevealRequest()
        request.request("active")

        XCTAssertNil(request.consume(frames: [:], viewportWidth: 180))
        XCTAssertEqual(request.pendingID, "active")

        XCTAssertNil(request.consume(
            frames: ["active": CGRect(x: 40, y: 0, width: 70, height: 28)],
            viewportWidth: 180
        ))
        XCTAssertNil(request.pendingID)
    }

    func testTerminalTakeoverCannotStarveTheDocumentChrome() {
        for theme in [AppTheme.codexLight, AppTheme.codexDark] {
            for zoomScale in WorkspaceZoomPolicy.supportedLevels {
                let documentMinimum = MonknotMetrics.interfaceDensity(
                    MonknotMetrics.takeoverDocumentChromeMinWidthBase,
                    theme: theme,
                    zoomScale: zoomScale
                )
                let terminalMaximum = MonknotMetrics.interfaceDensity(
                    MonknotMetrics.takeoverTerminalChromeMaxWidthBase,
                    theme: theme,
                    zoomScale: zoomScale
                )
                let completeTabWidth = MonknotMetrics.interfaceDensity(
                    MonknotMetrics.tabMinWidthBase,
                    theme: theme,
                    zoomScale: zoomScale
                )
                let fixedDocumentControls = MonknotMetrics.chromeButtonDimension(
                    theme: theme,
                    zoomScale: zoomScale
                ) * 3

                XCTAssertGreaterThanOrEqual(
                    documentMinimum,
                    completeTabWidth + fixedDocumentControls,
                    "Takeover must retain a recognizable active file at zoom \(zoomScale)"
                )
                XCTAssertGreaterThan(
                    documentMinimum,
                    terminalMaximum,
                    "Terminal controls must not win layout priority over the active document"
                )

                let terminalMinimum = MonknotMetrics.interfaceDensity(
                    MonknotMetrics.takeoverTerminalChromeMinWidthBase,
                    theme: theme,
                    zoomScale: zoomScale
                )
                XCTAssertLessThanOrEqual(
                    documentMinimum + terminalMinimum,
                    WorkspaceSplitMetrics.detailMinimumWidth,
                    "Takeover minimums must fit the narrowest legal detail pane at zoom \(zoomScale)"
                )
            }
        }
    }

    func testMountedTerminalTakeoverFitsAtMinimumDetailWidthAndMaximumZoom() {
        let theme = AppTheme.codexDark
        let zoomScale = WorkspaceZoomPolicy.maximum
        let sessions = TerminalSessionCollectionStore()
        XCTAssertNotNil(sessions.createTerminal(in: FileManager.default.temporaryDirectory))
        defer { sessions.stopAll() }

        let documentMinimum = MonknotMetrics.interfaceDensity(
            MonknotMetrics.takeoverDocumentChromeMinWidthBase,
            theme: theme,
            zoomScale: zoomScale
        )
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            ChromeOriginMarker(identifier: "takeover-document")
                .frame(minWidth: documentMinimum, maxWidth: .infinity)
                .layoutPriority(1)

            TerminalDrawerTakeoverSegment(
                sessions: sessions,
                workingDirectory: FileManager.default.temporaryDirectory,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: theme.uiFontSize,
                close: {}
            )
            .background(ChromeOriginMarker(identifier: "takeover-terminal"))
            .layoutPriority(0)
        }
        .frame(
            width: WorkspaceSplitMetrics.detailMinimumWidth,
            height: MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
        ))
        host.frame = NSRect(
            x: 0,
            y: 0,
            width: WorkspaceSplitMetrics.detailMinimumWidth,
            height: MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        guard let terminalMarker = host.allDescendantsForTesting().first(where: {
            $0.identifier?.rawValue == "Monknot.Test.Chrome.takeover-terminal"
        }) else {
            return XCTFail("Missing mounted terminal takeover marker")
        }
        let terminalFrame = terminalMarker.convert(terminalMarker.bounds, to: host)
        XCTAssertGreaterThanOrEqual(terminalFrame.minX, documentMinimum - 1)
        XCTAssertLessThanOrEqual(terminalFrame.maxX, host.bounds.maxX + 1)

        for button in host.allDescendantsForTesting().compactMap({ $0 as? NSButton })
            where !button.isHidden {
            let frame = button.convert(button.bounds, to: host)
            XCTAssertGreaterThanOrEqual(frame.minX, host.bounds.minX - 1)
            XCTAssertLessThanOrEqual(
                frame.maxX,
                host.bounds.maxX + 1,
                "A terminal takeover control clipped at minimum detail width"
            )
        }
    }

    func testMountedDocumentTabBarKeepsManualHorizontalScrollPosition() async {
        let theme = AppTheme.codexDark
        let tabs = (0..<10).map { index in
            WorkspaceTabItem(
                documentID: "tab-\(index)",
                displayName: "Long production document \(index).md",
                relativePath: "Long production document \(index).md",
                kind: .markdown
            )
        }
        let chromeHeight = MonknotMetrics.chromeHeight(
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum
        )
        let host = NSHostingView(rootView: DocumentTabBar(
            tabs: tabs,
            selectedDocumentID: tabs[0].documentID,
            missingDocumentIDs: [],
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum,
            uiFontSize: theme.uiFontSize,
            isDisabled: false,
            saveState: { _ in .clean },
            selectTab: { _ in },
            closeTab: { _ in },
            togglePin: { _ in },
            reorderTab: { _, _ in }
        ).frame(width: 320, height: chromeHeight))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: chromeHeight)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        try? await Task.sleep(nanoseconds: 150_000_000)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let horizontalScrollView = host.allDescendantsForTesting()
            .compactMap { $0 as? NSScrollView }
            .first { scrollView in
                guard let documentView = scrollView.documentView else { return false }
                return documentView.frame.width > scrollView.contentView.bounds.width + 1
            }

        guard let horizontalScrollView,
              let documentView = horizontalScrollView.documentView
        else {
            return XCTFail("Mounted overflowing file tabs must expose a horizontal scroll container")
        }

        let maximumOffset = documentView.frame.width - horizontalScrollView.contentView.bounds.width
        XCTAssertGreaterThan(maximumOffset, 120)

        horizontalScrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
        horizontalScrollView.reflectScrolledClipView(horizontalScrollView.contentView)
        let manualOffset = horizontalScrollView.contentView.bounds.origin.x
        XCTAssertEqual(manualOffset, 120, accuracy: 1)

        // Frame preferences update as the lane scrolls. They must not trigger
        // another active-tab reveal and snap the user back to the first tab.
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            horizontalScrollView.contentView.bounds.origin.x,
            manualOffset,
            accuracy: 1,
            "Manual tab scrolling was overridden by selection reveal"
        )
    }

    func testMountedTerminalTabsKeepManualHorizontalScrollPosition() async {
        let theme = AppTheme.codexDark
        let sessions = TerminalSessionCollectionStore()
        for _ in 0..<10 {
            XCTAssertNotNil(sessions.createTerminal(in: FileManager.default.temporaryDirectory))
        }
        defer { sessions.stopAll() }

        let chromeHeight = MonknotMetrics.chromeHeight(
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum
        )
        let host = NSHostingView(rootView: TerminalDrawerTakeoverSegment(
            sessions: sessions,
            workingDirectory: FileManager.default.temporaryDirectory,
            theme: theme,
            zoomScale: WorkspaceZoomPolicy.maximum,
            uiFontSize: theme.uiFontSize,
            close: {}
        ).frame(width: 180, height: chromeHeight))
        host.frame = NSRect(x: 0, y: 0, width: 180, height: chromeHeight)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        try? await Task.sleep(nanoseconds: 150_000_000)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let horizontalScrollView = host.allDescendantsForTesting()
            .compactMap { $0 as? NSScrollView }
            .first { scrollView in
                guard let documentView = scrollView.documentView else { return false }
                return documentView.frame.width > scrollView.contentView.bounds.width + 1
            }

        guard let horizontalScrollView,
              let documentView = horizontalScrollView.documentView
        else {
            return XCTFail("Mounted terminal overflow must expose a horizontal scroll container")
        }

        let maximumOffset = documentView.frame.width - horizontalScrollView.contentView.bounds.width
        XCTAssertGreaterThan(maximumOffset, 80)

        horizontalScrollView.contentView.scroll(to: NSPoint(x: 60, y: 0))
        horizontalScrollView.reflectScrolledClipView(horizontalScrollView.contentView)
        let manualOffset = horizontalScrollView.contentView.bounds.origin.x
        XCTAssertEqual(manualOffset, 60, accuracy: 1)

        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            horizontalScrollView.contentView.bounds.origin.x,
            manualOffset,
            accuracy: 1,
            "Manual terminal-tab scrolling was overridden by active-tab reveal"
        )
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

private extension NSView {
    func allDescendantsForTesting() -> [NSView] {
        subviews + subviews.flatMap { $0.allDescendantsForTesting() }
    }

}

private struct ChromeColumnOriginFixture: View {
    let chromeHeight: CGFloat

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ChromeOriginMarker(identifier: "sidebar")
                    .frame(maxWidth: .infinity)
                    .frame(height: chromeHeight)
                Spacer(minLength: 0)
            }
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
                .ignoresSafeArea(.container, edges: .top)

            VStack(spacing: 0) {
                ChromeOriginMarker(identifier: "detail")
                    .frame(maxWidth: .infinity)
                    .frame(height: chromeHeight)
                Spacer(minLength: 0)
            }
                .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .topLeading) {
            ChromeOriginMarker(identifier: "navigation")
                .frame(width: 160, height: chromeHeight)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct ChromeOriginMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier("Monknot.Test.Chrome.\(identifier)")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private func keyEvent(
    _ characters: String,
    modifiers: NSEvent.ModifierFlags
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    )!
}

private final class StandardFrameWindowDelegate: NSObject, NSWindowDelegate {
    var standardFrameCallCount = 0

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        standardFrameCallCount += 1
        return newFrame.insetBy(dx: 12, dy: 12)
    }
}
