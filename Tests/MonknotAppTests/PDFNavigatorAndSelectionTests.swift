import AppKit
import MonknotCore
import PDFKit
import SwiftUI
import XCTest
@testable import MonknotApp

private final class PDFNavigatorReloadCountingDataSource: NSObject, NSTableViewDataSource {
    private(set) var numberOfRowsCallCount = 0
    var onNumberOfRows: (() -> Void)?

    func numberOfRows(in tableView: NSTableView) -> Int {
        numberOfRowsCallCount += 1
        onNumberOfRows?()
        return 0
    }
}

@MainActor
final class PDFNavigatorAndSelectionTests: XCTestCase {
    func testDocumentLoadIdentityReloadsSameURLOnlyWhenContentVersionChanges() {
        let url = URL(fileURLWithPath: "/workspace/notes/../Paper.pdf")
        let first = PDFDocumentLoadIdentity(url: url, contentVersion: 4)

        XCTAssertEqual(
            first,
            PDFDocumentLoadIdentity(
                url: URL(fileURLWithPath: "/workspace/Paper.pdf"),
                contentVersion: 4
            )
        )
        XCTAssertNotEqual(
            first,
            PDFDocumentLoadIdentity(url: url, contentVersion: 5)
        )
    }

    func testPreviewInitializerExposesPageAndNavigatorCommandsWithoutRequiringThem() {
        let workspaceURL = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let document = WorkspaceDocument(
            url: workspaceURL.appendingPathComponent("Paper.pdf"),
            rootURL: workspaceURL
        )
        let request = PDFPageNavigationRequest(
            serial: 4,
            documentID: document.id,
            pageNumber: 3
        )

        let preview = PDFPreviewView(
            document: document,
            theme: .defaultLight,
            zoomScale: 1,
            saveState: .clean,
            dirtyData: nil,
            savedEditCheckpoint: nil,
            contentVersion: 0,
            viewportState: nil,
            viewportCaptureBridge: PDFViewportCaptureBridge(),
            externalUndoCommandSerial: 0,
            externalRedoCommandSerial: 0,
            searchState: .constant(DocumentSearchState()),
            searchTarget: .constant(nil),
            markEdited: { _, _, _ in },
            restoreSavedEditCheckpoint: { _ in false },
            reportError: { _ in },
            saveDocument: {},
            pageNavigationRequest: request,
            externalNavigatorToggleCommandSerial: 2,
            copyLinkedExcerpt: { _ in },
            onSelectionSnapshotChange: { _ in },
            onPageNavigationRequestConsumed: { _ in },
            onViewportStateChange: { _ in },
            updateAnnotationUndoState: { _, _ in }
        )

        XCTAssertEqual(preview.pageNavigationRequest, request)
        XCTAssertEqual(preview.externalNavigatorToggleCommandSerial, 2)
    }

    func testNavigatorUsesTheActivePDFViewAndDetachesCompletely() throws {
        let container = PDFPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 700))
        let document = try makeImagePDFDocument(pageCount: 2)
        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1)
        container.pdfView.document = document
        container.navigatorView.attach(to: container.pdfView)
        container.setNavigatorPresented(true)
        container.layoutSubtreeIfNeeded()

        XCTAssertTrue(container.navigatorView.thumbnailView.pdfView === container.pdfView)
        XCTAssertTrue(container.pdfView.document === document)
        XCTAssertEqual(container.navigatorView.thumbnailView.thumbnailSize, NSSize(width: 184, height: 260))
        XCTAssertEqual(container.navigatorView.thumbnailView.maximumNumberOfColumns, 1)
        XCTAssertEqual(container.navigatorView.outlineView.rowHeight, 30)
        XCTAssertEqual(container.navigatorView.annotationTableView.rowHeight, 30)
        XCTAssertEqual(container.navigatorView.frame.width, 248, accuracy: 1)
        container.navigatorView.selectSection(.outline)
        XCTAssertNil(container.navigatorView.thumbnailView.pdfView)
        container.navigatorView.selectSection(.pages)
        XCTAssertTrue(container.navigatorView.thumbnailView.pdfView === container.pdfView)

        var editCallbackCount = 0
        container.pdfView.onEdited = { _, _, _ in editCallbackCount += 1 }
        container.prepareForDismantle()

        XCTAssertNil(container.navigatorView.thumbnailView.pdfView)
        XCTAssertNil(container.navigatorView.outlineView.delegate)
        XCTAssertNil(container.navigatorView.outlineView.dataSource)
        XCTAssertNil(container.navigatorView.annotationTableView.delegate)
        XCTAssertNil(container.navigatorView.annotationTableView.dataSource)
        XCTAssertNil(container.pdfView.document)

        container.pdfView.onEdited(
            nil,
            Data(),
            PDFAnnotationEditCheckpoint(operationCount: 0, lastOperationID: nil)
        )
        XCTAssertEqual(editCallbackCount, 0)
    }

    func testNavigatorMetricsScaleFromClampedBaseWidthsAtEveryWorkspaceZoomLevel() {
        let cases: [(zoom: Double, minimum: CGFloat, preferred: CGFloat, maximum: CGFloat)] = [
            (0.8, 176, 198, 256),
            (0.9, 198, 223, 288),
            (1, 220, 248, 320),
            (1.1, 242, 273, 352),
            (1.25, 275, 310, 400),
            (1.5, 330, 372, 480),
            (1.75, 385, 434, 560),
            (2, 440, 496, 640)
        ]

        for item in cases {
            let scale = CGFloat(item.zoom)
            let density: (CGFloat) -> CGFloat = { ($0 * scale).rounded() }
            let text: (CGFloat) -> CGFloat = { ($0 * scale * 2).rounded() / 2 }
            let metrics = PDFNavigatorMetrics(
                theme: .defaultLight,
                workspaceZoomScale: item.zoom
            )
            XCTAssertEqual(metrics.minimumWidth, item.minimum, "zoom \(item.zoom)")
            XCTAssertEqual(metrics.preferredWidth, item.preferred, "zoom \(item.zoom)")
            XCTAssertEqual(metrics.maximumWidth, item.maximum, "zoom \(item.zoom)")
            XCTAssertEqual(
                metrics.renderedWidth(forBaseWidth: 100),
                item.minimum,
                "base width must clamp before scaling at zoom \(item.zoom)"
            )
            XCTAssertEqual(
                metrics.renderedWidth(forBaseWidth: 1_000),
                item.maximum,
                "base width must clamp before scaling at zoom \(item.zoom)"
            )
            XCTAssertEqual(metrics.headerHeight, density(40))
            XCTAssertEqual(metrics.headerInset, density(8))
            XCTAssertEqual(metrics.segmentedHeight, density(28))
            XCTAssertEqual(metrics.contentInset, density(8))
            XCTAssertEqual(metrics.thumbnailLabelFontSize, text(12))
            XCTAssertEqual(metrics.outlineRowHeight, density(30))
            XCTAssertEqual(metrics.outlineIndentation, density(16))
            XCTAssertEqual(metrics.outlineFontSize, text(13))
            XCTAssertEqual(metrics.annotationRowHeight, density(30))
            XCTAssertEqual(metrics.annotationFontSize, text(13))
            XCTAssertEqual(metrics.cellInset, density(10))
            XCTAssertEqual(metrics.selectionHorizontalInset, density(4))
            XCTAssertEqual(metrics.selectionVerticalInset, density(2))
            XCTAssertEqual(metrics.selectionCornerRadius, density(8))
            XCTAssertEqual(metrics.emptyFontSize, text(12))
            XCTAssertEqual(metrics.emptyInset, density(16))
            let thumbnailSize = metrics.thumbnailSize(forPanelWidth: item.preferred)
            XCTAssertEqual(thumbnailSize.width, (item.preferred * 0.74).rounded())
            XCTAssertEqual(thumbnailSize.height, (thumbnailSize.width * sqrt(2)).rounded())
        }
    }

    func testNavigatorSectionControlIsCenteredContentHuggedAndScaledAtOneAndTwo() {
        let cases: [(zoom: Double, theme: AppTheme, panelWidth: CGFloat)] = [
            (1, .defaultLight, 248),
            (2, .defaultDark, 496)
        ]

        for item in cases {
            let navigator = PDFNavigatorView(
                frame: NSRect(x: 0, y: 0, width: item.panelWidth, height: 700)
            )
            let metrics = PDFNavigatorMetrics(theme: item.theme, workspaceZoomScale: item.zoom)
            navigator.applyMetrics(metrics, theme: item.theme, panelWidth: item.panelWidth)
            navigator.layoutSubtreeIfNeeded()
            navigator.sectionControlHostingView.layoutSubtreeIfNeeded()

            let scale = CGFloat(item.zoom)
            let expectedWidth = CGFloat(92) * scale
            XCTAssertEqual(
                navigator.sectionControlHostingView.frame.width,
                expectedWidth,
                accuracy: 1,
                "zoom \(item.zoom)"
            )
            XCTAssertEqual(
                navigator.sectionControlHostingView.frame.height,
                metrics.segmentedHeight,
                accuracy: 0.5,
                "zoom \(item.zoom)"
            )
            XCTAssertEqual(
                navigator.sectionControlHostingView.frame.midX,
                navigator.bounds.midX,
                accuracy: 0.5,
                "zoom \(item.zoom)"
            )
            XCTAssertLessThan(
                navigator.sectionControlHostingView.frame.width,
                navigator.bounds.width - (metrics.headerInset * 2),
                "the section control must hug its three icons rather than fill the navigator"
            )
            XCTAssertEqual(navigator.sectionControlHostingView.rootView.zoomScale, item.zoom)
            XCTAssertEqual(
                navigator.sectionControlHostingView.rootView.theme,
                item.theme
            )
            navigator.prepareForDismantle()
        }
    }

    func testSharedPDFSegmentFocusRingCoversNavigatorAndFormattingSegmentsWithoutChangingMetrics() {
        XCTAssertTrue(MonknotSegmentButton.showsFocusRing(isFocused: true, isDisabled: false))
        XCTAssertFalse(MonknotSegmentButton.showsFocusRing(isFocused: false, isDisabled: false))
        XCTAssertFalse(MonknotSegmentButton.showsFocusRing(isFocused: true, isDisabled: true))
        XCTAssertEqual(MonknotSegmentButton.focusRingLineWidth, 3)
        XCTAssertEqual(MonknotSegmentButton.focusRingOutset, 2)
        XCTAssertEqual(MonknotSegmentButton.focusRingOpacity, 0.35)

        for zoomScale in [1.0, 2.0] {
            let theme = AppTheme.defaultLight
            let formattingSegment = MonknotSegmentButton(
                systemImage: "bold",
                accessibilityLabel: "Bold",
                isSelected: false,
                theme: theme,
                zoomScale: zoomScale,
                action: {}
            )
            let formattingHost = NSHostingView(rootView: formattingSegment)
            XCTAssertEqual(
                formattingHost.fittingSize.width,
                MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale),
                accuracy: 0.5
            )
            XCTAssertEqual(
                formattingHost.fittingSize.height,
                MonknotMetrics.interfaceControl(22, theme: theme, zoomScale: zoomScale),
                accuracy: 0.5
            )

            let navigatorControl = PDFNavigatorSectionControl(
                selection: .pages,
                theme: theme,
                zoomScale: zoomScale,
                onSelect: { _ in }
            )
            XCTAssertEqual(
                navigatorControl.options.map(\.accessibilityLabel),
                ["Pages", "Outline", "Annotations"]
            )
        }
    }

    func testNavigatorSectionControlActivationProgrammaticSelectionAccessibilityAndTeardown() throws {
        let navigator = PDFNavigatorView(frame: NSRect(x: 0, y: 0, width: 248, height: 700))
        let pdfView = AnnotatingPDFView()
        pdfView.document = try makeImagePDFDocument(pageCount: 1)
        navigator.attach(to: pdfView)
        navigator.setPresented(true)
        navigator.applyMetrics(
            PDFNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1),
            theme: .defaultLight,
            panelWidth: 248
        )
        navigator.layoutSubtreeIfNeeded()
        navigator.sectionControlHostingView.layoutSubtreeIfNeeded()

        let rootView = navigator.sectionControlHostingView.rootView
        XCTAssertEqual(rootView.options.map(\.accessibilityLabel), ["Pages", "Outline", "Annotations"])
        XCTAssertEqual(navigator.sectionControlHostingView.accessibilityRole(), .group)
        XCTAssertEqual(navigator.sectionControlHostingView.accessibilityLabel(), "PDF Navigator")

        // MonknotSegmentedControl writes this binding for both pointer and keyboard activation.
        rootView.controlSelection.wrappedValue = PDFNavigatorSection.outline.controlID
        XCTAssertEqual(
            navigator.sectionControlHostingView.rootView.selection.controlID,
            PDFNavigatorSection.outline.controlID
        )
        XCTAssertTrue(navigator.thumbnailView.isHidden)
        XCTAssertFalse(try XCTUnwrap(navigator.outlineView.enclosingScrollView).isHidden)

        navigator.selectSection(.annotations)
        XCTAssertEqual(
            navigator.sectionControlHostingView.rootView.selection.controlID,
            PDFNavigatorSection.annotations.controlID
        )
        XCTAssertTrue(try XCTUnwrap(navigator.outlineView.enclosingScrollView).isHidden)
        XCTAssertFalse(try XCTUnwrap(navigator.annotationTableView.enclosingScrollView).isHidden)

        let hostingView = navigator.sectionControlHostingView
        XCTAssertNotNil(hostingView.rootView.onSelect)
        navigator.prepareForDismantle()
        XCTAssertNil(hostingView.rootView.onSelect)
        XCTAssertNil(hostingView.superview)
        pdfView.prepareForDismantle()
    }

    func testNavigatorAppliesThemeAndScaledControlMetricsIdempotently() throws {
        let navigator = PDFNavigatorView(frame: NSRect(x: 0, y: 0, width: 310, height: 700))
        let theme = AppTheme.defaultDark
        let metrics = PDFNavigatorMetrics(theme: theme, workspaceZoomScale: 1.25)

        navigator.applyMetrics(metrics, theme: theme, panelWidth: 310)
        let pdfView = AnnotatingPDFView()
        pdfView.document = try makeImagePDFDocument(pageCount: 1)
        navigator.attach(to: pdfView)
        navigator.setPresented(true)
        let firstThumbnailSize = navigator.thumbnailView.thumbnailSize
        navigator.applyMetrics(metrics, theme: theme, panelWidth: 310)

        XCTAssertEqual(navigator.metrics, metrics)
        XCTAssertEqual(navigator.thumbnailView.thumbnailSize, firstThumbnailSize)
        XCTAssertEqual(firstThumbnailSize, NSSize(width: 229, height: 324))
        XCTAssertEqual(navigator.outlineView.rowHeight, 38)
        XCTAssertEqual(navigator.outlineView.indentationPerLevel, 20)
        XCTAssertEqual(navigator.annotationTableView.rowHeight, 38)
        XCTAssertEqual(navigator.metrics.thumbnailLabelFontSize, 15)
        XCTAssertTrue(navigator.foregroundColor.isEqual(NSColor(hex: theme.foreground)))
        XCTAssertTrue(navigator.selectionColor.isEqual(NSColor(hex: theme.selectionBackground)))
        XCTAssertTrue(
            NSColor(cgColor: try XCTUnwrap(navigator.layer?.backgroundColor))?
                .isEqual(NSColor(hex: theme.sidebarSurfaceHex)) == true
        )
        navigator.prepareForDismantle()
        pdfView.prepareForDismantle()
    }

    func testNavigatorSkipsRedundantAppearanceReloadButStillUpdatesThumbnailWidth() {
        let navigator = PDFNavigatorView(frame: NSRect(x: 0, y: 0, width: 248, height: 700))
        let metrics = PDFNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1)
        let reloadCounter = PDFNavigatorReloadCountingDataSource()
        navigator.annotationTableView.dataSource = reloadCounter

        navigator.applyMetrics(metrics, theme: .defaultLight, panelWidth: 248)
        let reloadsAfterInitialAppearance = reloadCounter.numberOfRowsCallCount
        XCTAssertGreaterThan(reloadsAfterInitialAppearance, 0)
        XCTAssertEqual(navigator.thumbnailView.thumbnailSize.width, 184)

        navigator.applyMetrics(metrics, theme: .defaultLight, panelWidth: 300)

        XCTAssertEqual(reloadCounter.numberOfRowsCallCount, reloadsAfterInitialAppearance)
        XCTAssertEqual(navigator.thumbnailView.thumbnailSize.width, 222)

        navigator.applyMetrics(
            PDFNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1.25),
            theme: .defaultLight,
            panelWidth: 300
        )
        XCTAssertGreaterThan(reloadCounter.numberOfRowsCallCount, reloadsAfterInitialAppearance)
        navigator.prepareForDismantle()
    }

    func testNavigatorDividerWidthSurvivesIdempotentUpdatesAndScalesWithWorkspaceZoom() throws {
        let container = PDFPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1)
        container.setNavigatorPresented(true)
        container.layoutSubtreeIfNeeded()
        let splitView = try XCTUnwrap(container.subviews.first as? PDFNavigatorSplitView)
        XCTAssertFalse(container.splitView(splitView, canCollapseSubview: container.navigatorView))

        splitView.setPosition(300, ofDividerAt: 0)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.navigatorView.frame.width, 300, accuracy: 1)

        container.frame.size.width = 1_400
        container.layoutSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.navigatorView.frame.width, 300, accuracy: 1)

        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.navigatorView.frame.width, 300, accuracy: 1)

        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1.5)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.navigatorView.frame.width, 450, accuracy: 1)
        container.prepareForDismantle()
    }

    func testAccessibilitySplitterResizeRemainsAuthoritativeAcrossLayoutAndZoom() throws {
        let container = PDFPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1)
        container.setNavigatorPresented(true)
        container.layoutSubtreeIfNeeded()
        let splitView = try XCTUnwrap(container.subviews.first as? PDFNavigatorSplitView)

        var accessibilitySplitter: (any NSAccessibilityProtocol)?
        for value in splitView.accessibilityChildren() ?? [] {
            guard let element = value as? any NSAccessibilityProtocol,
                  element.accessibilityRole() == .splitter
            else {
                continue
            }
            accessibilitySplitter = element
            break
        }
        let splitter = try XCTUnwrap(accessibilitySplitter)

        splitter.setAccessibilityValue(NSNumber(value: 300))
        XCTAssertEqual(container.navigatorView.frame.width, 300, accuracy: 1)

        container.frame.size.width = 1_400
        container.layoutSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.navigatorView.frame.width, 300, accuracy: 1)

        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1.5)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.navigatorView.frame.width, 450, accuracy: 1)
        container.prepareForDismantle()
    }

    func testNavigatorZoomTransitionDoesNotCaptureIntermediateRenderedWidthAsUserWidth() throws {
        let container = PDFPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 2)
        container.setNavigatorPresented(true)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.navigatorView.frame.width, 496, accuracy: 1)

        let splitView = try XCTUnwrap(container.subviews.first as? NSSplitView)
        let resizeDuringAppearance = PDFNavigatorReloadCountingDataSource()
        resizeDuringAppearance.onNumberOfRows = { [weak container, weak splitView] in
            guard let container, let splitView else { return }
            container.splitViewDidResizeSubviews(
                Notification(name: NSSplitView.didResizeSubviewsNotification, object: splitView)
            )
        }
        container.navigatorView.annotationTableView.dataSource = resizeDuringAppearance

        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.navigatorView.frame.width, 248, accuracy: 1)

        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 2)
        container.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(resizeDuringAppearance.numberOfRowsCallCount, 0)
        XCTAssertEqual(container.navigatorView.frame.width, 496, accuracy: 1)
        container.prepareForDismantle()
    }

    func testHiddenNavigatorZoomRoundTripIgnoresLaterParentLayoutResize() {
        let container = PDFPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 2)
        container.setNavigatorPresented(false)
        container.layoutSubtreeIfNeeded()
        XCTAssertTrue(container.navigatorView.isHidden)

        container.setNavigatorPresented(true)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.navigatorView.frame.width, 496, accuracy: 1)

        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.navigatorView.frame.width, 248, accuracy: 1)

        // Resetting Interface Zoom also shrinks surrounding chrome, so the representable
        // receives a later, wider parent layout after updateNSView has returned.
        container.frame.size.width = 1_176
        container.layoutSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.navigatorView.frame.width, 248, accuracy: 1)

        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 2)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.navigatorView.frame.width, 496, accuracy: 1)

        container.frame.size.width = 900
        container.layoutSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.navigatorView.frame.width, 496, accuracy: 1)
        container.prepareForDismantle()
    }

    func testNavigatorStartsCollapsedAtMaximumZoomAndRestoresAcrossShowHideShow() throws {
        let container = PDFPreviewContainerView()

        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 2)
        container.setNavigatorPresented(false)

        XCTAssertTrue(container.navigatorView.isHidden)

        container.frame = NSRect(x: 0, y: 0, width: 1_400, height: 700)
        container.layoutSubtreeIfNeeded()

        XCTAssertTrue(container.navigatorView.isHidden)
        XCTAssertEqual(container.navigatorView.frame.width, 0, accuracy: 1)
        XCTAssertEqual(container.pdfView.frame.width, container.bounds.width, accuracy: 1)

        // Match SwiftUI's first update after the zero-frame representable is mounted.
        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 2)
        container.setNavigatorPresented(false)
        container.layoutSubtreeIfNeeded()

        XCTAssertTrue(container.navigatorView.isHidden)
        XCTAssertEqual(container.navigatorView.frame.width, 0, accuracy: 1)
        XCTAssertNil(container.navigatorView.thumbnailView.pdfView)
        XCTAssertEqual(container.pdfView.frame.width, container.bounds.width, accuracy: 1)

        let document = try makeImagePDFDocument(pageCount: 2)
        container.pdfView.document = document
        container.navigatorView.attach(to: container.pdfView)
        container.setNavigatorPresented(true)
        XCTAssertEqual(container.navigatorView.frame.width, 496, accuracy: 1)
        container.layoutSubtreeIfNeeded()

        XCTAssertFalse(container.navigatorView.isHidden)
        XCTAssertEqual(container.navigatorView.frame.width, 496, accuracy: 1)
        XCTAssertTrue(container.navigatorView.thumbnailView.pdfView === container.pdfView)

        container.setNavigatorPresented(false)
        XCTAssertEqual(container.navigatorView.frame.width, 0, accuracy: 1)
        container.layoutSubtreeIfNeeded()

        XCTAssertTrue(container.navigatorView.isHidden)
        XCTAssertEqual(container.navigatorView.frame.width, 0, accuracy: 1)
        XCTAssertNil(container.navigatorView.thumbnailView.pdfView)
        XCTAssertEqual(container.pdfView.frame.width, container.bounds.width, accuracy: 1)

        container.setNavigatorPresented(true)
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(container.navigatorView.frame.width, 496, accuracy: 1)
        XCTAssertTrue(container.navigatorView.thumbnailView.pdfView === container.pdfView)
        XCTAssertTrue(container.pdfView.document === document)
        container.setNavigatorPresented(false)
        container.layoutSubtreeIfNeeded()
    }

    func testPDFPageZoomDoesNotChangeNavigatorMetrics() throws {
        let container = PDFPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        container.applyNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1.25)
        container.pdfView.document = try makeImagePDFDocument(pageCount: 2)
        container.navigatorView.attach(to: container.pdfView)
        container.setNavigatorPresented(true)
        container.layoutSubtreeIfNeeded()
        let metrics = container.navigatorMetrics
        let thumbnailSize = container.navigatorView.thumbnailView.thumbnailSize

        container.pdfView.autoScales = false
        container.pdfView.scaleFactor = 2
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(container.navigatorMetrics, metrics)
        XCTAssertEqual(container.navigatorView.metrics, metrics)
        XCTAssertEqual(container.navigatorView.thumbnailView.thumbnailSize, thumbnailSize)
        XCTAssertEqual(container.navigatorView.outlineView.rowHeight, metrics.outlineRowHeight)
        XCTAssertEqual(container.navigatorView.annotationTableView.rowHeight, metrics.annotationRowHeight)
        container.prepareForDismantle()
    }

    func testAnnotationNavigatorRowsAreSingleLineWithBoundedAccessibilityExcerpt() throws {
        let document = try makeImagePDFDocument(pageCount: 1)
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 20, y: 20, width: 100, height: 40),
            forType: .freeText,
            withProperties: nil
        )
        let fullText = String(repeating: "Accessible annotation detail ", count: 20_000) + "far-tail words"
        annotation.contents = "Accessible annotation\ndetail   " + fullText
        page.addAnnotation(annotation)

        let item = try XCTUnwrap(PDFNavigatorView.annotationItems(from: document).first)

        XCTAssertFalse(item.label.contains("\n"))
        XCTAssertLessThanOrEqual(item.excerpt?.count ?? 0, 140)
        XCTAssertGreaterThan(item.accessibilityExcerpt?.count ?? 0, 140)
        XCTAssertEqual(item.accessibilityExcerpt?.count, 500)
        XCTAssertFalse(item.accessibilityExcerpt?.contains("far-tail words") == true)
        XCTAssertFalse(item.accessibilityLabel.contains("far-tail words"))
    }

    func testAnnotationExcerptBoundsOneHugeCombiningGraphemeByUTF16Length() throws {
        let document = try makeImagePDFDocument(pageCount: 1)
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 20, y: 20, width: 100, height: 40),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = "A" + String(repeating: "\u{0301}", count: 100_000) + " far-tail words"
        page.addAnnotation(annotation)

        let item = try XCTUnwrap(PDFNavigatorView.annotationItems(from: document).first)
        let accessibilityExcerpt = try XCTUnwrap(item.accessibilityExcerpt)

        XCTAssertLessThanOrEqual(accessibilityExcerpt.unicodeScalars.count, 500)
        XCTAssertLessThanOrEqual(accessibilityExcerpt.utf16.count, 500)
        XCTAssertLessThanOrEqual(item.excerpt?.utf16.count ?? 0, 140)
        XCTAssertFalse(accessibilityExcerpt.contains("far-tail words"))
        XCTAssertFalse(item.accessibilityLabel.contains("far-tail words"))
    }

    func testNavigatorSelectedRowsUseScaledInsetsAndNativeInactiveColor() {
        let metrics = PDFNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1.5)
        let row = PDFNavigatorTableRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 45))
        row.themedSelectionColor = .systemBlue
        row.selectionHorizontalInset = metrics.selectionHorizontalInset
        row.selectionVerticalInset = metrics.selectionVerticalInset
        row.selectionCornerRadius = metrics.selectionCornerRadius
        row.isEmphasized = true

        XCTAssertEqual(row.selectionDrawingRect, NSRect(x: 6, y: 3, width: 288, height: 39))
        XCTAssertEqual(row.selectionCornerRadius, 12)
        XCTAssertTrue(row.resolvedSelectionColor(isKeyWindow: true).isEqual(NSColor.systemBlue))
        XCTAssertTrue(
            row.resolvedSelectionColor(isKeyWindow: false)
                .isEqual(NSColor.unemphasizedSelectedContentBackgroundColor)
        )

        row.isEmphasized = false
        XCTAssertTrue(
            row.resolvedSelectionColor(isKeyWindow: true)
                .isEqual(NSColor.unemphasizedSelectedContentBackgroundColor)
        )
    }

    func testFinalViewportDeliveryIsSynchronousBeforePDFTeardown() throws {
        let container = PDFPreviewContainerView()
        container.pdfView.document = try makeImagePDFDocument(pageCount: 1)
        container.pdfView.autoScales = false
        container.pdfView.scaleFactor = 1.4
        var events = ["before"]
        var deliveredState: PDFDocumentViewportState?

        deliverFinalPDFViewportStateSynchronously(from: container.pdfView) { state in
            events.append("callback")
            deliveredState = state
            XCTAssertNotNil(container.pdfView.document)
        }
        events.append("after")
        container.prepareForDismantle()

        XCTAssertEqual(events, ["before", "callback", "after"])
        XCTAssertEqual(deliveredState?.zoomMode, .fixed(scaleFactor: 1.4))
        XCTAssertNil(container.pdfView.document)
    }

    func testLatePersistedViewportStateRetriesAfterDocumentLoad() throws {
        let container = PDFPreviewContainerView()
        let coordinator = PDFKitPreviewRepresentable.Coordinator()
        coordinator.documentID = "/workspace/Paper.pdf"
        coordinator.attach(to: container.pdfView)
        container.navigatorView.attach(to: container.pdfView)
        defer {
            coordinator.detach()
            container.prepareForDismantle()
        }

        let persistedState = PDFDocumentViewportState(
            position: PDFDocumentViewportPosition(
                pageIndex: 1,
                point: DocumentScrollPosition(x: 20, y: 280)
            ),
            zoomMode: .fixed(scaleFactor: 1.2)
        )
        coordinator.restoreViewportStateIfNeeded(
            persistedState,
            force: true,
            skipPosition: false,
            in: container.pdfView
        )
        XCTAssertNil(container.pdfView.document)

        let data = try XCTUnwrap(makeImagePDFDocument(pageCount: 2).dataRepresentation())
        XCTAssertTrue(coordinator.loadDocumentIfNeeded(
            URL(fileURLWithPath: "/workspace/Paper.pdf"),
            dirtyData: data,
            contentVersion: 1,
            in: container.pdfView,
            navigatorView: container.navigatorView
        ))
        coordinator.restoreViewportStateIfNeeded(
            persistedState,
            force: false,
            skipPosition: false,
            in: container.pdfView
        )

        let document = try XCTUnwrap(container.pdfView.document)
        let currentPage = try XCTUnwrap(container.pdfView.currentDestination?.page)
        XCTAssertEqual(document.index(for: currentPage), 1)
        XCTAssertEqual(container.pdfView.scaleFactor, 1.2, accuracy: 0.001)
    }

    func testRapidViewportCallbackEchoDoesNotRestoreAnOlderPosition() throws {
        let container = PDFPreviewContainerView()
        let coordinator = PDFKitPreviewRepresentable.Coordinator()
        coordinator.documentID = "/workspace/Paper.pdf"
        container.navigatorView.attach(to: container.pdfView)
        defer {
            coordinator.detach()
            container.prepareForDismantle()
        }

        let data = try XCTUnwrap(makeImagePDFDocument(pageCount: 2).dataRepresentation())
        XCTAssertTrue(coordinator.loadDocumentIfNeeded(
            URL(fileURLWithPath: "/workspace/Paper.pdf"),
            dirtyData: data,
            contentVersion: 1,
            in: container.pdfView,
            navigatorView: container.navigatorView
        ))
        coordinator.restoreViewportStateIfNeeded(
            nil,
            force: false,
            skipPosition: false,
            in: container.pdfView
        )
        let document = try XCTUnwrap(container.pdfView.document)
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let secondPage = try XCTUnwrap(document.page(at: 1))

        var publishedStates: [PDFDocumentViewportState] = []
        coordinator.onViewportStateChange = { publishedStates.append($0) }
        container.pdfView.scaleFactor = 1.3
        container.pdfView.go(to: PDFDestination(page: firstPage, at: CGPoint(x: 20, y: 280)))
        coordinator.publishViewportState(from: container.pdfView)
        let firstPublishedState = try XCTUnwrap(publishedStates.last)

        container.pdfView.scaleFactor = 1.4
        container.pdfView.go(to: PDFDestination(page: secondPage, at: CGPoint(x: 20, y: 280)))
        coordinator.restoreViewportStateIfNeeded(
            firstPublishedState,
            force: false,
            skipPosition: false,
            in: container.pdfView
        )
        coordinator.publishViewportState(from: container.pdfView)
        let secondPublishedState = try XCTUnwrap(publishedStates.last)
        XCTAssertEqual(publishedStates.count, 2)
        coordinator.restoreViewportStateIfNeeded(
            secondPublishedState,
            force: false,
            skipPosition: false,
            in: container.pdfView
        )

        let livePage = try XCTUnwrap(container.pdfView.currentDestination?.page)
        XCTAssertEqual(document.index(for: livePage), 1)
        XCTAssertEqual(container.pdfView.scaleFactor, 1.4, accuracy: 0.001)
    }

    func testCleanDiskLoadUsesExactBytesForFirstEditAndDirtyReloadNeedsNoNewBaseline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-pdf-load-baseline-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("Paper.pdf")
        let sourceDocument = try makeImagePDFDocument(pageCount: 1)
        let sourcePage = try XCTUnwrap(sourceDocument.page(at: 0))
        sourcePage.addAnnotation(makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 40, width: 150, height: 54),
            contents: "Editable"
        ))
        var exactDiskData = try XCTUnwrap(sourceDocument.dataRepresentation())
        exactDiskData.append(Data("\n% Monknot exact-byte baseline fixture\n".utf8))
        try exactDiskData.write(to: url)

        let reparsed = try XCTUnwrap(PDFDocument(data: exactDiskData)?.dataRepresentation())
        XCTAssertNotEqual(reparsed, exactDiskData, "Fixture must expose PDFKit reserialization drift")

        let container = PDFPreviewContainerView()
        let coordinator = PDFKitPreviewRepresentable.Coordinator()
        container.navigatorView.attach(to: container.pdfView)
        defer {
            coordinator.detach()
            container.prepareForDismantle()
        }

        XCTAssertTrue(coordinator.loadDocumentIfNeeded(
            url,
            dirtyData: nil,
            contentVersion: 1,
            in: container.pdfView,
            navigatorView: container.navigatorView
        ))
        container.pdfView.reconcileEditBaselineCapture(hasDirtyData: false)
        let loadedPage = try XCTUnwrap(container.pdfView.document?.page(at: 0))
        let annotation = try XCTUnwrap(loadedPage.annotations.first(where: {
            ($0.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText"
        }))
        var firstPreviousData: Data?
        var firstDirtyData: Data?
        container.pdfView.onEdited = { previousData, data, _ in
            firstPreviousData = previousData
            firstDirtyData = data
        }
        container.pdfView.selectFreeTextAnnotation(annotation, on: loadedPage)
        var formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.fontSize = 18
        container.pdfView.applyFreeTextFormatting(formatting)

        XCTAssertEqual(firstPreviousData, exactDiskData)
        _ = try XCTUnwrap(firstDirtyData)

        container.pdfView.reconcileEditBaselineCapture(hasDirtyData: true)
        var undoPreviousData: Data?
        var undoData: Data?
        container.pdfView.onEdited = { previousData, data, _ in
            undoPreviousData = previousData
            undoData = data
        }
        container.pdfView.undoAnnotationEdit()
        XCTAssertNil(undoPreviousData)
        XCTAssertEqual(undoData, exactDiskData)

        container.pdfView.reconcileEditBaselineCapture(hasDirtyData: false)
        var redoPreviousData: Data?
        var redoData: Data?
        container.pdfView.onEdited = { previousData, data, _ in
            redoPreviousData = previousData
            redoData = data
        }
        container.pdfView.redoAnnotationEdit()
        XCTAssertEqual(redoPreviousData, exactDiskData)
        let dirtyData = try XCTUnwrap(redoData)

        XCTAssertTrue(coordinator.loadDocumentIfNeeded(
            url,
            dirtyData: dirtyData,
            contentVersion: 2,
            in: container.pdfView,
            navigatorView: container.navigatorView
        ))
        container.pdfView.reconcileEditBaselineCapture(hasDirtyData: true)
        let dirtyPage = try XCTUnwrap(container.pdfView.document?.page(at: 0))
        let dirtyAnnotation = try XCTUnwrap(dirtyPage.annotations.first(where: {
            ($0.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText"
        }))
        var dirtyReloadPreviousData: Data?
        container.pdfView.onEdited = { previousData, _, _ in
            dirtyReloadPreviousData = previousData
        }
        container.pdfView.selectFreeTextAnnotation(dirtyAnnotation, on: dirtyPage)
        formatting = PDFFreeTextFormatting(annotation: dirtyAnnotation)
        formatting.fontSize = 22
        container.pdfView.applyFreeTextFormatting(formatting)

        XCTAssertNil(dirtyReloadPreviousData)
    }

    func testNavigatorPageCaptureWinsWhenCurrentDestinationLagsAndPersistsForRelaunch() throws {
        let suiteName = "MonknotPDFTerminationViewportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = DocumentViewportStatePersistence(defaults: defaults)
        let workspaceURL = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let documentID = "/workspace/Paper.pdf"
        let pdfView = NavigatorLaggingPDFView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        let document = try makeImagePDFDocument(
            pageCount: 2,
            pageSize: NSSize(width: 612, height: 792)
        )
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let secondPage = try XCTUnwrap(document.page(at: 1))
        pdfView.document = document
        pdfView.layoutDocumentView()
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.2
        pdfView.go(to: PDFDestination(
            page: secondPage,
            at: CGPoint(x: 20, y: secondPage.bounds(for: .cropBox).maxY - 20)
        ))
        pdfView.navigatorCurrentPage = secondPage
        pdfView.laggingDestination = PDFDestination(
            page: firstPage,
            at: CGPoint(x: -500, y: firstPage.bounds(for: .cropBox).maxY)
        )
        let bridge = PDFViewportCaptureBridge()
        bridge.attach(documentID: documentID, to: pdfView)

        let capture = try XCTUnwrap(bridge.capture())
        XCTAssertEqual(PDFPageStatus(pdfView: pdfView).currentPage, 2)
        XCTAssertTrue(pdfView.currentDestination?.page === firstPage)
        XCTAssertEqual(capture.state.position?.pageIndex, 1)
        let capturedPoint = try XCTUnwrap(capture.state.position?.point.point)
        XCTAssertTrue(secondPage.bounds(for: .cropBox).contains(capturedPoint))
        persistence.save(
            [documentID: DocumentViewportState(
                textScrollPosition: nil,
                textSelection: nil,
                markdownPreviewScrollPosition: nil,
                htmlPreviewScrollPosition: nil,
                pdfViewportState: capture.state
            )],
            retaining: [documentID],
            for: workspaceURL
        )
        bridge.detach(from: pdfView)
        pdfView.navigatorCurrentPage = nil
        pdfView.laggingDestination = nil
        pdfView.document = nil

        let restored = try XCTUnwrap(persistence.load(for: workspaceURL)[documentID]?.pdfViewportState)
        XCTAssertEqual(restored.position?.pageIndex, 1)
        XCTAssertEqual(restored.zoomMode, .fixed(scaleFactor: 1.2))
        let restoredDestination = try XCTUnwrap(restored.position?.destination(in: document))
        XCTAssertTrue(restoredDestination.page === secondPage)
        XCTAssertNil(bridge.capture())
    }

    func testNavigatorDerivesOnlyUserFacingAnnotationsInPageOrder() throws {
        let document = try makeImagePDFDocument(pageCount: 2)
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let secondPage = try XCTUnwrap(document.page(at: 1))

        let link = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 40, height: 20),
            forType: .link,
            withProperties: nil
        )
        firstPage.addAnnotation(link)

        let highlight = PDFAnnotation(
            bounds: CGRect(x: 20, y: 120, width: 80, height: 18),
            forType: .highlight,
            withProperties: nil
        )
        highlight.contents = "Important result"
        firstPage.addAnnotation(highlight)

        let ink = PDFAnnotation(
            bounds: CGRect(x: 30, y: 90, width: 60, height: 30),
            forType: .ink,
            withProperties: nil
        )
        secondPage.addAnnotation(ink)

        let items = PDFNavigatorView.annotationItems(from: document)

        XCTAssertEqual(items.map(\.pageIndex), [0, 1])
        XCTAssertEqual(items.map(\.kind), ["Highlight", "Drawing"])
        XCTAssertEqual(items.first?.excerpt, "Important result")
        XCTAssertFalse(items.contains { $0.annotation === link })
    }

    func testSelectionSnapshotUsesOneBasedPhysicalPageAndRejectsMultiplePages() throws {
        let document = try makeTextPDFDocument(linesByPage: [
            ["First page quote"],
            ["Second page quote"]
        ])
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let secondPage = try XCTUnwrap(document.page(at: 1))
        let firstSelection = try XCTUnwrap(firstPage.selection(for: firstPage.bounds(for: .cropBox)))
        let secondSelection = try XCTUnwrap(secondPage.selection(for: secondPage.bounds(for: .cropBox)))

        let snapshot = makePDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            contentVersion: 7,
            document: document,
            selection: secondSelection
        )

        XCTAssertEqual(snapshot?.documentID, "/workspace/Paper.pdf")
        XCTAssertEqual(snapshot?.pageNumber, 2)
        XCTAssertEqual(snapshot?.text, "Second page quote")
        XCTAssertEqual(snapshot?.contentVersion, 7)
        let expectedRanges = (0..<secondSelection.numberOfTextRanges(on: secondPage)).map {
            secondSelection.range(at: $0, on: secondPage)
        }
        XCTAssertEqual(snapshot?.textRanges, expectedRanges)
        let serializedData = try XCTUnwrap(document.dataRepresentation())
        XCTAssertNoThrow(try PDFLinkedExcerptSourceValidator().validate(
            XCTUnwrap(snapshot),
            in: serializedData
        ))

        let multiplePageSelection = PDFSelection(document: document)
        multiplePageSelection.add(firstSelection)
        multiplePageSelection.add(secondSelection)
        XCTAssertNil(makePDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            document: document,
            selection: multiplePageSelection
        ))
        XCTAssertNil(makePDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            document: document,
            selection: nil
        ))
    }

    func testSelectionSnapshotKeepsExactDuplicateOccurrenceIdentity() throws {
        let originalDocument = try makeTextPDFDocument(linesByPage: [
            ["Repeated quote", "Repeated quote"]
        ])
        let originalPage = try XCTUnwrap(originalDocument.page(at: 0))
        let pageText = try XCTUnwrap(originalPage.string) as NSString
        let firstRange = pageText.range(of: "Repeated quote")
        guard firstRange.location != NSNotFound else {
            return XCTFail("Expected the first duplicate in extracted PDF text")
        }
        let remainingRange = NSRange(
            location: NSMaxRange(firstRange),
            length: pageText.length - NSMaxRange(firstRange)
        )
        let secondRange = pageText.range(of: "Repeated quote", options: [], range: remainingRange)
        guard secondRange.location != NSNotFound else {
            return XCTFail("Expected the second duplicate in extracted PDF text")
        }
        let secondSelection = try XCTUnwrap(originalPage.selection(for: secondRange))
        let snapshot = try XCTUnwrap(makePDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            document: originalDocument,
            selection: secondSelection
        ))

        XCTAssertEqual(snapshot.textRanges, [secondRange])

        let changedDocument = try makeTextPDFDocument(linesByPage: [
            ["Repeated quote", "Replacement text"]
        ])
        let changedData = try XCTUnwrap(changedDocument.dataRepresentation())
        XCTAssertThrowsError(try PDFLinkedExcerptSourceValidator().validate(snapshot, in: changedData)) {
            XCTAssertEqual($0 as? PDFLinkedExcerptSourceValidationError, .selectionChanged)
        }
    }

    func testPageDestinationValidatesOneBasedPageNumber() throws {
        let document = try makeImagePDFDocument(pageCount: 2)

        XCTAssertNil(pdfPageDestination(pageNumber: 0, document: document, displayBox: .cropBox))
        XCTAssertNil(pdfPageDestination(pageNumber: 3, document: document, displayBox: .cropBox))

        let destination = try XCTUnwrap(
            pdfPageDestination(pageNumber: 2, document: document, displayBox: .cropBox)
        )
        let secondPage = try XCTUnwrap(document.page(at: 1))
        XCTAssertTrue(destination.page === secondPage)
        XCTAssertEqual(destination.point.y, secondPage.bounds(for: .cropBox).maxY, accuracy: 0.001)
    }

    func testRootRelativeWikilinkFromNestedMarkdownResolvesPDFPageTarget() throws {
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let source = WorkspaceDocument(
            url: root.appendingPathComponent("notes/deep/Review.md"),
            rootURL: root
        )
        let pdf = WorkspaceDocument(
            url: root.appendingPathComponent("papers/Paper.pdf"),
            rootURL: root
        )
        let markdown = "[[papers/Paper.pdf#page=4|Source: Paper.pdf, page 4]]"
        let link = try XCTUnwrap(MarkdownWorkspaceLinkParser().links(in: markdown).first)

        let resolution = MarkdownWorkspaceLinkResolver().resolve(
            link,
            sourceDocument: source,
            workspaceRootURL: root,
            documents: [source, pdf]
        )

        guard case .document(let documentID, _) = resolution else {
            return XCTFail("Expected the root-relative wikilink to resolve inside the workspace")
        }
        XCTAssertEqual(documentID, pdf.id)
        XCTAssertEqual(link.destinationComponents.fragment, "page=4")

        let document = try makeImagePDFDocument(pageCount: 4)
        let destination = try XCTUnwrap(
            pdfPageDestination(pageNumber: 4, document: document, displayBox: .cropBox)
        )
        XCTAssertTrue(destination.page === document.page(at: 3))
    }

    func testPDFPageFragmentParserAcceptsOnlyStrictPositivePageNumbers() {
        XCTAssertEqual(pdfPageNumber(from: "page=4"), 4)
        XCTAssertNil(pdfPageNumber(from: "page=0"))
        XCTAssertNil(pdfPageNumber(from: "page=04"))
        XCTAssertNil(pdfPageNumber(from: "Page=4"))
        XCTAssertNil(pdfPageNumber(from: "page=4&zoom=120"))
        XCTAssertNil(pdfPageNumber(from: "page=999999999999999999999999999999999"))
    }

    func testViewportDestinationClampsPageAndPointToReplacementDocument() throws {
        let document = try makeImagePDFDocument(pageCount: 2)
        let lastPage = try XCTUnwrap(document.page(at: 1))
        let bounds = lastPage.bounds(for: .cropBox)
        let position = PDFDocumentViewportPosition(
            pageIndex: 99,
            point: DocumentScrollPosition(x: bounds.maxX + 500, y: bounds.minY - 500)
        )

        let destination = try XCTUnwrap(position.destination(in: document, displayBox: .cropBox))

        XCTAssertTrue(destination.page === lastPage)
        XCTAssertEqual(destination.point.x, bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(destination.point.y, bounds.minY, accuracy: 0.001)
    }

    func testMultilineMarkupStoresOnlyEachLineTextOnItsAnnotation() throws {
        let document = try makeTextPDFDocument(linesByPage: [["First line", "Second line"]])
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: page.bounds(for: .cropBox)))
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        pdfView.setCurrentSelection(selection, animate: false)

        pdfView.addTextMarkup(kind: .highlight, color: .systemYellow)

        let contents = page.annotations.compactMap(\.contents)
        XCTAssertGreaterThanOrEqual(contents.count, 2)
        XCTAssertTrue(contents.allSatisfy { !$0.contains("\n") })
        XCTAssertTrue(contents.contains { $0.contains("First line") })
        XCTAssertTrue(contents.contains { $0.contains("Second line") })
    }

    func testPDFSearchUsesSharedCaseAndWholeWordOptions() throws {
        let document = try makeTextPDFDocument(linesByPage: [[
            "Needle needle needler needle-café"
        ]])
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        let coordinator = PDFKitPreviewRepresentable.Coordinator()
        var result = DocumentSearchResult()
        coordinator.onSearchResult = { result = $0 }

        var state = DocumentSearchState()
        state.present()
        state.setQuery("needle")

        coordinator.applySearch(state, theme: .defaultLight, in: pdfView)
        XCTAssertEqual(result.totalCount, 4)

        coordinator.applySearch(
            state,
            options: MonknotSearchOptions(isCaseSensitive: true),
            theme: .defaultLight,
            in: pdfView
        )
        XCTAssertEqual(result.totalCount, 3)

        coordinator.applySearch(
            state,
            options: MonknotSearchOptions(isCaseSensitive: true, isWholeWord: true),
            theme: .defaultLight,
            in: pdfView
        )
        XCTAssertEqual(result.totalCount, 2)
    }

    private func makeImagePDFDocument(
        pageCount: Int,
        pageSize: NSSize = NSSize(width: 240, height: 300)
    ) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw NSError(domain: "PDFNavigatorAndSelectionTests", code: 2)
        }

        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    private func makeTextPDFDocument(linesByPage: [[String]]) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 260, height: 220)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw NSError(domain: "PDFNavigatorAndSelectionTests", code: 1)
        }

        for lines in linesByPage {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: 20, y: 154 - CGFloat(index * 26)),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 14),
                        .foregroundColor: NSColor.black
                    ]
                )
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

}

@MainActor
private final class NavigatorLaggingPDFView: PDFView {
    var navigatorCurrentPage: PDFPage?
    var laggingDestination: PDFDestination?

    override var currentPage: PDFPage? {
        navigatorCurrentPage ?? super.currentPage
    }

    override var currentDestination: PDFDestination? {
        laggingDestination ?? super.currentDestination
    }
}
