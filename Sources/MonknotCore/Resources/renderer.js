(() => {
  "use strict";

  // =====================================================================
  // Markdown core
  //
  // One parser serves the preview, PDF export and the visual editor. Every
  // block and inline node records where it sits in the source, so the editor
  // can turn a change on the rendered page into a text patch on the Markdown
  // itself instead of converting the page back into Markdown.
  // =====================================================================

  const TOKEN_BASE = 0xE000;
  const TOKEN_LAST = 0xF8FF;

  const RE_FENCE = /^ {0,3}(```+|~~~+)\s*([\w.+-]*)\s*$/;
  const RE_FENCE_CLOSE = /^ {0,3}(`+|~+)/;
  const RE_HEADING = /^( {0,3}(#{1,6})[ \t]+)(.*?)(?:[ \t]+#+)?[ \t]*$/;
  const RE_HEADING_START = /^ {0,3}#{1,6}\s+/;
  const RE_THEMATIC = /^ {0,3}([-*_])(?:\s*\1){2,}\s*$/;
  const RE_QUOTE = /^ {0,3}>\s?/;
  const RE_LIST_LINE = /^(\s*)([-+*]|\d+[.)])\s+/;
  const RE_ITEM = /^(\s*)([-+*]|\d+[.)])(\s+)(\[[ xX]\]\s+)?(.*)$/;
  const RE_FOOTNOTE_DEF = /^\[\^([^\]]+)\]:\s*(.*)$/;
  // Notion-style blocks that have a Markdown form: GitHub's alert callouts, HTML toggles and a
  // `[TOC]` line, as GitHub, Typora and Obsidian write them.
  const RE_CALLOUT = /^\[!(note|tip|important|warning|caution)\]\s*$/i;
  const RE_DETAILS_OPEN = /^ {0,3}<details(\s+open)?\s*>\s*$/i;
  const RE_DETAILS_CLOSE = /^ {0,3}<\/details>\s*$/i;
  const RE_SUMMARY = /^(\s*<summary>)(.*?)<\/summary>\s*$/i;
  const RE_TOC = /^ {0,3}\[toc\]\s*$/i;
  const RE_FENCE_MARKER = /^ {0,3}(`{3,}|~{3,})(.*)$/;
  const RE_VIDEO = /\.(mp4|m4v|mov|webm)(?:[?#].*)?$/i;
  const RE_AUDIO = /\.(mp3|m4a|aac|wav|aiff?|caf|flac|ogg|oga)(?:[?#].*)?$/i;
  const CALLOUT_TITLES = { note: "Note", tip: "Tip", important: "Important", warning: "Warning", caution: "Caution" };
  const RE_REFERENCE_DEF = /^ {0,3}\[([^\]\r\n]+)\]:[ \t]*(<[^>\r\n]+>|[^\s\r\n]+)(?:[ \t]+(?:"([^"\r\n]*)"|'([^'\r\n]*)'|\(([^)\r\n]*)\)))?[ \t]*$/;

  // ---------------------------------------------------------------------
  // Lines
  // ---------------------------------------------------------------------

  /// Reads source lines on demand from `offset`. A line view's `start`/`end`
  /// are source offsets of its text; `next` is where the following line starts.
  function streamReader(source, offset, lineNumber, hasCR) {
    const lines = [];
    let position = offset;
    let line = lineNumber;
    const length = source.length;
    return {
      at(index) {
        while (lines.length <= index) {
          if (position >= length) return null;
          const view = readLine(source, position, hasCR);
          view.line = line;
          lines.push(view);
          position = view.next;
          line += 1;
        }
        return lines[index];
      }
    };
  }

  function arrayReader(lines) {
    return { at: (index) => (index < lines.length ? lines[index] : null) };
  }

  function readLine(source, position, hasCR) {
    const length = source.length;
    let end = source.indexOf("\n", position);
    let next;
    if (end < 0) {
      end = length;
      next = length;
    } else {
      next = end + 1;
    }
    if (hasCR) {
      const cr = source.indexOf("\r", position);
      if (cr >= 0 && cr < end) {
        end = cr;
        next = source.charCodeAt(cr + 1) === 10 ? cr + 2 : cr + 1;
      }
    }
    return { text: source.slice(position, end), start: position, end, next, line: 0 };
  }

  function isBlank(text) {
    return /^\s*$/.test(text);
  }

  function openingFence(text) {
    const match = RE_FENCE.exec(text);
    if (!match) return null;
    return { marker: match[1][0], length: match[1].length, language: match[2] || "" };
  }

  function isFenceCloser(text, opening) {
    const match = RE_FENCE_CLOSE.exec(text);
    return Boolean(match && match[1][0] === opening.marker && match[1].length >= opening.length);
  }

  function isListLine(text) {
    return RE_LIST_LINE.test(text);
  }

  function splitTableRow(text) {
    let row = text.trim();
    if (row.startsWith("|")) row = row.slice(1);
    if (row.endsWith("|")) row = row.slice(0, -1);
    return row.split(/(?<!\\)\|/).map((cell) => cell.replace(/\\\|/g, "|"));
  }

  function isTableStart(reader, index) {
    const line = reader.at(index);
    const next = reader.at(index + 1);
    if (!line || !next) return false;
    if (!/\|/.test(line.text)) return false;
    // GitHub's rule: any run of hyphens, with optional colons, and as many cells as the header.
    const delimiter = splitTableRow(next.text);
    return delimiter.length === splitTableRow(line.text).length
      && delimiter.every((cell) => /^:?-+:?$/.test(cell.trim()));
  }

  function definitionOf(text) {
    const footnote = RE_FOOTNOTE_DEF.exec(text);
    if (footnote) {
      return {
        kind: "footnote",
        key: footnote[1].trim(),
        text: footnote[2],
        textOffset: text.length - footnote[2].length
      };
    }
    const reference = RE_REFERENCE_DEF.exec(text);
    if (reference && !reference[1].startsWith("^")) {
      let destination = reference[2];
      if (destination.startsWith("<") && destination.endsWith(">")) destination = destination.slice(1, -1);
      return {
        kind: "reference",
        key: normalizeReferenceLabel(reference[1]),
        destination,
        title: reference[3] ?? reference[4] ?? reference[5] ?? ""
      };
    }
    return null;
  }

  function isBlockStart(reader, index, context) {
    const line = reader.at(index);
    const text = line ? line.text : "";
    return /^ {0,3}(```+|~~~+)/.test(text)
      || RE_HEADING_START.test(text)
      || RE_THEMATIC.test(text)
      || RE_QUOTE.test(text)
      || isListLine(text)
      || isTableStart(reader, index)
      || RE_DETAILS_OPEN.test(text)
      || RE_TOC.test(text)
      || (context.definitions && definitionOf(text) !== null);
  }

  // ---------------------------------------------------------------------
  // Blocks
  // ---------------------------------------------------------------------

  /// Parses one block at `index` (a non-blank line). Returns the block and the
  /// index of the first line after it.
  function parseBlock(reader, index, context) {
    const line = reader.at(index);
    const text = line.text;

    if (context.definitions) {
      const definition = definitionOf(text);
      if (definition) {
        return {
          block: { type: "definition", definition, lines: [line], start: line.start, end: line.end, line: line.line },
          next: index + 1
        };
      }
    }

    const fence = openingFence(text);
    if (fence) {
      const body = [];
      let cursor = index + 1;
      let close = null;
      while (reader.at(cursor)) {
        const candidate = reader.at(cursor);
        if (isFenceCloser(candidate.text, fence)) {
          close = candidate;
          cursor += 1;
          break;
        }
        body.push(candidate);
        cursor += 1;
      }
      const last = close || body[body.length - 1] || line;
      return {
        block: { type: "code", fence, open: line, body, close, start: line.start, end: last.end, line: line.line },
        next: cursor
      };
    }

    if (RE_TOC.test(text)) {
      return {
        block: { type: "toc", view: line, start: line.start, end: line.end, line: line.line },
        next: index + 1
      };
    }

    const details = RE_DETAILS_OPEN.exec(text);
    if (details) {
      const toggle = parseToggle(reader, index, context, Boolean(details[1]));
      if (toggle) return toggle;
    }

    const heading = RE_HEADING.exec(text);
    if (heading) {
      const contentStart = line.start + heading[1].length;
      // While editing, spaces typed at the end of a heading are its text (Markdown drops them when it
      // renders, so the caret would not move past a space just typed); a closing `#` run still ends it.
      const rest = text.slice(heading[1].length);
      const contentLength = context.editing && !/[ \t]#+[ \t]*$/.test(rest) && rest !== "#" ? rest.length : heading[3].length;
      return {
        block: {
          type: "heading",
          level: heading[2].length,
          view: line,
          prefixEnd: contentStart,
          contentStart,
          contentEnd: contentStart + contentLength,
          start: line.start,
          end: line.end,
          line: line.line
        },
        next: index + 1
      };
    }

    if (RE_THEMATIC.test(text)) {
      return {
        block: { type: "hr", view: line, start: line.start, end: line.end, line: line.line },
        next: index + 1
      };
    }

    if (isTableStart(reader, index)) return parseTable(reader, index, context);

    if (RE_QUOTE.test(text)) {
      const lines = [];
      let cursor = index;
      while (reader.at(cursor) && (RE_QUOTE.test(reader.at(cursor).text) || isBlank(reader.at(cursor).text))) {
        const view = reader.at(cursor);
        // A blank line before another `> [!KIND]` line ends this quote: two callouts stay two.
        if (lines.length && isBlank(lines[lines.length - 1].text) && RE_QUOTE.test(view.text)
          && RE_CALLOUT.test(view.text.slice(RE_QUOTE.exec(view.text)[0].length))) break;
        lines.push(view);
        cursor += 1;
      }
      // Blank lines after the last quoted line separate the quote from what
      // follows; they are not part of it.
      while (lines.length > 1 && !RE_QUOTE.test(lines[lines.length - 1].text)) {
        lines.pop();
        cursor -= 1;
      }
      const inner = lines.map((view) => {
        const match = RE_QUOTE.exec(view.text);
        const prefix = match ? match[0].length : 0;
        return {
          text: view.text.slice(prefix),
          start: view.start + prefix,
          end: view.end,
          next: view.next,
          line: view.line,
          prefixStart: view.start
        };
      });
      // `> [!NOTE]` on the first line makes the quote a callout; the marker line is not text.
      const calloutMatch = RE_CALLOUT.exec(inner[0].text);
      let callout = null;
      let childLines = inner;
      if (calloutMatch) {
        const prefix = lines[0].text.slice(0, lines[0].text.length - inner[0].text.length);
        callout = { kind: calloutMatch[1].toLowerCase(), marker: inner[0], prefix };
        childLines = inner.slice(1);
      }
      const childContext = {
        ...context,
        definitions: false,
        top: false,
        separators: false,
        virtual: callout && childLines.length === 0
          ? { anchor: inner[0].end, before: "\n" + (/[ \t]$/.test(callout.prefix) ? callout.prefix : callout.prefix + " "), after: "" }
          : null
      };
      const children = parseBlockList(arrayReader(childLines), childContext, false).blocks;
      const last = lines[lines.length - 1];
      return {
        block: { type: "quote", lines, inner, children, callout, start: line.start, end: last.end, line: line.line },
        next: cursor
      };
    }

    if (isListLine(text)) {
      const parsed = parseList(reader, index, context);
      return { block: parsed.list, next: parsed.next };
    }

    const lines = [];
    let cursor = index;
    while (reader.at(cursor)
      && !isBlank(reader.at(cursor).text)
      && (cursor === index || !isBlockStart(reader, cursor, context))) {
      lines.push(reader.at(cursor));
      cursor += 1;
    }
    const last = lines[lines.length - 1];
    return {
      block: { type: "paragraph", lines, start: line.start, end: last.end, line: line.line },
      next: cursor
    };
  }

  /// `<details>`, a one-line `<summary>`, a body and `</details>`: a toggle. Anything else
  /// is left to the other rules, so unusual HTML stays text.
  function parseToggle(reader, index, context, isOpen) {
    const open = reader.at(index);
    const summaryView = reader.at(index + 1);
    if (!summaryView) return null;
    const summary = RE_SUMMARY.exec(summaryView.text);
    if (!summary) return null;
    let depth = 1;
    let cursor = index + 2;
    const body = [];
    let close = null;
    let fence = null;
    while (reader.at(cursor)) {
      const view = reader.at(cursor);
      const marker = RE_FENCE_MARKER.exec(view.text);
      if (fence) {
        if (marker && marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) fence = null;
      } else if (marker) {
        fence = marker[1];
      } else if (RE_DETAILS_OPEN.test(view.text)) {
        depth += 1;
      } else if (RE_DETAILS_CLOSE.test(view.text)) {
        depth -= 1;
        if (depth === 0) {
          close = view;
          cursor += 1;
          break;
        }
      }
      body.push(view);
      cursor += 1;
    }
    // Without `</details>` the toggle runs to the end, as HTML closes it there. That also keeps an
    // edit's effect local: typing the closing line never changes how lines far above it parse.
    const summaryStart = summaryView.start + summary[1].length;
    const childContext = {
      ...context,
      definitions: false,
      top: false,
      // GitHub reads Markdown in a toggle only with blank lines around it.
      separators: true,
      virtual: body.length === 0 ? { anchor: summaryView.end, before: "\n\n", after: "\n" } : null
    };
    const children = parseBlockList(arrayReader(body), childContext, false).blocks;
    return {
      block: {
        type: "toggle",
        open: isOpen,
        openView: open,
        summaryView,
        summaryStart,
        summaryEnd: summaryStart + summary[2].length,
        body,
        children,
        close,
        start: open.start,
        end: close ? close.end : (body.length ? body[body.length - 1].end : summaryView.end),
        line: open.line
      },
      next: cursor
    };
  }

  function indentWidth(whitespace) {
    let width = 0;
    for (const character of whitespace) width += character === "\t" ? 4 : 1;
    return width;
  }

  function parseList(reader, start, context) {
    const firstMatch = RE_ITEM.exec(reader.at(start).text);
    const baseIndent = indentWidth(firstMatch[1]);
    const ordered = /\d/.test(firstMatch[2]);
    const items = [];
    let index = start;

    while (reader.at(index)) {
      const view = reader.at(index);
      const match = RE_ITEM.exec(view.text);
      if (!match) break;
      const indent = indentWidth(match[1]);
      if (indent < baseIndent) break;
      if (indent >= baseIndent + 2 && items.length > 0) {
        const nested = parseList(reader, index, context);
        items[items.length - 1].children.push(nested.list);
        index = nested.next;
        continue;
      }
      if (/\d/.test(match[2]) !== ordered) break;

      const markerStart = view.start + match[1].length;
      const markerEnd = markerStart + match[2].length;
      const taskStart = markerEnd + match[3].length;
      const task = match[4]
        ? {
          checked: /\[[xX]\]/.test(match[4]),
          start: taskStart,
          end: taskStart + 3,
          boxStart: taskStart + 1
        }
        : null;
      const contentStart = taskStart + (match[4] ? match[4].length : 0);
      const lines = [{ text: view.text.slice(contentStart - view.start), start: contentStart, end: view.end, next: view.next, line: view.line }];
      index += 1;
      // A wrapped item continues on following lines until a blank line,
      // another item or the start of another block.
      while (reader.at(index)
        && !isBlank(reader.at(index).text)
        && !RE_ITEM.test(reader.at(index).text)
        && !isBlockStart(reader, index, context)) {
        // The continuation's indentation is list structure, not text.
        const continuation = reader.at(index);
        const lead = continuation.text.length - continuation.text.replace(/^[ \t]+/, "").length;
        lines.push({ ...continuation, text: continuation.text.slice(lead), start: continuation.start + lead });
        index += 1;
      }
      items.push({
        view,
        lines,
        indent,
        marker: match[2],
        markerStart,
        markerEnd,
        task,
        contentStart,
        contentEnd: lines[lines.length - 1].end,
        end: lines[lines.length - 1].end,
        children: []
      });
    }

    const lastItem = items[items.length - 1];
    const end = listEnd(lastItem);
    return {
      list: {
        type: "list",
        ordered,
        startNumber: ordered ? parseInt(firstMatch[2], 10) : 1,
        items,
        start: reader.at(start).start,
        end,
        line: reader.at(start).line
      },
      next: index
    };
  }

  function listEnd(item) {
    if (!item) return 0;
    const lastChild = item.children[item.children.length - 1];
    return lastChild ? listEnd(lastChild.items[lastChild.items.length - 1]) : item.end;
  }

  function parseTable(reader, start, context) {
    const header = tableRow(reader.at(start));
    const delimiter = reader.at(start + 1);
    const alignment = splitTableRow(delimiter.text).map((cell) => {
      const trimmed = cell.trim();
      if (/^:-+:$/.test(trimmed)) return "center";
      if (/^-+:$/.test(trimmed)) return "right";
      if (/^:-+$/.test(trimmed)) return "left";
      return "";
    });
    let index = start + 2;
    const rows = [];
    while (reader.at(index)
      && /\|/.test(reader.at(index).text)
      && !isBlank(reader.at(index).text)
      && !(context.definitions && definitionOf(reader.at(index).text))) {
      rows.push(tableRow(reader.at(index)));
      index += 1;
    }
    const last = rows.length ? rows[rows.length - 1].view : delimiter;
    return {
      block: {
        type: "table",
        header,
        delimiter,
        alignment,
        rows,
        start: reader.at(start).start,
        end: last.end,
        line: reader.at(start).line
      },
      next: index
    };
  }

  /// A table row's cells with the source range of each cell's trimmed text.
  function tableRow(view) {
    const text = view.text;
    let begin = 0;
    let finish = text.length;
    while (begin < finish && /\s/.test(text[begin])) begin += 1;
    while (finish > begin && /\s/.test(text[finish - 1])) finish -= 1;
    const leadingPipe = text[begin] === "|";
    const trailingPipe = finish > begin + (leadingPipe ? 1 : 0) && text[finish - 1] === "|" && text[finish - 2] !== "\\";
    let cursor = leadingPipe ? begin + 1 : begin;
    const stop = trailingPipe ? finish - 1 : finish;
    const cells = [];
    let cellStart = cursor;
    while (cursor <= stop) {
      const atEnd = cursor === stop;
      if (atEnd || (text[cursor] === "|" && text[cursor - 1] !== "\\")) {
        let s = cellStart;
        let e = cursor;
        while (s < e && /\s/.test(text[s])) s += 1;
        while (e > s && /\s/.test(text[e - 1])) e -= 1;
        if (s === e && cursor > cellStart) {
          // An empty cell's text goes one space in, so typing gives `| text |`.
          s = e = cellStart + 1;
        }
        cells.push({ start: view.start + s, end: view.start + e, slotStart: view.start + cellStart, slotEnd: view.start + cursor, text: text.slice(s, e) });
        cellStart = cursor + 1;
      }
      cursor += 1;
    }
    return { view, cells, leadingPipe, trailingPipe, pipeEnd: view.start + finish };
  }

  /// Parses consecutive blocks. Runs of blank lines between blocks become
  /// `empty` blocks: the first blank line separates, each further one is an
  /// empty line the editor shows. At the top level, blank lines before the
  /// first block and after the last are all empty lines.
  function parseBlockList(reader, context, topLevel, stop) {
    const blocks = [];
    let index = 0;
    let blanks = [];
    let hasBlock = false;
    while (reader.at(index)) {
      const view = reader.at(index);
      if (isBlank(view.text)) {
        blanks.push(view);
        index += 1;
        continue;
      }
      if (stop && stop(view, blocks)) {
        pushEmpties(blocks, blanks, topLevel ? (hasBlock ? "between" : "leading") : "between", topLevel, context, true);
        return { blocks, stoppedAt: index, stopView: view };
      }
      pushEmpties(blocks, blanks, topLevel ? (hasBlock ? "between" : "leading") : "between", topLevel, context, true);
      blanks = [];
      const parsed = parseBlock(reader, index, context);
      blocks.push(parsed.block);
      hasBlock = true;
      index = parsed.next;
    }
    pushEmpties(blocks, blanks, topLevel ? (hasBlock ? "trailing" : "only") : "between", topLevel, context, false);
    if (context.editing && blocks.length === 0) {
      // Nothing to type into yet: one empty line, where text would go.
      const block = emptyBlock(reader.at(0) || null, "only", 0, 0, context);
      if (block.view && context.separators) {
        block.needsSeparatorBefore = true;
        block.needsSeparatorAfter = true;
      }
      if (!block.view && context.virtual) {
        block.anchor = context.virtual.anchor;
        block.start = block.end = context.virtual.anchor;
        block.virtual = context.virtual;
      }
      blocks.push(block);
    }
    return { blocks, stoppedAt: index, stopView: null };
  }

  function pushEmpties(blocks, blanks, position, topLevel, context, followedByBlock) {
    if (!context.editing) return;
    const count = blanks.length;
    if (count === 0) return;
    let first = position === "between" ? 1 : 0;
    if (!topLevel && position === "between" && blocks.length === 0) first = 1;
    for (let index = first; index < count; index += 1) {
      const block = emptyBlock(blanks[index], position, index, count, context);
      block.needsSeparatorBefore = blocks.length > 0 && index === 0;
      block.needsSeparatorAfter = followedByBlock && index === count - 1;
      blocks.push(block);
    }
  }

  function emptyBlock(view, position, index, count, context) {
    const anchor = view ? view.start : (context.anchor || 0);
    return {
      type: "empty",
      view,
      position,
      runIndex: index,
      runLength: count,
      start: view ? (view.prefixStart ?? view.start) : anchor,
      end: view ? view.end : anchor,
      anchor,
      line: view ? view.line : 0,
      needsSeparatorBefore: false,
      needsSeparatorAfter: false
    };
  }

  /// Parses a whole document.
  function parseDocument(source, options = {}) {
    const hasCR = source.indexOf("\r") >= 0;
    const context = {
      definitions: true,
      top: true,
      editing: Boolean(options.editing),
      anchor: 0
    };
    const reader = streamReader(source, 0, 0, hasCR);
    const parsed = parseBlockList(reader, context, true);
    const doc = { source, hasCR, blocks: parsed.blocks, editing: context.editing };
    collectDefinitions(doc);
    return doc;
  }

  function collectDefinitions(doc) {
    const footnotes = new Map();
    const footnoteOrder = [];
    const references = new Map();
    for (const block of doc.blocks) {
      if (block.type !== "definition") continue;
      const definition = block.definition;
      if (definition.kind === "footnote") {
        if (!footnotes.has(definition.key)) footnoteOrder.push(definition.key);
        footnotes.set(definition.key, definition.text);
      } else if (definition.key && definition.destination && !references.has(definition.key)) {
        references.set(definition.key, { destination: definition.destination, title: definition.title });
      }
    }
    doc.footnotes = footnotes;
    doc.footnoteOrder = footnoteOrder;
    doc.references = references;
  }

  // ---------------------------------------------------------------------
  // Inline
  // ---------------------------------------------------------------------

  /// The inline passes, applied in order. A match becomes one opaque token,
  /// so later passes can span it but never split it.
  const PASSES = [
    { name: "code", re: /`([\s\S]+?)`/dg, needs: ["`"] },
    { name: "wikilink", re: /\[\[([^\]\n]+)\]\]/dg, needs: ["[["] },
    { name: "reflink", re: /(?<!!)\[([^\]\n]+)\]\[([^\]\n]*)\]/dg, needs: ["]["] },
    { name: "br", re: /(?: {2,}|\\)\n/dg, needs: ["\n"] },
    { name: "image", re: /!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]+)")?\)/dg, needs: ["!["] },
    { name: "link", re: /\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]+)")?\)/dg, needs: ["]("] },
    { name: "autolink", re: /(^|[\s(])(https?:\/\/[^\s<\uE000-\uF8FF]+)/dg, needs: ["://"] },
    { name: "anglelink", re: /<(https?:\/\/[^&\s>\uE000-\uF8FF]+)>/dg, needs: ["<http"] },
    { name: "footnote", re: /\[\^([^\]]+)\]/dg, needs: ["[^"] },
    { name: "strongem", re: /(\*\*\*|___)([^\s*_][\s\S]*?)\1/dg, needs: ["***", "___"] },
    { name: "strong", re: /(\*\*|__)([\s\S]+?)\1/dg, needs: ["**", "__"] },
    { name: "del", re: /~~([\s\S]+?)~~/dg, needs: ["~~"] },
    { name: "em", re: /(^|[^*])\*([^*\s][^*]*?)\*/dg, needs: ["*"] },
    { name: "emu", re: /(^|[^_])_([^_\s][^_]*?)_/dg, needs: ["_"] }
  ];
  const INLINE_TRIGGER = /[`[\n!:<*_~\uE000-\uF8FF]/;
  const PASS_INDEX = Object.fromEntries(PASSES.map((pass, index) => [pass.name, index]));

  /// Tokenizes inline Markdown in `j` into nodes that carry `j` offsets.
  function parseInline(j, context) {
    if (!INLINE_TRIGGER.test(j)) return j.length ? [{ t: "text", s: 0, e: j.length }] : [];
    const state = { j, tokens: [], context };
    let w = j;
    let map = null;
    if (/[\uE000-\uF8FF]/.test(j)) {
      // Source characters in the private use area would read as tokens.
      let built = "";
      map = [];
      for (let index = 0; index < j.length; index += 1) {
        const code = j.charCodeAt(index);
        if (code >= TOKEN_BASE && code <= TOKEN_LAST) {
          built += tokenChar(state, { t: "text", s: index, e: index + 1 }) ?? "\uFFFD";
        } else {
          built += j[index];
        }
        map.push(index);
      }
      w = built;
    }
    const top = { w, map, base: 0 };
    runPasses(state, top, 0);
    return children(state, top, 0, top.w.length);
  }

  function tokenChar(state, node) {
    if (state.tokens.length > TOKEN_LAST - TOKEN_BASE) return null;
    state.tokens.push(node);
    return String.fromCharCode(TOKEN_BASE + state.tokens.length - 1);
  }

  function jAt(view, index) {
    return view.map ? view.map[index] : view.base + index;
  }

  function tokenAt(state, view, index) {
    const code = view.w.charCodeAt(index);
    return code >= TOKEN_BASE && code <= TOKEN_LAST ? state.tokens[code - TOKEN_BASE] : null;
  }

  function jStart(state, view, index) {
    const token = tokenAt(state, view, index);
    return token ? token.s : jAt(view, index);
  }

  function jEnd(state, view, index) {
    const token = tokenAt(state, view, index);
    return token ? token.e : jAt(view, index) + 1;
  }

  function children(state, view, from, to) {
    const nodes = [];
    let index = from;
    while (index < to) {
      const token = tokenAt(state, view, index);
      if (token) {
        nodes.push(token);
        index += 1;
        continue;
      }
      const s = jAt(view, index);
      let e = s + 1;
      index += 1;
      while (index < to && !tokenAt(state, view, index) && jAt(view, index) === e) {
        e += 1;
        index += 1;
      }
      nodes.push({ t: "text", s, e });
    }
    return nodes;
  }

  function subView(view, from, to) {
    return {
      w: view.w.slice(from, to),
      map: view.map ? view.map.slice(from, to) : null,
      base: view.map ? 0 : view.base + from
    };
  }

  function parseRange(state, view, from, to, passIndex) {
    const sub = subView(view, from, to);
    runPasses(state, sub, passIndex);
    return children(state, sub, 0, sub.w.length);
  }

  function textOf(state, view, from, to) {
    if (from >= to) return "";
    return state.j.slice(jStart(state, view, from), jEnd(state, view, to - 1));
  }

  function runPasses(state, view, firstPass) {
    for (let index = firstPass; index < PASSES.length; index += 1) {
      applyPass(state, view, index);
    }
  }

  function applyPass(state, view, passIndex) {
    const pass = PASSES[passIndex];
    if (!pass.needs.some((needle) => view.w.indexOf(needle) >= 0)) return;
    // Building a node parses its content with these same expressions, so
    // collect every match before building any.
    const matches = Array.from(view.w.matchAll(pass.re));
    const found = [];
    for (const match of matches) {
      if (match[0].length === 0) continue;
      const node = buildNode(state, view, pass.name, match, passIndex);
      if (node) found.push(node);
    }
    if (found.length === 0) return;

    const pieces = [];
    const map = [];
    let cursor = 0;
    const copy = (from, to) => {
      if (from >= to) return;
      pieces.push(view.w.slice(from, to));
      if (view.map) {
        for (let index = from; index < to; index += 1) map.push(view.map[index]);
      } else {
        for (let index = from; index < to; index += 1) map.push(view.base + index);
      }
    };
    for (const node of found) {
      const char = tokenChar(state, node.node);
      if (char === null) break;
      copy(cursor, node.from);
      pieces.push(char);
      map.push(-1);
      cursor = node.to;
    }
    copy(cursor, view.w.length);
    view.w = pieces.join("");
    view.map = map;
    view.base = 0;
  }

  function trimRange(text, from, to) {
    while (from < to && /\s/.test(text[from])) from += 1;
    while (to > from && /\s/.test(text[to - 1])) to -= 1;
    return [from, to];
  }

  function buildNode(state, view, name, match, passIndex) {
    const [from, to] = match.indices[0];
    const s = jStart(state, view, from);
    const e = jEnd(state, view, to - 1);
    const context = state.context;
    const group = (index) => match.indices[index] || null;

    switch (name) {
      case "code": {
        const [cs, ce] = group(1);
        return {
          from,
          to,
          node: { t: "code", s, e, cs: jStart(state, view, cs), ce: jEnd(state, view, ce - 1), kids: children(state, view, cs, ce) }
        };
      }
      case "wikilink": {
        const [cs, ce] = group(1);
        const separator = view.w.indexOf("|", cs);
        const hasAlias = separator >= 0 && separator < ce;
        const [ds, de] = trimRange(view.w, cs, hasAlias ? separator : ce);
        const [as, ae] = hasAlias ? trimRange(view.w, separator + 1, ce) : [0, 0];
        const [ls, le] = ae > as ? [as, ae] : [ds, de];
        const destination = textOf(state, view, ds, de);
        if (context.editing && le <= ls) return null;
        return {
          from,
          to,
          node: {
            t: "wiki",
            s,
            e,
            cs: le > ls ? jStart(state, view, ls) : s,
            ce: le > ls ? jEnd(state, view, le - 1) : s,
            destination,
            kids: children(state, view, ls, le)
          }
        };
      }
      case "reflink": {
        const [ls, le] = group(1);
        const [is, ie] = group(2);
        const label = textOf(state, view, ls, le);
        const identifier = textOf(state, view, is, ie);
        const reference = context.references && context.references.get(normalizeReferenceLabel(identifier || label));
        if (!reference) return null;
        const safe = sanitizeURL(reference.destination, false);
        return {
          from,
          to,
          node: {
            t: "link",
            s,
            e,
            cs: jStart(state, view, ls),
            ce: jEnd(state, view, le - 1),
            href: safe,
            title: reference.title || "",
            kids: parseRange(state, view, ls, le, passIndex)
          }
        };
      }
      case "br":
        return { from, to, node: { t: "br", s, e } };
      case "image": {
        const alt = group(1) ? textOf(state, view, group(1)[0], group(1)[1]) : "";
        const url = textOf(state, view, group(2)[0], group(2)[1]);
        const title = group(3) ? textOf(state, view, group(3)[0], group(3)[1]) : "";
        const safe = sanitizeURL(url, true);
        if (!safe && context.editing) return null;
        return { from, to, node: { t: "img", s, e, src: safe, alt, title } };
      }
      case "link": {
        const [ls, le] = group(1);
        const url = textOf(state, view, group(2)[0], group(2)[1]);
        const title = group(3) ? textOf(state, view, group(3)[0], group(3)[1]) : "";
        return {
          from,
          to,
          node: {
            t: "link",
            s,
            e,
            cs: jStart(state, view, ls),
            ce: jEnd(state, view, le - 1),
            href: sanitizeURL(url, false),
            title,
            kids: parseRange(state, view, ls, le, passIndex)
          }
        };
      }
      case "autolink": {
        const [us, ue] = group(2);
        const start = jStart(state, view, us);
        return {
          from: us,
          to,
          node: { t: "auto", s: start, e, cs: start, ce: e, href: state.j.slice(start, e) }
        };
      }
      case "anglelink": {
        const [us, ue] = group(1);
        const cs = jStart(state, view, us);
        const ce = jEnd(state, view, ue - 1);
        return { from, to, node: { t: "angle", s, e, cs, ce, href: state.j.slice(cs, ce) } };
      }
      case "footnote": {
        const key = textOf(state, view, group(1)[0], group(1)[1]).trim();
        if (!context.footnotes || !context.footnotes.has(key)) return null;
        return { from, to, node: { t: "fn", s, e, key } };
      }
      case "strongem": {
        const [cs, ce] = group(2);
        const inner = parseRange(state, view, cs, ce, passIndex + 1);
        const contentStart = jStart(state, view, cs);
        const contentEnd = jEnd(state, view, ce - 1);
        const em = { t: "em", s: contentStart - 1, e: contentEnd + 1, cs: contentStart, ce: contentEnd, kids: inner };
        return { from, to, node: { t: "strong", s, e, cs: contentStart - 1, ce: contentEnd + 1, kids: [em] } };
      }
      case "strong":
      case "del": {
        const [cs, ce] = group(name === "strong" ? 2 : 1);
        return {
          from,
          to,
          node: {
            t: name,
            s,
            e,
            cs: jStart(state, view, cs),
            ce: jEnd(state, view, ce - 1),
            kids: parseRange(state, view, cs, ce, passIndex + 1)
          }
        };
      }
      case "em":
      case "emu": {
        const [ps, pe] = group(1);
        const [cs, ce] = group(2);
        const start = jStart(state, view, pe);
        return {
          from: pe,
          to,
          node: {
            t: "em",
            s: start,
            e,
            cs: jStart(state, view, cs),
            ce: jEnd(state, view, ce - 1),
            kids: parseRange(state, view, cs, ce, passIndex + 1)
          }
        };
      }
      default:
        return null;
    }
  }

  /// Renders inline nodes as HTML. With a `collector`, also records the
  /// visible text: each run of characters (or one atom such as an image) with
  /// the `j` range it came from, and every construct's markup ranges.
  function renderInlineNodes(nodes, j, render, collector) {
    let html = "";
    for (const node of nodes) {
      html += renderInlineNode(node, j, render, collector);
    }
    return html;
  }

  function renderInlineNode(node, j, render, collector) {
    const editing = render.editing;
    switch (node.t) {
      case "text": {
        const text = j.slice(node.s, node.e);
        if (collector) {
          collector.segments.push({ v: collector.v, len: text.length, j: node.s });
          collector.v += text.length;
          collector.visible += text;
        }
        return escapeHTML(text);
      }
      case "code": {
        if (collector) collector.constructs.push({ type: "code", s: node.s, e: node.e, cs: node.cs, ce: node.ce, inclusive: true });
        return `<code>${renderInlineNodes(node.kids, j, render, collector)}</code>`;
      }
      case "wiki": {
        if (collector) collector.constructs.push({ type: "wikilink", s: node.s, e: node.e, cs: node.cs, ce: node.ce, inclusive: false, destination: node.destination });
        const label = renderInlineNodes(node.kids, j, render, collector);
        if (!node.destination) return label;
        return `<a href="#" class="wikilink" data-monknot-link-kind="wikilink" data-monknot-destination="${escapeAttr(node.destination)}">${label}</a>`;
      }
      case "link": {
        if (collector) collector.constructs.push({ type: "link", s: node.s, e: node.e, cs: node.cs, ce: node.ce, inclusive: false, href: node.href });
        const label = renderInlineNodes(node.kids, j, render, collector);
        if (!node.href) return label;
        const titleAttr = node.title ? ` title="${escapeAttr(node.title)}"` : "";
        return `<a href="${escapeAttr(node.href)}" data-monknot-link-kind="markdown" data-monknot-destination="${escapeAttr(node.href)}"${titleAttr}>${label}</a>`;
      }
      case "auto":
      case "angle": {
        if (collector) collector.constructs.push({ type: "autolink", s: node.s, e: node.e, cs: node.cs, ce: node.ce, inclusive: false, href: node.href });
        const label = renderInlineNode({ t: "text", s: node.cs, e: node.ce }, j, render, collector);
        return `<a href="${escapeAttr(node.href)}" data-monknot-link-kind="markdown" data-monknot-destination="${escapeAttr(node.href)}">${label}</a>`;
      }
      case "br":
        recordAtom(collector, node);
        return "<br>";
      case "img": {
        if (!node.src) return "";
        recordAtom(collector, node);
        const titleAttr = node.title ? ` title="${escapeAttr(node.title)}"` : "";
        // Image syntax pointing at a video or audio file plays it, as GitHub does.
        if (RE_VIDEO.test(node.src) || RE_AUDIO.test(node.src)) {
          const tag = RE_VIDEO.test(node.src) ? "video" : "audio";
          const extra = editing ? ` contenteditable="false" data-mk-atom` : "";
          return `<${tag} src="${escapeAttr(node.src)}" controls preload="metadata" aria-label="${escapeAttr(node.alt || node.title || node.src)}"${extra}></${tag}>`;
        }
        const extra = editing ? ` data-mk-atom draggable="false"` : "";
        return `<img src="${escapeAttr(node.src)}" alt="${escapeAttr(node.alt)}"${titleAttr}${extra}>`;
      }
      case "fn": {
        recordAtom(collector, node);
        const refNumbers = render.refNumbers;
        if (!refNumbers.has(node.key)) refNumbers.set(node.key, refNumbers.size + 1);
        const number = refNumbers.get(node.key);
        const extra = editing ? ` contenteditable="false" data-mk-atom` : "";
        return `<sup class="footnote-ref" id="fnref-${escapeAttr(slug(node.key))}"${extra}><a href="#fn-${escapeAttr(slug(node.key))}">${number}</a></sup>`;
      }
      case "strong":
      case "em":
      case "del": {
        if (collector) collector.constructs.push({ type: node.t, s: node.s, e: node.e, cs: node.cs, ce: node.ce, inclusive: true });
        return `<${node.t}>${renderInlineNodes(node.kids, j, render, collector)}</${node.t}>`;
      }
      default:
        return "";
    }
  }

  function recordAtom(collector, node) {
    if (!collector) return;
    collector.segments.push({ v: collector.v, len: 1, j: node.s, atom: true, s: node.s, e: node.e });
    collector.v += 1;
    collector.visible += "\uFFFC";
  }

  /// Renders inline Markdown text to HTML (and optionally its visible map).
  function renderInline(j, render, collector) {
    const nodes = parseInline(j, render);
    return renderInlineNodes(nodes, j, render, collector);
  }

  // ---------------------------------------------------------------------
  // Editable units
  //
  // In the editor, every element that holds text the user can type into
  // (a paragraph, a heading, a list item's text, a table cell, a code block,
  // a raw block, an empty line) is a unit. A unit knows the `j` text it
  // renders and how each `j` offset maps back to the source.
  // ---------------------------------------------------------------------

  function makeUnit(render, kind, props) {
    if (!render.editing) return null;
    // `scope`: the toggle whose body holds the unit; edits never join text across its edge.
    const unit = { id: ++render.unitSequence, kind, scope: render.scope || null, ...props };
    render.units.push(unit);
    return unit;
  }

  function unitAttributes(unit, extra = "") {
    if (!unit) return extra;
    return ` data-mk-u="${unit.id}"${extra}`;
  }

  /// Consecutive line views joined into one paragraph: soft breaks read as a
  /// space, hard breaks keep their newline.
  function paragraphRegion(lines) {
    let j = "";
    lines.forEach((view, index) => {
      if (index > 0) j += /(?: {2,}|\\)$/.test(j) ? "\n" : " ";
      j += view.text;
    });
    return { kind: "lines", lines, j, map: null };
  }

  function linesRegion(lines) {
    return { kind: "lines", lines, j: lines.map((view) => view.text).join("\n"), map: null };
  }

  function sliceRegion(source, start, end) {
    return { kind: "slice", start, end, j: source.slice(start, end), map: null };
  }

  function fixedRegion(j, map) {
    return { kind: "fixed", j, map };
  }

  /// A table cell's text with escaped pipes read as `|`.
  function cellRegion(source, start, end) {
    let j = "";
    const map = [];
    for (let offset = start; offset < end; offset += 1) {
      map.push(offset);
      if (source[offset] === "\\" && source[offset + 1] === "|") {
        j += "|";
        offset += 1;
        continue;
      }
      j += source[offset];
    }
    map.push(end);
    return fixedRegion(j, map);
  }

  /// The source offset of every `j` offset (and of the end) in a region. A
  /// `j` character can stand for several source characters, such as a soft
  /// break for a line ending and the next line's quote marker.
  function regionMap(region) {
    if (region.map) return region.map;
    const map = [];
    if (region.kind === "slice") {
      for (let offset = region.start; offset <= region.end; offset += 1) map.push(offset);
    } else {
      const lines = region.lines;
      lines.forEach((view, index) => {
        if (index > 0) map.push(lines[index - 1].end);
        for (let offset = 0; offset < view.text.length; offset += 1) map.push(view.start + offset);
      });
      map.push(lines.length ? lines[lines.length - 1].end : 0);
    }
    region.map = map;
    return map;
  }

  // ---------------------------------------------------------------------
  // Block rendering
  // ---------------------------------------------------------------------

  function newRender(doc, options = {}) {
    return {
      editing: Boolean(options.editing ?? doc.editing),
      footnotes: doc.footnotes,
      footnoteOrder: doc.footnoteOrder,
      references: doc.references,
      refNumbers: options.refNumbers || new Map(),
      unitSequence: options.unitSequence || 0,
      units: [],
      source: doc.source,
      blocks: doc.blocks
    };
  }

  function openTag(tag, line, attributes = "") {
    return `<${tag} data-source-line="${line + 1}"${attributes}>`;
  }

  function renderBlock(block, render, container) {
    switch (block.type) {
      case "paragraph": {
        const region = paragraphRegion(block.lines);
        const unit = makeUnit(render, "inline", { block, container, region, role: "paragraph" });
        return `${openTag("p", block.line, unitAttributes(unit))}${renderInline(region.j, render)}</p>`;
      }
      case "heading": {
        const region = sliceRegion(render.source, block.contentStart, block.contentEnd);
        const unit = makeUnit(render, "inline", { block, container, region, role: "heading", level: block.level });
        const text = region.j;
        const empty = unit && text.length === 0;
        const extra = unit
          ? `${unitAttributes(unit)}${empty ? ` data-mk-empty data-placeholder="Heading ${block.level}"` : ""}`
          : "";
        const body = empty ? `<br data-mk-filler>` : renderInline(text, render);
        return `<h${block.level} data-source-line="${block.line + 1}" id="${escapeAttr(slug(stripInline(text)))}"${extra}>${body}</h${block.level}>`;
      }
      case "code": {
        const region = block.body.length
          ? linesRegion(block.body)
          : fixedRegion("", [block.open.next > block.open.end ? block.open.next : block.open.end]);
        const language = block.fence.language;
        const highlighted = highlightCode(region.j, language);
        if (!render.editing) {
          return `${openTag("pre", block.line)}<code class="language-${escapeAttr(language)}">${highlighted}</code></pre>`;
        }
        const unit = makeUnit(render, "code", { block, container, region, role: "code" });
        const filler = region.j.length === 0 || region.j.endsWith("\n") ? `<br data-mk-filler>` : "";
        const label = language || "Plain text";
        return `${openTag("div", block.line, ` class="mk-code-block"`)}`
          + `<button type="button" class="mk-code-language" contenteditable="false" data-mk-skip data-mk-action="code-language" tabindex="-1" aria-label="Code language: ${escapeAttr(label)}">${escapeHTML(label)}</button>`
          + `<pre><code class="language-${escapeAttr(language)}"${unitAttributes(unit)}>${highlighted}${filler}</code></pre></div>`;
      }
      case "hr":
        if (!render.editing) return "";
        return `${openTag("div", block.line, ` class="mk-hr" contenteditable="false" data-mk-skip`)}<hr></div>`;
      case "definition": {
        if (!render.editing) return "";
        const region = linesRegion(block.lines);
        const unit = makeUnit(render, "raw", { block, container, region, role: "definition" });
        return `${openTag("div", block.line, ` class="mk-raw" data-mk-raw-kind="${block.definition.kind}"${unitAttributes(unit)}`)}${escapeHTML(region.j)}</div>`;
      }
      case "empty": {
        if (!render.editing) return "";
        const unit = makeUnit(render, "empty", { block, container, region: fixedRegion("", [block.anchor]), role: "empty" });
        return `<p class="mk-empty" data-source-line="${block.line + 1}"${unitAttributes(unit)} data-mk-empty><br data-mk-filler></p>`;
      }
      case "quote": {
        const inner = block.children.map((child) => renderBlock(child, render, block)).filter(Boolean).join("\n");
        if (block.callout) {
          const kind = block.callout.kind;
          const title = CALLOUT_TITLES[kind];
          const titleAttributes = render.editing
            ? ` contenteditable="false" data-mk-skip data-mk-action="callout-kind" role="button" aria-label="Callout type: ${title}"`
            : "";
          return `${openTag("div", block.line, ` class="callout callout-${kind}" role="note"`)}<p class="callout-title"${titleAttributes}>${title}</p>${inner}</div>`;
        }
        return `${openTag("blockquote", block.line)}${inner}</blockquote>`;
      }
      case "toggle":
        return renderToggle(block, render, container);
      case "toc":
        return renderTableOfContents(block, render);
      case "list":
        return renderList(block, render, container);
      case "table":
        return renderTable(block, render, container);
      default:
        return "";
    }
  }

  function renderList(list, render, container) {
    const tag = list.ordered ? "ol" : "ul";
    const hasTasks = list.items.some((item) => item.task);
    const listClass = hasTasks ? ` class="contains-task-list"` : "";
    const startAttr = list.ordered && list.startNumber !== 1 && Number.isFinite(list.startNumber) ? ` start="${list.startNumber}"` : "";
    const items = list.items.map((item) => {
      const line = item.view.line;
      const region = paragraphRegion(item.lines);
      const unit = makeUnit(render, "inline", { block: list, container, region, role: "item", item, list });
      let content;
      if (unit) {
        const empty = region.j.length === 0;
        const placeholder = item.task ? "To-do" : "List";
        const attributes = `${unitAttributes(unit)} class="mk-item-text"${empty ? ` data-mk-empty data-placeholder="${placeholder}"` : ""}`;
        content = `<span${attributes}>${empty ? "<br data-mk-filler>" : renderInline(region.j, render)}</span>`;
      } else {
        content = renderInline(region.j, render);
      }
      let className = "";
      if (item.task) {
        className = ` class="task-list-item"`;
        const checked = item.task.checked ? " checked" : "";
        const extra = render.editing ? ` contenteditable="false" data-mk-skip tabindex="-1"` : "";
        const wrapped = render.editing ? content : `<span>${content}</span>`;
        content = `<input type="checkbox" data-monknot-task data-source-line="${line + 1}" data-task-checked="${item.task.checked}" aria-label="Toggle task"${checked}${extra}>${wrapped}`;
      }
      const nested = item.children.map((child) => renderList(child, render, container)).join("");
      return `<li data-source-line="${line + 1}"${className}>${content}${nested}</li>`;
    }).join("");
    return `${openTag(tag, list.line, `${listClass}${startAttr}`)}${items}</${tag}>`;
  }

  function renderToggle(block, render, container) {
    const region = sliceRegion(render.source, block.summaryStart, block.summaryEnd);
    const outer = render.scope || null;
    block.scopeParent = outer;
    // The summary's unit comes before the body's, in document order.
    const unit = makeUnit(render, "inline", { block, container, region, role: "summary" });
    render.scope = block;
    const children = block.children.map((child) => renderBlock(child, render, block)).filter(Boolean).join("\n");
    render.scope = outer;
    if (!render.editing) {
      const open = block.open ? " open" : "";
      return `${openTag("details", block.line, open)}<summary>${renderInline(region.j, render)}</summary>${children}</details>`;
    }
    const empty = region.j.length === 0;
    // Opening a toggle while editing is a view state: the file keeps its `open` attribute.
    const open = block.viewOpen ?? block.open;
    const summaryAttributes = `${unitAttributes(unit)} class="mk-toggle-summary"${empty ? ` data-mk-empty data-placeholder="Toggle"` : ""}`;
    const summary = empty ? "<br data-mk-filler>" : renderInline(region.j, render);
    return `${openTag("div", block.line, ` class="mk-toggle" data-open="${open}"`)}`
      + `<div class="mk-toggle-head"><button type="button" class="mk-toggle-arrow" contenteditable="false" data-mk-skip data-mk-action="toggle" tabindex="-1" aria-label="${open ? "Collapse" : "Expand"}" aria-expanded="${open}"></button>`
      + `<div${summaryAttributes}>${summary}</div></div>`
      + `<div class="mk-toggle-body">${children}</div></div>`;
  }

  /// A `[TOC]` line lists the document's headings, linked to them.
  function renderTableOfContents(block, render) {
    const headings = [];
    // Entries are numbered by their place among the document's top-level h1–h3, which is how a
    // click finds the heading on the page; empty headings keep their number but get no entry.
    let position = 0;
    for (const candidate of render.blocks || []) {
      if (candidate.type !== "heading" || candidate.level > 3) continue;
      const shift = candidate.shift || 0;
      const text = render.source.slice(candidate.contentStart + shift, candidate.contentEnd + shift);
      if (text.trim()) headings.push({ level: candidate.level, text, index: position });
      position += 1;
    }
    const extra = render.editing ? ` contenteditable="false" data-mk-skip` : "";
    if (headings.length === 0) {
      if (!render.editing) return "";
      return `${openTag("nav", block.line, ` class="toc toc-empty"${extra} aria-label="Table of contents"`)}<p>Headings you add appear here.</p></nav>`;
    }
    const minimum = Math.min(...headings.map((heading) => heading.level));
    const items = headings.map((heading) => {
      const label = stripInline(heading.text);
      return `<li class="toc-level-${heading.level - minimum + 1}"><a href="#${escapeAttr(slug(label))}" data-mk-toc="${heading.index}">${escapeHTML(label)}</a></li>`;
    }).join("");
    return `${openTag("nav", block.line, ` class="toc"${extra} aria-label="Table of contents"`)}<ul>${items}</ul></nav>`;
  }

  function renderTable(table, render, container) {
    if (!render.editing) return renderStaticTable(table, render);
    const columns = table.header.cells.length;
    if (render.editing && table.rows.some((row) => row.cells.length > columns)) {
      // A row with more cells than the header would lose cells; edit it as text.
      const lines = [table.header.view, table.delimiter, ...table.rows.map((row) => row.view)];
      const region = linesRegion(lines);
      const unit = makeUnit(render, "raw", { block: table, container, region, role: "table-source" });
      return `${openTag("div", table.line, ` class="mk-raw"${unitAttributes(unit)}`)}${escapeHTML(region.j)}</div>`;
    }
    const alignAttr = (index) => (table.alignment[index] ? ` align="${table.alignment[index]}"` : "");
    const cell = (tag, row, rowIndex, index) => {
      const source = row.cells[index];
      // GFM trims a cell's text; a space typed at its end is kept on the page past the one space of
      // padding before the pipe, so the caret moves as the space is typed.
      let end = source ? source.end : 0;
      if (source) {
        let spaces = 0;
        while (end + spaces < source.slotEnd && (render.source[end + spaces] === " " || render.source[end + spaces] === "\t")) spaces += 1;
        if (spaces >= 2) end += spaces - 1;
      }
      const region = source ? cellRegion(render.source, source.start, end) : fixedRegion("", [row.pipeEnd]);
      const unit = makeUnit(render, "inline", {
        block: table,
        container,
        region,
        role: "cell",
        table,
        row,
        rowIndex,
        column: index,
        missing: !source
      });
      const body = region.j.length ? renderInline(region.j, render) : `<br data-mk-filler>`;
      return `<${tag}${alignAttr(index)}${unitAttributes(unit)}>${body}</${tag}>`;
    };
    const head = `<thead><tr>${table.header.cells.map((_, index) => cell("th", table.header, -1, index)).join("")}</tr></thead>`;
    const body = `<tbody>${table.rows.map((row, rowIndex) => `<tr>${table.header.cells.map((_, index) => cell("td", row, rowIndex, index)).join("")}</tr>`).join("")}</tbody>`;
    return `${openTag("div", table.line, ` class="table-wrapper"`)}<table>${head}${body}</table></div>`;
  }

  function renderStaticTable(table, render) {
    const headers = splitTableRow(table.header.view.text);
    const rows = table.rows.map((row) => splitTableRow(row.view.text));
    const alignAttr = (index) => (table.alignment[index] ? ` align="${table.alignment[index]}"` : "");
    const thead = `<thead><tr>${headers.map((cell, index) => `<th${alignAttr(index)}>${renderInline(cell.trim(), render)}</th>`).join("")}</tr></thead>`;
    const tbody = `<tbody>${rows.map((row) => `<tr>${headers.map((_, index) => `<td${alignAttr(index)}>${renderInline((row[index] || "").trim(), render)}</td>`).join("")}</tr>`).join("")}</tbody>`;
    return `${openTag("div", table.line, ` class="table-wrapper"`)}<table>${thead}${tbody}</table></div>`;
  }

  function renderFootnotes(doc, render) {
    const refNumbers = render.refNumbers;
    if (refNumbers.size === 0) return "";
    const notes = doc.footnoteOrder
      .filter((key) => refNumbers.has(key))
      .sort((a, b) => refNumbers.get(a) - refNumbers.get(b))
      .map((key) => {
        const text = renderInline(doc.footnotes.get(key) || "", { ...render, editing: false, units: [] });
        return `<li id="fn-${escapeAttr(slug(key))}">${text} <a class="footnote-backref" href="#fnref-${escapeAttr(slug(key))}">↩</a></li>`;
      })
      .join("");
    const extra = render.editing ? ` contenteditable="false" data-mk-skip` : "";
    return `<section class="footnotes"${extra}><ol>${notes}</ol></section>`;
  }

  function renderDocument(doc, options = {}) {
    const render = newRender(doc, options);
    const html = doc.blocks.map((block) => renderBlock(block, render, null)).filter(Boolean).join("\n");
    return { html: html + renderFootnotes(doc, render), render };
  }

  // ---------------------------------------------------------------------
  // Unit maps (editor)
  // ---------------------------------------------------------------------

  /// Visible text, runs and constructs of a unit, computed on first use.
  function unitMap(unit, context) {
    if (unit.visibleMap) return unit.visibleMap;
    const collector = { v: 0, segments: [], constructs: [], visible: "" };
    if (unit.kind === "inline") {
      renderInline(unit.region.j, { ...context, editing: true, refNumbers: new Map(), units: [] }, collector);
    } else if (unit.region.j.length > 0) {
      collector.segments.push({ v: 0, len: unit.region.j.length, j: 0 });
      collector.v = unit.region.j.length;
      collector.visible = unit.region.j;
    }
    unit.visibleMap = collector;
    return collector;
  }

  function stripInline(text) {
    return text
      .replace(/`([^`]+)`/g, "$1")
      .replace(/!\[([^\]]*)\]\([^)]+\)/g, "$1")
      .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
      .replace(/[*_~#]/g, "");
  }

  function normalizeReferenceLabel(label) {
    return String(label || "").trim().split(/\s+/).join(" ").toLowerCase();
  }

  function slug(text) {
    const value = text.toLowerCase().trim()
      .replace(/<[^>]*>/g, "")
      .replace(/[^a-z0-9\s-]/g, "")
      .replace(/\s+/g, "-")
      .replace(/-+/g, "-");
    return value || "section";
  }

  function sanitizeURL(url, image) {
    const trimmed = String(url || "").trim().replace(/^['"]|['"]$/g, "");
    const lowered = trimmed.toLowerCase();
    if (!trimmed) return "";
    if (lowered.startsWith("javascript:")) return "";
    if (lowered.startsWith("vbscript:")) return "";
    if (lowered.startsWith("data:") && !(image && lowered.startsWith("data:image/"))) return "";
    return trimmed;
  }

  function escapeHTML(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function escapeAttr(value) {
    return escapeHTML(value).replace(/`/g, "&#96;");
  }

  function highlightCode(code, language) {
    const keywordSet = new Set([
      "actor", "as", "async", "await", "break", "case", "catch", "class", "const",
      "continue", "default", "defer", "do", "else", "enum", "export", "extends",
      "false", "final", "for", "func", "function", "guard", "if", "import", "in",
      "interface", "let", "nil", "null", "private", "public", "return", "static",
      "struct", "switch", "throw", "throws", "true", "try", "type", "var", "while"
    ]);
    const builtinSet = new Set(["Array", "Bool", "Date", "Dictionary", "Double", "Int", "JSON", "Set", "String", "URL"]);
    const tokenPattern = /(\/\/.*|\/\*[\s\S]*?\*\/|#.*$|"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|`(?:\\.|[^`])*`|\b\d+(?:\.\d+)?\b|\b[A-Za-z_][A-Za-z0-9_]*\b)/gm;
    let html = "";
    let cursor = 0;
    let match;

    while ((match = tokenPattern.exec(code)) !== null) {
      html += escapeHTML(code.slice(cursor, match.index));
      const token = match[0];
      if (/^(\/\/|\/\*|#)/.test(token)) {
        html += `<span class="tok-comment">${escapeHTML(token)}</span>`;
      } else if (/^["'`]/.test(token)) {
        html += `<span class="tok-string">${escapeHTML(token)}</span>`;
      } else if (/^\d/.test(token)) {
        html += `<span class="tok-number">${escapeHTML(token)}</span>`;
      } else if (keywordSet.has(token)) {
        html += `<span class="tok-keyword">${escapeHTML(token)}</span>`;
      } else if (builtinSet.has(token) || language === "json" && /^[A-Za-z_]/.test(token)) {
        html += `<span class="tok-builtin">${escapeHTML(token)}</span>`;
      } else {
        html += escapeHTML(token);
      }
      cursor = match.index + token.length;
    }

    return html + escapeHTML(code.slice(cursor));
  }

  /// Renders Markdown to preview/export HTML.
  function renderMarkdown(source) {
    return renderDocument(parseDocument(source)).html;
  }

  const MonknotMarkdown = {
    parseDocument,
    parseBlockList,
    parseBlock,
    streamReader,
    arrayReader,
    readLine,
    renderDocument,
    renderBlock,
    renderFootnotes,
    renderInline,
    parseInline,
    collectDefinitions,
    newRender,
    unitMap,
    regionMap,
    renderMarkdown,
    openingFence,
    isBlank,
    definitionOf,
    splitTableRow,
    tableRow,
    escapeHTML,
    escapeAttr,
    slug,
    stripInline,
    highlightCode,
    sanitizeURL
  };
  window.MonknotMarkdown = MonknotMarkdown;

  // =====================================================================
  // Preview page
  // =====================================================================

  let markdown = "";
  let searchQuery = "";
  let searchOptions = { isCaseSensitive: false, isWholeWord: false };
  let searchNavigationSerial = -1;
  let searchMatches = [];
  let searchCurrentIndex = 0;
  let hasRendered = false;
  let documentID = "";
  let renderID = 0;

  const target = typeof document !== "undefined" && document.getElementById ? document.getElementById("content") : null;
  if (!target) return;

  let readingAnchor = null;
  let readingAnchorFrame = 0;
  let readingWidth = window.innerWidth;

  window.monknotRender = render;
  window.monknotApplyAppearance = applyAppearance;
  window.monknotSearch = searchDocument;
  window.monknotRevealSourceLine = revealSourceLine;
  window.monknotScrollToLine = scrollToSourceLine;
  window.monknotVisibleSourceLine = visibleSourceLine;
  window.monknotCurrentIdentity = currentIdentity;
  window.monknotNormalizeHeadingFragment = slug;
  window.monknotTearDown = tearDown;
  render(window.monknot || {});
  target.addEventListener("dblclick", handleSourceJump);
  target.addEventListener("click", handleInteraction);
  if (typeof window.addEventListener === "function") {
    window.addEventListener("scroll", scheduleReadingAnchor, { passive: true });
    window.addEventListener("resize", keepReadingPosition);
  }

  function editor() {
    const instance = window.MonknotEditor;
    return instance && instance.isActive && instance.isActive() ? instance : null;
  }

  function render(nextState) {
    const nextMarkdown = typeof nextState.markdown === "string" ? nextState.markdown : "";
    const nextTheme = nextState.theme === "dark" ? "dark" : "light";
    const nextDocumentID = typeof nextState.documentID === "string" ? nextState.documentID : "";
    const parsedRenderID = Number(nextState.renderID);
    const nextRenderID = Number.isSafeInteger(parsedRenderID) && parsedRenderID >= 0 ? parsedRenderID : 0;
    const wantsEditing = nextState.editable === true && window.MonknotEditor;
    if (!wantsEditing && editor()) window.MonknotEditor.deactivate();
    if (hasRendered
        && !wantsEditing
        && nextMarkdown === markdown
        && document.documentElement.dataset.theme === nextTheme
        && nextDocumentID === documentID
        && nextRenderID === renderID) {
      return;
    }

    markdown = nextMarkdown;
    documentID = nextDocumentID;
    renderID = nextRenderID;
    document.documentElement.dataset.theme = nextTheme;
    if (wantsEditing) {
      window.MonknotEditor.activate(target, {
        markdown: nextMarkdown,
        documentID: nextDocumentID,
        renderID: nextRenderID,
        selection: nextState.selection || null,
        focus: nextState.focus === true
      });
    } else {
      target.innerHTML = renderMarkdown(markdown);
    }
    hasRendered = true;
    scheduleReadingAnchor();
    if (searchQuery) {
      searchDocument({
        query: searchQuery,
        ...searchOptions,
        navigationSerial: searchNavigationSerial,
        direction: "current",
        isPresented: true
      });
    }
  }

  function currentIdentity() {
    return { documentID, renderID };
  }

  function postInteraction(action, payload = {}) {
    if (!documentID || !Number.isSafeInteger(renderID) || renderID < 1) return;
    window.webkit?.messageHandlers?.monknotInteraction?.postMessage({
      action,
      documentID,
      renderID,
      ...payload
    });
  }

  /// A table of contents entry scrolls to its heading, in Preview and while editing alike.
  function scrollToHeading(anchor) {
    const index = Number(anchor.dataset.mkToc);
    const headings = Array.from(target.querySelectorAll(":scope > h1, :scope > h2, :scope > h3"));
    const heading = Number.isInteger(index) ? headings[index] : null;
    heading?.scrollIntoView({ block: "start", behavior: "smooth" });
    return heading || null;
  }
  window.monknotScrollToHeading = scrollToHeading;

  function handleInteraction(event) {
    const tocAnchor = event.target instanceof Element ? event.target.closest("a[data-mk-toc]") : null;
    if (tocAnchor) {
      event.preventDefault();
      event.stopPropagation();
      scrollToHeading(tocAnchor);
      return;
    }
    if (editor()) return;
    const targetElement = event.target instanceof Element ? event.target : event.target?.parentElement;
    if (!targetElement) return;

    const task = targetElement.closest('input[type="checkbox"][data-monknot-task]');
    if (task) {
      event.preventDefault();
      event.stopPropagation();
      const expectedChecked = task.dataset.taskChecked === "true";
      task.checked = expectedChecked;
      const sourceLine = Number(task.dataset.sourceLine || task.closest("[data-source-line]")?.dataset.sourceLine || "0");
      if (!Number.isSafeInteger(sourceLine) || sourceLine < 1) return;
      postInteraction("task", {
        sourceLine,
        expectedChecked,
        desiredChecked: !expectedChecked
      });
      return;
    }

    const anchor = targetElement.closest("a");
    if (!anchor) return;
    const href = anchor.getAttribute("href") || "";
    if (anchor.classList.contains("footnote-backref")
        || anchor.closest(".footnote-ref")
        || href.startsWith("#fn-")
        || href.startsWith("#fnref-")) {
      return;
    }

    const destination = anchor.dataset.monknotDestination || href;
    if (!destination) return;
    event.preventDefault();
    event.stopPropagation();
    postInteraction("link", {
      kind: anchor.dataset.monknotLinkKind === "wikilink" ? "wikilink" : "markdown",
      destination
    });
  }
  window.monknotPostLinkInteraction = (kind, destination) => postInteraction("link", { kind, destination });

  // The reading position survives a change of width (the window resized, a side pane opened):
  // the block at the top of the window stays where it was, rather than the text rewrapping under a
  // fixed scroll offset and sliding out of view.
  function scheduleReadingAnchor() {
    if (readingAnchorFrame || typeof window.setTimeout !== "function") return;
    readingAnchorFrame = window.setTimeout(() => {
      readingAnchorFrame = 0;
      recordReadingAnchor();
    }, 50);
  }

  function recordReadingAnchor() {
    const scroller = document.scrollingElement || document.documentElement;
    if (scroller.scrollTop <= 1) {
      readingAnchor = { atTop: true };
      return;
    }
    const blocks = target.children;
    let low = 0;
    let high = blocks.length - 1;
    let found = null;
    while (low <= high) {
      const middle = (low + high) >> 1;
      const rect = blocks[middle].getBoundingClientRect();
      if (rect.bottom <= 0) {
        low = middle + 1;
      } else {
        found = blocks[middle];
        high = middle - 1;
      }
    }
    readingAnchor = found ? { element: found, top: found.getBoundingClientRect().top } : null;
  }

  function keepReadingPosition() {
    if (window.innerWidth === readingWidth) return;
    readingWidth = window.innerWidth;
    const anchor = readingAnchor;
    if (!anchor) return;
    const scroller = document.scrollingElement || document.documentElement;
    if (anchor.atTop) {
      scroller.scrollTop = 0;
    } else if (anchor.element && anchor.element.isConnected) {
      scroller.scrollTop += anchor.element.getBoundingClientRect().top - anchor.top;
    }
    recordReadingAnchor();
  }

  function tearDown() {
    if (typeof window.removeEventListener === "function") {
      window.removeEventListener("scroll", scheduleReadingAnchor);
      window.removeEventListener("resize", keepReadingPosition);
    }
    target.removeEventListener("dblclick", handleSourceJump);
    target.removeEventListener("click", handleInteraction);
    if (window.MonknotEditor) window.MonknotEditor.deactivate();
    window.monknotTearDown = undefined;
  }

  function applyAppearance(nextState) {
    const restoreScroll = captureScrollAnchor();
    const theme = nextState.theme === "dark" ? "dark" : "light";
    document.documentElement.dataset.theme = theme;
    document.documentElement.style.colorScheme = theme;

    if (nextState.variables && typeof nextState.variables === "object") {
      Object.entries(nextState.variables).forEach(([key, value]) => {
        if (typeof key === "string" && key.startsWith("--") && typeof value === "string") {
          document.documentElement.style.setProperty(key, value);
        }
      });
    }

    restoreScroll();
  }

  function searchDocument(nextState = {}) {
    const requestedQuery = nextState.isPresented === false
      ? ""
      : typeof nextState.query === "string"
        ? nextState.query.trim()
        : "";
    const navigationSerial = Number.isFinite(Number(nextState.navigationSerial))
      ? Number(nextState.navigationSerial)
      : searchNavigationSerial;
    const direction = nextState.direction === "previous" ? "previous" : nextState.direction === "next" ? "next" : "current";
    const requestedOptions = {
      isCaseSensitive: nextState.isCaseSensitive === true,
      isWholeWord: nextState.isWholeWord === true
    };
    const queryChanged = requestedQuery !== searchQuery
      || requestedOptions.isCaseSensitive !== searchOptions.isCaseSensitive
      || requestedOptions.isWholeWord !== searchOptions.isWholeWord;
    const navigationChanged = navigationSerial !== searchNavigationSerial;

    searchQuery = requestedQuery;
    searchOptions = requestedOptions;
    removeSearchHighlights();

    if (!searchQuery) {
      searchMatches = [];
      searchCurrentIndex = 0;
      searchNavigationSerial = navigationSerial;
      return searchResult();
    }

    searchMatches = highlightSearchMatches(searchQuery, searchOptions);

    if (searchMatches.length === 0) {
      searchCurrentIndex = 0;
      searchNavigationSerial = navigationSerial;
      return searchResult();
    }

    if (queryChanged || searchCurrentIndex >= searchMatches.length) {
      searchCurrentIndex = 0;
    } else if (navigationChanged) {
      searchCurrentIndex = direction === "previous"
        ? (searchCurrentIndex - 1 + searchMatches.length) % searchMatches.length
        : (searchCurrentIndex + 1) % searchMatches.length;
    }

    searchNavigationSerial = navigationSerial;
    revealCurrentSearchMatch(queryChanged || navigationChanged);
    return searchResult();
  }
  window.monknotRefreshSearch = () => {
    if (!searchQuery) return;
    searchDocument({ query: searchQuery, ...searchOptions, navigationSerial: searchNavigationSerial, direction: "current", isPresented: true });
  };

  function searchResult() {
    return {
      currentIndex: searchMatches.length > 0 ? searchCurrentIndex + 1 : 0,
      totalCount: searchMatches.length
    };
  }

  /// Highlights in the editor use the CSS highlight registry, which marks
  /// ranges without changing the page the user is typing into.
  function usesHighlightRegistry() {
    return Boolean(editor() && window.CSS && CSS.highlights && typeof Highlight === "function");
  }

  function removeSearchHighlights() {
    if (window.CSS && CSS.highlights) {
      CSS.highlights.delete("monknot-search");
      CSS.highlights.delete("monknot-search-current");
    }
    const parents = new Set();
    target.querySelectorAll("mark.monknot-search-match").forEach((mark) => {
      const parent = mark.parentNode;
      if (!parent) return;
      parents.add(parent);
      mark.replaceWith(document.createTextNode(mark.textContent || ""));
    });
    parents.forEach((parent) => parent.normalize());
  }

  function highlightSearchMatches(query, options) {
    const matches = [];
    const nodes = textNodesForSearch();
    const registry = usesHighlightRegistry();

    for (const node of nodes) {
      const value = node.nodeValue || "";
      const ranges = matchingSearchRanges(value, query, options);
      if (ranges.length === 0) continue;

      if (registry) {
        for (const range of ranges) {
          const domRange = document.createRange();
          domRange.setStart(node, range.start);
          domRange.setEnd(node, range.end);
          matches.push(domRange);
        }
        continue;
      }

      let cursor = 0;
      const fragment = document.createDocumentFragment();
      for (const range of ranges) {
        if (range.start > cursor) {
          fragment.appendChild(document.createTextNode(value.slice(cursor, range.start)));
        }

        const mark = document.createElement("mark");
        mark.className = "monknot-search-match";
        mark.textContent = value.slice(range.start, range.end);
        fragment.appendChild(mark);
        matches.push(mark);

        cursor = range.end;
      }

      if (cursor < value.length) {
        fragment.appendChild(document.createTextNode(value.slice(cursor)));
      }

      node.parentNode?.replaceChild(fragment, node);
    }

    return matches;
  }

  function matchingSearchRanges(value, query, options) {
    const source = foldSearchText(value, options.isCaseSensitive);
    const needle = foldSearchText(query, options.isCaseSensitive).text;
    if (!needle) return [];

    const ranges = [];
    let cursor = 0;
    let index = source.text.indexOf(needle, cursor);
    while (index >= 0) {
      const lastFoldedIndex = index + needle.length - 1;
      const start = source.starts[index];
      const end = source.ends[lastFoldedIndex];
      if (Number.isSafeInteger(start)
          && Number.isSafeInteger(end)
          && end > start
          && (!options.isWholeWord || isWholeWordRange(value, start, end))) {
        const previous = ranges[ranges.length - 1];
        if (!previous || previous.start !== start || previous.end !== end) {
          ranges.push({ start, end });
        }
      }
      cursor = index + needle.length;
      index = source.text.indexOf(needle, cursor);
    }
    return ranges;
  }

  function foldSearchText(value, isCaseSensitive) {
    const text = typeof value === "string" ? value : "";
    const starts = [];
    const ends = [];
    let folded = "";
    let segments;
    if (typeof Intl.Segmenter === "function") {
      segments = Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text));
    } else {
      segments = [];
      let index = 0;
      for (const segment of text) {
        segments.push({ segment, index });
        index += segment.length;
      }
    }

    for (const item of segments) {
      const start = item.index;
      const end = start + item.segment.length;
      let token = item.segment.normalize("NFD").replace(/\p{M}/gu, "");
      if (!isCaseSensitive) token = token.toLocaleLowerCase();
      folded += token;
      for (let offset = 0; offset < token.length; offset += 1) {
        starts.push(start);
        ends.push(end);
      }
    }
    return { text: folded, starts, ends };
  }

  function isWholeWordRange(value, start, end) {
    return !isWordCharacter(previousScalar(value, start))
      && !isWordCharacter(nextScalar(value, end));
  }

  function previousScalar(value, index) {
    if (index <= 0) return "";
    let start = index - 1;
    const unit = value.charCodeAt(start);
    if (unit >= 0xDC00 && unit <= 0xDFFF && start > 0) {
      const previous = value.charCodeAt(start - 1);
      if (previous >= 0xD800 && previous <= 0xDBFF) start -= 1;
    }
    return value.slice(start, index);
  }

  function nextScalar(value, index) {
    if (index >= value.length) return "";
    const first = value.charCodeAt(index);
    const length = first >= 0xD800 && first <= 0xDBFF ? 2 : 1;
    return value.slice(index, index + length);
  }

  function isWordCharacter(value) {
    return typeof value === "string" && /[\p{L}\p{N}\p{M}\p{Pc}]/u.test(value);
  }

  function textNodesForSearch() {
    const nodes = [];
    const walker = document.createTreeWalker(
      target,
      NodeFilter.SHOW_TEXT,
      {
        acceptNode(node) {
          const value = node.nodeValue || "";
          if (!value.trim()) return NodeFilter.FILTER_REJECT;

          const parent = node.parentElement;
          if (!parent) return NodeFilter.FILTER_REJECT;
          if (parent.closest("script, style, mark.monknot-search-match, [data-mk-skip], .mk-menu-layer")) {
            return NodeFilter.FILTER_REJECT;
          }

          return NodeFilter.FILTER_ACCEPT;
        }
      }
    );

    while (walker.nextNode()) {
      nodes.push(walker.currentNode);
    }

    return nodes;
  }

  function revealCurrentSearchMatch(shouldScroll) {
    if (searchMatches.length && !(searchMatches[0] instanceof Element)) {
      CSS.highlights.set("monknot-search", new Highlight(...searchMatches.filter((_, index) => index !== searchCurrentIndex)));
      const currentRange = searchMatches[searchCurrentIndex];
      if (currentRange) CSS.highlights.set("monknot-search-current", new Highlight(currentRange));
      if (shouldScroll && currentRange) {
        const element = currentRange.startContainer.parentElement;
        element?.scrollIntoView({ block: "center", inline: "nearest", behavior: "smooth" });
      }
      return;
    }

    searchMatches.forEach((match, index) => {
      match.classList.toggle("monknot-search-current", index === searchCurrentIndex);
    });

    const current = searchMatches[searchCurrentIndex];
    if (shouldScroll && current) {
      current.scrollIntoView({ block: "center", inline: "nearest", behavior: "smooth" });
    }
  }

  function revealSourceLine(nextState = {}) {
    return scrollToSourceLine(nextState, { highlight: true });
  }

  function sourceLineElements() {
    const active = editor();
    if (active) return active.sourceLineElements();
    return Array.from(target.querySelectorAll("[data-source-line]")).map((element) => ({
      element,
      line: Number(element.dataset.sourceLine || "0")
    }));
  }

  function scrollToSourceLine(nextState = {}, options = {}) {
    const line = Number(nextState.line || 0);
    if (!Number.isFinite(line) || line < 1) return false;

    const sourceElements = sourceLineElements();
    if (sourceElements.length === 0) return false;

    let bestElement = null;
    let bestLine = 0;
    let nextElement = null;
    let nextLine = Number.MAX_SAFE_INTEGER;

    for (const { element, line: sourceLine } of sourceElements) {
      if (!Number.isFinite(sourceLine) || sourceLine < 1) continue;

      if (sourceLine <= line && sourceLine >= bestLine) {
        bestElement = element;
        bestLine = sourceLine;
      } else if (sourceLine > line && sourceLine < nextLine) {
        nextElement = element;
        nextLine = sourceLine;
      }
    }

    const targetElement = bestElement || nextElement;
    if (!targetElement) return false;

    if (options.highlight) {
      target.querySelectorAll(".monknot-source-reveal").forEach((element) => {
        element.classList.remove("monknot-source-reveal");
      });
      targetElement.classList.add("monknot-source-reveal");
      window.setTimeout(() => {
        targetElement.classList.remove("monknot-source-reveal");
      }, 1400);
    }

    if (line === 1) {
      const scroller = document.scrollingElement || document.documentElement;
      scroller.scrollTop = 0;
      return true;
    }

    targetElement.scrollIntoView({
      block: "start",
      inline: "nearest",
      behavior: options.highlight ? "smooth" : "auto"
    });

    return true;
  }

  function visibleSourceLine() {
    const probeY = Math.max(0, (window.scrollY || 0) + 12);
    const elements = sourceLineElements();
    let bestLine = 1;

    for (const { element, line: sourceLine } of elements) {
      if (!Number.isFinite(sourceLine) || sourceLine < 1) continue;
      const top = element.getBoundingClientRect().top + (window.scrollY || 0);
      if (top <= probeY && sourceLine >= bestLine) {
        bestLine = sourceLine;
      }
    }

    return bestLine;
  }

  function captureScrollAnchor() {
    const scroller = document.scrollingElement || document.documentElement;
    const wasAtTop = scroller.scrollTop <= 1;
    const maxBefore = Math.max(1, scroller.scrollHeight - window.innerHeight);
    const ratio = scroller.scrollTop / maxBefore;
    const pointX = Math.max(1, Math.floor(window.innerWidth / 2));
    const pointY = Math.max(1, Math.min(window.innerHeight - 1, Math.floor(window.innerHeight / 2)));
    const anchor = document.elementFromPoint(pointX, pointY);
    const anchorTop = anchor?.getBoundingClientRect().top;

    return () => {
      requestAnimationFrame(() => {
        if (wasAtTop) {
          scroller.scrollTop = 0;
          return;
        }

        if (anchor && anchor.isConnected && Number.isFinite(anchorTop)) {
          const nextTop = anchor.getBoundingClientRect().top;
          scroller.scrollTop += nextTop - anchorTop;
          return;
        }

        const maxAfter = Math.max(0, scroller.scrollHeight - window.innerHeight);
        scroller.scrollTop = ratio * maxAfter;
      });
    };
  }

  function handleSourceJump(event) {
    if (editor()) return;
    const targetElement = event.target instanceof Element ? event.target : event.target?.parentElement;
    if (targetElement?.closest("a, button, input")) return;
    const quoteElement = targetElement?.closest("blockquote[data-source-line]");
    const sourceElement = quoteElement || targetElement?.closest("[data-source-line]");

    const line = sourceElement ? Number(sourceElement.dataset.sourceLine || "0") : estimateSourceLine(event);
    if (!Number.isFinite(line) || line < 1) return;

    event.preventDefault();
    window.webkit?.messageHandlers?.monknotSourceJump?.postMessage({
      line,
      offset: 0,
      documentID,
      renderID
    });
  }

  function estimateSourceLine(event) {
    const rect = target.getBoundingClientRect();
    const lineCount = Math.max(1, markdown.replace(/\r\n?/g, "\n").split("\n").length);
    const ratio = rect.height > 0 ? Math.min(1, Math.max(0, (event.clientY - rect.top) / rect.height)) : 0;
    return Math.max(1, Math.round(ratio * lineCount));
  }
})();
