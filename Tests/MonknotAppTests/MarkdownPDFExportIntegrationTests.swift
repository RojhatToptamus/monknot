import MonknotCore
import PDFKit
import XCTest
@testable import MonknotApp

@MainActor
final class MarkdownPDFExportIntegrationTests: XCTestCase {
    func testRealMultipageExportIsSearchableAndUsesLetterPageSize() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownPDFExportIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Export.pdf")
        let body = (1...80)
            .map { "Paragraph \($0) verifies that multi-page exported Markdown remains searchable." }
            .joined(separator: "\n\n")

        try await MarkdownPDFExportService.makeDefault().exportPDF(
            for: MarkdownPDFExportRequest(
                markdown: "# Export Title\n\n\(body)\n\nFinal Export Sentinel",
                baseURL: root,
                theme: .defaultLight,
                usePointerCursors: false,
                fontSmoothing: true,
                options: MarkdownPDFExportOptions(
                    pageSize: .letter,
                    marginPreset: .normal,
                    themeMode: .light,
                    scalePercent: 100,
                    textSizePoints: 12,
                    contentWidthPercent: 92
                )
            ),
            to: destination
        )

        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 2)
        for index in 0..<pdf.pageCount {
            let mediaBox = try XCTUnwrap(pdf.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(mediaBox.width, 612, accuracy: 1)
            XCTAssertEqual(mediaBox.height, 792, accuracy: 1)
        }
        XCTAssertTrue(pdf.string?.localizedCaseInsensitiveContains("Export Title") == true)
        XCTAssertTrue(pdf.string?.localizedCaseInsensitiveContains("Final Export Sentinel") == true)
    }
}
