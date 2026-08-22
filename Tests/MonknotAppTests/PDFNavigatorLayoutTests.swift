import AppKit
import MonknotCore
import PDFKit
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class PDFNavigatorLayoutTests: PDFNavigatorTestCase {
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
}
