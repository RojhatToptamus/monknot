import AppKit
import MonknotCore
import PDFKit
import SwiftUI
import XCTest
@testable import MonknotApp

@MainActor
final class PDFNavigatorSearchTests: PDFNavigatorTestCase {
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
}
