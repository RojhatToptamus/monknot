import Foundation
import JavaScriptCore
import XCTest

final class MarkdownRendererJavaScriptTests: XCTestCase {
    func testInlineMarkdownRendersStyledText() throws {
        let html = try renderMarkdown("**bold** *italic* ~~strike~~ `code`")

        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<del>strike</del>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
        XCTAssertFalse(html.contains("**bold**"))
        XCTAssertFalse(html.contains("~~strike~~"))
    }

    func testMultilineBoldRendersStyledTextInsteadOfRawDelimiters() throws {
        let html = try renderMarkdown(
            """
            **TEST with bold
            **
            """
        )

        XCTAssertTrue(html.contains("<strong>TEST with bold </strong>"))
        XCTAssertFalse(html.contains("**"))
    }

    func testMultilineInlineCodeRendersAsCodeInsteadOfRawBackticks() throws {
        let html = try renderMarkdown(
            """
            `multi
            line`
            """
        )

        XCTAssertTrue(html.contains("<code>multi line</code>"))
        XCTAssertFalse(html.contains("`multi"))
    }

    func testHardLineBreakRendersBreakInParagraph() throws {
        let html = try renderMarkdown(
            """
            First line  
            Second line
            """
        )

        XCTAssertTrue(html.contains("First line<br>Second line"))
    }

    func testTableRendersAsScrollableHTMLTable() throws {
        let html = try renderMarkdown(
            """
            | Layer | Responsibility | Example |
            | --- | --- | --- |
            | Presentation / UI | Shows information and interprets user commands. | `ProductViewController` |
            | Infrastructure | Technical support: persistence, external APIs, messaging, email. | `DatabaseRepository`, `PaymentGateway` |
            """
        )

        XCTAssertTrue(html.contains(#"<div data-source-line="1" class="table-wrapper"><table>"#))
        XCTAssertTrue(html.contains("<th>Layer</th>"))
        XCTAssertTrue(html.contains("<td>Presentation / UI</td>"))
        XCTAssertTrue(html.contains("<code>ProductViewController</code>"))
        XCTAssertFalse(html.contains("| --- | --- | --- |"))
    }

    private func renderMarkdown(_ markdown: String) throws -> String {
        let rendererURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MonknotCore/Resources/renderer.js")
        let renderer = try String(contentsOf: rendererURL, encoding: .utf8)
        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            XCTFail(exception?.toString() ?? "Unknown JavaScript exception")
        }

        context.evaluateScript(
            """
            var target = {
              innerHTML: "",
              addEventListener: function() {},
              querySelectorAll: function() { return []; }
            };
            var document = {
              documentElement: { dataset: {}, style: {} },
              getElementById: function(id) { return id === "content" ? target : null; }
            };
            var window = {
              monknot: { markdown: \(javascriptStringLiteral(markdown)) }
            };
            """
        )
        context.evaluateScript(renderer)

        if let exception = context.exception {
            throw NSError(
                domain: "MarkdownRendererJavaScriptTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: exception.toString() ?? "Unknown JavaScript exception"]
            )
        }

        return context.objectForKeyedSubscript("target")!
            .objectForKeyedSubscript("innerHTML")!
            .toString()
    }

    private func javascriptStringLiteral(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }
}
