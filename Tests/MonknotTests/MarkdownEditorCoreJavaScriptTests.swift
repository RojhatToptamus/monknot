import Foundation
import JavaScriptCore
import XCTest

/// The visual editor's core in JavaScriptCore: every edit is planned as a patch on the Markdown
/// source, and re-parsing only the blocks a patch touches gives the same document as parsing it all.
final class MarkdownEditorCoreJavaScriptTests: XCTestCase {
    /// Each scenario is the source with the caret (‸) or selection («…»), an edit, and the exact
    /// source and selection that must result.
    func testEditingScenariosProduceTheExpectedMarkdown() throws {
        let context = try editorContext()
        let output = try XCTUnwrap(context.evaluateScript(Self.scenarios)?.toString())
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        let failures = result?["failures"] as? [String] ?? ["no result"]
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(result?["passed"] as? Int ?? 0, 60)
    }

    /// Random documents and random patches, including CRLF line endings: after every patch the
    /// incrementally updated document must equal a fresh parse of the new text.
    func testIncrementalParseMatchesAFullParse() throws {
        let context = try editorContext()
        let output = try XCTUnwrap(context.evaluateScript(Self.fuzz)?.toString())
        XCTAssertEqual(output, "ok", output)
    }

    func testWrappedListItemsStayOneItemAndOrderedListsKeepTheirStart() throws {
        let context = try editorContext()
        let html = try XCTUnwrap(context.evaluateScript(#"window.MonknotMarkdown.renderMarkdown("3. First item\n   wraps here\n4. Second")"#)?.toString())
        XCTAssertTrue(html.contains(#"<ol data-source-line="1" start="3">"#), html)
        XCTAssertTrue(html.contains("First item wraps here</li>"), html)
        XCTAssertFalse(html.contains("<p"), "The continuation line is part of the item: \(html)")
    }

    func testNestedListsRenderNested() throws {
        let context = try editorContext()
        let html = try XCTUnwrap(context.evaluateScript(#"window.MonknotMarkdown.renderMarkdown("- Parent\n  - Child\n- Sibling")"#)?.toString())
        XCTAssertTrue(html.contains("Parent<ul data-source-line=\"2\"><li data-source-line=\"2\">Child</li></ul></li><li data-source-line=\"3\">Sibling"), html)
    }

    func testHeadingKeepsAHashThatIsPartOfItsText() throws {
        let context = try editorContext()
        let html = try XCTUnwrap(context.evaluateScript(##"window.MonknotMarkdown.renderMarkdown("# C# notes #")"##)?.toString())
        XCTAssertTrue(html.contains(">C# notes</h1>"), html)
    }

    func testCodeInsideLinkInsideTableRendersAsCode() throws {
        let context = try editorContext()
        let html = try XCTUnwrap(context.evaluateScript(#"window.MonknotMarkdown.renderMarkdown("| A |\n| --- |\n| [`x`](https://a.b) |")"#)?.toString())
        XCTAssertTrue(html.contains("<code>x</code></a>"), html)
    }

    private func editorContext() throws -> JSContext {
        let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MonknotCore/Resources")
        let renderer = try String(contentsOf: resources.appendingPathComponent("renderer.js"), encoding: .utf8)
        let editor = try String(contentsOf: resources.appendingPathComponent("editor.js"), encoding: .utf8)
        let context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript("var window = {}; var document = { getElementById: function() { return null; } };")
        context.evaluateScript(renderer)
        context.evaluateScript(editor)
        if let exception { throw NSError(domain: "MarkdownEditorCoreJavaScriptTests", code: 1, userInfo: [NSLocalizedDescriptionKey: exception]) }
        XCTAssertTrue(context.evaluateScript("Boolean(window.MonknotEditorCore)")?.toBool() == true)
        return context
    }

    private static let fuzz = #"""
    (() => {
      const E = window.MonknotEditorCore;
      let seed = 20261017;
      const random = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
      const pick = (list) => list[Math.floor(random() * list.length)];
      const snippets = ["# Title", "## Sub", "para text", "more *em* and **bold**", "- item", "- [ ] task", "1. one", "  - nested", "> quote", "> > deep", "```js", "```", "code line", "| a | b |", "| --- | --- |", "| 1 | 2 |", "---", "[ref]: http://x", "[^n]: note", "see [^n] and [l][ref]", "", "", "text with [link](u) end", "~~del~~", "`code`", "line  ", "next"];
      const describe = (model) => model.blocks.map((b) => [b.type, E.bStart(b), E.bEnd(b), E.bLine(b)].join("|")).join("\n")
        + "\n--\n" + E.allUnits(model).map((u) => [u.kind, u.role, u.region.j, E.unitStart(u), E.unitEnd(u)].join("|")).join("\n");
      for (let run = 0; run < 1500; run += 1) {
        const lines = [];
        const count = 3 + Math.floor(random() * 20);
        for (let index = 0; index < count; index += 1) lines.push(pick(snippets));
        let text = lines.join(random() < 0.15 ? "\r\n" : "\n") + (random() < 0.5 ? "\n" : "");
        const model = E.createModel(text);
        for (let step = 0; step < 6; step += 1) {
          const from = Math.floor(random() * (text.length + 1));
          const to = Math.min(text.length, from + (random() < 0.5 ? 0 : Math.floor(random() * 12)));
          const insert = random() < 0.3 ? "" : pick(["x", "\n", "\n\n", "# ", "- ", "**", "`", "```", "> ", "|", " ", "[a](b)", pick(snippets) + "\n"]);
          text = text.slice(0, from) + insert + text.slice(to);
          E.applyPatch(model, from, to, insert);
          if (model.source !== text) return "source differs at run " + run;
          const incremental = describe(model);
          const full = describe(E.createModel(text));
          if (incremental !== full) return "run " + run + " step " + step + " differs for " + JSON.stringify(text);
        }
      }
      return "ok";
    })()
    """#

    private static let scenarios = #"""
    (() => {
    const E = window.MonknotEditorCore;

    function parse(marked) {
      let source = ""; let anchor = null, head = null;
      for (const ch of marked) {
        if (ch === "‸") { anchor = head = source.length; continue; }
        if (ch === "«") { anchor = source.length; continue; }
        if (ch === "»") { head = source.length; continue; }
        source += ch;
      }
      return { source, sel: { anchor, head, from: Math.min(anchor, head), to: Math.max(anchor, head) } };
    }
    function show(source, sel) {
      if (!sel) return source;
      const a = sel.anchor, h = sel.head;
      if (a === h) return source.slice(0, a) + "‸" + source.slice(a);
      const s = Math.min(a, h), e = Math.max(a, h);
      return source.slice(0, s) + "«" + source.slice(s, e) + "»" + source.slice(e);
    }
    function applyOp(model, op) {
      if (!op) return null;
      if (op.move) return { source: model.source, sel: op.select };
      E.applyPatch(model, op.from, op.to, op.insert);
      const sel = typeof op.select === "function" ? op.select(model) : op.select;
      return { source: model.source, sel };
    }
    const failures = [];
    let passed = 0;
    function check(name, marked, plan, expected) {
      const { source, sel } = parse(marked);
      const model = E.createModel(source);
      let got;
      try {
        got = (() => { const result = applyOp(model, plan(model, sel)); return result ? show(result.source, result.sel) : "(no-op)"; })();
      } catch (error) { failures.push(name + ": threw " + error); return; }
      if (got === expected) passed += 1;
      else failures.push(name + ": got " + JSON.stringify(got) + ", expected " + JSON.stringify(expected));
    }
    const type = (text) => (m, s) => E.planInsertText(m, s, text, { typing: true });
    const enter = (m, s) => E.planEnter(m, s, {});
    const backspaceAtStart = (m, s) => E.planBackspaceAtStart(m, E.unitAt(m, s.head, "left"));
    const del = (m, s) => E.planDelete(m, s.from, s.to);
    const style = (st, v) => (m, s) => E.planInlineStyle(m, s, st, v);
    const block = (t, o) => (m, s) => E.planBlockType(m, s, t, o || {});

    check("type mid", "Hel‸lo", type("x"), "Helx‸lo");
    check("type end of bold", "**bold‸**", type("x"), "**boldx‸**");
    check("enter end of paragraph", "Hello‸", enter, "Hello\n‸\n");
    check("enter end with next", "Hello‸\n\nNext", enter, "Hello\n\n‸\nNext");
    check("enter middle", "Hel‸lo", enter, "Hel\n\n‸lo");
    check("enter middle of bold", "**bo‸ld**", enter, "**bo**\n\n**‸ld**");
    check("enter start", "a\n\n‸b", enter, "a\n\n\n‸b");
    check("enter heading end", "# Title‸\nText", enter, "# Title\n\n‸\nText");
    check("enter list end", "- one‸", enter, "- one\n- ‸");
    check("enter ordered", "1. one‸", enter, "1. one\n2. ‸");
    check("enter task", "- [x] a‸", enter, "- [x] a\n- [ ] ‸");
    check("enter list middle", "- on‸e", enter, "- on\n- ‸e");
    check("enter empty item exits", "- one\n- ‸\n- two", enter, "- one\n\n‸\n- two");
    check("enter empty last item", "- one\n- ‸", enter, "- one\n‸");
    check("enter empty nested outdents", "- one\n  - ‸", enter, "- one\n- ‸");
    check("enter quote middle", "> ab‸cd", enter, "> ab\n>\n> ‸cd");
    check("enter quote end", "> abcd‸", enter, "> abcd\n>\n>‸");
    check("enter code", "```\nfoo‸\n```", enter, "```\nfoo\n‸\n```");
    check("enter code indent", "```\n  foo‸\n```", enter, "```\n  foo\n  ‸\n```");
    check("enter fence paragraph", "```js‸", enter, "```js\n‸\n```");
    check("backspace heading", "# ‸Title", backspaceAtStart, "‸Title");
    check("backspace join", "a\n\n‸b", backspaceAtStart, "a‸b");
    check("backspace item", "- ‸a", backspaceAtStart, "‸a");
    check("backspace quote", "> ‸a", backspaceAtStart, "‸a");
    check("backspace after hr", "a\n\n---\n\n‸b", backspaceAtStart, "a\n\n‸b");
    check("backspace empty line", "a\n\n\n‸\nb", (m, s) => E.planBackspaceAtStart(m, E.unitAt(m, s.head, "right")), "a\n\n‸\nb");
    check("typing into empty line", "a\n\n\n\nb", (m) => { const u = E.allUnits(m).find((x) => x.kind === "empty"); return E.planInsertText(m, { anchor: E.unitStart(u), head: E.unitStart(u), from: E.unitStart(u), to: E.unitStart(u) }, "x", { typing: true }); }, "a\n\nx‸\n\nb");
    check("typing into trailing empty", "a\n\n", (m) => { const u = E.allUnits(m).find((x) => x.kind === "empty"); const p = E.unitStart(u); return E.planInsertText(m, { anchor: p, head: p, from: p, to: p }, "x", { typing: true }); }, "a\n\nx‸\n");
    check("typing into empty doc", "‸", type("x"), "x‸");
    check("rule todo", "[]‸", type(" "), "- [ ] ‸");
    check("rule code", "``‸", type("`"), "```\n‸\n```");
    check("rule divider", "--‸", type("-"), "---\n‸\n");
    check("bold selection", "hello «world»", style("strong"), "hello **«world»**");
    check("unbold part", "**hello «world»**", style("strong"), "**hello** «world»");
    check("italic inside bold", "**a «b» c**", style("em"), "**a *«b»* c**");
    check("bold across italic", "*ab«c* d»e", style("strong"), "*ab*__*«c* d»__e");
    check("code selection", "say «hi» now", style("code"), "say `«hi»` now");
    check("link selection", "see «docs» here", style("link", "https://x.com"), "see «[docs](https://x.com)» here");
    check("unlink", "see [«docs»](https://x.com) here", style("link", null), "see «docs» here");
    check("heading type", "Hel‸lo", block("heading2"), "## Hel‸lo");
    check("bullet two paragraphs", "«a\n\nb»", block("bullet"), "- «a\n- b»");
    check("toggle bullet off", "- «a\n- b»", block("bullet", { toggle: true }), "«a\n\nb»");
    check("quote type", "Hel‸lo", block("quote"), "> Hel‸lo");
    check("code type", "a ‸b", block("code"), "```\na b‸\n```");
    check("delete across paragraphs", "ab«c\n\nd»ef", del, "ab‸ef");
    check("delete partial bold", "x **bo«ld** y»z", del, "x **bo‸**z");
    check("delete whole link label", "a [«docs»](u) b", del, "a ‸ b");
    check("delete into code", "a«b\n\n```\nco»de\n```", del, "a‸\n\n```\nde\n```");
    check("paste in quote", "> a‸b", (m, s) => E.planInsertText(m, s, "x\n\ny", { kind: "paste" }), "> ax\n>\n> y‸b");
    check("cell pipe", "| a | b |\n| --- | --- |\n| c‸ | d |", type("|"), "| a | b |\n| --- | --- |\n| c\\|‸ | d |");
    check("slash h1 empty", "/h1‸", (m, s) => E.planSlashCommand(m, E.unitAt(m, s.head, "left"), 0, 3, "h1"), "# ‸");
    check("slash bullet with text", "Hello /bul‸", (m, s) => E.planSlashCommand(m, E.unitAt(m, s.head, "left"), 6, 10, "bullet"), "- Hello ‸");
    check("slash table", "/table‸", (m, s) => E.planSlashCommand(m, E.unitAt(m, s.head, "left"), 0, 6, "table"), "| ‸ |  |  |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |");
    check("slash code after text", "Hello /code‸", (m, s) => E.planSlashCommand(m, E.unitAt(m, s.head, "left"), 6, 11, "code"), "Hello \n\n```\n‸\n```");
    check("slash divider", "/divider‸\n\nNext", (m, s) => E.planSlashCommand(m, E.unitAt(m, s.head, "left"), 0, 8, "divider"), "---\n\n‸\nNext");
    check("table row below", "| a | b |\n| --- | --- |\n| c‸ | d |", (m, s) => E.planTable(m, E.unitAt(m, s.head, "left"), "rowBelow"), "| a | b |\n| --- | --- |\n| c | d |\n| ‸ |  |");
    check("table column right", "| a | b |\n| --- | --- |\n| c‸ | d |", (m, s) => E.planTable(m, E.unitAt(m, s.head, "left"), "columnRight"), "| a |  | b |\n| --- | --- | --- |\n| c | ‸ | d |");
    check("table delete column", "| a | b |\n| --- | --- |\n| c‸ | d |", (m, s) => E.planTable(m, E.unitAt(m, s.head, "left"), "deleteColumn"), "| ‸b |\n| --- |\n| d |");
    check("indent item", "- a\n- b‸", (m, s) => E.planIndent(m, s, 1), "- a\n  - b‸");
    check("outdent item", "- a\n  - b‸", (m, s) => E.planIndent(m, s, -1), "- a\n- b‸");
    check("enter on empty quote line exits", "> a\n>\n>‸", (m, s) => E.planEnter(m, { anchor: s.head, head: s.head, from: s.head, to: s.head }), "> a\n‸\n");
    check("crlf enter", "Hello‸\r\n", enter, "Hello\r\n‸\r\n");
    check("toggle task", "- [ ] a‸", (m, s) => E.planToggleTask(m, E.unitAt(m, s.head, "left")), "- [x] a");
    check("delete all", "«# T\n\npara\n\n```\ncode\n```»", del, "‸");
    check("delete through whole code block", "a«b\n\n```\ncode\n```»\n\nnext", del, "a‸\n\nnext");
    check("delete from code start into text", "```\nco«de\n```\n\nte»xt", del, "```\nco‸\n```\n\nxt");
    check("table row above first", "| a | b |\n| --- | --- |\n| c‸ | d |", (m, s) => E.planTable(m, E.unitAt(m, s.head, "left"), "rowAbove"), "| a | b |\n| --- | --- |\n| ‸ |  |\n| c | d |");
    check("table row below header", "| a‸ | b |\n| --- | --- |\n| c | d |", (m, s) => E.planTable(m, E.unitAt(m, s.head, "left"), "rowBelow"), "| a | b |\n| --- | --- |\n| ‸ |  |\n| c | d |");
    check("table delete row", "| a | b |\n| --- | --- |\n| c | d |\n| e‸ | f |", (m, s) => E.planTable(m, E.unitAt(m, s.head, "left"), "deleteRow"), "| a | b |\n| --- | --- |\n| c | d |‸");
    return JSON.stringify({ passed, failures });
    })()
    """#
}
