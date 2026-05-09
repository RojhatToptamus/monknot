import CoreGraphics
import CoreText
import Foundation
import MarkprevCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

func writeSearchablePDF(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw NSError(domain: "MarkprevSmokeTests", code: 1)
    }

    context.beginPDFPage(nil)

    let attributed = NSAttributedString(string: text, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 14, nil),
        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1)
    ])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
    let path = CGMutablePath()
    path.addRect(CGRect(x: 72, y: 72, width: 468, height: 648))
    let frame = CTFramesetterCreateFrame(
        framesetter,
        CFRange(location: 0, length: attributed.length),
        path,
        nil
    )
    CTFrameDraw(frame, context)

    context.endPDFPage()
    context.closePDF()
}

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("markprev-smoke")
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
defer { try? FileManager.default.removeItem(at: root) }

try write("# Markprev", to: root.appendingPathComponent("README.md"))
try writeSearchablePDF("Guide pdf-only-token", to: root.appendingPathComponent("Guide.pdf"))
try write("- [ ] item", to: root.appendingPathComponent("Notes/Todo.markdown"))
try write("ignored", to: root.appendingPathComponent("Notes/image.png"))
try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("Loop"),
    withDestinationURL: root
)

let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
let paths = scan.documents.map(\.relativePath).sorted()
expect(paths == ["Guide.pdf", "Notes/Todo.markdown", "Notes/image.png", "README.md"], "scanner should include regular workspace files")
expect(scan.documents.first(where: { $0.relativePath == "Guide.pdf" })?.kind == .pdf, "scanner should classify PDFs")
expect(scan.documents.first(where: { $0.relativePath == "Notes/image.png" })?.kind == .nativePreview, "scanner should classify image files as native-preview documents")
expect(!scan.root.children!.contains(where: { $0.name == "Loop" }), "scanner should skip symbolic link directories")
expect(scan.root.children?.first?.name == "Notes", "folders should sort before documents")

guard let readmeDocument = scan.documents.first(where: { $0.relativePath == "README.md" }),
      let guideDocument = scan.documents.first(where: { $0.relativePath == "Guide.pdf" }),
      let todoDocument = scan.documents.first(where: { $0.relativePath == "Notes/Todo.markdown" })
else {
    fputs("FAIL: expected tab smoke documents\n", stderr)
    exit(1)
}

var tabs = WorkspaceTabState()
tabs.open(readmeDocument)
expect(tabs.tabs.map(\.documentID) == [readmeDocument.id], "opening first document should create one tab")
expect(tabs.selectedDocumentID == readmeDocument.id, "opening first document should select its tab")
tabs.open(guideDocument)
expect(tabs.tabs.map(\.documentID) == [readmeDocument.id, guideDocument.id], "opening second document should append a tab")
expect(tabs.selectedDocumentID == guideDocument.id, "opening second document should select it")
tabs.open(readmeDocument)
expect(tabs.tabs.count == 2, "opening an already-open document should not duplicate tabs")
expect(tabs.selectedDocumentID == readmeDocument.id, "opening an existing tab should activate it")
tabs.moveTab(documentID: guideDocument.id, before: readmeDocument.id)
expect(tabs.tabs.map(\.documentID) == [guideDocument.id, readmeDocument.id], "drag reordering should move a tab before the target tab")
tabs.moveTab(documentID: readmeDocument.id, before: guideDocument.id)
expect(tabs.tabs.map(\.documentID) == [readmeDocument.id, guideDocument.id], "drag reordering should support moving a tab back")
tabs.moveTab(documentID: readmeDocument.id, before: nil)
expect(tabs.tabs.map(\.documentID) == [guideDocument.id, readmeDocument.id], "drag reordering should support moving a tab to the end")
tabs.moveTab(documentID: readmeDocument.id, before: guideDocument.id)
expect(tabs.tabs.map(\.documentID) == [readmeDocument.id, guideDocument.id], "drag reordering should preserve order after moving from the end")
tabs.togglePin(documentID: guideDocument.id)
expect(tabs.tabs.first?.documentID == guideDocument.id, "pinning should move a tab before unpinned tabs")
let nextAfterClose = tabs.close(documentID: readmeDocument.id)
expect(nextAfterClose == guideDocument.id, "closing the active tab should choose a neighboring tab")
expect(tabs.selectedDocumentID == guideDocument.id, "closing the active tab should update selection")
tabs.close(documentID: guideDocument.id)
expect(tabs.tabs.isEmpty, "closing the final tab should empty the tab list")
expect(tabs.selectedDocumentID == nil, "closing the final tab should clear selection")
expect(tabs.isEmptyByUserChoice, "closing the final tab should record user-empty state")
tabs.open(readmeDocument)
tabs.open(todoDocument)
let renamedTodoID = root.appendingPathComponent("Notes/Renamed.markdown").standardizedFileURL.path
tabs.remapDocumentID(sourceID: todoDocument.id, destinationID: renamedTodoID)
expect(tabs.contains(documentID: renamedTodoID), "tab state should remap renamed document IDs")
expect(!tabs.contains(documentID: todoDocument.id), "tab state should remove old renamed document IDs")
tabs.pruneUnavailableDocuments(availableDocumentIDs: [readmeDocument.id], preserving: [renamedTodoID])
expect(tabs.contains(documentID: renamedTodoID), "tab pruning should preserve known dirty removed tab IDs")
tabs.pruneUnavailableDocuments(availableDocumentIDs: [readmeDocument.id])
expect(!tabs.contains(documentID: renamedTodoID), "tab pruning should remove unavailable unpreserved tab IDs")

let outline = MarkdownOutlineParser().parse("""
# Title

```swift
# Ignored
```

## Section
""")
expect(outline.map(\.title) == ["Title", "Section"], "outline parser should skip fenced code headings")
expect(outline.map { $0.location.line } == [1, 7], "outline parser should preserve source line numbers")

let searchMatches = try WorkspaceSearchService().search(query: "item", documents: scan.documents)
expect(searchMatches.count == 1, "workspace search should find Markdown matches")
expect(searchMatches.first?.relativePath == "Notes/Todo.markdown", "workspace search should report the matched document")
expect(searchMatches.first?.line == 1, "workspace search should report the matched line")

let pdfSearchMatches = try WorkspaceSearchService().search(query: "pdf-only-token", documents: scan.documents)
expect(pdfSearchMatches.count == 1, "workspace search should find searchable PDF matches")
expect(pdfSearchMatches.first?.kind == .pdf, "workspace search should mark PDF matches")
expect(pdfSearchMatches.first?.locationLabel == "p1", "workspace search should report PDF page labels")
expect(pdfSearchMatches.first?.pdfTarget?.page == 1, "workspace search should attach a PDF page target")
expect(pdfSearchMatches.first?.pdfTarget?.matchIndex == 0, "workspace search should attach a PDF match target")

let lowScale = MarkdownPDFExportOptions(scalePercent: 40)
let highScale = MarkdownPDFExportOptions(scalePercent: 250)
let customScale = MarkdownPDFExportOptions(scalePercent: 125)
expect(lowScale.scalePercent == 70, "PDF export scale should clamp the lower bound")
expect(highScale.scalePercent == 180, "PDF export scale should clamp the upper bound")
expect(customScale.resolvedScale == 1.25, "PDF export scale should resolve from percent")

let renderService = MarkdownRenderService(stylesheet: "body {}", rendererJavaScript: "window.ready = true;")
let html = try renderService.htmlDocument(
    markdown: "# Hello\n<script>alert(1)</script>",
    theme: .dark,
    baseURL: root
)
expect(html.contains(#"data-theme="dark""#), "render shell should include the selected theme")
expect(!html.contains("</script>alert"), "render shell should safely encode script-closing Markdown")
expect(html.contains("window.ready = true"), "render shell should embed local renderer JavaScript")

let preferenceHTML = try renderService.htmlDocument(
    markdown: "# Preferences",
    appTheme: AppTheme.codexDark,
    zoomScale: 1,
    baseFontSize: 16,
    previewWidthPercent: 88,
    usePointerCursors: true,
    fontSmoothing: false,
    baseURL: root
)
expect(preferenceHTML.contains("--interactive-cursor: pointer;"), "preview shell should reflect pointer cursor preference")
expect(preferenceHTML.contains("--font-smoothing: auto;"), "preview shell should reflect font smoothing preference")

print("Markprev smoke tests passed")
