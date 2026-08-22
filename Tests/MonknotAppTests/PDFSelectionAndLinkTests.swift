import AppKit
import MonknotCore
import PDFKit
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class PDFSelectionAndLinkTests: PDFNavigatorTestCase {
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
}
