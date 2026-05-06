import Foundation
@testable import MarkprevCore
import XCTest

final class MarkdownRenderServiceTests: XCTestCase {
    func testHTMLDocumentEmbedsThemeBaseAndLocalAssets() throws {
        let service = MarkdownRenderService(
            stylesheet: "body { color: var(--fg); }",
            rendererJavaScript: "document.body.dataset.ready = 'true';"
        )
        let baseURL = URL(fileURLWithPath: "/tmp/Markprev Workspace", isDirectory: true)

        let html = try service.htmlDocument(
            markdown: "# Hello\n<script>alert('x')</script>",
            theme: .dark,
            baseURL: baseURL
        )

        XCTAssertTrue(html.contains(#"data-theme="dark""#))
        XCTAssertTrue(html.contains(#"<base href="file:///tmp/Markprev%20Workspace/">"#))
        XCTAssertTrue(html.contains("body { color: var(--fg); }"))
        XCTAssertTrue(html.contains("document.body.dataset.ready"))
        XCTAssertTrue(html.contains(#"<\/script>alert"#))
    }

    func testHTMLDocumentEscapesMarkdownForJavaScriptString() throws {
        let service = MarkdownRenderService(stylesheet: "", rendererJavaScript: "")
        let html = try service.htmlDocument(markdown: #"quote " slash \ newline"#, theme: .light, baseURL: nil)

        XCTAssertTrue(html.contains(#"quote \" slash \\ newline"#))
    }
}
