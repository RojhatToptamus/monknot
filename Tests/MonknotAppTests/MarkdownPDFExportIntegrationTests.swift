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
                resourceRoot: root,
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

    func testExportEmbedsWorkspaceImagesReferencedByTheNote() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownPDFExportIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let png = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("assets/chart.png"))
        let destination = root.appendingPathComponent("Images.pdf")

        try await MarkdownPDFExportService.makeDefault().exportPDF(
            for: MarkdownPDFExportRequest(
                markdown: "# Images\n\n![Chart](../assets/chart.png)\n\nAfter the image",
                baseURL: notes,
                resourceRoot: root,
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

        let page = try XCTUnwrap(PDFDocument(url: destination)?.page(at: 0)?.pageRef)
        XCTAssertGreaterThan(imageXObjectCount(in: page), 0, "the note's image is drawn into the PDF")
    }

    func testRelativeLinksInTheExportPointAtFilesNotTheAppScheme() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownPDFExportIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Links.pdf")

        try await MarkdownPDFExportService.makeDefault().exportPDF(
            for: MarkdownPDFExportRequest(
                markdown: "# Links\n\nSee [the plan](Plan%20B.md#goals), [the site](https://example.com/) and [below](#later).\n\n## Later\n",
                baseURL: notes,
                resourceRoot: root,
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

        let page = try XCTUnwrap(PDFDocument(url: destination)?.page(at: 0))
        let linkURLs = page.annotations.compactMap(\.url)
        // The page loads under Monknot's private scheme; a PDF opened anywhere else needs file: links.
        // The in-page link (#later) must not become a link to the note's folder.
        XCTAssertEqual(
            linkURLs.map(\.absoluteString).sorted(),
            [
                "https://example.com/",
                notes.appendingPathComponent("Plan B.md").absoluteString + "#goals",
            ].sorted()
        )
        XCTAssertEqual(page.annotations.count, 3)
    }

    private func imageXObjectCount(in page: CGPDFPage) -> Int {
        var count = 0
        func visit(_ resources: CGPDFDictionaryRef) {
            var xObjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return }
            CGPDFDictionaryApplyBlock(xObjects, { _, object, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream)
                else { return true }
                var subtype: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype {
                    if String(cString: subtype) == "Image" {
                        count += 1
                    } else {
                        var nested: CGPDFDictionaryRef?
                        if CGPDFDictionaryGetDictionary(dictionary, "Resources", &nested), let nested {
                            visit(nested)
                        }
                    }
                }
                return true
            }, nil)
        }
        if let pageDictionary = page.dictionary {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources), let resources {
                visit(resources)
            }
        }
        return count
    }
}
