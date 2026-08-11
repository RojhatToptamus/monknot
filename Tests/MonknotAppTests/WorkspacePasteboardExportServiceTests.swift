import AppKit
import CoreGraphics
import CoreText
import MonknotCore
import PDFKit
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspacePasteboardExportServiceTests: XCTestCase {
    func testCopyPlainTextWritesExactlyOnePlainString() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }

        try WorkspacePasteboardExportService.copyPlainText(
            "Sources/My File.swift",
            to: pasteboard
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "Sources/My File.swift")
        XCTAssertTrue(pasteboard.types?.contains(.string) == true)
        XCTAssertFalse(pasteboard.types?.contains(.fileURL) == true)
        XCTAssertFalse(pasteboard.types?.contains(.URL) == true)
    }

    func testCopyRelativePathWritesUnquotedWorkspacePath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Notes Folder", isDirectory: true)
        let file = folder.appendingPathComponent("Reader's Note.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Note\n".write(to: file, atomically: true, encoding: .utf8)
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }

        let copied = try WorkspacePasteboardExportService.copyRelativePath(
            for: file,
            in: root,
            to: pasteboard
        )

        XCTAssertEqual(copied, "Notes Folder/Reader's Note.md")
        XCTAssertEqual(pasteboard.string(forType: .string), copied)
        XCTAssertFalse(copied.hasPrefix("'"))
        XCTAssertFalse(copied.hasPrefix("/"))
    }

    func testInvalidRelativePathDoesNotChangePasteboard() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("Removed.md")
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("keep me", forType: .string))

        XCTAssertThrowsError(
            try WorkspacePasteboardExportService.copyRelativePath(
                for: missing,
                in: root,
                to: pasteboard
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testEmptyPlainTextDoesNotChangePasteboard() {
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("keep me", forType: .string))

        XCTAssertThrowsError(
            try WorkspacePasteboardExportService.copyPlainText("", to: pasteboard)
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testFailedPlainTextWriteRestoresExistingClipboardItems() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("keep me", forType: .string))
        XCTAssertTrue(item.setData(Data([0x01, 0x02]), forType: .init("com.monknot.test")))
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertThrowsError(
            try WorkspacePasteboardExportService.copyPlainText(
                "replacement",
                to: pasteboard,
                write: { _, _ in false }
            )
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
        XCTAssertEqual(
            pasteboard.data(forType: .init("com.monknot.test")),
            Data([0x01, 0x02])
        )
    }

    func testUncopyableExistingItemFailsBeforeChangingClipboard() {
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        let item = NSPasteboardItem()
        let unavailableType = NSPasteboard.PasteboardType("com.monknot.unavailable-test-data")
        let provider = EmptyPasteboardDataProvider()
        XCTAssertTrue(item.setString("keep me", forType: .string))
        item.setDataProvider(provider, forTypes: [unavailableType])
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertThrowsError(
            try WorkspacePasteboardExportService.copyPlainText("replacement", to: pasteboard)
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testFailedPlainTextWriteKeepsRestoredFileTransferAlive() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Source.md")
        try "source".write(to: sourceURL, atomically: true, encoding: .utf8)
        let pasteboard = makePasteboard()
        defer { WorkspacePasteboardExportService.clearFileTransferPasteboard(pasteboard) }
        try WorkspacePasteboardExportService.copyFile(at: sourceURL, to: pasteboard)
        let exportedURL = try XCTUnwrap(
            pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL
        )

        XCTAssertThrowsError(
            try WorkspacePasteboardExportService.copyPlainText(
                "replacement",
                to: pasteboard,
                write: { _, _ in false }
            )
        )

        XCTAssertTrue(WorkspacePasteboardExportService.ownsPasteboard(pasteboard))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))
    }

    func testValidatedLinkedExcerptCopiesExactMarkdown() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        let pdfData = try makeTextPDFData("Selected PDF text")
        let selection = try makeSelectionSnapshot(in: pdfData)
        let markdown = try PDFLinkedExcerptFormatter().validatedMarkdown(
            for: selection,
            sourceRelativePath: "papers/example.pdf",
            pdfData: pdfData
        )

        try WorkspacePasteboardExportService.copyPlainText(markdown, to: pasteboard)

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "> Selected PDF text\n>\n> [[papers/example.pdf#page=1|Source: example.pdf, page 1]]"
        )
    }

    func testStaleLinkedExcerptValidationLeavesClipboardUnchanged() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("keep me", forType: .string))
        let selection = try makeSelectionSnapshot(
            in: makeTextPDFData("Earlier text")
        )

        XCTAssertThrowsError(
            try PDFLinkedExcerptFormatter().validatedMarkdown(
                for: selection,
                sourceRelativePath: "papers/example.pdf",
                pdfData: try makeTextPDFData("Current text")
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    private func makeSelectionSnapshot(in data: Data) throws -> PDFSelectionSnapshot {
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let text = try XCTUnwrap(page.string)
        let range = NSRange(location: 0, length: (text as NSString).length)
        let selection = try XCTUnwrap(page.selection(for: range))
        let rangeCount = selection.numberOfTextRanges(on: page)
        return PDFSelectionSnapshot(
            documentID: "/workspace/papers/example.pdf",
            text: try XCTUnwrap(selection.string),
            pageNumber: 1,
            textRanges: (0..<rangeCount).map { selection.range(at: $0, on: page) }
        )
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("monknot-export-\(UUID().uuidString)"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacePasteboardExportServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeTextPDFData(_ text: String) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 240)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 28, y: 180)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)]
        ))
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

private final class EmptyPasteboardDataProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {}
}
