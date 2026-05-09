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

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("markprev-smoke")
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
defer { try? FileManager.default.removeItem(at: root) }

try write("# Markprev", to: root.appendingPathComponent("README.md"))
try write("%PDF-1.7", to: root.appendingPathComponent("Guide.pdf"))
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
expect(scan.documents.first(where: { $0.relativePath == "Notes/image.png" })?.kind == .unsupported, "scanner should classify unsupported files without opening them")
expect(!scan.root.children!.contains(where: { $0.name == "Loop" }), "scanner should skip symbolic link directories")
expect(scan.root.children?.first?.name == "Notes", "folders should sort before documents")

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
