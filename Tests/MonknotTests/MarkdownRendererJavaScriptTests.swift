import Foundation
import JavaScriptCore
import XCTest
@testable import MonknotCore

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

    func testThematicBreakDoesNotRenderHorizontalRule() throws {
        let html = try renderMarkdown(
            """
            # Title

            ---

            ## Section
            """
        )

        XCTAssertFalse(html.contains("<hr"))
    }

    func testFencedCodeBlockRendersSyntaxHighlightTokens() throws {
        let html = try renderMarkdown(
            """
            ```swift
            let count = 42
            // comment
            ```
            """
        )

        XCTAssertTrue(html.contains(#"class="language-swift""#))
        XCTAssertTrue(html.contains(#"<span class="tok-keyword">let</span>"#))
        XCTAssertTrue(html.contains(#"<span class="tok-number">42</span>"#))
        XCTAssertTrue(html.contains(#"<span class="tok-comment">// comment</span>"#))
    }

    func testShorterFenceDoesNotCloseLongerFenceOrExposeHiddenReferenceDefinition() throws {
        let html = try renderMarkdown(
            """
            ````md
            [inside][ref]
            ```
            [ref]: Hidden.md
            ````
            [visible][ref]

            [ref]: Visible.md
            """
        )

        XCTAssertTrue(html.contains("[ref]: Hidden.md"))
        XCTAssertTrue(html.contains(#"data-monknot-destination="Visible.md">visible</a>"#))
        XCTAssertFalse(html.contains(#"data-monknot-destination="Hidden.md""#))
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

    func testWorkspaceLinksRenderAsDelegatedActionTargets() throws {
        let html = try renderMarkdown("See [[Daily Note#Plan|today]] and [**guide**](Folder/Guide.md#Setup).")

        XCTAssertTrue(html.contains(#"class="wikilink" data-monknot-link-kind="wikilink" data-monknot-destination="Daily Note#Plan">today</a>"#))
        XCTAssertTrue(html.contains(#"data-monknot-link-kind="markdown" data-monknot-destination="Folder/Guide.md#Setup""#))
        XCTAssertTrue(html.contains("<strong>guide</strong></a>"))
        XCTAssertFalse(html.contains("<span class=\"wikilink\""))
    }

    func testReferenceStyleLinksUseDefinitionsWithoutRenderingOrActivatingDefinitions() throws {
        let html = try renderMarkdown(
            """
            Read [**the guide**][Guide   Ref] and [collapsed][].

            [guide ref]: <Folder/Guide.md#Setup> "Setup title"
            [collapsed]: Other.md

            `[code][guide ref]`

            ```md
            [fenced][hidden]
            [hidden]: Hidden.md
            ```
            """
        )

        XCTAssertTrue(html.contains(#"data-monknot-link-kind="markdown" data-monknot-destination="Folder/Guide.md#Setup" title="Setup title"><strong>the guide</strong></a>"#))
        XCTAssertTrue(html.contains(#"data-monknot-link-kind="markdown" data-monknot-destination="Other.md">collapsed</a>"#))
        XCTAssertFalse(html.contains("[guide ref]:"))
        XCTAssertFalse(html.contains("[collapsed]:"))
        XCTAssertTrue(html.contains("<code>[code][guide ref]</code>"))
        XCTAssertTrue(html.contains("[hidden]: Hidden.md"))
        XCTAssertFalse(html.contains(#"data-monknot-destination="Hidden.md""#))
    }

    func testTaskMetadataUsesOriginalSourceLineAfterFootnoteDefinitions() throws {
        let html = try renderMarkdown(
            """
            [^note]: Footnote text
            # Heading
            - [ ] open
            - [X] done
            """
        )

        XCTAssertTrue(html.contains(#"<h1 data-source-line="2""#))
        XCTAssertTrue(html.contains(#"data-monknot-task data-source-line="3" data-task-checked="false""#))
        XCTAssertTrue(html.contains(#"data-monknot-task data-source-line="4" data-task-checked="true""#))
        XCTAssertFalse(html.contains("checkbox\" disabled"))
    }

    func testQuotedTaskMetadataUsesAbsoluteSourceLine() throws {
        let html = try renderMarkdown(
            """
            Intro

            > Context
            > - [ ] quoted task
            """
        )

        XCTAssertTrue(html.contains(#"data-monknot-task data-source-line="4" data-task-checked="false""#))
        XCTAssertTrue(html.contains(#"<li data-source-line="4" class="task-list-item">"#))
    }

    func testFencedCodeOffersPasteIntoTerminalWithoutEmbeddingExecutableBehavior() throws {
        let html = try renderMarkdown(
            """
            ```sh
            printf 'safe'
            ```
            """
        )

        XCTAssertTrue(html.contains(#"type="button" class="monknot-code-terminal-action" data-monknot-paste-code"#))
        XCTAssertTrue(html.contains(">Paste into Terminal</button>"))
        XCTAssertFalse(html.contains("onclick="))
    }

    func testExportedHeadingNormalizerMatchesCoreNormalizer() throws {
        let context = try rendererContext(markdown: "# Heading")
        let javascriptValue = context.evaluateScript("window.monknotNormalizeHeadingFragment(' Hello, **World**! ')")?.toString()

        XCTAssertEqual(javascriptValue, MarkdownHeadingFragment.normalized(" Hello, **World**! "))
    }

    private func renderMarkdown(_ markdown: String) throws -> String {
        let context = try rendererContext(markdown: markdown)
        let target = try XCTUnwrap(context.objectForKeyedSubscript("target"))
        return try XCTUnwrap(target.objectForKeyedSubscript("innerHTML")?.toString())
    }

    private func rendererContext(markdown: String) throws -> JSContext {
        let rendererURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MonknotCore/Resources/renderer.js")
        let renderer = try String(contentsOf: rendererURL, encoding: .utf8)
        let context = try XCTUnwrap(JSContext())
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
              getElementById: function(id) { return id === "content" ? target : null; },
              addEventListener: function() {},
              removeEventListener: function() {}
            };
            var window = {
              monknot: {
                markdown: \(try javascriptStringLiteral(markdown)),
                documentID: "/workspace/Note.md",
                renderID: 1
              }
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

        return context
    }

    private func javascriptStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
