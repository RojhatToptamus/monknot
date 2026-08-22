import AppKit
import MonknotCore
import PDFKit
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class PDFViewportPersistenceTests: PDFNavigatorTestCase {
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
}
