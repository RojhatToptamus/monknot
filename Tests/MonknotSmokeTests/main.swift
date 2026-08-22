import CoreGraphics
import CoreText
import Foundation
import MonknotCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
}

func writeSearchablePDF(_ text: String, to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.beginPDFPage(nil)
    context.textPosition = CGPoint(x: 72, y: 700)
    CTLineDraw(
        CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key:
                    CTFontCreateWithName("Helvetica" as CFString, 14, nil)
            ]
        )),
        context
    )
    context.endPDFPage()
    context.closePDF()
}

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("MonknotSmokeTests-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: root) }
try write("# Monknot\ntext-only-token", to: root.appendingPathComponent("README.md"))
try write("<p>html-only-token</p>", to: root.appendingPathComponent("Notes/Preview.html"))
try writeSearchablePDF("pdf-only-token", to: root.appendingPathComponent("Guide.pdf"))
try write("ignored", to: root.appendingPathComponent("image.png"))
try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("Loop"),
    withDestinationURL: root
)

let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
expect(
    scan.documents.map(\.relativePath).sorted() == ["Guide.pdf", "Notes/Preview.html", "README.md"],
    "scanner must retain only supported workspace documents"
)
expect(!scan.root.children!.contains { $0.name == "Loop" }, "scanner must not cross symlink boundaries")

let search = WorkspaceSearchService()
let textResults = try search.search(query: "text-only-token", documents: scan.documents).results
let htmlResults = try search.search(query: "html-only-token", documents: scan.documents).results
let pdfResults = try search.search(query: "pdf-only-token", documents: scan.documents).results
expect(textResults.count == 1, "text search failed")
expect(htmlResults.count == 1, "HTML search failed")
expect(pdfResults.first?.kind == .pdf, "PDF search failed")

let html = try MarkdownRenderService(stylesheet: "body {}", rendererJavaScript: "window.ready = true;")
    .htmlDocument(markdown: "# Hello", theme: .dark, baseURL: root)
expect(html.contains(#"data-theme="dark""#), "Markdown render shell must include the selected theme")
print("Monknot smoke tests passed")
