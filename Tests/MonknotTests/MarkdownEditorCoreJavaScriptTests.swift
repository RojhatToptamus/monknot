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
        XCTAssertGreaterThanOrEqual(result?["passed"] as? Int ?? 0, 190)
    }

    /// HTML pasted from other apps becomes Markdown that reads back as the same blocks: a code
    /// block's fence and a code span's backticks are longer than any run inside them, and a list
    /// nested under an item is indented as far as that item's marker is wide.
    func testPastedHTMLBecomesMarkdown() throws {
        let context = try editorContext()
        let output = try XCTUnwrap(context.evaluateScript(Self.paste)?.toString())
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        let failures = result?["failures"] as? [String] ?? ["no result"]
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
        XCTAssertEqual(result?["passed"] as? Int, 7)
    }

    /// Random documents and random patches, including CRLF line endings: after every patch the
    /// incrementally updated document must equal a fresh parse of the new text.
    /// Toggles, callouts and `[TOC]` lines are among the snippets, so a typed `</details>` far below
    /// its `<details>` is covered too. Toggles opened or closed on the page keep that state wherever
    /// a toggle still starts at the same place, footnotes and references match a fresh parse, and
    /// every new unit gets an id no unit had before.
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
      const snippets = ["<details>\n<summary>T</summary>\n\nbody [^n]\n\n</details>", "> [!NOTE]", "> [!TIP]", "<details>", "<details open>", "<summary>Title</summary>", "<summary></summary>", "</details>", "[TOC]", "![v](a.mp4)", "# Title", "## Sub", "para text", "more *em* and **bold**", "- item", "- [ ] task", "1. one", "  - nested", "> quote", "> > deep", "```js", "```", "code line", "| a | b |", "| --- | --- |", "| 1 | 2 |", "---", "[ref]: http://x", "[^n]: note", "see [^n] and [l][ref]", "", "", "text with [link](u) end", "~~del~~", "`code`", "line  ", "next"];
      // Every node at every depth and every unit, with each offset where it is now: an edit inside a
      // container moves the nodes after it by their own shifts, so those have to add up.
      const describe = (model) => {
        const out = [];
        const where = (node, offset) => offset + E.nodeShift(node);
        const walk = (node, depth) => {
          if (!node.type) {
            out.push([depth, "item", where(node, node.view.start), where(node, node.markerStart), where(node, node.contentStart), where(node, node.end), E.itemSubtreeEnd(node), node.view.line + E.nodeLineShift(node), node.task ? node.task.checked : "-"].join("|"));
          } else {
            // An empty line with no line of its own (in an empty toggle or callout) has no line number.
            const fields = [depth, node.type, E.bStart(node), E.bEnd(node), node.type === "empty" && !node.view ? "-" : E.bLine(node)];
            if (node.type === "toggle") fields.push(node.open, where(node, node.summaryStart), where(node, node.summaryEnd), where(node, node.summaryView.end), node.close ? [where(node, node.close.start), where(node, node.close.end), node.close.line + E.nodeLineShift(node)].join(",") : "-");
            if (node.type === "quote") fields.push(node.callout ? node.callout.kind : "-");
            if (node.type === "list") fields.push(node.ordered, node.startNumber);
            if (node.type === "empty") fields.push(node.position, node.needsSeparatorBefore, node.needsSeparatorAfter, where(node, node.anchor), Boolean(node.virtual));
            if (node.type === "heading") fields.push(where(node, node.contentStart), where(node, node.contentEnd));
            out.push(fields.join("|"));
          }
          for (const child of E.childNodes(node)) {
            if (child.parent !== node) out.push("parent differs");
            walk(child, depth + 1);
          }
        };
        model.blocks.forEach((block) => {
          if (block.parent) out.push("top-level parent");
          walk(block, 0);
        });
        out.push("--");
        const tops = new Map(model.blocks.map((block, index) => [block, index]));
        for (const unit of E.allUnits(model)) {
          const length = unit.region.j.length;
          const map = [0, 1, length >> 1, length - 1, length].filter((j) => j >= 0 && j <= length).map((j) => E.rawOf(unit, j));
          const container = unit.container ? unit.container.type + "@" + E.bStart(unit.container) : "-";
          const scope = unit.scope ? E.bStart(unit.scope) : "-";
          out.push([unit.kind, unit.role, unit.region.j, map.join(","), tops.get(unit.top), container, scope].join("|"));
        }
        out.push("--", JSON.stringify([[...model.doc.footnotes], [...model.doc.references], model.doc.footnoteOrder]));
        return out.join("\n");
      };
      const unitAtByScan = (model, raw, side) => {
        const blocks = model.blocks;
        if (blocks.length === 0) return null;
        const firstFrom = (index) => {
          for (let position = Math.max(0, index); position < blocks.length; position += 1) if (blocks[position].units.length) return blocks[position].units[0];
          return null;
        };
        const lastUpTo = (index) => {
          for (let position = Math.min(index, blocks.length - 1); position >= 0; position -= 1) {
            const list = blocks[position].units;
            if (list.length) return list[list.length - 1];
          }
          return null;
        };
        let index = -1;
        blocks.forEach((block, position) => { if (E.bStart(block) <= raw) index = position; });
        if (index < 0) return firstFrom(0);
        const block = blocks[index];
        if (raw > E.bEnd(block)) return side === "left" ? lastUpTo(index) || firstFrom(index + 1) : firstFrom(index + 1) || lastUpTo(index);
        if (block.units.length === 0) return side === "left" ? lastUpTo(index - 1) || firstFrom(index + 1) : firstFrom(index + 1) || lastUpTo(index - 1);
        let before = null;
        let after = null;
        const inside = [];
        for (const unit of block.units) {
          const start = E.unitStart(unit);
          const end = E.unitEnd(unit);
          if (start <= raw && raw <= end) inside.push(unit);
          else if (end < raw) before = unit;
          else if (!after && start > raw) after = unit;
        }
        if (inside.length === 1) return inside[0];
        if (inside.length > 1) return side === "left" ? inside[0] : inside[inside.length - 1];
        return side === "left" ? before || after : after || before;
      };
      // What every planner makes of a caret or selection at `raw`: an edited model, whose nodes have
      // shifts of their own, has to plan the same patches as a fresh parse of its text.
      const plans = (model, raw, to) => {
        const unit = E.unitAt(model, raw, "left");
        const caret = { anchor: raw, head: raw, from: raw, to: raw };
        const range = { anchor: raw, head: to, from: raw, to };
        const out = [];
        const add = (name, run) => {
          let result;
          try { result = run(); } catch (error) { result = "threw " + error.message; }
          out.push(name + " " + JSON.stringify(result, (key, value) => {
            if (typeof value === "function") return "fn";
            if (value && typeof value === "object" && "region" in value && "kind" in value) return "unit at " + E.unitStart(value);
            return ["top", "list", "item", "block", "table", "row", "container", "scope", "parent"].includes(key) ? undefined : value;
          }));
        };
        add("unit", () => unit && [unit.kind, unit.role, E.unitStart(unit), E.unitEnd(unit)]);
        add("type", () => E.planInsertText(model, caret, "x", { typing: true }));
        add("replace", () => E.planInsertText(model, range, "y"));
        add("delete", () => E.planDelete(model, raw, to));
        add("enter", () => E.planEnter(model, caret));
        add("exit", () => E.planEnter(model, caret, { exitBlock: true }));
        add("break", () => E.planLineBreak(model, caret));
        add("indent", () => E.planIndent(model, range, 1));
        add("outdent", () => E.planIndent(model, range, -1));
        add("heading", () => E.planBlockType(model, range, "heading2", { toggle: true }));
        add("todo", () => E.planBlockType(model, range, "todo", { toggle: true }));
        add("bold", () => E.planInlineStyle(model, range, "strong"));
        add("toggle", () => E.planWrapToggle(model, caret));
        add("callout", () => E.planWrapCallout(model, caret));
        add("markdown", () => E.balancedMarkdown(model, raw, to));
        if (unit) {
          add("backspace", () => E.planBackspaceAtStart(model, unit));
          add("forward", () => E.planDeleteForwardAtEnd(model, unit));
          add("task", () => E.planToggleTask(model, unit));
          add("kind", () => E.planCalloutKind(model, unit, "tip"));
          add("unquote", () => E.planUnwrapQuote(model, unit, caret));
          for (const action of ["rowBelow", "deleteRow", "columnRight", "deleteColumn"]) add(action, () => E.planTable(model, unit, action));
          const target = E.handleTargetOf(model, unit);
          add("target", () => target && [target.kind, target.index]);
          add("move", () => E.planMoveByStep(model, target, 1, caret));
          add("moveUp", () => E.planMoveByStep(model, target, -1, caret));
          add("duplicate", () => E.planDuplicateBlock(model, target));
          add("remove", () => E.planDeleteBlock(model, target));
          add("copy", () => E.blockMarkdown(model, target));
          add("selectBlock", () => E.targetSelection(model, target));
          add("itemBelow", () => target && target.kind === "item" ? E.insertItemNear(model, target, false) : null);
          add("itemAbove", () => target && target.kind === "item" ? E.insertItemNear(model, target, true) : null);
        }
        return out.join("\n");
      };
      const toggles = (model) => {
        const list = [];
        const walk = (block) => {
          if (block.type === "toggle") list.push({ block, start: E.bStart(block) });
          for (const child of block.children || []) walk(child);
        };
        model.blocks.forEach(walk);
        return list;
      };
      // Documents of nested toggles, quotes, callouts and lists, where most edits land inside a container.
      const leaf = () => pick(["para text", "more *em* and **bold**", "## Sub", "- item", "- [ ] task", "1. one", "```\ncode\n```", "| a | b |\n| --- | --- |\n| 1 | 2 |", "---", "[TOC]", "text [^n] end", ""]);
      const inner = (depth) => {
        const roll = random();
        if (depth > 2 || roll < 0.35) return leaf();
        if (roll < 0.5) return "<details" + (random() < 0.5 ? " open" : "") + ">\n<summary>T" + depth + "</summary>\n\n" + body(depth + 1) + "\n\n</details>";
        if (roll < 0.65) return (random() < 0.4 ? "[!NOTE]\n" : "") + body(depth + 1);
        if (roll < 0.85) {
          const items = [];
          const count = 1 + Math.floor(random() * 6);
          for (let index = 0; index < count; index += 1) items.push(pick(["- ", "- ", "- [ ] ", "- [x] "]) + "item " + index + (random() < 0.2 ? "\n  wrapped" : "") + (random() < 0.3 ? "\n  - nested " + index + (random() < 0.3 ? "\n    - deeper" : "") : ""));
          return items.join("\n");
        }
        const items = [];
        const count = 1 + Math.floor(random() * 4);
        for (let index = 0; index < count; index += 1) items.push((index + 1) + ". step " + index);
        return items.join("\n");
      };
      const quoted = (text) => text.split("\n").map((line) => (line ? "> " + line : ">")).join("\n");
      const body = (depth) => {
        const parts = [];
        const count = 1 + Math.floor(random() * 5);
        for (let index = 0; index < count; index += 1) {
          const part = inner(depth);
          parts.push(random() < 0.25 && depth < 3 ? quoted(part) : part);
        }
        return parts.join(random() < 0.8 ? "\n\n" : "\n");
      };
      const inserts = ["<details>\n", "<summary>S</summary>\n", "</details>", "> [!NOTE]\n", "[TOC]\n", "x", "x", "x", "ab", " ", "\n", "\n\n", "\n> ", "\n- ", "\n  - ", "# ", "- ", "  ", "**", "`", "```", "> ", "|", "[ ] ", "1. ", "[a](b)", "[^n]"];
      let steps = 0;
      let inside = 0;
      let nested = 0;
      const check = (run, step, model, text, expectedOpen, unitsBefore, lastId, patch) => {
        if (model.source !== text) return "source differs at run " + run;
        const parsed = E.createModel(text);
        const incremental = describe(model);
        const full = describe(parsed);
        if (incremental !== full) {
          const a = incremental.split("\n");
          const b = full.split("\n");
          let line = 0;
          while (line < a.length && a[line] === b[line]) line += 1;
          return "run " + run + " step " + step + " differs for " + JSON.stringify(text) + " after " + JSON.stringify(patch) + " at line " + line + ":\n" + a[line] + "\n" + b[line];
        }
        for (const toggle of toggles(model)) {
          if (toggle.block.viewOpen !== expectedOpen.get(toggle.start)) return "run " + run + " step " + step + " toggle at " + toggle.start + " is " + toggle.block.viewOpen + " in " + JSON.stringify(text);
        }
        const units = E.allUnits(model);
        if (model.units.size !== units.length || units.some((unit) => model.units.get(unit.id) !== unit)) return "run " + run + " step " + step + " unit map differs";
        // Toggles opened or closed on the page plan as they show, and new lines keep the line ending
        // the document had when it opened.
        parsed.eol = model.eol;
        const states = new Map(toggles(model).map((toggle) => [toggle.start, toggle.block.viewOpen]));
        for (const toggle of toggles(parsed)) toggle.block.viewOpen = states.get(toggle.start);
        if (run >= 1000) {
          const raw = Math.floor(random() * (text.length + 1));
          const to = Math.min(text.length, raw + Math.floor(random() * 8));
          const edited = plans(model, raw, to);
          const fresh = plans(parsed, raw, to);
          if (edited !== fresh) {
            const a = edited.split("\n");
            const b = fresh.split("\n");
            let line = 0;
            while (line < a.length && a[line] === b[line]) line += 1;
            return "run " + run + " step " + step + " plans differently at " + raw + "-" + to + " in " + JSON.stringify(text) + ":\n" + a[line] + "\n" + b[line];
          }
        }
        // unitAt searches a block's units by halves; it finds what looking at each of them finds.
        for (let probe = 0; probe < 2; probe += 1) {
          const raw = Math.floor(random() * (text.length + 1));
          for (const side of ["left", "right"]) {
            if (E.unitAt(model, raw, side) !== unitAtByScan(model, raw, side)) return "run " + run + " step " + step + " unitAt " + raw + " " + side + " differs in " + JSON.stringify(text);
          }
        }
        if (units.some((unit) => !unitsBefore.has(unit) && unit.id <= lastId)) return "run " + run + " step " + step + " reuses a unit id";
        return null;
      };
      for (let run = 0; run < 2000; run += 1) {
        let text;
        if (run < 1000) {
          const lines = [];
          const count = 3 + Math.floor(random() * 20);
          for (let index = 0; index < count; index += 1) lines.push(pick(snippets));
          text = lines.join("\n");
        } else {
          text = body(0);
        }
        if (random() < 0.15) text = text.replace(/\n/g, "\r\n");
        if (random() < 0.5) text += random() < 0.15 && text.indexOf("\r") >= 0 ? "\r\n" : "\n";
        const model = E.createModel(text);
        for (let step = 0; step < 6; step += 1) {
          const from = Math.floor(random() * (text.length + 1));
          const to = Math.min(text.length, from + (random() < 0.6 ? 0 : Math.floor(random() * 12)));
          const insert = random() < 0.25 ? "" : run < 1000 ? pick(["<details>\n", "<summary>S</summary>\n", "</details>", "> [!NOTE]\n", "[TOC]\n", "x", "\n", "\n\n", "# ", "- ", "**", "`", "```", "> ", "|", " ", "[a](b)", pick(snippets) + "\n"]) : pick(inserts);
          // Open or close some toggles, as a click on the page does; the state should follow each
          // toggle that still starts where it did, moved by the patch.
          const expectedOpen = new Map();
          for (const toggle of toggles(model)) {
            if (random() < 0.3) toggle.block.viewOpen = random() < 0.5;
            if (toggle.block.viewOpen === undefined) continue;
            if (toggle.start < from) expectedOpen.set(toggle.start, toggle.block.viewOpen);
            else if (toggle.start >= to) expectedOpen.set(toggle.start + insert.length - (to - from), toggle.block.viewOpen);
          }
          const unitsBefore = new Set(E.allUnits(model));
          const lastId = Math.max(0, ...[...unitsBefore].map((unit) => unit.id));
          const patch = [text, from, to, insert];
          text = text.slice(0, from) + insert + text.slice(to);
          const update = E.applyPatch(model, from, to, insert);
          if (run >= 1000) {
            steps += 1;
            if (update.container) inside += 1;
            if (update.container && update.container !== update.top) nested += 1;
          }
          const failure = check(run, step, model, text, expectedOpen, unitsBefore, lastId, patch);
          if (failure) return failure;
        }
        // A page drawn whole draws again the blocks an edit inside re-rendered in parts: the same
        // markup as a fresh render, aside from unit ids, toggles' open state, line numbers, which
        // blocks after an edit keep (the page reads lines from the model), and tables of contents,
        // which the page draws again as headings change.
        E.redrawStaleBlocks(model);
        const markup = (blocks) => {
          const ids = new Map();
          return blocks.map((block) => block.html).join("")
            .replace(/<nav[^>]* class="toc[^"]*"[^>]*>[\s\S]*?<\/nav>/g, "<nav>")
            .replace(/ data-open="\w+"| aria-expanded="\w+"| aria-label="(?:Collapse|Expand)"| data-source-line="\d+"/g, "")
            .replace(/data-mk-u="(\d+)"/g, (match, id) => {
              if (!ids.has(id)) ids.set(id, ids.size);
              return `data-mk-u="${ids.get(id)}"`;
            });
        };
        const fresh = E.createModel(text);
        if (markup(model.blocks) !== markup(fresh.blocks)) return "run " + run + " draws differently whole for " + JSON.stringify(text);
        if (describe(model) !== describe(fresh)) return "run " + run + " differs once drawn whole for " + JSON.stringify(text);
      }
      // Most edits in the documents of containers have to stay inside one, some of them deep.
      if (inside < steps * 0.25 || nested < steps * 0.05) return "too few edits re-parsed inside a container: " + inside + " of " + steps + ", " + nested + " nested";
      return "ok";
    })()
    """#

    private static let paste = #"""
    (() => {
    (() => {
      // A small stand-in for WebKit's DOMParser: elements, text and the selectors the converter uses.
      const VOID = new Set(["BR", "HR", "INPUT", "IMG", "META"]);
      const decode = (text) => text.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&amp;/g, "&");
      function element(tagName, attributes) {
        return {
          nodeType: 1, tagName, attributes, childNodes: [],
          get children() { return this.childNodes.filter((node) => node.nodeType === 1); },
          get className() { return attributes.class || ""; },
          get checked() { return "checked" in attributes; },
          get textContent() { return this.childNodes.map((node) => (node.nodeType === 3 ? node.nodeValue : node.textContent)).join(""); },
          getAttribute(name) { return name in attributes ? attributes[name] : null; },
          querySelectorAll(selector) {
            if (selector === ":scope > input[type=checkbox]") return this.children.filter((node) => node.tagName === "INPUT" && node.attributes.type === "checkbox");
            const found = [];
            const walk = (node) => node.children.forEach((child) => { if (child.tagName === selector.toUpperCase()) found.push(child); walk(child); });
            walk(this);
            return found;
          },
          querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
        };
      }
      globalThis.DOMParser = function () {};
      globalThis.DOMParser.prototype.parseFromString = (html) => {
        const body = element("BODY", {});
        const stack = [body];
        for (const match of html.matchAll(/<(\/?)([a-zA-Z0-9]+)([^>]*)>|([^<]+)/g)) {
          const parent = stack[stack.length - 1];
          if (match[4] !== undefined) { parent.childNodes.push({ nodeType: 3, nodeValue: decode(match[4]) }); continue; }
          const tag = match[2].toUpperCase();
          if (match[1]) { if (stack.length > 1) stack.pop(); continue; }
          const attributes = {};
          for (const attribute of match[3].matchAll(/([a-zA-Z-]+)(?:="([^"]*)")?/g)) attributes[attribute[1]] = attribute[2] ?? "";
          const node = element(tag, attributes);
          parent.childNodes.push(node);
          if (!VOID.has(tag)) stack.push(node);
        }
        return { body };
      };
    })();
    const E = window.MonknotEditorCore;
    const failures = [];
    let passed = 0;
    const check = (name, html, expected) => {
      const got = E.htmlToMarkdown(html);
      if (got === expected) passed += 1;
      else failures.push(name + ": got " + JSON.stringify(got) + ", expected " + JSON.stringify(expected));
    };
    check("paragraphs", "<p>One <b>bold</b></p><p>Two</p>", "One **bold**\n\nTwo");
    check("code block with a fence inside", "<pre><code class=\"language-md\">a\n```\nb\n</code></pre>", "````md\na\n```\nb\n````");
    check("inline code with a backtick", "<p>use <code>a`b</code> here</p>", "use ``a`b`` here");
    check("inline code starting with a backtick", "<p><code>`x</code></p>", "`` `x ``");
    check("list nested under a numbered item", "<ol><li>a<ul><li>b</li></ul></li><li>c</li></ol>", "1. a\n   - b\n2. c");
    check("list nested under a bullet", "<ul><li>a<ol start=\"9\"><li>b</li><li>c<ul><li>d</li></ul></li></ol></li></ul>", "- a\n  9. b\n  10. c\n      - d");
    check("tasks", "<ul><li><input type=\"checkbox\" checked>done</li><li><input type=\"checkbox\">todo</li></ul>", "- [x] done\n- [ ] todo");
    return JSON.stringify({ passed, failures });
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
    // A last line with no line break is no line: the empty line gets one, or the next text would join the item.
    check("enter empty last item", "- one\n- ‸", enter, "- one\n‸\n");
    check("enter empty last item before a line break", "- one\n- ‸\n", enter, "- one\n‸\n");
    check("enter empty nested outdents", "- one\n  - ‸", enter, "- one\n- ‸");
    check("enter quote middle", "> ab‸cd", enter, "> ab\n>\n> ‸cd");
    check("enter quote end", "> abcd‸", enter, "> abcd\n>\n>‸");
    check("enter code", "```\nfoo‸\n```", enter, "```\nfoo\n‸\n```");
    check("enter code indent", "```\n  foo‸\n```", enter, "```\n  foo\n  ‸\n```");
    check("enter fence paragraph", "```js‸", enter, "```js\n‸\n```");
    check("backspace heading", "# ‸Title", backspaceAtStart, "‸Title");
    check("backspace join", "a\n\n‸b", backspaceAtStart, "a‸b");
    check("backspace item", "- ‸a", backspaceAtStart, "‸a");
    // Text taken out of a list stands apart from it, or Markdown would read it as more of the item above.
    check("backspace first item", "- ‸a\n- b", backspaceAtStart, "‸a\n\n- b");
    check("backspace middle item", "- a\n- ‸b\n- c", backspaceAtStart, "- a\n\n‸b\n\n- c");
    check("backspace last item", "- a\n- ‸b\n", backspaceAtStart, "- a\n\n‸b\n");
    check("backspace middle task", "- [ ] a\n- [ ] ‸b\n- [x] c\n", backspaceAtStart, "- [ ] a\n\n‸b\n\n- [x] c\n");
    check("backspace middle ordered", "1. a\n2. ‸b\n3. c", backspaceAtStart, "1. a\n\n‸b\n\n3. c");
    check("backspace item after paragraph", "Intro\n- ‸a", backspaceAtStart, "Intro\n\n‸a");
    check("backspace item with children", "- ‸a\n  - b", backspaceAtStart, "‸a\n\n  - b");
    check("backspace nested item outdents", "- [ ] a\n  - [ ] ‸b\n- [ ] c", backspaceAtStart, "- [ ] a\n- [ ] ‸b\n- [ ] c");
    check("backspace item in quote", "> - a\n> - ‸b", backspaceAtStart, "> - a\n>\n> ‸b");
    check("backspace item crlf", "- a\r\n- ‸b\r\n- c", backspaceAtStart, "- a\r\n\r\n‸b\r\n\r\n- c");
    check("item to text", "- a\n- ‸b\n- c", block("paragraph"), "- a\n\n‸b\n\n- c");
    check("items to text", "- «a\n- b»\n- c", block("paragraph"), "«a\n\nb»\n\n- c");
    check("heading to text", "a\n# ‸H\nb", block("paragraph"), "a\n\n‸H\n\nb");
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
    check("indent numbered item starts its sub-list at 1", "1. a\n2. ‸b\n3. c", (m, s) => E.planIndent(m, s, 1), "1. a\n   1. ‸b\n3. c");
    check("indent numbered item into a sub-list", "1. a\n   1. x\n2. ‸b", (m, s) => E.planIndent(m, s, 1), "1. a\n   1. x\n   2. ‸b");
    check("indent two items keeps the selection on them", "1. a\n2. «b\n3. c»", (m, s) => E.planIndent(m, s, 1), "1. a\n   1. «b\n   3. c»");
    check("outdent two items keeps the selection on them", "- a\n  - «b\n  - c»", (m, s) => E.planIndent(m, s, -1), "- a\n- «b\n- c»");
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
    // Toggles, callouts and the table of contents.
    const delFwd = (m, s) => E.planDeleteForwardAtEnd(m, E.unitAt(m, s.head, "left"));
    check("toggle enter open", "<details open>\n<summary>Title‸</summary>\n\nBody\n\n</details>", enter, "<details open>\n<summary>Title</summary>\n\n‸\nBody\n\n</details>");
    check("toggle enter open no blank", "<details open>\n<summary>Title‸</summary>\nBody\n</details>", enter, "<details open>\n<summary>Title</summary>\n\n‸\nBody\n</details>");
    check("toggle enter closed", "<details>\n<summary>Title‸</summary>\n\nBody\n\n</details>", enter, "<details>\n<summary>Title</summary>\n\nBody\n\n</details>\n‸\n");
    check("toggle enter into virtual", "<details open>\n<summary>T‸</summary>\n</details>", enter, "<details open>\n<summary>T</summary>‸\n</details>");
    check("toggle type into virtual", "<details open>\n<summary>T</summary>‸\n</details>", type("x"), "<details open>\n<summary>T</summary>\n\nx‸\n\n</details>");
    check("toggle type into blank body", "<details open>\n<summary>T</summary>\n‸\n</details>", type("x"), "<details open>\n<summary>T</summary>\n\nx‸\n\n</details>");
    check("toggle leave", "<details open>\n<summary>T</summary>\n\nBody\n\n‸\n</details>", enter, "<details open>\n<summary>T</summary>\n\nBody\n\n</details>\n‸\n");
    check("toggle leave before text", "<details open>\n<summary>T</summary>\n\nBody\n\n‸\n</details>\n\nAfter", enter, "<details open>\n<summary>T</summary>\n\nBody\n\n</details>\n\n‸\nAfter");
    check("toggle enter body end", "<details open>\n<summary>T</summary>\n\nBody‸\n\n</details>", enter, "<details open>\n<summary>T</summary>\n\nBody\n\n‸\n</details>");
    check("toggle unwrap", "<details>\n<summary>‸Title</summary>\n\nBody\n\n</details>", backspaceAtStart, "‸Title\n\nBody");
    check("toggle unwrap empty", "<details>\n<summary>‸Title</summary>\n</details>", backspaceAtStart, "‸Title");
    check("toggle backspace body start", "<details open>\n<summary>Title</summary>\n\n‸Body\n\n</details>", backspaceAtStart, "<details open>\n<summary>Title‸</summary>\n\nBody\n\n</details>");
    check("toggle delete fwd summary", "<details open>\n<summary>Title‸</summary>\n\nBody\n\n</details>", delFwd, "(no-op)");
    check("toggle delete fwd last body", "<details open>\n<summary>T</summary>\n\nBody‸\n\n</details>\n\nAfter", delFwd, "(no-op)");
    check("before toggle delete fwd", "Para‸\n\n<details>\n<summary>T</summary>\n</details>", delFwd, "(no-op)");
    check("after toggle backspace closed", "<details>\n<summary>T</summary>\n\nBody\n\n</details>\n\n‸After", backspaceAtStart, "<details>\n<summary>T‸</summary>\n\nBody\n\n</details>\n\nAfter");
    check("toggle select delete", "<details open>\n<summary>Ti«tle</summary>\n\nBo»dy\n\n</details>", del, "<details open>\n<summary>Ti‸</summary>\n\ndy\n\n</details>");
    check("unclosed toggle", "<details open>\n<summary>T</summary>\n\nBody‸", type("x"), "<details open>\n<summary>T</summary>\n\nBodyx‸");
    check("callout type virtual", "> [!NOTE]‸", type("x"), "> [!NOTE]\n> x‸");
    check("callout enter after text", "> [!NOTE]\n> Hi‸", enter, "> [!NOTE]\n> Hi\n>\n>‸");
    check("callout backspace first", "> [!TIP]\n> ‸Hello", backspaceAtStart, "> ‸Hello");
    check("callout backspace virtual", "> [!NOTE]‸", backspaceAtStart, "> ‸");
    check("toc backspace", "[TOC]\n\n‸Text", backspaceAtStart, "‸Text");
    check("toc delete fwd", "Text‸\n\n[TOC]\n\nMore", delFwd, "Text‸\n\nMore");
    // What the block handles and menus do.
    const target = (m, s) => E.handleTargetOf(m, E.unitAt(m, s.head, "left"));
    const move = (gap) => (m, s) => E.planMoveBlock(m, target(m, s), gap, s);
    const step = (d) => (m, s) => E.planMoveByStep(m, target(m, s), d, s);
    const dup = (m, s) => E.planDuplicateBlock(m, target(m, s));
    const delBlock = (m, s) => E.planDeleteBlock(m, target(m, s));
    const wrapToggle = (m, s) => E.planWrapToggle(m, s);
    const wrapCallout = (m, s) => E.planWrapCallout(m, s);
    const unquote = (m, s) => E.planUnwrapQuote(m, E.unitAt(m, s.head, "left"), s);
    const slash = (cmd) => (m, s) => { const u = E.unitAt(m, s.head, "left"); return E.planSlashCommand(m, u, s.head - 1, s.head, cmd); };
    check("move first to end", "A‸\n\nB\n\nC", move(3), "B\n\nC\n\nA‸");
    check("move last to start", "A\n\nB\n\nC‸", move(0), "C‸\n\nA\n\nB");
    check("move middle up", "A\n\nB‸\n\nC", move(0), "B‸\n\nA\n\nC");
    check("move no-op", "A\n\nB‸\n\nC", move(1), "(no-op)");
    check("move trailing newline", "A\n\nB‸\n", move(0), "B‸\n\nA\n");
    check("move heading adjacent", "# H\nPara‸\n\nEnd", move(0), "Para‸\n\n# H\n\nEnd");
    check("move keeps empty", "A‸\n\nB\n\n\nC", move(4), "B\n\n\nC\n\nA‸");
    check("step up", "A\n\nB‸", step(-1), "B‸\n\nA");
    check("step down", "A‸\n\nB", step(1), "B\n\nA‸");
    check("step top no-op", "A‸\n\nB", step(-1), "(no-op)");
    check("move item down", "- a‸\n- b\n- c", move(2), "- b\n- a‸\n- c");
    check("move item to end", "- a‸\n- b\n- c", move(3), "- b\n- c\n- a‸");
    check("move item with child", "- a‸\n  - x\n- b", move(2), "- b\n- a‸\n  - x");
    check("move ordered keeps numbers", "1. a\n2. b‸\n3. c", move(0), "1. b‸\n2. a\n3. c");
    check("step item up", "- a\n- b‸", step(-1), "- b‸\n- a");
    check("remove list under para", "Para\n- x‸\n\nNext", delBlock, "Para‸\n\nNext");
    check("move toggle", "<details>\n<summary>T‸</summary>\n\nBody\n\n</details>\n\nAfter", move(2), "After\n\n<details>\n<summary>T‸</summary>\n\nBody\n\n</details>");
    check("dup block", "A‸\n\nB", dup, "A\n\nA‸\n\nB");
    check("dup item", "- a‸\n- b", dup, "- a\n- a‸\n- b");
    check("delete middle", "A\n\nB‸\n\nC", delBlock, "A‸\n\nC");
    check("delete last", "A\n\nB‸", delBlock, "A‸");
    check("delete item", "- a\n- b‸\n- c", delBlock, "- a‸\n- c");
    check("delete last item", "- a\n- b‸", delBlock, "- a‸");
    check("wrap toggle", "Hello‸", wrapToggle, "<details>\n<summary>Hello‸</summary>\n\n</details>");
    check("wrap toggle between", "A\n\nHello‸\n\nB", wrapToggle, "A\n\n<details>\n<summary>Hello‸</summary>\n\n</details>\n\nB");
    check("wrap toggle empty", "A\n\n‸", wrapToggle, "A\n\n<details>\n<summary>‸</summary>\n\n</details>\n");
    check("wrap callout", "Hello‸", wrapCallout, "> [!NOTE]\n> Hello‸");
    check("wrap callout empty", "A\n\n‸", wrapCallout, "A\n\n> [!NOTE]‸\n");
    check("wrap callout quote", "> Hel‸lo", wrapCallout, "> [!NOTE]\n> Hel‸lo");
    check("unwrap quote", "> a‸\n>\n> b", unquote, "a‸\n\nb");
    check("unwrap callout", "> [!TIP]\n> a‸", unquote, "a‸");
    check("slash toc", "A\n\n/‸", slash("toc"), "A\n\n[TOC]\n‸\n");
    check("item near after", "- a‸\n- b", (m, s) => E.insertItemNear(m, target(m, s), false), "- a\n- ‸\n- b");
    check("item near above", "- a\n- b‸", (m, s) => E.insertItemNear(m, target(m, s), true), "- a\n- ‸\n- b");
    check("empty before", "A\n\nB‸", (m, s) => E.insertEmptyBeforeBlock(m, 1), "A\n\n‸\nB");
    check("empty before first", "A‸", (m, s) => E.insertEmptyBeforeBlock(m, 0), "‸\nA");
    const slashQuery = (cmd) => (m, s) => E.planSlashCommand(m, E.unitAt(m, s.head, "left"), m.source.lastIndexOf("/", s.head), s.head, cmd);
    // Turn Into keeps blocks it cannot convert, and never touches a toggle's title.
    check("bullets keep a code block between", "«a\n\n```\ncode\n```\n\nb»", block("bullet"), "- «a\n\n```\ncode\n```\n\n- b»");
    check("text keeps a divider between", "«# a\n\n---\n\n# b»", block("paragraph"), "«a\n\n---\n\nb»");
    check("quote keeps a table between", "«a\n\n| x |\n| --- |\n| 1 |\n\nb»", block("quote"), "> «a\n\n| x |\n| --- |\n| 1 |\n\n> b»");
    check("code keeps a table between", "«a\n\n| x |\n| --- |\n| 1 |\n\nb»", block("code"), "```\na\n```\n\n| x |\n| --- |\n| 1 |\n\n```\nb‸\n```");
    check("heading in a toggle title does nothing", "<details>\n<summary>Ti‸tle</summary>\n\nBody\n\n</details>", block("heading1"), "(no-op)");
    check("text in a toggle title does nothing", "<details>\n<summary>Ti‸tle</summary>\n\nBody\n\n</details>", block("paragraph"), "(no-op)");
    check("bullets from a toggle title into its body", "<details open>\n<summary>T«itle</summary>\n\nBo»dy\n\n</details>", block("bullet"), "<details open>\n<summary>Title</summary>\n\n- Bo‸dy\n\n</details>");
    check("callout in a toggle title does nothing", "<details>\n<summary>Ti‸tle</summary>\n\nBody\n\n</details>", (m, s) => E.planWrapCallout(m, s), "(no-op)");
    // A heading in a quote keeps one quote marker.
    check("quoted heading level", "> # Ti‸tle", block("heading2"), "> ## Ti‸tle");
    check("callout heading to text", "> [!NOTE]\n> # Ti‸tle", block("paragraph"), "> [!NOTE]\n>\n> Ti‸tle");
    check("quoted heading to code", "> # Ti‸tle", block("code"), "> ```\n> Title‸\n> ```");
    check("slash in a quoted heading", "> ## /h1‸", slashQuery("h1"), "> # ‸");
    check("quoted heading to toggle", "> # Ti‸tle", wrapToggle, "> <details>\n> <summary>Title‸</summary>\n>\n> </details>");
    check("callout text to toggle", "> [!NOTE]\n> Hel‸lo", wrapToggle, "> [!NOTE]\n>\n> <details>\n> <summary>Hello‸</summary>\n>\n> </details>");
    check("empty callout to toggle", "> [!NOTE]‸", wrapToggle, "> [!NOTE]\n> <details>\n> <summary>‸</summary>\n>\n> </details>");
    // ⌫ at the start of a heading or quote leaves a paragraph of its own.
    check("backspace heading between text", "a\n# ‸Title\nb", backspaceAtStart, "a\n\n‸Title\n\nb");
    check("backspace quote between text", "a\n> ‸Quote\nb", backspaceAtStart, "a\n\n‸Quote\n\nb");
    check("backspace heading in a quote", "> a\n> # ‸T", backspaceAtStart, "> a\n>\n> ‸T");
    // ⇧↩ breaks the line inside a paragraph; at its end there is no line to break onto.
    const lineBreak = (m, s) => E.planLineBreak(m, s);
    check("line break middle", "ab‸c", lineBreak, "ab\\\n‸c");
    check("line break end", "abc‸", lineBreak, "abc\n‸\n");
    check("line break before a soft break", "abc‸\ndef", lineBreak, "abc\\\n‸def");
    check("line break in a quote", "> ab‸c", lineBreak, "> ab\\\n> ‸c");
    check("line break end of first line in a quote", "> ab‸\n> cd", lineBreak, "> ab\\\n> ‸cd");
    // Slash commands change the block as Turn Into does.
    check("slash todo nested", "- a\n  - /todo‸", slashQuery("todo"), "- a\n  - [ ] ‸");
    check("slash numbered keeps the text", "Hello /num‸", (m, s) => E.planSlashCommand(m, E.unitAt(m, s.head, "left"), 6, 10, "numbered"), "1. Hello ‸");
    check("slash code empty heading", "## /code‸", slashQuery("code"), "```\n‸\n```");
    check("slash code empty item", "- /code‸", slashQuery("code"), "```\n‸\n```");
    check("slash table empty item", "- a\n- /table‸", slashQuery("table"), "- a\n\n| ‸ |  |  |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |");
    check("slash divider empty item", "- a\n- /divider‸\n- b", slashQuery("divider"), "- a\n\n---\n\n‸\n- b");
    // The caret goes on the code block's line in a quote, and a quote's first line needs no blank above.
    check("slash code first line of a quote", "> /code‸", slashQuery("code"), "> ```\n>‸\n> ```");
    check("slash code in a quote", "> a\n>\n> /code‸", slashQuery("code"), "> a\n>\n> ```\n>‸\n> ```");
    check("slash code after text in a quote", "> Hello /code‸", slashQuery("code"), "> Hello \n>\n> ```\n>‸\n> ```");
    // Links never nest; emphasis beside emphasis alternates its marker.
    check("link part of a link", "[a«b»c](u)", style("link", "v"), "[a](u)«[b](v)»[c](u)");
    check("bold beside bold", "**a**«b»", style("strong"), "**a**__«b»__");
    check("bold beside italic", "*a*«b»", style("strong"), "*a*__«b»__");
    check("bold before bold", "«a»**b**", style("strong"), "__«a»__**b**");
    // ⌦ at the end of a toggle's body never deletes the block after the toggle.
    check("delete forward in a toggle before a divider", "<details open>\n<summary>T</summary>\n\nBody‸\n\n</details>\n\n---\n\nAfter", delFwd, "(no-op)");
    // Numbers count per list level and start again after a block between.
    check("numbered per level", "- «a\n  - b\n- c»", block("numbered"), "1. «a\n  1. b\n2. c»");
    check("numbered after a code block", "«a\n\n```\nx\n```\n\nb»", block("numbered"), "1. «a\n\n```\nx\n```\n\n1. b»");
    // Indenting keeps each line's own line ending.
    check("indent keeps mixed line endings", "- a\r\n- b‸\n  - c", (m, s) => E.planIndent(m, s, 1), "- a\r\n  - b‸\n    - c");
    check("enter empty nested item outdents its children too", "- a\n  - ‸\n    - c", enter, "- a\n- ‸\n  - c");
    check("callout kind", "> [!NOTE]\n> Hi‸", (m, s) => E.planCalloutKind(m, E.unitAt(m, s.head, "left"), "tip"), "> [!TIP]\n> Hi");
    check("callout kind outside a callout", "> Hi‸", (m, s) => E.planCalloutKind(m, E.unitAt(m, s.head, "left"), "tip"), "(no-op)");

    // A toggle opened on the page stays open when an edit re-parses it, and when a changed link
    // reference renders the whole document again; unit ids keep counting up.
    function toggleAfter(source, after, insert) {
      const model = E.createModel(source);
      const toggle = model.blocks.find((b) => b.type === "toggle");
      toggle.viewOpen = true;
      const before = new Set(E.allUnits(model));
      const maxId = Math.max(...E.allUnits(model).map((u) => u.id));
      const at = source.indexOf(after) + after.length;
      const update = E.applyPatch(model, at, at, insert);
      const next = model.blocks.find((b) => b.type === "toggle");
      const fresh = E.allUnits(model).filter((u) => !before.has(u));
      return [update.full ? "full" : "partial", next === toggle ? "kept" : "parsed again", next.viewOpen ? "open" : "closed", fresh.every((u) => u.id > maxId) ? "ids count up" : "ids reused"].join(", ");
    }
    const toggleDoc = "Intro [x][ref]\n\n<details>\n<summary>T</summary>\n\nBody\n\n</details>\n\n[ref]: http://a\n\n[^n]: note";
    const expectEqual = (name, got, expected) => { if (got === expected) passed += 1; else failures.push(name + ": got " + JSON.stringify(got) + ", expected " + JSON.stringify(expected)); };
    // Typing in the body re-parses only the body's blocks; typing in the title parses the toggle again.
    expectEqual("toggle kept by an edit in its body", toggleAfter(toggleDoc, "Bo", "x"), "partial, kept, open, ids count up");
    expectEqual("toggle state across a re-parse", toggleAfter(toggleDoc, "<summary>T", "x"), "partial, parsed again, open, ids count up");
    expectEqual("toggle state across a rebuild", toggleAfter(toggleDoc, "http://a", "x"), "full, parsed again, open, ids count up");
    expectEqual("footnote text edits in place", toggleAfter(toggleDoc, "note", "x"), "partial, kept, open, ids count up");
    (() => {
      const model = E.createModel(toggleDoc);
      const at = toggleDoc.indexOf("note") + 2;
      E.applyPatch(model, at, at, "w");
      expectEqual("footnote text in the document", model.doc.footnotes.get("n"), "nowte");
    })();
    return JSON.stringify({ passed, failures });
    })()
    """#
}
