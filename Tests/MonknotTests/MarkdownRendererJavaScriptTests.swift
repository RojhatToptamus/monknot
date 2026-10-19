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

    func testTableAcceptsGitHubDelimiterRowsOfAnyLength() throws {
        let compact = try renderMarkdown("|a|b|\n|-|:-:|\n|1|2|")
        XCTAssertTrue(compact.contains("<th>a</th>"), compact)
        XCTAssertTrue(compact.contains(#"<td align="center">2</td>"#), compact)

        // As on GitHub, a delimiter row with a different number of cells is no table.
        let mismatched = try renderMarkdown("a | b\n-\nc")
        XCTAssertFalse(mismatched.contains("<table>"), mismatched)
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

    func testFencedCodeRendersCompleteSelectableBlockWithoutTerminalAction() throws {
        let html = try renderMarkdown(
            """
            ```sh
            printf 'safe'
            ```
            """
        )

        XCTAssertTrue(html.contains(#"<pre data-source-line="1"><code class="language-sh">printf "#))
        XCTAssertTrue(html.contains("safe"))
        XCTAssertFalse(html.contains("data-monknot-paste-code"))
        XCTAssertFalse(html.contains("Paste into Terminal"))
        XCTAssertFalse(html.contains("monknot-code-terminal-action"))
    }

    func testExportedHeadingNormalizerMatchesCoreNormalizer() throws {
        let context = try rendererContext(markdown: "# Heading")
        let javascriptValue = context.evaluateScript("window.monknotNormalizeHeadingFragment(' Hello, **World**! ')")?.toString()

        XCTAssertEqual(javascriptValue, MarkdownHeadingFragment.normalized(" Hello, **World**! "))
    }

    /// CommonMark code spans (6.1): a run of N backticks closes at the next run of exactly N, so a
    /// backtick fits inside a longer run, as the editor's paste writes it; one space each side is
    /// dropped when both are there and the span is not all spaces; a run nothing closes is literal.
    func testCodeSpansMatchBacktickRunsOfEqualLength() throws {
        XCTAssertEqual(try renderMarkdown("``a`b``"), #"<p data-source-line="1"><code>a`b</code></p>"#)
        XCTAssertEqual(try renderMarkdown("x `` ` `` y"), #"<p data-source-line="1">x <code>`</code> y</p>"#)
        XCTAssertEqual(try renderMarkdown("` `` `"), #"<p data-source-line="1"><code>``</code></p>"#)
        XCTAssertEqual(try renderMarkdown("`  a  `"), #"<p data-source-line="1"><code> a </code></p>"#)
        XCTAssertEqual(try renderMarkdown("` a`"), #"<p data-source-line="1"><code> a</code></p>"#)
        XCTAssertEqual(try renderMarkdown("` `"), #"<p data-source-line="1"><code> </code></p>"#)
        XCTAssertEqual(try renderMarkdown("`code` and ``more``"), #"<p data-source-line="1"><code>code</code> and <code>more</code></p>"#)
        XCTAssertEqual(try renderMarkdown("one ` tick and `code`"), #"<p data-source-line="1">one <code>tick and</code>code`</p>"#)
        XCTAssertEqual(try renderMarkdown("a ``b` c"), #"<p data-source-line="1">a ``b` c</p>"#)
        XCTAssertEqual(try renderMarkdown("**`x`** `[link](y)`"), #"<p data-source-line="1"><strong><code>x</code></strong> <code>[link](y)</code></p>"#)
    }

    /// The editor maps a code span's text to the source through these ranges: the whole span, and its
    /// text inside the backtick runs and the space dropped at each end.
    func testCodeSpanSourceRangesCoverTheRunsAndDroppedSpaces() throws {
        let context = try rendererContext(markdown: "")
        func code(_ text: String) throws -> [Int] {
            let literal = try javascriptStringLiteral(text)
            let value = context.evaluateScript("""
            (() => {
              const node = window.MonknotMarkdown.parseInline(\(literal), { editing: true }).find((item) => item.t === "code");
              return [node.s, node.e, node.cs, node.ce];
            })()
            """)
            return try XCTUnwrap(value?.toArray() as? [NSNumber]).map(\.intValue)
        }
        XCTAssertEqual(try code("x ``a`b`` y"), [2, 9, 4, 7])
        XCTAssertEqual(try code("` a `"), [0, 5, 2, 3])
        XCTAssertEqual(try code("`a`"), [0, 3, 1, 2])
    }

    // MARK: - What the read-only Preview and PDF export show

    func testTogglesRenderAsDetailsKeepingTheFilesOpenState() throws {
        let closed = try renderMarkdown("<details>\n<summary>Closed **title**</summary>\n\nBody text\n\n</details>\nAfter")
        XCTAssertTrue(closed.contains(#"<details data-source-line="1"><summary>Closed <strong>title</strong></summary><p data-source-line="4">Body text</p></details>"#), closed)
        XCTAssertTrue(closed.contains(#"<p data-source-line="7">After</p>"#), closed)

        let open = try renderMarkdown("<details open>\n<summary>Open</summary>\n\n- item\n\n</details>")
        XCTAssertTrue(open.contains(#"<details data-source-line="1" open><summary>Open</summary><ul data-source-line="4"><li data-source-line="4">item</li></ul></details>"#), open)
    }

    /// Without `</details>` a toggle runs to the end of the document, as HTML closes it.
    func testAnUnclosedToggleRunsToTheEnd() throws {
        let html = try renderMarkdown("Before\n\n<details>\n<summary>Open ended</summary>\n\nInside\n\n# Still inside")
        XCTAssertTrue(html.hasSuffix(#"<p data-source-line="6">Inside</p>"# + "\n" + #"<h1 data-source-line="8" id="still-inside">Still inside</h1></details>"#), html)
        // Without a one-line summary it is no toggle; the HTML stays text.
        XCTAssertFalse(try renderMarkdown("<details>\nNo summary").contains("<details"))
    }

    func testCalloutsRenderTheirKindAndABlankLineSplitsTwo() throws {
        let html = try renderMarkdown("> [!NOTE]\n> First\n\n> [!WARNING]\n> Second\n\nText\n\n> Plain quote")
        XCTAssertTrue(html.contains(#"<div data-source-line="1" class="callout callout-note" role="note"><p class="callout-title">Note</p><p data-source-line="2">First</p></div>"#), html)
        XCTAssertTrue(html.contains(#"<div data-source-line="4" class="callout callout-warning" role="note"><p class="callout-title">Warning</p><p data-source-line="5">Second</p></div>"#), html)
        XCTAssertTrue(html.contains(#"<blockquote data-source-line="9"><p data-source-line="9">Plain quote</p></blockquote>"#), html)
        // A callout with no text yet still shows its kind.
        XCTAssertTrue(try renderMarkdown("> [!tip]").contains(#"<p class="callout-title">Tip</p></div>"#))
    }

    /// `[TOC]` lists the top-level h1–h3, indented from the shallowest level present; read-only, a
    /// document without headings shows nothing for it.
    func testTableOfContentsListsTopLevelHeadingsByLevel() throws {
        let html = try renderMarkdown("[TOC]\n\n## Two **bold**\n\n### Three\n\n#### Four\n\n> # Quoted")
        XCTAssertTrue(html.hasPrefix(##"<nav data-source-line="1" class="toc" aria-label="Table of contents"><ul><li class="toc-level-1"><a href="#two-bold" data-mk-toc="0">Two bold</a></li><li class="toc-level-2"><a href="#three" data-mk-toc="1">Three</a></li></ul></nav>"##), html)
        XCTAssertFalse(html.contains(#">Four</a>"#))
        XCTAssertFalse(html.contains(#">Quoted</a>"#))

        let empty = try renderMarkdown("[TOC]\n\nNo headings")
        XCTAssertEqual(empty, #"<p data-source-line="3">No headings</p>"#)
    }

    /// Image syntax pointing at a video or audio file plays it, as GitHub does.
    func testMediaEmbedsPlayVideoAndAudio() throws {
        let html = try renderMarkdown("![clip](movie.mp4)\n\n![song](a%20b.m4a)\n\n![photo](p.png)")
        XCTAssertTrue(html.contains(#"<video src="movie.mp4" controls preload="metadata" aria-label="clip"></video>"#), html)
        XCTAssertTrue(html.contains(#"<audio src="a%20b.m4a" controls preload="metadata" aria-label="song"></audio>"#), html)
        XCTAssertTrue(html.contains(#"<img src="p.png" alt="photo">"#), html)
    }

    /// Source lines count Windows and classic Mac line endings, mixed or not, so a double-click and
    /// split view's sync land on the right line.
    func testSourceLinesCountCarriageReturnLineEndings() throws {
        let html = try renderMarkdown("# A\r\n\r\nPara\r\nmore\r\n- item\r- [x] done\n\n> quote")
        XCTAssertTrue(html.contains(#"<h1 data-source-line="1" id="a">A</h1>"#), html)
        XCTAssertTrue(html.contains(#"<p data-source-line="3">Para more</p>"#), html)
        XCTAssertTrue(html.contains(#"<li data-source-line="5">item</li>"#), html)
        XCTAssertTrue(html.contains(#"<input type="checkbox" data-monknot-task data-source-line="6""#), html)
        XCTAssertTrue(html.contains(#"<blockquote data-source-line="8">"#), html)
        XCTAssertFalse(html.contains("\r"))
    }

    /// One carriage return in a long Unix file must not make every line search the rest of it.
    func testOneCarriageReturnKeepsReadingLinear() throws {
        let context = try rendererContext(markdown: "")
        let elapsed = try XCTUnwrap(context.evaluateScript("""
        (() => {
          const lines = [];
          for (let i = 0; i < 30000; i += 1) lines.push(`Line ${i} with **bold** text and a [link](x.md).`);
          const plain = lines.join("\\n\\n");
          const time = (source) => {
            const start = Date.now();
            window.MonknotMarkdown.parseDocument(source);
            return Date.now() - start;
          };
          time(plain);
          return [time(plain), time("first\\r\\n" + plain), time(plain + "\\r\\nlast")];
        })()
        """)?.toArray() as? [NSNumber]).map(\.doubleValue)
        XCTAssertLessThan(elapsed[1], elapsed[0] * 4 + 100, "A CR at the start: \(elapsed)")
        XCTAssertLessThan(elapsed[2], elapsed[0] * 4 + 100, "A CR at the end: \(elapsed)")
    }

    /// A closed toggle's body is not laid out; its empty rects must not read as the top of the window,
    /// or split view would jump Source into the toggle.
    func testVisibleSourceLineSkipsWhatAClosedToggleHides() throws {
        let context = try rendererContext(markdown: "")
        func visibleLine(_ elements: String) -> Int32? {
            context.evaluateScript("""
            (() => {
              const element = (line, top, shown) => ({
                dataset: { sourceLine: String(line) },
                getClientRects: () => (shown ? [{ top }] : []),
                getBoundingClientRect: () => (shown ? { top } : { top: 0, bottom: 0 })
              });
              const elements = \(elements);
              target.querySelectorAll = () => elements;
              return window.monknotVisibleSourceLine();
            })()
            """)?.toInt32()
        }
        // Lines 4 and 6 are the hidden body of the toggle on line 3.
        XCTAssertEqual(visibleLine("[element(1, 33, true), element(3, 80, true), element(4, 0, false), element(6, 0, false), element(9, 150, true)]"), 1)
        _ = context.evaluateScript("window.monknotRender({ markdown: 'x', renderID: 2 })")
        XCTAssertEqual(visibleLine("[element(1, -90, true), element(3, -40, true), element(4, 0, false), element(6, 0, false), element(9, 10, true), element(11, 60, true)]"), 9)
        _ = context.evaluateScript("window.monknotRender({ markdown: 'y', renderID: 3 })")
        XCTAssertEqual(visibleLine("[element(1, -90, true), element(3, -4, true), element(4, 0, false), element(6, 0, false), element(9, 30, true)]"), 3)
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
