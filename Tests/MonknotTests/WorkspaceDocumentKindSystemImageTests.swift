import XCTest
@testable import MonknotCore

final class WorkspaceDocumentKindSystemImageTests: XCTestCase {
    func testMarkdownUsesTextDocumentSymbol() {
        XCTAssertEqual(WorkspaceDocumentKind.markdown.systemImage, "doc.text.fill")
    }

    func testPDFUsesDocumentFillSymbol() {
        XCTAssertEqual(WorkspaceDocumentKind.pdf.systemImage, "doc.fill")
    }

    func testEditorModeSymbolsDifferFromNewDocumentAndFileIcons() {
        XCTAssertEqual(EditorMode.source.systemImage, "text.alignleft")
        XCTAssertEqual(EditorMode.preview.systemImage, "eye")
        XCTAssertNotEqual(EditorMode.source.systemImage, "doc.badge.plus")
        XCTAssertNotEqual(WorkspaceDocumentKind.markdown.systemImage, EditorMode.source.systemImage)
    }
}
