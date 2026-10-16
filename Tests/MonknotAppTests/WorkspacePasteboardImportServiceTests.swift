import AppKit
import XCTest
@testable import MonknotApp

final class WorkspacePasteboardImportServiceTests: XCTestCase {
    func testCapturedMarkdownImportsIntoInboxWithoutOverwriting() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = WorkspacePasteboardImportItem.capturedMarkdown(
            "# Captured\n\nBody\n",
            suggestedName: "Captured.md"
        )

        let firstImport = try WorkspacePasteboardImportService.importItems([item], into: root)
        let secondImport = try WorkspacePasteboardImportService.importItems([item], into: root)

        XCTAssertEqual(firstImport.first?.deletingLastPathComponent().lastPathComponent, "inbox")
        XCTAssertEqual(firstImport.first?.lastPathComponent, "Captured.md")
        XCTAssertEqual(secondImport.first?.lastPathComponent, "Captured copy.md")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("inbox/Captured.md"), encoding: .utf8),
            "# Captured\n\nBody\n"
        )
    }

    /// HTML-only clipboard text keeps its paragraphs, breaks and list items, decodes character
    /// references, and leaves out the head, styles and scripts.
    func testPlainTextFromHTMLKeepsParagraphsAndDropsMarkup() {
        let html = """
        <html><head><meta charset="utf-8"><title>Page</title><style>p { color: red; }</style></head>
        <body><!-- note --><h1>Plan &amp; notes</h1>
        <p>First   line<br>second line</p>
        <p title="a > b">Caf&eacute; &#8212; &#x2603; 3 &lt; 4 and 5 < 6</p>
        <ul><li>One</li>
        <li>Two <img src="https://example.com/tracker.png"></li></ul>
        <script>document.write("<p>no</p>")</script><div>End&nbsp;</div></body></html>
        """

        XCTAssertEqual(
            WorkspacePasteboardImportService.plainText(fromHTML: html),
            "Plan & notes\n\nFirst line\nsecond line\n\nCaf&eacute; \u{2014} \u{2603} 3 < 4 and 5 < 6\n\n- One\n- Two\n\nEnd"
        )
    }

    func testURLStringCaptureUsesReadablePathTitleAndMetadata() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("monknot-url-capture-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/research/important-finding?utm_source=test#section", forType: .string)

        let items = try WorkspacePasteboardImportService.importItems(from: pasteboard)

        XCTAssertEqual(items.count, 1)
        guard case .capturedMarkdown(let markdown, let suggestedName) = items[0].payload else {
            return XCTFail("Expected captured markdown")
        }
        XCTAssertTrue(suggestedName.contains("Important Finding.md"), suggestedName)
        XCTAssertTrue(markdown.contains("# Important Finding"))
        XCTAssertTrue(markdown.contains("Source: https://example.com/research/important-finding?utm_source=test"))
        XCTAssertTrue(markdown.contains("Host: example.com"))
        XCTAssertTrue(markdown.contains("Path: /research/important-finding"))
        XCTAssertFalse(markdown.contains("#section"))
    }

    func testExplicitURLPasteboardCaptureUsesURLMetadata() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("monknot-explicit-url-capture-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("https://docs.example.dev/guides/custom_provider_setup", forType: .URL)

        let items = try WorkspacePasteboardImportService.importItems(from: pasteboard)

        XCTAssertEqual(items.count, 1)
        guard case .capturedMarkdown(let markdown, let suggestedName) = items[0].payload else {
            return XCTFail("Expected captured markdown")
        }
        XCTAssertTrue(suggestedName.contains("Custom Provider Setup.md"), suggestedName)
        XCTAssertTrue(markdown.contains("# Custom Provider Setup"))
        XCTAssertTrue(markdown.contains("Source: https://docs.example.dev/guides/custom_provider_setup"))
        XCTAssertTrue(markdown.contains("Host: docs.example.dev"))
        XCTAssertTrue(markdown.contains("Path: /guides/custom_provider_setup"))
    }

    func testCapturedTextItemUsesTitleOverride() throws {
        let item = try XCTUnwrap(WorkspacePasteboardImportService.capturedTextItem(
            from: "https://example.com/posts/unclear-slug",
            isURL: true,
            titleOverride: "Readable Page Title"
        ))

        guard case .capturedMarkdown(let markdown, let suggestedName) = item.payload else {
            return XCTFail("Expected captured markdown")
        }
        XCTAssertTrue(suggestedName.contains("Readable Page Title.md"), suggestedName)
        XCTAssertTrue(markdown.contains("# Readable Page Title"))
        XCTAssertTrue(markdown.contains("Source: https://example.com/posts/unclear-slug"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-pasteboard-import-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
