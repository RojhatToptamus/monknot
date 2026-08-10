import AppKit
import MonknotCore
import PDFKit
import SwiftUI
import XCTest
@testable import MonknotApp

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
            contentVersion: 0,
            viewportState: nil,
            viewportCaptureBridge: PDFViewportCaptureBridge(),
            externalUndoCommandSerial: 0,
            externalRedoCommandSerial: 0,
            searchState: .constant(DocumentSearchState()),
            searchTarget: .constant(nil),
            markEdited: { _, _ in },
            reportError: { _ in },
            saveDocument: {},
            pageNavigationRequest: request,
            externalNavigatorToggleCommandSerial: 2,
            insertLinkedExcerpt: { _ in },
            onSelectionSnapshotChange: { _ in },
            onPageNavigationRequestConsumed: { _ in },
            onViewportStateChange: { _ in },
            updateAnnotationUndoState: { _, _ in }
        )

        XCTAssertEqual(preview.pageNavigationRequest, request)
        XCTAssertEqual(preview.externalNavigatorToggleCommandSerial, 2)
    }

    func testNavigatorUsesTheActivePDFViewAndDetachesCompletely() throws {
        let container = PDFPreviewContainerView()
        let document = try makeImagePDFDocument(pageCount: 2)
        container.pdfView.document = document
        container.navigatorView.attach(to: container.pdfView)
        container.setNavigatorPresented(true)

        XCTAssertTrue(container.navigatorView.thumbnailView.pdfView === container.pdfView)
        XCTAssertTrue(container.pdfView.document === document)
        container.navigatorView.selectSection(.outline)
        XCTAssertNil(container.navigatorView.thumbnailView.pdfView)
        container.navigatorView.selectSection(.pages)
        XCTAssertTrue(container.navigatorView.thumbnailView.pdfView === container.pdfView)

        var editCallbackCount = 0
        container.pdfView.onEdited = { _, _ in editCallbackCount += 1 }
        container.prepareForDismantle()

        XCTAssertNil(container.navigatorView.thumbnailView.pdfView)
        XCTAssertNil(container.navigatorView.outlineView.delegate)
        XCTAssertNil(container.navigatorView.outlineView.dataSource)
        XCTAssertNil(container.navigatorView.annotationTableView.delegate)
        XCTAssertNil(container.navigatorView.annotationTableView.dataSource)
        XCTAssertNil(container.pdfView.document)

        container.pdfView.onEdited(nil, Data())
        XCTAssertEqual(editCallbackCount, 0)
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

    func testLiveViewportCapturePersistsPageAndZoomBeforeTerminationTeardown() throws {
        let suiteName = "MonknotPDFTerminationViewportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = DocumentViewportStatePersistence(defaults: defaults)
        let workspaceURL = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let documentID = "/workspace/Paper.pdf"
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        let document = try makeImagePDFDocument(
            pageCount: 2,
            pageSize: NSSize(width: 612, height: 792)
        )
        let secondPage = try XCTUnwrap(document.page(at: 1))
        pdfView.document = document
        pdfView.layoutDocumentView()
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.2
        pdfView.go(to: PDFDestination(
            page: secondPage,
            at: CGPoint(x: 20, y: secondPage.bounds(for: .cropBox).maxY - 20)
        ))
        let bridge = PDFViewportCaptureBridge()
        bridge.attach(documentID: documentID, to: pdfView)

        let capture = try XCTUnwrap(bridge.capture())
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
        pdfView.prepareForDismantle()

        let restored = try XCTUnwrap(persistence.load(for: workspaceURL)[documentID]?.pdfViewportState)
        XCTAssertEqual(restored.position?.pageIndex, 1)
        XCTAssertEqual(restored.zoomMode, .fixed(scaleFactor: 1.2))
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
