(() => {
  "use strict";

  // =====================================================================
  // Visual Markdown editor
  //
  // The Markdown source is the only document. The page is a rendering of it,
  // and every edit on the page becomes one text patch on the source: a range
  // and its replacement. Nothing is ever converted back from HTML, so
  // Markdown the editor does not understand is kept exactly as written.
  // =====================================================================

  const MD = window.MonknotMarkdown;
  if (!MD) return;

  // ---------------------------------------------------------------------
  // Model
  // ---------------------------------------------------------------------

  function detectEol(source) {
    if (source.indexOf("\r\n") >= 0) return "\r\n";
    const lf = source.indexOf("\n");
    const cr = source.indexOf("\r");
    if (cr >= 0 && (lf < 0 || cr < lf)) return "\r";
    return "\n";
  }

  function createModel(source) {
    const doc = MD.parseDocument(source, { editing: true });
    const model = {
      source,
      doc,
      blocks: doc.blocks,
      units: new Map(),
      unitSequence: 0,
      eol: detectEol(source),
      hasCR: doc.hasCR
    };
    renderBlocks(model, model.blocks);
    return model;
  }

  /// Renders top-level blocks just parsed. `block.units` holds every unit inside the block, and each
  /// unit's `top` is the top-level block it is in.
  function renderBlocks(model, blocks) {
    const render = MD.newRender(model.doc, { editing: true, unitSequence: model.unitSequence });
    for (const block of blocks) {
      linkNodes(block, null);
      const first = render.units.length;
      block.html = MD.renderBlock(block, render, null);
      block.units = render.units.slice(first);
      for (const unit of block.units) {
        unit.top = block;
        model.units.set(unit.id, unit);
      }
    }
    model.unitSequence = render.unitSequence;
  }

  // Every node (a block at any depth, or a list item) keeps the offsets and line numbers it was
  // parsed with. `shift` and `lineShift` say how far its text has moved since, on top of what its
  // `parent` moved, so an edit moves everything after it by changing a few of those numbers.

  const NO_NODES = [];

  /// The nodes right under one: a quote's or toggle's blocks, a list's items, an item's lists.
  function childNodes(node) {
    return node.items || node.children || NO_NODES;
  }

  function linkNodes(node, parent) {
    node.parent = parent;
    node.shift = 0;
    node.lineShift = 0;
    for (const child of childNodes(node)) linkNodes(child, node);
  }

  function nodeShift(node) {
    let shift = 0;
    for (let current = node; current; current = current.parent) shift += current.shift;
    return shift;
  }

  function nodeLineShift(node) {
    let shift = 0;
    for (let current = node; current; current = current.parent) shift += current.lineShift;
    return shift;
  }

  /// Where `offset`, read from `node`'s fields, is in the source now.
  const atNode = (node, offset) => offset + nodeShift(node);
  const bStart = (block) => block.start + nodeShift(block);
  const bEnd = (block) => block.end + nodeShift(block);
  const bLine = (block) => block.line + nodeLineShift(block);
  /// The node a unit's region and fields are read from: its list item, or its block.
  const ownerOf = (unit) => unit.item || unit.block;
  const S = (unit, offset) => offset + nodeShift(ownerOf(unit));

  /// Where an item's text and the items nested under it end.
  function itemSubtreeEnd(item) {
    const end = atNode(item, item.end);
    const last = item.children[item.children.length - 1];
    return last ? Math.max(end, bEnd(last)) : end;
  }

  function nodeStart(node) {
    return node.type ? bStart(node) : atNode(node, node.view.start);
  }

  function nodeEnd(node) {
    return node.type ? bEnd(node) : itemSubtreeEnd(node);
  }

  function nodeLine(node) {
    return node.type ? bLine(node) : node.view.line + nodeLineShift(node);
  }

  function countLineBreaks(text) {
    const matches = text.match(/\r\n|\r|\n/g);
    return matches ? matches.length : 0;
  }

  /// Index of the first block that ends at or after `offset`.
  function firstBlockEndingAtOrAfter(blocks, offset) {
    let low = 0;
    let high = blocks.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (bEnd(blocks[middle]) < offset) low = middle + 1;
      else high = middle;
    }
    return low;
  }

  /// Index of the last block that starts at or before `offset`, or -1.
  function lastBlockStartingAtOrBefore(blocks, offset) {
    let low = 0;
    let high = blocks.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (bStart(blocks[middle]) <= offset) low = middle + 1;
      else high = middle;
    }
    return low - 1;
  }

  function blockIndex(model, block) {
    const index = lastBlockStartingAtOrBefore(model.blocks, bStart(block));
    for (let candidate = index; candidate >= 0 && bStart(model.blocks[candidate]) === bStart(block); candidate -= 1) {
      if (model.blocks[candidate] === block) return candidate;
    }
    return model.blocks.indexOf(block);
  }

  function blockText(source, block) {
    return source.slice(bStart(block), bEnd(block));
  }

  function sameBlock(oldBlock, oldSource, newBlock, newSource, delta) {
    if (oldBlock.type !== newBlock.type) return false;
    if (bStart(oldBlock) + delta !== newBlock.start) return false;
    if (oldBlock.type === "empty") {
      return oldBlock.position === newBlock.position
        && Boolean(oldBlock.view) === Boolean(newBlock.view)
        && oldBlock.needsSeparatorBefore === newBlock.needsSeparatorBefore
        && oldBlock.needsSeparatorAfter === newBlock.needsSeparatorAfter
        && bEnd(oldBlock) + delta === newBlock.end;
    }
    // The line break after a block decides where text typed into an empty
    // code block goes, so it has to match too.
    const oldEnd = bEnd(oldBlock);
    const oldBreak = oldSource.slice(oldEnd, Math.min(oldSource.length, oldEnd + 2)).replace(/^(\r\n|\r|\n).*$/s, "$1");
    const newBreak = newSource.slice(newBlock.end, Math.min(newSource.length, newBlock.end + 2)).replace(/^(\r\n|\r|\n).*$/s, "$1");
    return (/^[\r\n]/.test(oldBreak) ? oldBreak : "") === (/^[\r\n]/.test(newBreak) ? newBreak : "")
      && blockText(oldSource, oldBlock) === newSource.slice(newBlock.start, newBlock.end);
  }

  /// Applies `insert` over [from, to) and re-parses only the blocks the change
  /// can affect. Returns what changed so the page can replace just those blocks:
  /// top-level blocks, or with `container` set, the blocks or items right under it.
  function applyPatch(model, from, to, insert) {
    const oldSource = model.source;
    const source = oldSource.slice(0, from) + insert + oldSource.slice(to);
    const delta = insert.length - (to - from);
    // Count line breaks one character past each edge, so a patch that splits
    // or joins a CRLF pair still counts lines right.
    const windowStart = Math.max(0, from - 1);
    const lineDelta = countLineBreaks(source.slice(windowStart, Math.min(source.length, from + insert.length + 1)))
      - countLineBreaks(oldSource.slice(windowStart, Math.min(oldSource.length, to + 1)));
    const blocks = model.blocks;
    const hasCR = model.hasCR || insert.indexOf("\r") >= 0;

    model.doc.source = source;
    const edit = { from, to, insertEnd: from + insert.length, delta, lineDelta, oldSource, source, hasCR };
    const inside = applyInside(model, edit);
    if (inside) {
      model.source = source;
      model.hasCR = hasCR;
      return inside;
    }

    const first = firstBlockEndingAtOrAfter(blocks, from);
    let restart = Math.min(first, blocks.length) - 1;
    while (restart >= 0 && blocks[restart].type === "empty") restart -= 1;
    const parseStart = restart >= 0 ? bStart(blocks[restart]) : 0;
    const parseLine = restart >= 0 ? bLine(blocks[restart]) : 0;
    const replaceFrom = Math.max(0, restart);

    const insertEnd = from + insert.length;
    let cursor = replaceFrom + 1;
    let resyncIndex = -1;
    const stop = (view) => {
      if (view.start < insertEnd) return false;
      const oldStart = view.start - delta;
      if (oldStart < to) return false;
      while (cursor < blocks.length && (blocks[cursor].type === "empty" || bStart(blocks[cursor]) < oldStart)) cursor += 1;
      if (cursor < blocks.length && bStart(blocks[cursor]) === oldStart) {
        resyncIndex = cursor;
        return true;
      }
      return false;
    };

    const reader = MD.streamReader(source, parseStart, parseLine, hasCR);
    const context = { definitions: true, top: true, editing: true, anchor: 0 };
    const added = MD.parseBlockList(reader, context, true, stop).blocks;
    const replaceTo = resyncIndex >= 0 ? resyncIndex : blocks.length;

    // Keep blocks whose text did not change, so the page keeps their elements.
    let keepFront = 0;
    while (keepFront < added.length
      && replaceFrom + keepFront < replaceTo
      && sameBlock(blocks[replaceFrom + keepFront], oldSource, added[keepFront], source, 0)
      && bEnd(blocks[replaceFrom + keepFront]) <= from) {
      keepFront += 1;
    }
    let keepBack = 0;
    while (keepBack < added.length - keepFront
      && replaceTo - keepBack - 1 >= replaceFrom + keepFront
      && bStart(blocks[replaceTo - keepBack - 1]) >= to
      && sameBlock(blocks[replaceTo - keepBack - 1], oldSource, added[added.length - keepBack - 1], source, delta)) {
      keepBack += 1;
    }

    const index = replaceFrom + keepFront;
    const removed = blocks.slice(index, replaceTo - keepBack);
    const inserted = added.slice(keepFront, added.length - keepBack);

    model.source = source;
    model.hasCR = hasCR;
    const isDefinition = (block) => block.type === "definition";
    if (removed.some(isDefinition) || inserted.some(isDefinition)) {
      const definitions = definitionsAfter(blocks, index, removed.length, inserted);
      if (!readsTheSame(model.doc, definitions)) {
        // A reference link or footnote mark anywhere may now read differently.
        rebuild(model, from, to, delta);
        return { full: true };
      }
      // Only a footnote's text changed, which the footnotes list alone shows.
      model.doc.footnotes = definitions.footnotes;
      model.doc.footnoteOrder = definitions.footnoteOrder;
    }

    for (const block of removed) {
      for (const unit of block.units || []) model.units.delete(unit.id);
    }
    carryToggleState(model, removed, inserted, from, to, delta);
    renderBlocks(model, inserted);
    blocks.splice(index, removed.length, ...inserted);
    for (let position = index + inserted.length; position < blocks.length; position += 1) {
      blocks[position].shift += delta;
      blocks[position].lineShift += lineDelta;
    }
    return { full: false, index, removed, inserted };
  }

  /// A toggle opened or closed on the page stays so when an edit inside it re-parses it: the
  /// state moves to the new toggle that starts where the old one did.
  function carryToggleState(model, removed, inserted, from, to, delta) {
    const states = new Map();
    const collect = (block) => {
      if (block.type === "toggle" && block.viewOpen !== undefined) {
        const start = bStart(block);
        if (start < from) states.set(start, block.viewOpen);
        else if (start >= to) states.set(start + delta, block.viewOpen);
      }
      for (const child of block.children || []) if (child.type === "toggle" || child.type === "quote") collect(child);
    };
    removed.forEach(collect);
    // A toggle just inserted from a menu opens, so its body is there to type into.
    if (model.pendingToggleOpen !== undefined && model.pendingToggleOpen !== null) {
      states.set(model.pendingToggleOpen, true);
      model.pendingToggleOpen = null;
    }
    if (states.size === 0) return;
    const assign = (block) => {
      if (block.type === "toggle" && states.has(block.start)) block.viewOpen = states.get(block.start);
      for (const child of block.children || []) if (child.type === "toggle" || child.type === "quote") assign(child);
    };
    inserted.forEach(assign);
  }

  /// The footnotes and link references once `inserted` takes the place of `count` blocks at `index`.
  function definitionsAfter(blocks, index, count, inserted) {
    const list = [];
    const add = (block) => {
      if (block.type === "definition") list.push(block);
    };
    for (let position = 0; position < index; position += 1) add(blocks[position]);
    inserted.forEach(add);
    for (let position = index + count; position < blocks.length; position += 1) add(blocks[position]);
    const definitions = { blocks: list };
    MD.collectDefinitions(definitions);
    return definitions;
  }

  /// Whether the text outside the definitions renders as before: every reference keeps its
  /// destination and title, and the same footnotes exist (a footnote's text shows only in the list).
  function readsTheSame(doc, next) {
    if (doc.references.size !== next.references.size || doc.footnotes.size !== next.footnotes.size) return false;
    for (const key of doc.footnotes.keys()) if (!next.footnotes.has(key)) return false;
    for (const [key, reference] of doc.references) {
      const other = next.references.get(key);
      if (!other || other.destination !== reference.destination || other.title !== reference.title) return false;
    }
    return true;
  }

  /// Parses and renders the whole source again after the change [from, to) of `delta` characters.
  /// Toggles keep their open state, and unit ids keep counting up, so none is used twice.
  function rebuild(model, from, to, delta) {
    const doc = MD.parseDocument(model.source, { editing: true });
    carryToggleState(model, model.blocks, doc.blocks, from, to, delta);
    Object.assign(model, { doc, blocks: doc.blocks, units: new Map(), eol: detectEol(model.source), hasCR: doc.hasCR });
    renderBlocks(model, model.blocks);
  }

  /// Parses and renders again each top-level block an edit inside it re-rendered in parts, for a
  /// page drawn whole. Its toggles keep their state; its units are new.
  function redrawStaleBlocks(model) {
    const blocks = model.blocks;
    const context = { definitions: true, top: true, editing: true, anchor: 0 };
    for (let index = 0; index < blocks.length; index += 1) {
      const old = blocks[index];
      if (old.html !== null) continue;
      const reader = MD.streamReader(model.source, parsedLineStart(model.source, bStart(old)), bLine(old), model.hasCR);
      const block = MD.parseBlockList(reader, context, true, (view, parsed) => parsed.length > 0).blocks[0];
      if (!block || block.type !== old.type || block.start !== bStart(old) || block.end !== bEnd(old)) {
        rebuild(model, 0, 0, 0);
        return;
      }
      for (const unit of old.units) model.units.delete(unit.id);
      carryToggleState(model, [old], [block], 0, 0, 0);
      renderBlocks(model, [block]);
      blocks[index] = block;
    }
  }

  // Edits inside a container -------------------------------------------
  //
  // An edit whose changed lines lie inside a toggle's body, a quote or a list re-parses only the
  // blocks or items there it can affect, resynchronising at the next one it left alone, as the top
  // level does between its blocks. Lines that would change where the container itself ends (a
  // `</details>`, a line without `>`) send the edit out to the level above.

  /// The start of the line holding `position`, as the parser splits lines (a CRLF is one break).
  function parsedLineStart(source, position) {
    let index = Math.max(0, Math.min(position, source.length));
    while (index > 0) {
      const code = source.charCodeAt(index - 1);
      if (code === 10 || (code === 13 && source.charCodeAt(index) !== 10)) break;
      index -= 1;
    }
    return index;
  }

  /// The start of the line after the one whose text ends at `end`.
  function lineAfter(source, end) {
    const code = source.charCodeAt(end);
    if (code === 13) return source.charCodeAt(end + 1) === 10 ? end + 2 : end + 1;
    return code === 10 ? end + 1 : end;
  }

  /// A line as a quote's blocks see it: without its `>` marker.
  function insideQuote(view) {
    const match = MD.patterns.quote.exec(view.text);
    const prefix = match ? match[0].length : 0;
    return { text: view.text.slice(prefix), start: view.start + prefix, end: view.end, next: view.next, line: view.line, prefixStart: view.start };
  }

  function seenThrough(quotes, view) {
    let seen = view;
    for (let index = 0; index < quotes.length; index += 1) seen = insideQuote(seen);
    return seen;
  }

  /// The quotes `node` sits in, outermost first.
  function quotesAround(node) {
    const quotes = [];
    for (let current = node.parent; current; current = current.parent) if (current.type === "quote") quotes.unshift(current);
    return quotes;
  }

  /// The source lines [start, end) as `quotes`' blocks see them: what the parser read them as.
  function linesInside(source, start, line, hasCR, end, quotes) {
    const raw = MD.streamReader(source, start, line, hasCR);
    const lines = [];
    return {
      at(index) {
        while (lines.length <= index) {
          const view = raw.at(lines.length);
          if (!view || view.start >= end) return null;
          lines.push(seenThrough(quotes, view));
        }
        return lines[index];
      }
    };
  }

  /// The source lines [start, end) as `node` reads them, from the source as it is now: a toggle's or
  /// quote's own lists of its lines are not kept up to date by edits re-parsed inside it.
  function nodeLines(model, node, start, end) {
    const reader = linesInside(model.source, start, 0, model.hasCR, end, quotesAround(node));
    const lines = [];
    for (let line = reader.at(0); line; line = reader.at(lines.length)) lines.push(line);
    return lines;
  }

  /// The lines the edit changed, as they were and as they are: whole lines, at least one past each
  /// end of the patch, less the ones at either end it left as they were.
  function changedLines(model, edit) {
    const { from, to, delta, oldSource, source } = edit;
    const start = parsedLineStart(oldSource, Math.max(0, from - 1));
    const oldReader = MD.streamReader(oldSource, start, 0, model.hasCR);
    const oldLines = [];
    for (let line = oldReader.at(0); line && line.start <= to; line = oldReader.at(oldLines.length)) oldLines.push(line);
    const oldEnd = oldLines.length ? oldLines[oldLines.length - 1].next : start;
    const newReader = MD.streamReader(source, start, 0, edit.hasCR);
    const newLines = [];
    for (let line = newReader.at(0); line && line.start < oldEnd + delta; line = newReader.at(newLines.length)) newLines.push(line);
    if ((newLines.length ? newLines[newLines.length - 1].next : start) !== oldEnd + delta) return null;
    const same = (a, b) => a.text === b.text && a.next - a.end === b.next - b.end;
    let lead = 0;
    while (lead < oldLines.length && lead < newLines.length && same(oldLines[lead], newLines[lead])) lead += 1;
    let tail = 0;
    while (tail < oldLines.length - lead && tail < newLines.length - lead
      && same(oldLines[oldLines.length - 1 - tail], newLines[newLines.length - 1 - tail])) tail += 1;
    const changedOld = oldLines.slice(lead, oldLines.length - tail);
    const changedNew = newLines.slice(lead, newLines.length - tail);
    if (changedOld.length === 0 && changedNew.length === 0) return null;
    const regionStart = lead > 0 ? oldLines[lead - 1].next : start;
    const regionEnd = tail > 0 ? oldLines[oldLines.length - tail].start : oldEnd;
    return { start: regionStart, oldEnd: regionEnd, oldLines: changedOld, newLines: changedNew };
  }

  /// The last of `nodes` whose first line starts at or before `position`, or null.
  function nodeOnLine(source, nodes, position) {
    let low = 0;
    let high = nodes.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (parsedLineStart(source, nodeStart(nodes[middle])) <= position) low = middle + 1;
      else high = middle;
    }
    return low > 0 ? nodes[low - 1] : null;
  }

  function firstNodeEndingAtOrAfter(nodes, offset) {
    let low = 0;
    let high = nodes.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (nodeEnd(nodes[middle]) < offset) low = middle + 1;
      else high = middle;
    }
    return low;
  }

  function lastNodeStartingAtOrBefore(nodes, offset) {
    let low = 0;
    let high = nodes.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (nodeStart(nodes[middle]) <= offset) low = middle + 1;
      else high = middle;
    }
    return low - 1;
  }

  /// Where a toggle's body lines or a quote's lines end, the line after them: a toggle's
  /// `</details>`, or the line after the last.
  function containerLinesEnd(source, node) {
    if (node.type === "toggle" && node.close) return parsedLineStart(source, atNode(node, node.close.start));
    return lineAfter(source, bEnd(node));
  }

  /// The containers holding the changed lines, outermost first, with the list items between a list
  /// and a list nested in it. Each one keeps its extent whatever the edit did to its lines.
  function containersHolding(model, edit, region) {
    const chain = [];
    let nodes = model.blocks;
    for (;;) {
      const node = nodeOnLine(model.source, nodes, region.start);
      if (!node) break;
      if (node.type && !holdsRegion(model, edit, node, region, chain)) break;
      chain.push(node);
      nodes = childNodes(node);
    }
    // An item at the end holds the lines in its own text, which its list re-parses.
    while (chain.length && !chain[chain.length - 1].type) chain.pop();
    return chain;
  }

  /// Whether the changed lines lie inside `node`'s blocks or items, and leave `node` where it is.
  function holdsRegion(model, edit, node, region, chain) {
    const source = model.source;
    const P = MD.patterns;
    const quotes = chain.filter((ancestor) => ancestor.type === "quote");
    const seen = (line) => seenThrough(quotes, line).text;
    const lines = region.oldLines.concat(region.newLines);
    // A quote or list starts after the `>` of the quotes around it on its first line: when that line
    // changed, those markers have to take as many characters as they did.
    const startStays = () => !quotes.length
      || (region.oldLines.length > 0 && region.newLines.length > 0
        && seenThrough(quotes, region.oldLines[0]).start === seenThrough(quotes, region.newLines[0]).start);
    if (node.type === "toggle") {
      if (node.children.length === 1 && node.children[0].virtual) return false;
      const bodyStart = lineAfter(source, atNode(node, node.summaryView.end));
      const bodyEnd = containerLinesEnd(source, node);
      if (region.start < bodyStart || region.oldEnd > bodyEnd) return false;
      if (region.start === bodyStart && region.oldEnd === bodyEnd && region.newLines.length === 0) return false;
      // A fence or a `<details>` line changes which `</details>` closes the toggle.
      return !lines.some((line) => {
        const text = seen(line);
        return P.fenceMarker.test(text) || P.detailsOpen.test(text) || P.detailsClose.test(text);
      });
    }
    if (node.type === "quote") {
      if (node.callout && node.children.some((child) => child.virtual)) return false;
      const first = parsedLineStart(source, bStart(node));
      if (region.start < first || region.oldEnd > lineAfter(source, bEnd(node))) return false;
      // The first line decides whether the quote is a callout.
      if (region.start === first && (node.callout || region.newLines.length === 0 || !startStays())) return false;
      if (!stillStarts(node, edit, first, quotes)) return false;
      // Every changed line stays quoted, and none reads as a callout's `[!KIND]` line, which after
      // a blank line would start a quote of its own.
      const quoted = (line) => {
        const text = seen(line);
        const match = P.quote.exec(text);
        return Boolean(match) && !P.callout.test(text.slice(match[0].length));
      };
      if (!lines.every(quoted)) return false;
      if (region.newLines.length === 0) {
        // Lines only went: the line now before the next one has to be quoted too.
        const before = parsedLineStart(source, region.start - 1);
        return quoted({ text: source.slice(before, lineEndOf(source, before)), start: before });
      }
      return true;
    }
    if (node.type === "list") {
      const first = parsedLineStart(source, bStart(node));
      if (region.start < first || region.oldEnd > lineAfter(source, bEnd(node))) return false;
      if (region.start === first) {
        // The first item's indent and marker make the list what it is, and a first line of hyphens
        // and pipes would make the line above it a table's header.
        if (!region.oldLines.length || !region.newLines.length) return false;
        const before = P.item.exec(seen(region.oldLines[0]));
        const after = P.item.exec(seen(region.newLines[0]));
        if (!before || !after || before[1] !== after[1] || before[2] !== after[2]) return false;
        if (MD.isTableDelimiter(seen(region.newLines[0])) || !startStays()) return false;
      }
      return stillStarts(node, edit, first, quotes);
    }
    return false;
  }

  /// Whether the parser still begins a quote or list at its first line after the edit: it reads a
  /// line with pipes over a row of hyphens as a table's header, and a list's `- - -` as a divider,
  /// before it looks for either.
  function stillStarts(node, edit, first, quotes) {
    const reader = linesInside(edit.source, first, 0, edit.hasCR, edit.source.length, quotes);
    const line = reader.at(0);
    if (!line || MD.isTableStart(reader, 0)) return false;
    return node.type !== "list" || !MD.patterns.thematic.test(line.text);
  }

  /// The parser's context for the blocks right under `chain[depth]`.
  function contextInside(chain, depth) {
    let context = { definitions: true, top: true, editing: true, anchor: 0 };
    for (let index = 0; index <= depth; index += 1) {
      const node = chain[index];
      if (node.type === "toggle") context = { ...context, definitions: false, top: false, separators: true, virtual: null };
      else if (node.type === "quote") context = { ...context, definitions: false, top: false, separators: false, virtual: null };
    }
    return context;
  }

  function applyInside(model, edit) {
    if (model.blocks.length === 0) return null;
    const region = changedLines(model, edit);
    if (!region) return null;
    const chain = containersHolding(model, edit, region);
    for (let depth = chain.length - 1; depth >= 0; depth -= 1) {
      const node = chain[depth];
      if (!node.type) continue;
      const parsed = node.type === "list"
        ? reparseItems(model, edit, region, chain, depth)
        : reparseBlocks(model, edit, chain, depth);
      if (parsed) return commitInside(model, edit, region, chain, depth, parsed);
    }
    return null;
  }

  /// The source end of the lines the blocks of `chain[depth]` were read from (the end of the
  /// toggle's body or the quote holding a list), after the edit.
  function linesEndAfter(model, edit, chain, depth) {
    for (let index = depth; index >= 0; index -= 1) {
      const node = chain[index];
      if (node.type === "toggle" || node.type === "quote") return containerLinesEnd(model.source, node) + edit.delta;
    }
    return edit.source.length;
  }

  /// Re-parses the blocks of the toggle or quote `chain[depth]` from the block before the edit.
  function reparseBlocks(model, edit, chain, depth) {
    const container = chain[depth];
    const kids = container.children;
    const { from, to, delta, insertEnd } = edit;
    const source = model.source;
    const first = firstNodeEndingAtOrAfter(kids, from);
    let restart = Math.min(first, kids.length) - 1;
    while (restart >= 0 && kids[restart].type === "empty") restart -= 1;
    let parseStart;
    let parseLine;
    if (restart >= 0) {
      parseStart = parsedLineStart(source, bStart(kids[restart]));
      parseLine = bLine(kids[restart]);
    } else if (container.type === "toggle") {
      parseStart = lineAfter(source, atNode(container, container.summaryView.end));
      parseLine = container.summaryView.line + nodeLineShift(container) + 1;
    } else {
      parseStart = parsedLineStart(source, bStart(container));
      parseLine = bLine(container);
      if (container.callout) {
        parseStart = lineAfter(source, atNode(container, container.callout.marker.end));
        parseLine += 1;
      }
    }
    const replaceFrom = Math.max(0, restart);
    let cursor = replaceFrom + 1;
    let resync = -1;
    const stop = (view) => {
      if (view.start < insertEnd) return false;
      const oldStart = view.start - delta;
      if (oldStart < to) return false;
      while (cursor < kids.length && (kids[cursor].type === "empty" || bStart(kids[cursor]) < oldStart)) cursor += 1;
      if (cursor < kids.length && bStart(kids[cursor]) === oldStart) {
        resync = cursor;
        return true;
      }
      return false;
    };
    const quotes = chain.slice(0, depth + 1).filter((node) => node.type === "quote");
    const reader = linesInside(edit.source, parseStart, parseLine, edit.hasCR, linesEndAfter(model, edit, chain, depth), quotes);
    const added = MD.parseBlockList(reader, contextInside(chain, depth), false, stop).blocks;
    const replaceTo = resync >= 0 ? resync : kids.length;
    let keepFront = 0;
    while (keepFront < added.length
      && replaceFrom + keepFront < replaceTo
      && sameBlock(kids[replaceFrom + keepFront], edit.oldSource, added[keepFront], edit.source, 0)
      && bEnd(kids[replaceFrom + keepFront]) <= from) {
      keepFront += 1;
    }
    let keepBack = 0;
    while (keepBack < added.length - keepFront
      && replaceTo - keepBack - 1 >= replaceFrom + keepFront
      && bStart(kids[replaceTo - keepBack - 1]) >= to
      && sameBlock(kids[replaceTo - keepBack - 1], edit.oldSource, added[added.length - keepBack - 1], edit.source, delta)) {
      keepBack += 1;
    }
    const index = replaceFrom + keepFront;
    return { index, removed: kids.slice(index, replaceTo - keepBack), inserted: added.slice(keepFront, added.length - keepBack) };
  }

  /// Re-parses the items of the list `chain[depth]` from the item holding the line before the edit.
  /// Null when the list would end anywhere else: the level above re-parses it then.
  function reparseItems(model, edit, region, chain, depth) {
    const list = chain[depth];
    const items = list.items;
    const { from, to, delta, insertEnd } = edit;
    const source = model.source;
    const restart = region.start > parsedLineStart(source, bStart(list))
      ? Math.max(0, lastNodeStartingAtOrBefore(items, region.start - 1))
      : 0;
    let cursor = restart + 1;
    let resync = -1;
    const stop = (view) => {
      if (view.start < insertEnd) return false;
      const oldStart = view.start - delta;
      if (oldStart < to) return false;
      while (cursor < items.length && nodeStart(items[cursor]) < oldStart) cursor += 1;
      if (cursor < items.length && nodeStart(items[cursor]) === oldStart) {
        resync = cursor;
        return true;
      }
      return false;
    };
    const quotes = chain.slice(0, depth).filter((node) => node.type === "quote");
    const linesEnd = linesEndAfter(model, edit, chain, depth);
    const reader = linesInside(edit.source, parsedLineStart(source, nodeStart(items[restart])), nodeLine(items[restart]), edit.hasCR, linesEnd, quotes);
    const parsed = MD.parseList(reader, 0, contextInside(chain, depth), { baseIndent: items[0].indent, ordered: list.ordered, stop });
    if (!parsed.stopped) {
      // The list has to end before the same line as it did.
      const next = reader.at(parsed.next);
      const after = next ? parsedLineStart(edit.source, next.start) : linesEnd;
      if (after !== lineAfter(source, bEnd(list)) + delta) return null;
    }
    const added = parsed.list.items;
    const replaceTo = resync >= 0 ? resync : items.length;
    const subtreeEnd = (item) => (item.children.length ? Math.max(item.end, item.children[item.children.length - 1].end) : item.end);
    const sameItem = (old, item, shift) => nodeStart(old) + shift === item.view.start
      && edit.oldSource.slice(nodeStart(old), nodeEnd(old)) === edit.source.slice(item.view.start, subtreeEnd(item));
    let keepFront = 0;
    while (keepFront < added.length
      && restart + keepFront < replaceTo
      && nodeEnd(items[restart + keepFront]) <= from
      && sameItem(items[restart + keepFront], added[keepFront], 0)) {
      keepFront += 1;
    }
    let keepBack = 0;
    while (keepBack < added.length - keepFront
      && replaceTo - keepBack - 1 >= restart + keepFront
      && nodeStart(items[replaceTo - keepBack - 1]) >= to
      && sameItem(items[replaceTo - keepBack - 1], added[added.length - keepBack - 1], delta)) {
      keepBack += 1;
    }
    const index = restart + keepFront;
    return { index, removed: items.slice(index, replaceTo - keepBack), inserted: added.slice(keepFront, added.length - keepBack) };
  }

  /// Puts re-parsed nodes in place of `removed` under `chain[depth]`, renders them, and moves
  /// everything after them by the edit.
  function commitInside(model, edit, region, chain, depth, parsed) {
    const { index, removed, inserted } = parsed;
    const { from, to, delta, lineDelta } = edit;
    const source = model.source;
    const container = chain[depth];
    const top = chain[0];
    const kids = childNodes(container);

    // How a toggle's or quote's last line ends now: further along by the edit, or where the last
    // changed line ends when it was that line.
    const endAfter = (node) => {
      const end = bEnd(node);
      if (parsedLineStart(source, end) >= region.oldEnd) return node.end + delta;
      const last = region.newLines[region.newLines.length - 1];
      const now = last ? last.end : lineEndOf(edit.source, parsedLineStart(edit.source, region.start - 1));
      return now - nodeShift(node);
    };
    const ends = new Map();
    for (let level = 0; level <= depth; level += 1) {
      const node = chain[level];
      if (node.type === "toggle" || node.type === "quote") ends.set(node, endAfter(node));
    }

    // The removed nodes' units: a run of the top block's, which are in the order they render in.
    const units = top.units;
    const removedSet = new Set(removed);
    const childOf = (unit) => {
      for (let node = ownerOf(unit); node; node = node.parent) if (node.parent === container) return node;
      return null;
    };
    const anchor = removed[0] || kids[index] || null;
    let firstUnit;
    if (anchor) {
      firstUnit = unitsFrom(units, nodeStart(anchor), false);
      // An empty code block's unit waits at the start of the line after it, which can be where the
      // next block starts: that unit still belongs before.
      while (firstUnit < units.length) {
        const child = childOf(units[firstUnit]);
        if (!child || child === anchor || removedSet.has(child) || nodeStart(child) >= nodeStart(anchor)) break;
        firstUnit += 1;
      }
    } else {
      firstUnit = unitsFrom(units, nodeEnd(container), true);
    }
    let lastUnit = firstUnit;
    while (lastUnit < units.length && removedSet.has(childOf(units[lastUnit]))) lastUnit += 1;
    const removedUnits = units.slice(firstUnit, lastUnit);

    carryToggleState(model, removed, inserted, from, to, delta);

    const base = nodeShift(container);
    const lineBase = nodeLineShift(container);
    for (const node of inserted) {
      linkNodes(node, container);
      node.shift = -base;
      node.lineShift = -lineBase;
    }
    spliceInPlace(kids, index, removed.length, inserted);
    for (let position = index + inserted.length; position < kids.length; position += 1) {
      kids[position].shift += delta;
      kids[position].lineShift += lineDelta;
    }
    // Then each container up to the top: what follows the edit in it moves, and it ends further on.
    for (let level = depth; level >= 0; level -= 1) {
      const node = chain[level];
      if (level < depth) {
        const siblings = childNodes(node);
        for (let position = siblings.indexOf(chain[level + 1]) + 1; position < siblings.length; position += 1) {
          siblings[position].shift += delta;
          siblings[position].lineShift += lineDelta;
        }
      }
      if (node.type === "list") {
        node.end = itemSubtreeEnd(node.items[node.items.length - 1]) - nodeShift(node);
      } else if (ends.has(node)) {
        node.end = ends.get(node);
        if (node.type === "toggle" && node.close) {
          const close = node.close;
          node.close = { ...close, start: close.start + delta, end: close.end + delta, next: close.next + delta, line: close.line + lineDelta };
        }
      }
    }
    const blocks = model.blocks;
    for (let position = blockIndex(model, top) + 1; position < blocks.length; position += 1) {
      blocks[position].shift += delta;
      blocks[position].lineShift += lineDelta;
    }

    // Rendered once everything is where it is now: a table of contents reads the headings after it.
    const render = MD.newRender(model.doc, { editing: true, unitSequence: model.unitSequence });
    let scope = null;
    let outer = null;
    for (let level = depth; level >= 0 && (!scope || !outer); level -= 1) {
      const node = chain[level];
      if (!scope && node.type === "toggle") scope = node;
      if (!outer && level < depth && (node.type === "toggle" || node.type === "quote")) outer = node;
    }
    render.scope = scope;
    for (const node of inserted) {
      node.html = container.type === "list"
        ? MD.renderListItem(node, container, render, outer)
        : MD.renderBlock(node, render, container);
    }
    for (const unit of removedUnits) model.units.delete(unit.id);
    for (const unit of render.units) {
      unit.top = top;
      model.units.set(unit.id, unit);
    }
    model.unitSequence = render.unitSequence;
    spliceInPlace(units, firstUnit, lastUnit - firstUnit, render.units);
    // The page holds the markup of the containers now; the top block is drawn again from a parse
    // when the page is drawn whole.
    for (const node of chain) node.html = null;
    return { full: false, container, index, removed, inserted, top };
  }

  /// The index of the first unit starting at `position` or later, or, with `after`, later.
  function unitsFrom(units, position, after) {
    let low = 0;
    let high = units.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      const start = unitStart(units[middle]);
      if (start < position || (after && start === position)) low = middle + 1;
      else high = middle;
    }
    return low;
  }

  function spliceInPlace(array, start, count, items) {
    if (items.length < 10000) {
      array.splice(start, count, ...items);
      return;
    }
    const tail = array.slice(start + count);
    array.length = start;
    for (const item of items) array.push(item);
    for (const item of tail) array.push(item);
  }

  // ---------------------------------------------------------------------
  // Units and the visible text
  // ---------------------------------------------------------------------

  function regionMap(unit) {
    return MD.regionMap(unit.region);
  }

  function rawOf(unit, j) {
    const map = regionMap(unit);
    return S(unit, map[Math.max(0, Math.min(j, map.length - 1))]);
  }

  function unitStart(unit) {
    return rawOf(unit, 0);
  }

  function unitEnd(unit) {
    return rawOf(unit, unit.region.j.length);
  }

  /// The `j` offset whose source span holds `raw`.
  function jOf(unit, raw) {
    const map = regionMap(unit);
    const target = raw - nodeShift(ownerOf(unit));
    let low = 0;
    let high = map.length - 1;
    if (target <= map[0]) return 0;
    if (target >= map[high]) return high;
    while (low < high) {
      const middle = (low + high + 1) >> 1;
      if (map[middle] <= target) low = middle;
      else high = middle - 1;
    }
    return low;
  }

  function visibleMap(model, unit) {
    return MD.unitMap(unit, { footnotes: model.doc.footnotes, references: model.doc.references });
  }

  function visibleText(model, unit) {
    return visibleMap(model, unit).visible;
  }

  function isTextLike(unit) {
    return unit.kind === "empty" || unit.kind === "raw" || (unit.kind === "inline" && unit.role !== "cell");
  }

  /// Text a block type change may re-mark: not a definition's raw line, nor a toggle's title, whose
  /// markup holds the toggle.
  function isConvertible(unit) {
    return isTextLike(unit) && unit.kind !== "raw" && unit.role !== "summary";
  }

  function isStructural(unit) {
    return unit.kind === "code" || unit.role === "cell";
  }

  /// Source offset for a visible offset. `side` decides between the two
  /// sides of hidden markup: "left" keeps typing with the character before
  /// (inside bold that just ended), "right" with the character after.
  function visibleToRaw(model, unit, v, side) {
    const map = visibleMap(model, unit);
    const segments = map.segments;
    if (segments.length === 0) return unitStart(unit);
    let left = null;
    let right = null;
    for (const segment of segments) {
      const end = segment.v + segment.len;
      if (segment.v < v && v < end && !segment.atom) return rawOf(unit, segment.j + (v - segment.v));
      if (end === v) left = segment;
      if (segment.v === v && !right) right = segment;
      if (segment.v > v) break;
    }
    if (!left && !right) {
      const last = segments[segments.length - 1];
      if (v >= last.v + last.len) left = last;
      else right = segments[0];
    }
    let j;
    if ((side === "left" && left) || !right) {
      j = left.atom ? left.e : left.j + left.len;
      j = leaveNonInclusive(map.constructs, j, "end");
    } else {
      j = right.atom ? right.s : right.j;
      j = leaveNonInclusive(map.constructs, j, "start");
    }
    return rawOf(unit, j);
  }

  /// Links do not grow when typing at their edges.
  function leaveNonInclusive(constructs, j, edge) {
    let moved = true;
    let position = j;
    while (moved) {
      moved = false;
      for (const construct of constructs) {
        if (construct.inclusive) continue;
        if (edge === "end" && construct.ce === position && construct.e !== position) {
          position = construct.e;
          moved = true;
        } else if (edge === "start" && construct.cs === position && construct.s !== position) {
          position = construct.s;
          moved = true;
        }
      }
    }
    return position;
  }

  /// Visible offset for a source offset; inside hidden markup, `side` picks
  /// the visible position before or after it.
  function rawToVisible(model, unit, raw, side) {
    const map = visibleMap(model, unit);
    const segments = map.segments;
    if (segments.length === 0) return 0;
    const j = jOf(unit, raw);
    let before = null;
    let after = null;
    for (const segment of segments) {
      if (segment.atom) {
        if (j === segment.s) return segment.v;
        if (j > segment.s && j < segment.e) return side === "left" ? segment.v : segment.v + 1;
        if (j === segment.e) before = segment;
        else if (segment.e < j) before = segment;
        else if (!after && segment.s > j) after = segment;
        continue;
      }
      if (segment.j <= j && j <= segment.j + segment.len) {
        if (j === segment.j + segment.len) {
          before = segment;
          continue;
        }
        return segment.v + (j - segment.j);
      }
      if (segment.j + segment.len < j) before = segment;
      else if (!after && segment.j > j) after = segment;
    }
    if (before && (side === "left" || !after)) return before.v + before.len;
    if (after) return after.v;
    return map.v;
  }

  /// Source ranges covering exactly the visible characters [v0, v1).
  function visibleRangeToRaw(model, unit, v0, v1) {
    const map = visibleMap(model, unit);
    let start = null;
    let end = null;
    for (const segment of map.segments) {
      const segmentEnd = segment.v + segment.len;
      if (segmentEnd <= v0 || segment.v >= v1) continue;
      const from = Math.max(v0, segment.v);
      const to = Math.min(v1, segmentEnd);
      const rawFrom = segment.atom ? rawOf(unit, segment.s) : rawOf(unit, segment.j + (from - segment.v));
      const rawTo = segment.atom ? rawOf(unit, segment.e) : rawOf(unit, segment.j + (to - segment.v));
      if (start === null) start = rawFrom;
      end = rawTo;
    }
    if (start === null) {
      const position = visibleToRaw(model, unit, v0, "left");
      return [position, position];
    }
    return [start, end];
  }

  function unitsOf(block) {
    return block.units || [];
  }

  /// The unit holding `raw`. Between units, `side` picks the one before or after.
  function unitAt(model, raw, side = "left") {
    const blocks = model.blocks;
    if (blocks.length === 0) return null;
    let index = lastBlockStartingAtOrBefore(blocks, raw);
    if (index < 0) return firstUnitFrom(model, 0);
    const block = blocks[index];
    if (raw > bEnd(block)) {
      if (side === "left") return lastUnitUpTo(model, index) || firstUnitFrom(model, index + 1);
      return firstUnitFrom(model, index + 1) || lastUnitUpTo(model, index);
    }
    const units = unitsOf(block);
    if (units.length === 0) {
      return side === "left"
        ? lastUnitUpTo(model, index - 1) || firstUnitFrom(model, index + 1)
        : firstUnitFrom(model, index + 1) || lastUnitUpTo(model, index - 1);
    }
    // A block's units run in document order, and neither their starts nor their ends go back, so
    // the ones holding `raw` are a run found by two binary searches: a toggle or list can hold
    // thousands.
    let count = 0;
    let high = units.length;
    while (count < high) {
      const middle = (count + high) >> 1;
      if (unitStart(units[middle]) <= raw) count = middle + 1;
      else high = middle;
    }
    let first = 0;
    high = count;
    while (first < high) {
      const middle = (first + high) >> 1;
      if (unitEnd(units[middle]) < raw) first = middle + 1;
      else high = middle;
    }
    if (count - first === 1) return units[first];
    if (count - first > 1) return side === "left" ? units[first] : units[count - 1];
    const before = first > 0 ? units[first - 1] : null;
    const after = count < units.length ? units[count] : null;
    return side === "left" ? before || after : after || before;
  }

  function firstUnitFrom(model, index) {
    for (let position = Math.max(0, index); position < model.blocks.length; position += 1) {
      const units = unitsOf(model.blocks[position]);
      if (units.length) return units[0];
    }
    return null;
  }

  function lastUnitUpTo(model, index) {
    for (let position = Math.min(index, model.blocks.length - 1); position >= 0; position -= 1) {
      const units = unitsOf(model.blocks[position]);
      if (units.length) return units[units.length - 1];
    }
    return null;
  }

  function previousUnit(model, unit) {
    const units = unitsOf(unit.top);
    const position = units.indexOf(unit);
    if (position > 0) return units[position - 1];
    return lastUnitUpTo(model, blockIndex(model, unit.top) - 1);
  }

  function nextUnit(model, unit) {
    const units = unitsOf(unit.top);
    const position = units.indexOf(unit);
    if (position >= 0 && position < units.length - 1) return units[position + 1];
    return firstUnitFrom(model, blockIndex(model, unit.top) + 1);
  }

  function allUnits(model) {
    const result = [];
    for (const block of model.blocks) result.push(...unitsOf(block));
    return result;
  }

  function unitsBetween(model, from, to) {
    const result = [];
    const startIndex = Math.max(0, lastBlockStartingAtOrBefore(model.blocks, from));
    for (let index = startIndex; index < model.blocks.length; index += 1) {
      const block = model.blocks[index];
      if (bStart(block) > to) break;
      for (const unit of unitsOf(block)) {
        if (unitEnd(unit) >= from && unitStart(unit) <= to) result.push(unit);
      }
    }
    return result;
  }

  function firstUnitAfter(model, raw, predicate) {
    const startIndex = Math.max(0, lastBlockStartingAtOrBefore(model.blocks, raw));
    for (let index = startIndex; index < model.blocks.length; index += 1) {
      for (const unit of unitsOf(model.blocks[index])) {
        if (unitStart(unit) >= raw && (!predicate || predicate(unit))) return unit;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Source helpers
  // ---------------------------------------------------------------------

  function lineStartOf(source, raw) {
    let index = Math.max(0, Math.min(raw, source.length));
    while (index > 0) {
      const code = source.charCodeAt(index - 1);
      if (code === 10 || code === 13) break;
      index -= 1;
    }
    return index;
  }

  function lineEndOf(source, raw) {
    let index = Math.max(0, Math.min(raw, source.length));
    while (index < source.length) {
      const code = source.charCodeAt(index);
      if (code === 10 || code === 13) break;
      index += 1;
    }
    return index;
  }

  function nextLineStart(source, raw) {
    const end = lineEndOf(source, raw);
    if (end >= source.length) return end;
    return source.charCodeAt(end) === 13 && source.charCodeAt(end + 1) === 10 ? end + 2 : end + 1;
  }

  function previousLineEnd(source, lineStart) {
    if (lineStart <= 0) return -1;
    let index = lineStart - 1;
    if (source.charCodeAt(index) === 10 && index > 0 && source.charCodeAt(index - 1) === 13) index -= 1;
    return index;
  }

  const QUOTE_PREFIX = /^(?: {0,3}>[ \t]?)+/;

  function quotePrefixOfLine(source, raw) {
    const start = lineStartOf(source, raw);
    const match = QUOTE_PREFIX.exec(source.slice(start, lineEndOf(source, start)));
    return match ? match[0] : "";
  }

  function quoteDepth(prefix) {
    return (prefix.match(/>/g) || []).length;
  }

  /// Whether the line at `start` is blank inside a container whose lines
  /// carry `prefix` (empty at the top level).
  function isBlankLineIn(source, start, prefix) {
    const text = source.slice(start, lineEndOf(source, start));
    if (!prefix) return /^\s*$/.test(text);
    const match = QUOTE_PREFIX.exec(text);
    if (!match || quoteDepth(match[0]) !== quoteDepth(prefix)) return false;
    return /^\s*$/.test(text.slice(match[0].length));
  }

  function normalizeLineEndings(text, eol) {
    return text.replace(/\r\n|\r|\n/g, eol);
  }

  /// Gives every line after the first the container prefix (`> ` in a quote).
  function prefixFollowingLines(text, prefix, eol) {
    if (!prefix) return text;
    const blank = prefix.trimEnd();
    return text.split(eol).map((line, index) => {
      if (index === 0) return line;
      return line.length ? prefix + line : blank;
    }).join(eol);
  }

  function blankLinesAfter(source, lineEnd, prefix) {
    let count = 0;
    let position = nextLineStart(source, lineEnd);
    if (position === lineEnd) return { count, trailing: true, hasTerminator: false };
    while (position < source.length) {
      if (!isBlankLineIn(source, position, prefix)) return { count, trailing: false, hasTerminator: true };
      count += 1;
      const next = nextLineStart(source, position);
      if (next === position || next === lineEndOf(source, position)) {
        return { count, trailing: true, hasTerminator: true };
      }
      position = next;
    }
    return { count, trailing: !prefix, hasTerminator: true };
  }

  /// How many line breaks leave one empty line after a block, given `blankLinesAfter` it.
  function breaksForEmptyLine(gap) {
    return gap.trailing ? (gap.hasTerminator ? 1 : 2) : gap.count >= 1 ? 1 : 2;
  }

  function blankLinesBefore(source, lineStart, prefix) {
    let count = 0;
    let end = previousLineEnd(source, lineStart);
    while (end >= 0) {
      const start = lineStartOf(source, end);
      if (!isBlankLineIn(source, start, prefix)) return { count, leading: false };
      count += 1;
      end = previousLineEnd(source, start);
    }
    return { count, leading: !prefix };
  }

  /// The blank lines a paragraph made from the lines [start, end) needs so that Markdown reads it
  /// as a block of its own: without them it continues the list item or paragraph above it, and
  /// a following ordered item or paragraph folds into it. Lines in another container are left alone.
  function paragraphSeparation(source, start, end, prefix, eol) {
    const blank = prefix.trimEnd();
    const sameContainer = (lineStart) => quoteDepth(quotePrefixOfLine(source, lineStart)) === quoteDepth(prefix);
    const previousEnd = previousLineEnd(source, start);
    const previousStart = previousEnd >= 0 ? lineStartOf(source, previousEnd) : -1;
    const before = previousStart >= 0 && sameContainer(previousStart) && !isBlankLineIn(source, previousStart, prefix);
    const nextStart = nextLineStart(source, end);
    const after = nextStart > end && nextStart < source.length && sameContainer(nextStart) && !isBlankLineIn(source, nextStart, prefix);
    return { before: before ? blank + eol : "", after: after ? eol + blank : "" };
  }

  function escapeCell(text) {
    return text.replace(/\r\n|\r|\n/g, " ").replace(/(?<!\\)\|/g, "\\|");
  }

  // ---------------------------------------------------------------------
  // Operations
  //
  // A planner returns { from, to, insert, select } where `select` is the
  // selection after the patch, as source offsets or a function of the new
  // model. A planner never touches the page.
  // ---------------------------------------------------------------------

  function caretAt(position) {
    return { anchor: position, head: position };
  }

  /// A selection from `anchor` to `head` with its ordered ends.
  function withOrder(anchor, head) {
    return { anchor, head, from: Math.min(anchor, head), to: Math.max(anchor, head) };
  }

  function compose(source, parts, text = "") {
    const sorted = parts.filter(Boolean).sort((a, b) => a.s - b.s);
    if (sorted.length === 0) return null;
    let insert = text;
    for (let index = 0; index < sorted.length; index += 1) {
      const part = sorted[index];
      insert += part.keep || "";
      if (index < sorted.length - 1) insert += source.slice(part.e, sorted[index + 1].s);
    }
    const from = sorted[0].s;
    return {
      from,
      to: sorted[sorted.length - 1].e,
      insert,
      select: caretAt(from + text.length)
    };
  }

  /// Markup that has to stay when [s, e) is deleted inside an inline unit: a
  /// construct marker whose partner lies outside the range. A construct whose
  /// content is deleted whole goes with its markers.
  function markupAwareParts(model, unit, s, e, replacing) {
    if (unit.kind !== "inline" || s >= e) return [{ s, e, keep: "" }];
    const constructs = visibleMap(model, unit).constructs.map((construct) => ({
      s: rawOf(unit, construct.s),
      cs: rawOf(unit, construct.cs),
      ce: rawOf(unit, construct.ce),
      e: rawOf(unit, construct.e)
    }));
    let start = s;
    let end = e;
    if (!replacing) {
      let grew = true;
      while (grew) {
        grew = false;
        for (const construct of constructs) {
          if (construct.cs >= start && construct.ce <= end && construct.ce > construct.cs
            && (construct.s < start || construct.e > end)) {
            start = Math.min(start, construct.s);
            end = Math.max(end, construct.e);
            grew = true;
          }
        }
      }
    }
    const kept = [];
    for (const construct of constructs) {
      const openInside = start <= construct.s && construct.cs <= end && construct.cs > construct.s;
      const closeInside = start <= construct.ce && construct.e <= end && construct.e > construct.ce;
      if (openInside && !closeInside) kept.push([construct.s, construct.cs]);
      if (closeInside && !openInside) kept.push([construct.ce, construct.e]);
    }
    kept.sort((a, b) => a[0] - b[0]);
    const keep = kept.map(([from, to]) => model.source.slice(from, to)).join("");
    return [{ s: start, e: end, keep }];
  }

  /// Deletes [from, to) as the page shows it: units keep their structure,
  /// text-like blocks at both ends join, code blocks and tables only lose the
  /// selected text.
  function deleteParts(model, from, to, replacing) {
    if (from >= to) return [{ s: from, e: from, keep: "" }];
    const first = unitAt(model, from, "right");
    const last = unitAt(model, to, "left");
    if (!first || !last) return [{ s: from, e: to, keep: "" }];
    if (first === last) return markupAwareParts(model, first, from, to, replacing);

    if (isTextLike(first) && isTextLike(last) && canJoin(first, last)) {
      const head = markupAwareParts(model, first, from, Math.max(from, unitEnd(first)), replacing)[0];
      const tail = markupAwareParts(model, last, Math.min(to, unitStart(last)), to, replacing)[0];
      return [{ s: head.s, e: tail.e, keep: head.keep + tail.keep }];
    }

    const parts = [];
    const units = unitsBetween(model, from, to);
    const firstTop = first.top;
    const lastTop = last.top;
    // A code block or table selected from end to end goes whole, fences and pipes included.
    const coversBlock = (block) => unitsOf(block).every((unit) => from <= unitStart(unit) && unitEnd(unit) <= to);
    const firstWhole = firstTop !== lastTop && isStructural(first) && coversBlock(firstTop);
    const lastWhole = firstTop !== lastTop && isStructural(last) && coversBlock(lastTop);
    for (const unit of units) {
      const start = unitStart(unit);
      const end = unitEnd(unit);
      if ((unit.top === firstTop && firstWhole) || (unit.top === lastTop && lastWhole)) continue;
      if (unit === first) {
        parts.push(...markupAwareParts(model, unit, from, end, replacing));
      } else if (unit === last) {
        parts.push(...markupAwareParts(model, unit, start, to, replacing));
      } else if (unit.top === firstTop || unit.top === lastTop) {
        if (end > start) parts.push({ s: start, e: end, keep: "" });
      }
    }
    if (firstTop !== lastTop) {
      const firstIndex = blockIndex(model, firstTop);
      const lastIndex = blockIndex(model, lastTop);
      const startIndex = firstWhole ? firstIndex : firstIndex + 1;
      const endIndex = lastWhole ? lastIndex : lastIndex - 1;
      if (startIndex <= endIndex) {
        const s = firstWhole ? bStart(firstTop) : (lastWhole ? lineEndOf(model.source, unitEnd(first)) : bStart(model.blocks[startIndex]));
        const e = lastWhole ? bEnd(lastTop) : bStart(model.blocks[endIndex + 1]);
        if (e > s) parts.push({ s, e, keep: "" });
      }
    }
    return mergeParts(parts);
  }

  /// Whether text in `first` and `last` may run together when what lies between them goes: not
  /// across a toggle's edge, and never into a toggle's title, whose markup holds the toggle.
  function canJoin(first, last) {
    return first.scope === last.scope && first.role !== "summary" && last.role !== "summary";
  }

  /// Blocks the page draws whole, with no text to type in: a divider and a table of contents.
  function isAtomBlock(block) {
    return Boolean(block) && (block.type === "hr" || block.type === "toc");
  }

  function atomBlockLabel(block) {
    return block.type === "toc" ? "Delete Table of Contents" : "Delete Divider";
  }

  function mergeParts(parts) {
    const sorted = parts.filter((part) => part.e > part.s || part.keep).sort((a, b) => a.s - b.s);
    const merged = [];
    for (const part of sorted) {
      const previous = merged[merged.length - 1];
      if (previous && part.s < previous.e) {
        previous.e = Math.max(previous.e, part.e);
        previous.keep += part.keep;
      } else {
        merged.push({ ...part });
      }
    }
    return merged;
  }

  function planDelete(model, from, to) {
    const first = firstUnitFrom(model, 0);
    const last = lastUnitUpTo(model, model.blocks.length - 1);
    if (first && from <= unitStart(first) && to >= unitEnd(last) && to > from) {
      // Everything selected: the document becomes empty.
      return { from: 0, to: model.source.length, insert: "", select: caretAt(0), kind: "delete" };
    }
    const parts = deleteParts(model, from, to, false);
    const op = compose(model.source, parts);
    if (!op) return null;
    op.kind = "delete";
    return op;
  }

  /// Inserts typed or pasted text at a collapsed caret.
  function insertionAt(model, unit, position, text) {
    const eol = model.eol;
    if (unit.kind === "empty") return materializeEmpty(model, unit, text);
    if (unit.role === "code" && unit.block.body.length === 0) {
      const anchor = unitStart(unit);
      const open = unit.block.open;
      const atEndOfFence = anchor === S(unit, open.end);
      const prefix = quotePrefixOfLine(model.source, S(unit, open.start));
      const body = prefixFollowingLines(text, prefix, eol);
      const insert = atEndOfFence ? eol + prefix + body : prefix + body + eol;
      const caret = anchor + (atEndOfFence ? eol.length + prefix.length : prefix.length) + body.length;
      return { from: anchor, to: anchor, insert, select: caretAt(caret) };
    }
    if (unit.role === "cell") {
      const cellText = escapeCell(text);
      if (unit.missing) return materializeCell(model, unit, cellText);
      return { from: position, to: position, insert: cellText, select: caretAt(position + cellText.length) };
    }
    const prefix = quotePrefixOfLine(model.source, position);
    const body = prefixFollowingLines(text, prefix, eol);
    return { from: position, to: position, insert: body, select: caretAt(position + body.length) };
  }

  /// Typing into an empty line turns it into text, keeping one blank line
  /// between it and the blocks around it.
  function materializeEmpty(model, unit, text) {
    const block = unit.block;
    const eol = model.eol;
    if (!block.view) {
      const anchor = unitStart(unit);
      if (block.virtual) {
        // An empty callout or toggle body: the text goes on a line of its own inside it.
        const before = normalizeLineEndings(block.virtual.before, eol);
        const after = normalizeLineEndings(block.virtual.after, eol);
        const linePrefix = before.slice(before.lastIndexOf(eol) + eol.length);
        const body = prefixFollowingLines(text, linePrefix, eol);
        return { from: anchor, to: anchor, insert: before + body + after, select: caretAt(anchor + before.length + body.length) };
      }
      return { from: anchor, to: anchor, insert: text, select: caretAt(anchor + text.length) };
    }
    const start = S(unit, block.view.start);
    const end = S(unit, block.view.end);
    const prefix = quotePrefixOfLine(model.source, start);
    const blank = prefix.trimEnd();
    const lead = prefix && !/[ \t]$/.test(model.source.slice(lineStartOf(model.source, start), start)) ? " " : "";
    const before = block.needsSeparatorBefore ? eol + (blank ? prefix : "") : "";
    const body = prefixFollowingLines(text, prefix || "", eol);
    const after = block.needsSeparatorAfter ? eol + blank : "";
    const insert = before + lead + body + after;
    return { from: start, to: end, insert, select: caretAt(start + before.length + lead.length + body.length) };
  }

  function materializeCell(model, unit, text) {
    const row = unit.row;
    const cells = row.cells.length;
    const at = S(unit, row.pipeEnd);
    let insert = row.trailingPipe ? "" : " |";
    for (let column = cells; column < unit.column; column += 1) insert += "  |";
    const caret = at + insert.length + 1 + text.length;
    insert += ` ${text} |`;
    return { from: at, to: at, insert, select: caretAt(caret) };
  }

  function planInsertText(model, selection, text, options = {}) {
    const eol = model.eol;
    const normalized = normalizeLineEndings(text, eol);
    if (selection.from !== selection.to) {
      const first = unitAt(model, selection.from, "right");
      let body = normalized;
      if (first && first.role === "cell") body = escapeCell(body);
      else body = prefixFollowingLines(body, quotePrefixOfLine(model.source, selection.from), eol);
      const parts = deleteParts(model, selection.from, selection.to, true);
      const op = compose(model.source, parts, body);
      if (!op) return null;
      op.kind = options.kind || "typing";
      return op;
    }
    const unit = unitAt(model, selection.from, "left");
    if (!unit) {
      return { from: selection.from, to: selection.from, insert: normalized, select: caretAt(selection.from + normalized.length), kind: "typing" };
    }
    if (options.typing && normalized.length === 1) {
      const rule = inputRule(model, unit, selection.from, normalized);
      if (rule) return rule;
    }
    const op = insertionAt(model, unit, selection.from, normalized);
    op.kind = options.kind || "typing";
    return op;
  }

  /// Markdown shortcuts that need more than the typed character: `[] ` for a
  /// to-do, a third backtick for a code block, a third hyphen for a divider.
  function inputRule(model, unit, position, character) {
    if (unit.kind !== "inline" || unit.role !== "paragraph") return null;
    const j = unit.region.j;
    const caretJ = jOf(unit, position);
    const before = j.slice(0, caretJ);
    const start = unitStart(unit);
    const eol = model.eol;
    if (character === " " && (before === "[]" || before === "[ ]")) {
      const replacement = "- [ ] ";
      return {
        from: start,
        to: position,
        insert: replacement,
        select: caretAt(start + replacement.length),
        kind: "typing",
        label: "Task List"
      };
    }
    if (unit.region.lines && unit.region.lines.length === 1 && caretJ === j.length) {
      const prefix = quotePrefixOfLine(model.source, start);
      if (character === "`" && j === "``") {
        const insert = "```" + eol + prefix + eol + prefix + "```";
        return {
          from: start,
          to: unitEnd(unit),
          insert,
          select: caretAt(start + 3 + eol.length + prefix.length),
          kind: "typing",
          label: "Code Block"
        };
      }
      if (character === "-" && j === "--") {
        const lineEnd = unitEnd(unit);
        const breaks = breaksForEmptyLine(blankLinesAfter(model.source, lineEnd, prefix));
        const insert = "---" + (eol + prefix.trimEnd()).repeat(breaks);
        return {
          from: start,
          to: lineEnd,
          insert,
          select: (next) => caretOnFirstEmptyAfter(next, start + 3),
          kind: "typing",
          label: "Divider"
        };
      }
    }
    return null;
  }

  function caretOnFirstEmptyAfter(model, raw) {
    const unit = firstUnitAfter(model, raw, (candidate) => candidate.kind === "empty") || firstUnitAfter(model, raw);
    const position = unit ? unitStart(unit) : raw;
    return caretAt(position);
  }

  // Enter --------------------------------------------------------------

  function constructsOpenAt(model, unit, position) {
    if (unit.kind !== "inline") return [];
    const j = jOf(unit, position);
    return visibleMap(model, unit).constructs
      .filter((construct) => construct.cs < j && j < construct.ce)
      .sort((a, b) => a.s - b.s || b.e - a.e);
  }

  function splitAt(model, unit, position, separator) {
    const open = constructsOpenAt(model, unit, position);
    const source = model.source;
    const closers = open.slice().reverse().map((construct) => source.slice(rawOf(unit, construct.ce), rawOf(unit, construct.e))).join("");
    const openers = open.map((construct) => source.slice(rawOf(unit, construct.s), rawOf(unit, construct.cs))).join("");
    const insert = closers + separator + openers;
    return { from: position, to: position, insert, select: caretAt(position + insert.length) };
  }

  function lineEndOfUnit(model, unit) {
    return lineEndOf(model.source, unitEnd(unit));
  }

  /// A new empty line right after the block holding `unit`.
  function insertEmptyAfter(model, unit) {
    const at = unit.role === "item" ? S(unit, unit.item.end)
      : unit.role === "summary" ? S(unit, unit.block.end)
      : lineEndOfUnit(model, unit);
    return insertEmptyAt(model, at, quotePrefixOfLine(model.source, at));
  }

  /// A new empty line at the top level after a whole top-level block (a quote, toggle or table
  /// included), as a click below the last block makes.
  function insertEmptyAfterBlock(model, block) {
    return insertEmptyAt(model, bEnd(block), "");
  }

  function insertEmptyAt(model, at, prefix) {
    const source = model.source;
    const eol = model.eol;
    const insert = (eol + prefix.trimEnd()).repeat(breaksForEmptyLine(blankLinesAfter(source, at, prefix)));
    return {
      from: at,
      to: at,
      insert,
      select: (next) => caretOnFirstEmptyAfter(next, at + 1)
    };
  }

  function insertEmptyBefore(model, unit, position) {
    const source = model.source;
    const eol = model.eol;
    const lineStart = lineStartOf(source, unit.role === "item" ? S(unit, unit.item.view.start) : unitStart(unit));
    const prefix = quotePrefixOfLine(source, lineStart);
    const blank = prefix.trimEnd();
    const gap = blankLinesBefore(source, lineStart, prefix);
    const count = gap.leading ? 1 : gap.count >= 1 ? 1 : 2;
    const insert = (blank + eol).repeat(count);
    return { from: lineStart, to: lineStart, insert, select: caretAt(position + insert.length) };
  }

  function nextMarker(item) {
    const ordered = /^\d/.test(item.marker);
    let marker = item.marker;
    if (ordered) {
      const number = parseInt(marker, 10);
      marker = `${Number.isFinite(number) ? number + 1 : 1}${marker.slice(-1)}`;
    }
    return marker + " " + (item.task ? "[ ] " : "");
  }

  function planEnter(model, selection, options = {}) {
    const position = selection.head;
    const unit = unitAt(model, position, "left");
    if (!unit) return null;
    const eol = model.eol;
    const source = model.source;
    const prefix = quotePrefixOfLine(source, position);
    const blank = prefix.trimEnd();

    if (unit.kind === "empty") return enterOnEmpty(model, unit);
    if (unit.kind === "raw") return { ...insertionAt(model, unit, position, eol), kind: "enter" };
    if (unit.kind === "code") {
      if (options.exitBlock) return { ...insertEmptyAfter(model, unit), kind: "enter" };
      if (!unit.block.close && unit.block.body.length === 0) {
        const at = S(unit, unit.block.open.end);
        const insert = eol + prefix + eol + prefix + unit.block.fence.marker.repeat(unit.block.fence.length);
        return { from: at, to: at, insert, select: caretAt(at + eol.length + prefix.length), kind: "enter", label: "Code Block" };
      }
      const lineStart = lineStartOf(source, position);
      const lineText = source.slice(lineStart, position).slice(prefix.length);
      const indent = (/^[ \t]*/.exec(lineText) || [""])[0];
      return { ...insertionAt(model, unit, position, eol + indent), kind: "enter" };
    }
    if (unit.role === "cell") return { move: true, select: null, cellMove: "down", unit };

    const visible = visibleText(model, unit);
    const v = rawToVisible(model, unit, position, "left");
    const before = visible.slice(0, v);
    const after = visible.slice(v);

    if (unit.role === "item") return enterInItem(model, unit, position, before, after, prefix, blank);
    if (unit.role === "summary") return enterInSummary(model, unit);

    if (unit.role === "paragraph" && /^```[\w.+-]*$/.test(unit.region.j) && after === "" && unit.region.lines.length === 1) {
      const start = unitStart(unit);
      const insert = unit.region.j + eol + prefix + eol + prefix + "```";
      return { from: start, to: unitEnd(unit), insert, select: caretAt(start + unit.region.j.length + eol.length + prefix.length), kind: "enter", label: "Code Block" };
    }
    if (after === "" || options.exitBlock) return { ...insertEmptyAfter(model, unit), kind: "enter" };
    if (before === "") return { ...insertEmptyBefore(model, unit, position), kind: "enter" };
    const separator = prefix ? eol + blank + eol + prefix : eol + eol;
    return { ...splitAt(model, unit, position, separator), kind: "enter" };
  }

  function enterOnEmpty(model, unit) {
    const source = model.source;
    const eol = model.eol;
    const block = unit.block;
    const next = nextUnit(model, unit);
    if (unit.scope && unit.scope.type === "toggle" && (!next || next.scope !== unit.scope)) {
      return leaveToggle(model, unit);
    }
    if (!block.view) {
      const anchor = unitStart(unit);
      return { from: anchor, to: anchor, insert: eol, select: (next) => caretOnFirstEmptyAfter(next, anchor + 1), kind: "enter" };
    }
    const lineStart = lineStartOf(source, S(unit, block.view.start));
    const prefix = quotePrefixOfLine(source, lineStart);
    const container = unit.container;
    if (container && container.type === "quote") {
      const units = unitsOf(unit.top);
      const isLast = units[units.length - 1] === unit;
      if (isLast) {
        // Enter on the quote's last, empty line leaves the quote.
        const end = bEnd(container);
        let firstBlank = lineStart;
        for (let previous = previousLineEnd(source, lineStart); previous >= 0;) {
          const start = lineStartOf(source, previous);
          if (!isBlankLineIn(source, start, prefix)) break;
          firstBlank = start;
          previous = previousLineEnd(source, start);
        }
        const cut = previousLineEnd(source, firstBlank);
        const insert = eol.repeat(breaksForEmptyLine(blankLinesAfter(source, end, "")));
        return {
          from: cut,
          to: end,
          insert,
          select: (next) => caretOnFirstEmptyAfter(next, cut + 1),
          kind: "enter"
        };
      }
    }
    const at = S(unit, block.view.end);
    const blank = prefix.trimEnd();
    return { from: at, to: at, insert: eol + blank, select: (next) => caretOnFirstEmptyAfter(next, at + 1), kind: "enter" };
  }

  /// Return in a toggle's title: into its body when it is open (onto its empty first line, or a new
  /// one), past the whole toggle when it is closed. The title never splits.
  function enterInSummary(model, unit) {
    const toggle = unit.block;
    const source = model.source;
    const eol = model.eol;
    if (!isOpenToggle(toggle)) return { ...insertEmptyAfter(model, unit), kind: "enter" };
    const first = nextUnit(model, unit);
    if (first && first.scope === toggle && first.kind === "empty") return { move: true, select: caretAt(unitStart(first)) };
    const at = S(unit, toggle.summaryView.end);
    const prefix = quotePrefixOfLine(source, at);
    const blank = prefix.trimEnd();
    // The body starts after one separating blank line; the empty line goes after it.
    const existing = Math.min(2, blankLinesAfter(source, at, prefix).count);
    const insert = (eol + blank).repeat(Math.max(1, 2 - existing));
    return { from: at, to: at, insert, select: (next) => caretOnFirstEmptyAfter(next, at + 1), kind: "enter" };
  }

  /// Return on the empty last line of a toggle's body leaves the toggle, as on a quote's.
  function leaveToggle(model, unit) {
    const toggle = unit.scope;
    const source = model.source;
    const eol = model.eol;
    const end = bEnd(toggle);
    const parts = [];
    const previous = previousUnit(model, unit);
    const onlyLine = !previous || previous.role === "summary";
    let removed = 0;
    if (unit.block.view && !onlyLine) {
      const lineStart = lineStartOf(source, S(unit, unit.block.view.start));
      const from = previousLineEnd(source, lineStart);
      const to = lineEndOf(source, lineStart);
      if (from >= 0) {
        parts.push({ s: from, e: to, keep: "" });
        removed = to - from;
      }
    }
    const after = insertEmptyAt(model, end, quotePrefixOfLine(source, end));
    parts.push({ s: end, e: end, keep: after.insert });
    const op = compose(source, parts);
    op.select = (next) => caretOnFirstEmptyAfter(next, end - removed + 1);
    op.kind = "enter";
    return op;
  }

  function isOpenToggle(toggle) {
    return Boolean(toggle.viewOpen ?? toggle.open);
  }

  /// Whether a unit sits in the body of a closed toggle, so the page does not show it.
  function isHiddenUnit(unit) {
    for (let scope = unit && unit.scope; scope; scope = scope.scopeParent) {
      if (scope.type === "toggle" && !isOpenToggle(scope)) return true;
    }
    return false;
  }

  function enterInItem(model, unit, position, before, after, prefix, blank) {
    const source = model.source;
    const eol = model.eol;
    const item = unit.item;
    const lineStart = S(unit, item.view.start);
    const indent = source.slice(lineStart, S(unit, item.markerStart));
    const marker = nextMarker(item);

    if (before === "" && after === "") {
      if (item.indent >= 2) {
        const outdent = planIndent(model, withOrder(position, position), -1);
        if (outdent) return { ...outdent, kind: "enter" };
      }
      const contentEnd = S(unit, item.end);
      const lineBefore = blankLinesBefore(source, lineStartOf(source, lineStart), prefix);
      const lineAfter = blankLinesAfter(source, contentEnd, prefix);
      const run = lineBefore.count + 1 + lineAfter.count;
      // At the end of a file the item's line stays as the empty line, unless nothing ends it:
      // a last line with no line break is no line at all, and the next text would join the item.
      const unterminated = nextLineStart(source, contentEnd) === contentEnd;
      const needed = (lineAfter.trailing && !prefix) ? (unterminated && lineBefore.count === 0 ? 1 : 0) : Math.max(0, 2 - run);
      const insert = (eol + blank).repeat(needed);
      return {
        from: lineStart,
        to: contentEnd,
        insert,
        select: (next) => caretOnFirstEmptyAfter(next, lineStartOf(next.source, lineStart)),
        kind: "enter",
        label: "Paragraph"
      };
    }
    if (after === "") {
      const at = S(unit, item.end);
      const insert = eol + prefix + indent + marker;
      return { from: at, to: at, insert, select: caretAt(at + insert.length), kind: "enter" };
    }
    if (before === "") {
      const at = lineStartOf(source, lineStart);
      const sameMarker = item.marker + " " + (item.task ? "[ ] " : "");
      const insert = prefix + indent + sameMarker + eol;
      return { from: at, to: at, insert, select: caretAt(position + insert.length), kind: "enter" };
    }
    return { ...splitAt(model, unit, position, eol + prefix + indent + marker), kind: "enter" };
  }

  /// ⇧↩ in a paragraph: a hard line break, `\` before a line ending. At the paragraph's end there
  /// is no line to break onto (Markdown drops a break there), so it starts a new block as ↩ does.
  function planLineBreak(model, selection) {
    const position = selection.head;
    const unit = unitAt(model, position, "left");
    if (!unit) return null;
    if (unit.role !== "paragraph") return planEnter(model, selection);
    if (rawToVisible(model, unit, position, "left") >= visibleText(model, unit).length) return planEnter(model, selection);
    const source = model.source;
    // Before a soft break the line ending is there already and becomes a hard one.
    const lineEnd = lineEndOf(source, position);
    if (lineEnd < unitEnd(unit) && /^[ \t]*$/.test(source.slice(position, lineEnd))) {
      const next = unit.block.lines.find((view) => S(unit, view.start) > lineEnd);
      return { from: position, to: lineEnd, insert: "\\", select: caretAt(S(unit, next.start) + 1 - (lineEnd - position)), kind: "typing" };
    }
    const insert = "\\" + model.eol + quotePrefixOfLine(source, position);
    return { from: position, to: position, insert, select: caretAt(position + insert.length), kind: "typing" };
  }

  // Backspace and forward delete at unit edges -----------------------

  function planBackspaceAtStart(model, unit) {
    const source = model.source;
    const position = unitStart(unit);
    if (unit.role === "summary") return unwrapToggle(model, unit);
    const callout = calloutOf(unit);
    if (callout && isFirstInContainer(model, unit)) return calloutToQuote(model, unit, callout);
    if (unit.kind === "empty") {
      const block = unit.block;
      if (!block.view) {
        const previous = visiblePrevious(model, unit);
        return previous ? { move: true, select: caretAt(unitEnd(previous)) } : null;
      }
      const lineStart = lineStartOf(source, S(unit, block.view.start));
      const lineEnd = lineEndOf(source, lineStart);
      const previousEnd = previousLineEnd(source, lineStart);
      const from = previousEnd >= 0 ? previousEnd : lineStart;
      const to = previousEnd >= 0 ? lineEnd : nextLineStart(source, lineStart);
      return {
        from,
        to,
        insert: "",
        select: (next) => {
          const target = unitAt(next, Math.max(0, from), "left");
          return caretAt(target ? (from > 0 ? unitEnd(target) : unitStart(target)) : 0);
        },
        kind: "delete"
      };
    }
    if (unit.role === "heading") {
      const block = unit.block;
      const [lineStart, lineEnd] = unitLineRange(model, unit);
      const lead = source.slice(lineStart, S(unit, block.start));
      const gap = paragraphSeparation(source, lineStart, lineEnd, quotePrefixOfLine(source, lineStart), model.eol);
      const op = compose(source, [
        { s: lineStart, e: S(unit, block.prefixEnd), keep: gap.before + lead },
        { s: S(unit, block.contentEnd), e: lineEnd, keep: gap.after }
      ]);
      op.select = caretAt(lineStart + gap.before.length + lead.length);
      op.kind = "format";
      op.label = "Paragraph";
      return op;
    }
    if (unit.role === "item") {
      const item = unit.item;
      // A nested item steps out a level first, as ⇧⇥ does: without its marker it would read as
      // more of its parent's text.
      if (item.indent >= 2) {
        const outdent = planIndent(model, withOrder(position, position), -1);
        if (outdent) return outdent;
      }
      const from = S(unit, item.view.start);
      const lineStart = lineStartOf(source, from);
      const lead = source.slice(lineStart, from);
      const end = lineEndOf(source, S(unit, item.end));
      const gap = paragraphSeparation(source, lineStart, end, quotePrefixOfLine(source, lineStart), model.eol);
      const op = compose(source, [
        { s: lineStart, e: S(unit, item.contentStart), keep: gap.before + lead },
        gap.after ? { s: end, e: end, keep: gap.after } : null
      ]);
      op.select = caretAt(lineStart + gap.before.length + lead.length);
      op.kind = "format";
      op.label = "Paragraph";
      return op;
    }
    if (unit.role === "paragraph" && unit.container && unit.container.type === "quote") {
      const parts = unit.block.lines.map((view) => ({
        s: lineStartOf(source, S(unit, view.start)),
        e: S(unit, view.start),
        keep: ""
      }));
      const [lineStart, lineEnd] = unitLineRange(model, unit);
      const gap = paragraphSeparation(source, lineStart, lineEnd, "", model.eol);
      parts[0].keep = gap.before;
      parts.push({ s: lineEnd, e: lineEnd, keep: gap.after });
      const op = compose(source, parts);
      op.select = caretAt(lineStart + gap.before.length);
      op.kind = "format";
      op.label = "Paragraph";
      return op;
    }
    if (unit.role === "code") {
      if (unit.region.j.length === 0) {
        const block = unit.block;
        const from = S(unit, block.start);
        const to = S(unit, block.end);
        return { from, to, insert: "", select: (next) => caretAt(closestUnitPosition(next, from)), kind: "delete", label: "Delete Code Block" };
      }
      const previous = previousUnit(model, unit);
      return previous ? { move: true, select: caretAt(unitEnd(previous)) } : null;
    }
    if (unit.role === "cell") {
      const previous = previousUnit(model, unit);
      return previous && previous.top === unit.top ? { move: true, select: caretAt(unitEnd(previous)) } : null;
    }

    const previous = previousUnit(model, unit);
    const topIndex = blockIndex(model, unit.top);
    const previousTop = topIndex > 0 ? model.blocks[topIndex - 1] : null;
    if ((!previous || previous.top !== unit.top) && unitsOf(unit.top)[0] === unit && isAtomBlock(previousTop)) {
      return { from: bStart(previousTop), to: bStart(unit.top), insert: "", select: caretAt(bStart(previousTop)), kind: "delete", label: atomBlockLabel(previousTop) };
    }
    if (!previous) return null;
    if (!canJoin(previous, unit) || isHiddenUnit(previous)) {
      const target = visiblePrevious(model, unit);
      return target ? { move: true, select: caretAt(unitEnd(target)) } : null;
    }
    if (previous.kind === "empty") {
      const block = previous.block;
      if (!block.view) return null;
      const lineStart = lineStartOf(source, S(previous, block.view.start));
      const next = nextLineStart(source, lineStart);
      const removed = next - lineStart;
      return { from: lineStart, to: next, insert: "", select: caretAt(position - removed), kind: "delete" };
    }
    if (isStructural(previous)) return { move: true, select: caretAt(unitEnd(previous)) };
    const joinAt = unitEnd(previous);
    return { from: joinAt, to: position, insert: "", select: caretAt(joinAt), kind: "delete" };
  }

  function planDeleteForwardAtEnd(model, unit) {
    const source = model.source;
    const position = unitEnd(unit);
    const next = nextUnit(model, unit);
    if (unit.kind === "empty") {
      if (!next) return null;
      const block = unit.block;
      if (!block.view) return null;
      const lineStart = lineStartOf(source, S(unit, block.view.start));
      const lineNext = nextLineStart(source, lineStart);
      return { from: lineStart, to: lineNext, insert: "", select: caretAt(lineStart), kind: "delete" };
    }
    if (!next) return null;
    const topIndex = blockIndex(model, unit.top);
    const nextTop = model.blocks[topIndex + 1];
    // A divider or table of contents right after goes, unless the caret is inside a toggle it follows.
    if (next.top !== unit.top && isAtomBlock(nextTop) && unit.scope === next.scope) {
      const after = model.blocks[topIndex + 2];
      return { from: bStart(nextTop), to: after ? bStart(after) : bEnd(nextTop), insert: "", select: caretAt(position), kind: "delete", label: atomBlockLabel(nextTop) };
    }
    if (!canJoin(unit, next) || isHiddenUnit(next)) return null;
    if (next.kind === "empty") {
      const block = next.block;
      if (!block.view) return null;
      const lineStart = lineStartOf(source, S(next, block.view.start));
      return { from: lineStart, to: nextLineStart(source, lineStart), insert: "", select: caretAt(position), kind: "delete" };
    }
    if (isStructural(next) || isStructural(unit)) return null;
    return { from: position, to: unitStart(next), insert: "", select: caretAt(position), kind: "delete" };
  }

  /// The nearest unit before `unit` that the page shows (a closed toggle hides its body).
  function visiblePrevious(model, unit) {
    let previous = previousUnit(model, unit);
    while (previous && isHiddenUnit(previous)) previous = previousUnit(model, previous);
    return previous;
  }

  function calloutOf(unit) {
    return unit.container && unit.container.type === "quote" && unit.container.callout ? unit.container : null;
  }

  function isFirstInContainer(model, unit) {
    const previous = previousUnit(model, unit);
    return !previous || previous.container !== unit.container;
  }

  /// ⌫ at the start of a callout's text makes it a plain quote: its `[!KIND]` line goes.
  function calloutToQuote(model, unit, callout) {
    const source = model.source;
    const marker = callout.callout.marker;
    const lineStart = lineStartOf(source, atNode(callout, marker.start));
    // Only the marker line: the callout's one block is the empty line standing in for its text.
    const hasChildren = !callout.children.some((child) => child.virtual);
    if (!hasChildren) {
      const from = atNode(callout, marker.start);
      return { from, to: atNode(callout, marker.end), insert: "", select: (next) => caretAt(closestUnitPosition(next, from)), kind: "format", label: "Quote" };
    }
    const to = nextLineStart(source, lineStart);
    return { from: lineStart, to, insert: "", select: caretAt(unitStart(unit) - (to - lineStart)), kind: "format", label: "Quote" };
  }

  /// ⌫ at the start of a toggle's title turns it into a paragraph, its body following as blocks.
  function unwrapToggle(model, unit) {
    const toggle = unit.block;
    const source = model.source;
    const eol = model.eol;
    const from = S(unit, toggle.start);
    const to = S(unit, toggle.end);
    const title = source.slice(S(unit, toggle.summaryStart), S(unit, toggle.summaryEnd));
    const lines = nodeLines(model, toggle, lineAfter(source, S(unit, toggle.summaryView.end)), containerLinesEnd(source, toggle))
      .filter((view) => !MD.isBlank(view.text));
    let insert = title;
    if (lines.length) {
      const bodyStart = lines[0].prefixStart ?? lines[0].start;
      const bodyEnd = lines[lines.length - 1].end;
      insert += eol + eol + source.slice(bodyStart, bodyEnd);
    }
    return { from, to, insert, select: caretAt(from), kind: "format", label: "Paragraph" };
  }

  function closestUnitPosition(model, raw) {
    const unit = unitAt(model, raw, "right") || unitAt(model, raw, "left");
    if (!unit) return 0;
    const start = unitStart(unit);
    const end = unitEnd(unit);
    return Math.max(start, Math.min(end, raw));
  }

  // Inline formatting -------------------------------------------------

  const STYLE_ORDER = ["link", "del", "strong", "em", "code"];

  /// The characters of `unit` in [js, je) with the styles they carry, for
  /// re-writing a region with different formatting.
  function styledItems(model, unit, js, je) {
    const j = unit.region.j;
    const nodes = MD.parseInline(j, { footnotes: model.doc.footnotes, references: model.doc.references, editing: true });
    const items = [];
    const outer = [];
    const source = model.source;
    const rawSlice = (s, e) => source.slice(rawOf(unit, s), rawOf(unit, e));
    const walk = (list, styles) => {
      for (const node of list) {
        if (node.e <= js || node.s >= je) continue;
        const inside = node.s >= js && node.e <= je;
        switch (node.t) {
          case "text":
            for (let index = Math.max(node.s, js); index < Math.min(node.e, je); index += 1) {
              items.push({ char: j[index], raw: rawSlice(index, index + 1), styles });
            }
            break;
          case "strong":
          case "em":
          case "del":
            if (inside) walk(node.kids, { ...styles, [node.t]: true });
            else {
              outer.push(node.t);
              walk(node.kids, { ...styles, [`outer_${node.t}`]: true });
            }
            break;
          case "code": {
            const next = inside ? { ...styles, code: true } : { ...styles, outer_code: true };
            if (!inside) outer.push("code");
            walk(node.kids, next);
            break;
          }
          case "link":
            if (inside) walk(node.kids, { ...styles, link: { tail: rawSlice(node.ce, node.e) } });
            else {
              outer.push("link");
              walk(node.kids, { ...styles, outer_link: true });
            }
            break;
          default:
            items.push({ opaque: true, char: "\uFFFC", raw: rawSlice(node.s, node.e), styles });
        }
      }
    };
    walk(nodes, {});
    return { items, outer };
  }

  /// Expands [js, je) until no inline construct crosses its edges.
  function alignToConstructs(model, unit, js, je) {
    const constructs = visibleMap(model, unit).constructs;
    let start = js;
    let end = je;
    let grew = true;
    while (grew) {
      grew = false;
      for (const construct of constructs) {
        const overlaps = construct.e > start && construct.s < end;
        const contains = construct.s <= start && construct.e >= end && (construct.cs <= start && construct.ce >= end);
        if (overlaps && !contains && (construct.s < start || construct.e > end)) {
          start = Math.min(start, construct.s);
          end = Math.max(end, construct.e);
          grew = true;
        }
      }
    }
    return [start, end];
  }

  function hasStyle(item, style) {
    return Boolean(item.styles[style] || item.styles[`outer_${style}`]);
  }

  /// `before` and `after` are the source characters around the rewritten text.
  function serializeItems(items, before = "", after = "") {
    // Leading and trailing spaces stay outside emphasis markers.
    for (const style of ["strong", "em", "del", "code"]) {
      let index = 0;
      while (index < items.length) {
        if (!items[index].styles[style]) {
          index += 1;
          continue;
        }
        let end = index;
        while (end < items.length && items[end].styles[style]) end += 1;
        let a = index;
        while (a < end && /\s/.test(items[a].char)) {
          items[a] = { ...items[a], styles: { ...items[a].styles, [style]: false } };
          a += 1;
        }
        let b = end - 1;
        while (b >= a && /\s/.test(items[b].char)) {
          items[b] = { ...items[b], styles: { ...items[b].styles, [style]: false } };
          b -= 1;
        }
        index = end;
      }
    }

    // Each style's run end decides nesting: the style that lasts longer is
    // opened first, so crossing runs split the shorter one instead of
    // producing markers that close out of order. Code is always innermost.
    const runEnd = items.map(() => ({}));
    for (const style of STYLE_ORDER) {
      let end = items.length;
      let key = null;
      for (let index = items.length - 1; index >= 0; index -= 1) {
        const value = items[index].styles[style];
        const currentKey = value ? (style === "link" ? `link:${value.tail}` : style) : null;
        if (currentKey !== key) {
          end = index + 1;
          key = currentKey;
        }
        if (currentKey) runEnd[index][style] = end;
      }
    }
    const desired = (index) => STYLE_ORDER
      .filter((style) => items[index].styles[style])
      .map((style) => ({
        style,
        key: style === "link" ? `link:${items[index].styles.link.tail}` : style,
        tail: style === "link" ? items[index].styles.link.tail : null,
        end: runEnd[index][style]
      }))
      .sort((a, b) => (a.style === "code") - (b.style === "code") || b.end - a.end || STYLE_ORDER.indexOf(a.style) - STYLE_ORDER.indexOf(b.style));

    // Nested or adjacent markers of the same character would read as one
    // marker, so emphasis alternates between * and _, also beside the text around.
    const markerFor = (style, stack, out, end) => {
      const starOpen = stack.some((entry) => entry.open === "*" || entry.open === "**");
      const underscoreOpen = stack.some((entry) => entry.open === "_" || entry.open === "__");
      const last = out.length ? out[out.length - 1] : before;
      const next = end === items.length ? after : "";
      const useUnderscore = starOpen || ((last === "*" || next === "*") && !underscoreOpen);
      switch (style) {
        case "strong": return useUnderscore ? "__" : "**";
        case "em": return useUnderscore ? "_" : "*";
        case "del": return "~~";
        case "code": return "`";
        case "link": return "[";
        default: return "";
      }
    };

    let out = "";
    const stack = [];
    items.forEach((item, position) => {
      const target = desired(position);
      let common = 0;
      while (common < stack.length && common < target.length && stack[common].key === target[common].key) common += 1;
      while (stack.length > common) out += stack.pop().close;
      for (let level = common; level < target.length; level += 1) {
        const entry = { ...target[level] };
        entry.open = markerFor(entry.style, stack, out, entry.end);
        entry.close = entry.style === "link" ? entry.tail : entry.open;
        out += entry.open;
        stack.push(entry);
      }
      out += item.raw;
    });
    while (stack.length) out += stack.pop().close;
    return out;
  }

  /// Toggles bold, italic, strikethrough or inline code on the selected text
  /// of one unit, or sets or removes a link (`value` is the URL or null).
  function planInlineStyle(model, selection, style, value) {
    const first = unitAt(model, selection.from, "right");
    const last = unitAt(model, selection.to, "left");
    if (!first || first !== last || first.kind !== "inline") return null;
    const unit = first;
    const v0 = rawToVisible(model, unit, selection.from, "right");
    const v1 = rawToVisible(model, unit, selection.to, "left");
    if (v1 <= v0 && style !== "link") return null;
    const map = visibleMap(model, unit);
    const jFrom = v1 > v0 ? jOfVisible(map, v0, "start") : jOf(unit, selection.from);
    const jTo = v1 > v0 ? jOfVisible(map, v1, "end") : jOf(unit, selection.to);
    let [js, je] = alignToConstructs(model, unit, jFrom, jTo);
    let styled = styledItems(model, unit, js, je);
    const selectedIndexes = itemIndexesForVisible(styled.items, map, js, v0, v1);

    if (style === "code" && selectedIndexes.some((index) => styled.items[index].opaque || /`/.test(styled.items[index].char))) return null;

    const selectedItems = selectedIndexes.map((index) => styled.items[index]);
    const allHave = selectedItems.length > 0 && selectedItems.every((item) => item.opaque || /\s/.test(item.char) || hasStyle(item, style))
      && selectedItems.some((item) => !item.opaque && !/\s/.test(item.char));
    const removing = style === "link" ? !value : allHave;

    if ((removing || style === "link") && selectedItems.some((item) => item.styles[`outer_${style}`])) {
      // The style comes from a construct around the region; rewrite all of it. A link set on part
      // of a link's text splits it, as links cannot nest.
      const constructs = map.constructs.filter((construct) => construct.type === style && construct.s <= js && construct.e >= je);
      for (const construct of constructs) {
        js = Math.min(js, construct.s);
        je = Math.max(je, construct.e);
      }
      [js, je] = alignToConstructs(model, unit, js, je);
      styled = styledItems(model, unit, js, je);
    }
    const indexes = new Set(itemIndexesForVisible(styled.items, map, js, v0, v1));
    const items = styled.items.map((item, index) => {
      if (!indexes.has(index)) return item;
      const styles = { ...item.styles };
      if (style === "link") styles.link = value ? { tail: `](${value})` } : null;
      else styles[style] = !removing;
      return { ...item, styles };
    });
    const from = rawOf(unit, js);
    const to = rawOf(unit, je);
    const insert = serializeItems(items, model.source.charAt(from - 1), model.source.charAt(to));
    const topStart = bStart(unit.top);
    const unitIndex = unitsOf(unit.top).indexOf(unit);
    return {
      from,
      to,
      insert,
      kind: "format",
      label: STYLE_LABELS[style] || "Format",
      select: (next) => {
        const top = next.blocks[lastBlockStartingAtOrBefore(next.blocks, topStart)];
        const candidate = top && unitsOf(top)[unitIndex] ? unitsOf(top)[unitIndex] : unitAt(next, from, "right");
        if (!candidate) return caretAt(from);
        return {
          anchor: visibleToRaw(next, candidate, v0, "right"),
          head: visibleToRaw(next, candidate, v1, "left")
        };
      }
    };
  }

  const STYLE_LABELS = { strong: "Bold", em: "Italic", del: "Strikethrough", code: "Inline Code", link: "Link" };

  function jOfVisible(map, v, edge) {
    for (const segment of map.segments) {
      const end = segment.v + segment.len;
      if (edge === "start" && v >= segment.v && v < end) return segment.atom ? segment.s : segment.j + (v - segment.v);
      if (edge === "end" && v > segment.v && v <= end) return segment.atom ? segment.e : segment.j + (v - segment.v);
    }
    const last = map.segments[map.segments.length - 1];
    if (!last) return 0;
    return edge === "start" ? map.segments[0].j : (last.atom ? last.e : last.j + last.len);
  }

  /// Maps visible offsets to positions in a styled item list built for [js, …).
  function itemIndexesForVisible(items, map, js, v0, v1) {
    const result = [];
    let v = visibleBefore(map, js);
    items.forEach((_, index) => {
      if (v >= v0 && v < v1) result.push(index);
      v += 1;
    });
    return result;
  }

  function visibleBefore(map, j) {
    let count = 0;
    for (const segment of map.segments) {
      if (segment.atom) {
        if (segment.e <= j) count += 1;
        continue;
      }
      if (segment.j + segment.len <= j) count += segment.len;
      else if (segment.j < j) count += j - segment.j;
    }
    return count;
  }

  /// The styles every selected character carries, and the link under the caret.
  function inlineState(model, selection) {
    const unit = unitAt(model, selection.head, "left");
    const state = { strong: false, em: false, del: false, code: false, link: null };
    if (!unit || unit.kind !== "inline") return state;
    const map = visibleMap(model, unit);
    const j = jOf(unit, selection.head);
    const link = map.constructs.find((construct) => (construct.type === "link" || construct.type === "wikilink" || construct.type === "autolink")
      && construct.cs <= j && j <= construct.ce && (construct.cs < j || construct.ce > j || construct.cs === construct.ce));
    if (link) {
      state.link = {
        kind: link.type,
        href: link.type === "wikilink" ? link.destination : link.href,
        from: rawOf(unit, link.s),
        to: rawOf(unit, link.e),
        contentFrom: rawOf(unit, link.cs),
        contentTo: rawOf(unit, link.ce)
      };
    }
    let js;
    let je;
    if (selection.from === selection.to) {
      js = j;
      je = j;
    } else {
      js = jOf(unit, selection.from);
      je = jOf(unit, Math.min(selection.to, unitEnd(unit)));
    }
    for (const style of ["strong", "em", "del", "code"]) {
      const covering = map.constructs.filter((construct) => construct.type === style);
      if (js === je) {
        state[style] = covering.some((construct) => construct.cs < js && js <= construct.ce);
      } else {
        state[style] = rangeCovered(map, covering, js, je);
      }
    }
    return state;
  }

  function rangeCovered(map, constructs, js, je) {
    let any = false;
    for (const segment of map.segments) {
      if (segment.atom) continue;
      const start = Math.max(js, segment.j);
      const end = Math.min(je, segment.j + segment.len);
      for (let index = start; index < end; index += 1) {
        const character = map.visible[segment.v + (index - segment.j)];
        if (/\s/.test(character)) continue;
        any = true;
        if (!constructs.some((construct) => construct.cs <= index && index < construct.ce)) return false;
      }
    }
    return any;
  }

  // Block types -------------------------------------------------------

  function blockTypeOf(unit) {
    if (!unit) return "paragraph";
    if (unit.kind === "code") return "code";
    if (unit.role === "heading") return `heading${unit.level}`;
    if (unit.role === "item") {
      if (unit.item.task) return "todo";
      return unit.list.ordered ? "numbered" : "bullet";
    }
    if (unit.role === "cell") return "table";
    if (unit.role === "summary") return "toggle";
    if (unit.container && unit.container.type === "quote") return unit.container.callout ? "callout" : "quote";
    return "paragraph";
  }

  /// The raw content of a text-like unit, without its block markers, and without the source range
  /// `cut` when one is given.
  function unitContent(model, unit, cut) {
    const source = model.source;
    const slice = (s, e) => (cut
      ? source.slice(s, Math.max(s, Math.min(e, cut[0]))) + source.slice(Math.min(e, Math.max(s, cut[1])), e)
      : source.slice(s, e));
    if (unit.kind === "empty") return "";
    if (unit.role === "heading") return slice(S(unit, unit.block.contentStart), S(unit, unit.block.contentEnd));
    if (unit.role === "item") {
      return unit.item.lines.map((view, index) => index === 0
        ? slice(S(unit, unit.item.contentStart), S(unit, view.end))
        : slice(S(unit, view.start), S(unit, view.end)).replace(/^\s+/, "")).join(" ");
    }
    if (unit.role === "paragraph") {
      return unit.block.lines.map((view) => slice(S(unit, view.start), S(unit, view.end))).join(model.eol);
    }
    return slice(unitStart(unit), unitEnd(unit));
  }

  /// The source lines a unit occupies, from the start of its first line
  /// (container prefix included) to the end of its last.
  function unitLineRange(model, unit) {
    const source = model.source;
    if (unit.kind === "empty") {
      if (!unit.block.view) return [unitStart(unit), unitStart(unit)];
      const start = lineStartOf(source, S(unit, unit.block.view.start));
      return [start, lineEndOf(source, start)];
    }
    if (unit.role === "heading") return [lineStartOf(source, S(unit, unit.block.start)), S(unit, unit.block.view.end)];
    if (unit.role === "item") return [lineStartOf(source, S(unit, unit.item.view.start)), S(unit, unit.item.end)];
    if (unit.role === "paragraph") {
      const lines = unit.block.lines;
      return [lineStartOf(source, S(unit, lines[0].start)), S(unit, lines[lines.length - 1].end)];
    }
    return [lineStartOf(source, unitStart(unit)), lineEndOf(source, unitEnd(unit))];
  }

  function prefixForType(type, number, unit) {
    switch (type) {
      case "heading1": case "heading2": case "heading3": case "heading4": case "heading5": case "heading6":
        return "#".repeat(Number(type.slice(-1))) + " ";
      case "bullet": return "- ";
      case "numbered": return `${number}. `;
      case "todo": return unit && unit.role === "item" && unit.item.task && unit.item.task.checked ? "- [x] " : "- [ ] ";
      default: return "";
    }
  }

  /// Whether the source between two converted units holds blocks of its own (a code block, a
  /// table, a divider), which stay as they are: anything but blank lines and quote markers.
  function holdsBlock(between) {
    return /[^\s>]/.test(between);
  }

  /// Turns the selected blocks into `type`. Converting blocks that already
  /// all have the type turns them back into paragraphs when `toggle` is set.
  /// `without` is a source range left out of the text (a slash command).
  function planBlockType(model, selection, type, options = {}) {
    const units = unitsBetween(model, selection.from, selection.to).filter((unit) => isConvertible(unit) || unit.kind === "code");
    if (units.length === 0) return null;
    let target = type;
    if (options.toggle && units.every((unit) => blockTypeOf(unit) === type)) target = "paragraph";
    if (units.length === 1 && units[0].kind === "code") {
      if (target === "code") return null;
      return codeToText(model, units[0], target);
    }
    const textUnits = units.filter(isConvertible);
    if (textUnits.length === 0) return null;
    if (target === "code") return textToCode(model, textUnits);
    if (textUnits.length === 1 && textUnits[0].kind === "empty") {
      const marker = target === "quote" ? "> " : prefixForType(target, 1, textUnits[0]);
      if (!marker) return null;
      return { ...materializeEmpty(model, textUnits[0], marker), kind: "format", label: BLOCK_LABELS[target] };
    }

    const source = model.source;
    const eol = model.eol;
    const listLike = target === "bullet" || target === "numbered" || target === "todo";
    const caret = describeSelection(model, selection, textUnits);
    // Numbers count per list level, and start again after a block kept between.
    let levels = [];
    const numberAt = (indent) => {
      levels = levels.filter((level) => level.indent <= indent);
      const last = levels[levels.length - 1];
      if (last && last.indent === indent) return ++last.count;
      levels.push({ indent, count: 1 });
      return 1;
    };
    let previousEnd = null;
    let replacement = "";
    let rangeStart = null;
    for (const unit of textUnits) {
      const [lineStart, lineEnd] = unitLineRange(model, unit);
      const prefix = target === "quote" ? "" : quotePrefixOfLine(source, lineStart);
      if (previousEnd === null) {
        rangeStart = lineStart;
      } else {
        const between = source.slice(previousEnd, lineStart);
        if (holdsBlock(between)) {
          replacement += between;
          levels = [];
        } else if (listLike) {
          replacement += eol;
        } else {
          const separates = countLineBreaks(between) >= 2 || (target !== "paragraph" && target !== "quote");
          replacement += separates ? between : eol + prefix.trimEnd() + eol;
        }
      }
      const content = unitContent(model, unit, options.without);
      if (target === "quote") {
        const existing = quotePrefixOfLine(source, lineStart);
        replacement += content.split(eol).map((line) => `${existing}> ${line}`.replace(/> $/, ">")).join(eol);
      } else if (unit.kind === "empty" && target === "paragraph") {
        replacement += prefix;
      } else {
        const item = unit.role === "item" && listLike ? unit.item : null;
        const marker = prefixForType(target, numberAt(item ? item.indent : 0), unit);
        const indent = item ? source.slice(lineStart + prefix.length, S(unit, item.markerStart)) : "";
        const body = target.startsWith("heading") ? content.split(eol).join(" ") : prefixFollowingLines(content, prefix, eol);
        replacement += prefix + indent + marker + body;
      }
      previousEnd = lineEnd;
    }
    // An item or heading made into text gets blank lines around it, so it does not join its neighbours.
    let gap = { before: "", after: "" };
    if (target === "paragraph" && rangeStart === lineStartOf(source, rangeStart)
      && textUnits.some((unit) => unit.role === "item" || unit.role === "heading")) {
      gap = paragraphSeparation(source, rangeStart, lineEndOf(source, previousEnd), quotePrefixOfLine(source, rangeStart), eol);
    }
    const restoreFrom = rangeStart + gap.before.length;
    return {
      from: rangeStart,
      to: previousEnd,
      insert: gap.before + replacement + gap.after,
      select: (next) => restoreDescribedSelection(next, caret, restoreFrom, isConvertible),
      kind: "format",
      label: BLOCK_LABELS[target] || "Format"
    };
  }

  const BLOCK_LABELS = {
    paragraph: "Paragraph",
    heading1: "Heading 1",
    heading2: "Heading 2",
    heading3: "Heading 3",
    heading4: "Heading 4",
    heading5: "Heading 5",
    heading6: "Heading 6",
    bullet: "Bullet List",
    numbered: "Numbered List",
    todo: "Task List",
    quote: "Quote",
    code: "Code Block"
  };

  /// Where a selection sits as unit order and visible offsets, which a block
  /// type change keeps.
  function describeSelection(model, selection, units) {
    const describe = (raw, side) => {
      const unit = unitAt(model, raw, side);
      const index = units.indexOf(unit);
      if (index < 0) return null;
      return { index, v: rawToVisible(model, unit, raw, side) };
    };
    return { anchor: describe(selection.anchor, "left"), head: describe(selection.head, "left") };
  }

  /// The described selection in `model`, counting the units from `rangeStart` that `include` takes.
  function restoreDescribedSelection(model, described, rangeStart, include = () => true) {
    const units = allUnits(model).filter((unit) => unitEnd(unit) >= rangeStart && include(unit));
    const resolve = (point) => {
      if (!point) return null;
      const unit = units[point.index] || units[units.length - 1];
      if (!unit) return null;
      return visibleToRaw(model, unit, Math.min(point.v, visibleText(model, unit).length), "left");
    };
    const anchor = resolve(described.anchor);
    const head = resolve(described.head);
    if (anchor === null && head === null) return caretAt(closestUnitPosition(model, rangeStart));
    return { anchor: anchor ?? head, head: head ?? anchor };
  }

  /// Text blocks made into code: one code block for each run of them, around the blocks between
  /// runs, which stay. The caret goes to the end of the last one's code.
  function textToCode(model, units) {
    const source = model.source;
    const eol = model.eol;
    const runs = [];
    let previousEnd = null;
    for (const unit of units) {
      const [start, end] = unitLineRange(model, unit);
      if (previousEnd === null || holdsBlock(source.slice(previousEnd, start))) runs.push({ start, units: [] });
      const run = runs[runs.length - 1];
      run.units.push(unit);
      run.end = end;
      previousEnd = end;
    }
    let closing = 0;
    const parts = runs.map((run) => {
      const prefix = quotePrefixOfLine(source, run.start);
      const body = run.units.map((unit) => unitContent(model, unit)).join(eol).split(eol).join(eol + prefix);
      closing = eol.length + prefix.length + 3;
      return { s: run.start, e: run.end, keep: `${prefix}\`\`\`${eol}${prefix}${body}${eol}${prefix}\`\`\`` };
    });
    const op = compose(source, parts);
    return { ...op, select: caretAt(op.from + op.insert.length - closing), kind: "format", label: "Code Block" };
  }

  function codeToText(model, unit, target) {
    const block = unit.block;
    const source = model.source;
    const eol = model.eol;
    const start = S(unit, block.start);
    const end = S(unit, block.end);
    const prefix = quotePrefixOfLine(source, start);
    const lines = block.body.map((view) => source.slice(S(unit, view.start), S(unit, view.end)));
    const marker = prefixForType(target, 1, null);
    const text = lines.length ? lines.map((line, index) => (index === 0 ? marker : "") + line).join(eol + prefix) : marker;
    return { from: start, to: end, insert: text, select: caretAt(start + marker.length), kind: "format", label: BLOCK_LABELS[target] || "Paragraph" };
  }

  // Lists: indent and outdent -----------------------------------------

  function planIndent(model, selection, direction) {
    const units = unitsBetween(model, selection.from, selection.to).filter((unit) => unit.role === "item");
    if (units.length === 0) return null;
    const source = model.source;
    const first = units[0];
    const last = units[units.length - 1];
    const start = lineStartOf(source, S(first, first.item.view.start));
    const end = itemSubtreeEnd(last.item);
    // A list's first item has no item above to go under.
    if (direction > 0 && first.list.items[0] === first.item) return null;
    const prefix = quotePrefixOfLine(source, start);
    const width = Math.max(2, first.item.contentStart - first.item.markerStart - (first.item.task ? 4 : 0));
    // The lines at even places, each followed by its own line ending, which stays.
    const pieces = source.slice(start, end).split(/(\r\n|\r|\n)/);
    // How far the anchor and the head each move: by what changes on their line and the lines above.
    let anchorShift = 0;
    let headShift = 0;
    let lineOffset = start;
    for (let index = 0; index < pieces.length; index += 2) {
      const line = pieces[index];
      const body = line.slice(prefix.length);
      let result;
      let change;
      if (direction > 0) {
        result = prefix + " ".repeat(width) + body;
        change = width;
      } else {
        const leading = (/^[ \t]*/.exec(body) || [""])[0];
        const remove = leading.startsWith("\t") ? 1 : Math.min(leading.length, width);
        result = prefix + body.slice(remove);
        change = -remove;
      }
      if (lineOffset <= selection.anchor) anchorShift += change;
      if (lineOffset <= selection.head) headShift += change;
      lineOffset += line.length + (pieces[index + 1] || "").length;
      pieces[index] = result;
    }
    // A numbered item indented under a sibling with no sub-list starts one, numbered from 1.
    let renumbered = 0;
    if (direction > 0 && first.list.ordered) {
      const siblings = first.list.items;
      const previous = siblings[siblings.indexOf(first.item) - 1];
      if (previous && previous.children.length === 0) {
        pieces[0] = pieces[0].replace(/^((?:[ \t>]*?)[ \t]*)(\d+)([.)])/, (match, lead, number, delimiter) => {
          renumbered = number.length - 1;
          return `${lead}1${delimiter}`;
        });
      }
    }
    const insert = pieces.join("");
    if (insert === source.slice(start, end)) return null;
    return {
      from: start,
      to: end,
      insert,
      select: { anchor: selection.anchor + anchorShift - renumbered, head: selection.head + headShift - renumbered },
      kind: "format",
      label: direction > 0 ? "Indent" : "Outdent"
    };
  }

  // Tables ------------------------------------------------------------

  function tableCells(model, table) {
    return allUnits(model).filter((unit) => unit.role === "cell" && unit.table === table);
  }

  /// The cells of the table holding `cell`, from the units of its top-level block alone.
  function cellsOf(cell) {
    return unitsOf(cell.top).filter((unit) => unit.role === "cell" && unit.table === cell.table);
  }

  function emptyRow(table) {
    return "|" + "  |".repeat(table.header.cells.length);
  }

  function planTable(model, unit, action) {
    if (!unit || unit.role !== "cell") return null;
    const table = unit.table;
    const source = model.source;
    const eol = model.eol;
    const shift = nodeShift(table);
    const prefix = quotePrefixOfLine(source, table.start + shift);
    const rowIndex = unit.rowIndex + 1;
    const column = unit.column;
    const rowView = (index) => (index === 0 ? table.header.view : table.rows[index - 1].view);
    const lineStart = (view) => lineStartOf(source, view.start + shift);
    switch (action) {
      case "rowAbove":
      case "rowBelow": {
        // Rows go after a line: the delimiter for the first body row, otherwise the row before.
        const anchor = action === "rowBelow"
          ? (rowIndex === 0 ? table.delimiter : rowView(rowIndex))
          : (rowIndex <= 1 ? table.delimiter : rowView(rowIndex - 1));
        const at = anchor.end + shift;
        const insert = eol + prefix + emptyRow(table);
        return { from: at, to: at, insert, select: caretAt(at + eol.length + prefix.length + 2), kind: "format", label: "Insert Row" };
      }
      case "deleteRow": {
        if (rowIndex === 0) return null;
        const view = rowView(rowIndex);
        const start = lineStart(view);
        const end = view.end + shift;
        const previous = previousLineEnd(source, start);
        if (table.rows.length === 1) {
          return { from: start, to: end, insert: prefix + emptyRow(table), select: caretAt(start + prefix.length + 2), kind: "format", label: "Delete Row" };
        }
        return { from: previous, to: end, insert: "", select: caretAt(Math.max(0, previous)), kind: "format", label: "Delete Row" };
      }
      case "columnLeft":
      case "columnRight": {
        const parts = [];
        const allViews = [table.header, null, ...table.rows];
        allViews.forEach((row, index) => {
          if (index === 1) {
            const cells = MD.tableRow(table.delimiter).cells;
            const cell = cells[column];
            if (!cell) return;
            const at = action === "columnLeft" ? cell.slotStart + shift : cell.slotEnd + shift;
            parts.push({ s: at, e: at, keep: action === "columnLeft" ? " --- |" : "| --- " });
            return;
          }
          const cell = row.cells[column];
          if (!cell) return;
          const at = action === "columnLeft" ? cell.slotStart + shift : cell.slotEnd + shift;
          parts.push({ s: at, e: at, keep: action === "columnLeft" ? "  |" : "|  " });
        });
        const op = compose(source, parts);
        if (!op) return null;
        op.kind = "format";
        op.label = "Insert Column";
        op.select = (next) => {
          const targetColumn = action === "columnLeft" ? column : column + 1;
          const top = next.blocks[lastBlockStartingAtOrBefore(next.blocks, bStart(unit.top))];
          const cell = top && unitsOf(top).find((candidate) => candidate.role === "cell" && candidate.rowIndex === unit.rowIndex && candidate.column === targetColumn);
          return caretAt(cell ? unitStart(cell) : op.from);
        };
        return op;
      }
      case "deleteColumn": {
        if (table.header.cells.length <= 1) return planTable(model, unit, "deleteTable");
        const parts = [];
        const views = [table.header, MD.tableRow(table.delimiter), ...table.rows];
        for (const row of views) {
          const cell = row.cells[column];
          if (!cell) continue;
          const pipeAfter = source[cell.slotEnd + shift] === "|";
          parts.push(pipeAfter
            ? { s: cell.slotStart + shift, e: cell.slotEnd + shift + 1, keep: "" }
            : { s: cell.slotStart + shift - 1, e: cell.slotEnd + shift, keep: "" });
        }
        const op = compose(source, parts);
        if (!op) return null;
        op.kind = "format";
        op.label = "Delete Column";
        op.select = (next) => caretAt(closestUnitPosition(next, op.from));
        return op;
      }
      case "deleteTable": {
        const start = table.start + shift;
        const end = table.end + shift;
        return { from: start, to: end, insert: "", select: (next) => caretAt(closestUnitPosition(next, start)), kind: "delete", label: "Delete Table" };
      }
      default:
        return null;
    }
  }

  function cellNeighbor(model, unit, direction) {
    const cells = cellsOf(unit);
    const index = cells.indexOf(unit);
    if (direction === "next") return cells[index + 1] || null;
    if (direction === "previous") return cells[index - 1] || null;
    if (direction === "down") return cells.find((cell) => cell.rowIndex === unit.rowIndex + 1 && cell.column === unit.column) || null;
    return null;
  }

  // Blocks inserted from the slash menu -------------------------------

  function tableTemplate(eol, prefix) {
    return [`|  |  |  |`, `| --- | --- | --- |`, `|  |  |  |`, `|  |  |  |`].map((line, index) => (index === 0 ? "" : prefix) + line).join(eol);
  }

  /// Inserts a whole block (`text`, possibly several lines) on its own after
  /// the block holding `unit`, or in place of `unit` when it is empty.
  /// `caretIn` is the caret's offset inside `text`.
  function planInsertBlock(model, unit, text, caretIn, label) {
    const source = model.source;
    const eol = model.eol;
    if (unit.kind === "empty") {
      const op = materializeEmpty(model, unit, text);
      const start = op.from + (op.insert.indexOf(text.split(eol)[0]) >= 0 ? op.insert.indexOf(text.split(eol)[0]) : 0);
      op.select = caretAt(start + adjustCaretForPrefix(text, caretIn, quotePrefixOfLine(source, op.from), eol));
      op.kind = "format";
      op.label = label;
      return op;
    }
    const at = unit.role === "item" ? S(unit, unit.item.end) : lineEndOfUnit(model, unit);
    const prefix = quotePrefixOfLine(source, at);
    const blank = prefix.trimEnd();
    const after = blankLinesAfter(source, at, prefix);
    const body = prefixFollowingLines(text, prefix, eol);
    const before = eol + blank + eol + prefix;
    const trailing = after.trailing || after.count >= 1 ? "" : eol + blank;
    const insert = before + body + trailing;
    return {
      from: at,
      to: at,
      insert,
      select: caretAt(at + before.length + adjustCaretForPrefix(text, caretIn, prefix, eol)),
      kind: "format",
      label
    };
  }

  /// `caretIn` moved past the container prefixes `prefixFollowingLines` gives the lines of `text`:
  /// the whole prefix, or its trimmed form on a blank line.
  function adjustCaretForPrefix(text, caretIn, prefix, eol) {
    const lineEnd = text.indexOf(eol, caretIn);
    const end = lineEnd < 0 ? text.length : lineEnd;
    return prefixFollowingLines(text.slice(0, end), prefix, eol).length - (end - caretIn);
  }

  /// Replaces the `/query` typed in `unit` with the chosen block.
  function planSlashCommand(model, unit, slashFrom, slashTo, command) {
    const source = model.source;
    const eol = model.eol;
    if (!unit || unit.kind !== "inline") return null;
    const removeSlash = { s: slashFrom, e: slashTo, keep: "" };
    const typeCommands = {
      text: "paragraph", h1: "heading1", h2: "heading2", h3: "heading3",
      bullet: "bullet", numbered: "numbered", todo: "todo", quote: "quote"
    };

    if (typeCommands[command]) {
      // The block changes as Turn Into changes it, without the command's text.
      const op = unit.role === "cell" ? null : planBlockType(model, withOrder(slashFrom, slashFrom), typeCommands[command], { without: [slashFrom, slashTo] });
      return op || compose(source, [removeSlash]);
    }

    let block = null;
    let caretIn = 0;
    let label = "";
    switch (command) {
      case "code":
        block = "```" + eol + eol + "```";
        caretIn = 3 + eol.length;
        label = "Code Block";
        break;
      case "table":
        block = tableTemplate(eol, "");
        caretIn = 2;
        label = "Table";
        break;
      case "divider":
        block = "---";
        caretIn = 3;
        label = "Divider";
        break;
      case "toc":
        block = "[TOC]";
        caretIn = 5;
        label = "Table of Contents";
        break;
      default:
        return null;
    }
    // A divider or table of contents holds no text: the caret goes to a line after it.
    const atomic = command === "divider" || command === "toc";
    const content = visibleText(model, unit);
    const remaining = content.slice(0, rawToVisible(model, unit, slashFrom, "right")) + content.slice(rawToVisible(model, unit, slashTo, "left"));

    // A paragraph, heading or item holding nothing else gives its line to the block.
    if (remaining.trim() === "" && (unit.role === "paragraph" || unit.role === "heading" || unit.role === "item")) {
      const [start, end] = unitLineRange(model, unit);
      const prefix = quotePrefixOfLine(source, start);
      const blank = prefix.trimEnd();
      const gapAfter = blankLinesAfter(source, end, prefix);
      const body = prefixFollowingLines(block, prefix, eol);
      let trailing = "";
      if (atomic) trailing = (eol + blank).repeat(breaksForEmptyLine(gapAfter));
      else if (!gapAfter.trailing && gapAfter.count === 0) trailing = eol + blank;
      // Text above in the same container needs a blank line between; a container's first line does not.
      const leading = paragraphSeparation(source, start, end, prefix, eol).before;
      const insert = leading + prefix + body + trailing;
      const caret = start + leading.length + prefix.length + adjustCaretForPrefix(block, caretIn, prefix, eol);
      return {
        from: start,
        to: end,
        insert,
        select: atomic ? (next) => caretOnFirstEmptyAfter(next, start + leading.length + prefix.length + block.length) : caretAt(caret),
        kind: "format",
        label
      };
    }

    const inserted = planInsertBlock(model, unit, block, caretIn, label);
    const parts = [removeSlash, { s: inserted.from, e: inserted.to, keep: inserted.insert }];
    const op = compose(source, parts);
    const removed = slashTo - slashFrom;
    const caret = typeof inserted.select === "function" ? null : inserted.select.head - removed;
    op.select = caret === null ? inserted.select : caretAt(caret);
    if (atomic) op.select = (next) => caretOnFirstEmptyAfter(next, inserted.from - removed + 1);
    op.kind = "format";
    op.label = label;
    return op;
  }

  function planToggleTask(model, unit) {
    if (!unit || unit.role !== "item" || !unit.item.task) return null;
    const at = S(unit, unit.item.task.boxStart);
    const checked = unit.item.task.checked;
    return { from: at, to: at + 1, insert: checked ? " " : "x", select: null, kind: "format", label: "Toggle Task" };
  }

  /// The Markdown of [from, to) with markers added so emphasis cut by the
  /// selection still opens and closes.
  function balancedMarkdown(model, from, to) {
    const source = model.source;
    let text = source.slice(from, to);
    const first = unitAt(model, from, "right");
    const last = unitAt(model, to, "left");
    const prefix = [];
    const suffix = [];
    const scan = (unit, start, end, atStart) => {
      if (!unit || unit.kind !== "inline") return;
      for (const construct of visibleMap(model, unit).constructs) {
        const s = rawOf(unit, construct.s);
        const cs = rawOf(unit, construct.cs);
        const ce = rawOf(unit, construct.ce);
        const e = rawOf(unit, construct.e);
        if (atStart && s < start && cs <= start && start < ce && ce <= end && e <= end) prefix.push(source.slice(s, cs));
        if (!atStart && start <= s && cs <= end && ce >= end && e > end) suffix.unshift(source.slice(ce, e));
      }
    };
    scan(first, from, to, true);
    scan(last, from, to, false);
    if (first === last && first) {
      // Both edges inside one construct: wrap the selection in its markers.
      for (const construct of first.kind === "inline" ? visibleMap(model, first).constructs : []) {
        const s = rawOf(first, construct.s);
        const cs = rawOf(first, construct.cs);
        const ce = rawOf(first, construct.ce);
        const e = rawOf(first, construct.e);
        if (cs <= from && to <= ce && (cs < from || to < ce) && construct.type !== "link" && construct.type !== "wikilink" && construct.type !== "autolink") {
          prefix.unshift(source.slice(s, cs));
          suffix.push(source.slice(ce, e));
        }
      }
    }
    text = prefix.join("") + text + suffix.join("");
    return text;
  }

  // ---------------------------------------------------------------------
  // Whole blocks: what the handles move, duplicate, delete and turn into
  //
  // A handle belongs to a top-level block (a quote, callout, toggle or table
  // whole) or to a list item together with the items nested under it. Both
  // move as their source lines, so nothing inside them is re-written.
  // ---------------------------------------------------------------------

  function handleTargetOf(model, unit) {
    if (!unit) return null;
    if (unit.role === "item") return { kind: "item", top: unit.top, list: unit.list, item: unit.item };
    const index = blockIndex(model, unit.top);
    return index >= 0 ? { kind: "block", index, block: unit.top } : null;
  }

  function isLineBlank(source, position) {
    if (position < 0 || position > source.length) return true;
    const start = lineStartOf(source, position);
    return /^[ \t]*$/.test(source.slice(start, lineEndOf(source, start)));
  }

  /// The source a top-level block takes away when it leaves: its lines and the separator after
  /// them, or before them when it is the last block.
  function topRemovalRange(model, index) {
    const blocks = model.blocks;
    const source = model.source;
    const block = blocks[index];
    const start = lineStartOf(source, bStart(block));
    // Right under the block before it (a heading, a paragraph a list interrupts): its line break
    // goes and the gap after it stays, so the blocks on either side do not run together.
    if (index > 0 && !isLineBlank(source, previousLineEnd(source, start))) return { s: previousLineEnd(source, start), e: bEnd(block) };
    if (index < blocks.length - 1) return { s: start, e: lineStartOf(source, bStart(blocks[index + 1])) };
    if (index > 0) return { s: bEnd(blocks[index - 1]), e: bEnd(block) };
    return { s: 0, e: source.length };
  }

  function topChunk(model, index) {
    const block = model.blocks[index];
    return model.source.slice(lineStartOf(model.source, bStart(block)), bEnd(block));
  }

  /// Where a block goes in the gap before block `gap` (after the last block when `gap` is the
  /// block count), and the line breaks around it that leave one blank line on each side.
  function topInsertion(model, gap) {
    const blocks = model.blocks;
    const source = model.source;
    const eol = model.eol;
    if (blocks.length === 0) return { at: 0, before: "", after: "" };
    if (gap < blocks.length) {
      const at = lineStartOf(source, bStart(blocks[gap]));
      const before = at > 0 && !isLineBlank(source, previousLineEnd(source, at)) ? eol : "";
      return { at, before, after: eol + eol };
    }
    const at = bEnd(blocks[blocks.length - 1]);
    const next = nextLineStart(source, at);
    const after = next > at && next < source.length && !isLineBlank(source, next) ? eol : "";
    return { at, before: eol + eol, after };
  }

  function itemRange(model, target) {
    return [lineStartOf(model.source, atNode(target.item, target.item.view.start)), itemSubtreeEnd(target.item)];
  }

  /// Rewrites a list with its items in `order` (indexes into its items). Markers keep their
  /// places, so an ordered list still counts from its first number.
  function rebuildList(model, top, list, order, selection, label, moved) {
    const source = model.source;
    const items = list.items;
    const ranges = items.map((item) => [lineStartOf(source, atNode(item, item.view.start)), itemSubtreeEnd(item)]);
    const gaps = ranges.slice(1).map((range, index) => source.slice(ranges[index][1], range[0]));
    const from = ranges[0][0];
    const to = ranges[ranges.length - 1][1];
    const starts = new Map();
    let insert = "";
    order.forEach((original, position) => {
      if (position > 0) insert += gaps[position - 1];
      let chunk = source.slice(ranges[original][0], ranges[original][1]);
      let markerDelta = 0;
      const markerOffset = atNode(items[original], items[original].markerStart) - ranges[original][0];
      if (list.ordered && items[position].marker !== items[original].marker) {
        chunk = chunk.slice(0, markerOffset) + items[position].marker + chunk.slice(markerOffset + items[original].marker.length);
        markerDelta = items[position].marker.length - items[original].marker.length;
      }
      starts.set(original, { start: from + insert.length, markerOffset, markerDelta });
      insert += chunk;
    });
    const map = (position) => {
      if (position < from) return position;
      if (position > to) return position + insert.length - (to - from);
      for (let index = 0; index < ranges.length; index += 1) {
        const [start, end] = ranges[index];
        if (position >= start && position <= end) {
          const placed = starts.get(index);
          const offset = position - start;
          return placed.start + offset + (offset > placed.markerOffset ? placed.markerDelta : 0);
        }
      }
      return position;
    };
    return {
      from,
      to,
      insert,
      select: selection ? { anchor: map(selection.anchor), head: map(selection.head) } : null,
      kind: "format",
      label,
      movedStart: moved !== undefined && starts.has(moved) ? starts.get(moved).start : undefined
    };
  }

  /// Moves a handle's block into a gap: before block `gap` at the top level (the block count for
  /// the end), or before item `gap` of the same list. Returns null for a drop where it already is.
  function planMoveBlock(model, target, gap, selection) {
    if (!target) return null;
    if (target.kind === "item") {
      const items = target.list.items;
      const from = items.indexOf(target.item);
      if (from < 0 || gap === from || gap === from + 1 || gap < 0 || gap > items.length) return null;
      const order = items.map((_, index) => index);
      order.splice(from, 1);
      order.splice(gap > from ? gap - 1 : gap, 0, from);
      return rebuildList(model, target.top, target.list, order, selection, "Move", from);
    }
    const blocks = model.blocks;
    const index = target.index;
    if (index < 0 || index >= blocks.length || gap === index || gap === index + 1 || gap < 0 || gap > blocks.length) return null;
    const removal = topRemovalRange(model, index);
    const chunk = topChunk(model, index);
    const chunkStart = lineStartOf(model.source, bStart(blocks[index]));
    const place = topInsertion(model, gap);
    const text = place.before + chunk + place.after;
    const op = compose(model.source, [{ s: removal.s, e: removal.e, keep: "" }, { s: place.at, e: place.at, keep: text }]);
    if (!op) return null;
    const newChunkStart = (place.at <= removal.s ? place.at : place.at - (removal.e - removal.s)) + place.before.length;
    const map = (position) => {
      if (position >= chunkStart && position <= chunkStart + chunk.length) return newChunkStart + (position - chunkStart);
      return mapSelectionThrough({ anchor: position, head: position }, { from: removal.s, to: removal.e, insert: "" }).head;
    };
    op.select = selection ? { anchor: map(selection.anchor), head: map(selection.head) } : caretAt(newChunkStart);
    op.kind = "format";
    op.label = "Move";
    op.movedStart = newChunkStart;
    return op;
  }

  /// ⇧⌘↑ / ⇧⌘↓: a handle's block swaps with its neighbour (`direction` -1 or 1).
  function planMoveByStep(model, target, direction, selection) {
    if (!target) return null;
    const index = target.kind === "item" ? target.list.items.indexOf(target.item) : target.index;
    return planMoveBlock(model, target, direction < 0 ? index - 1 : index + 2, selection);
  }

  function planDuplicateBlock(model, target) {
    if (!target) return null;
    const source = model.source;
    const eol = model.eol;
    if (target.kind === "item") {
      const [start, end] = itemRange(model, target);
      const chunk = source.slice(start, end);
      return { from: end, to: end, insert: eol + chunk, select: caretAt(end + eol.length + (lineEndOf(source, start) - start)), kind: "format", label: "Duplicate" };
    }
    const block = model.blocks[target.index];
    const chunk = topChunk(model, target.index);
    const at = bEnd(block);
    const next = nextLineStart(source, at);
    const after = next > at && next < source.length && !isLineBlank(source, next) ? eol : "";
    const insert = eol + eol + chunk + after;
    const copyStart = at + eol.length * 2;
    return { from: at, to: at, insert, select: caretAt(copyStart + Math.min(chunk.length, lineEndOf(chunk, 0))), kind: "format", label: "Duplicate", movedStart: copyStart };
  }

  function planDeleteBlock(model, target) {
    if (!target) return null;
    const source = model.source;
    if (target.kind === "item") {
      const [start, end] = itemRange(model, target);
      const next = nextLineStart(source, end);
      const from = next > end ? start : Math.max(0, previousLineEnd(source, start));
      const to = next > end ? next : end;
      return { from, to, insert: "", select: (nextModel) => caretAt(positionBefore(nextModel, from)), kind: "delete", label: "Delete" };
    }
    const range = topRemovalRange(model, target.index);
    return { from: range.s, to: range.e, insert: "", select: (nextModel) => caretAt(positionBefore(nextModel, range.s)), kind: "delete", label: "Delete" };
  }

  /// Where the caret goes once a block is gone: the end of the text before it, as after ⌫.
  function positionBefore(model, raw) {
    const unit = unitAt(model, Math.max(0, raw - 1), "left");
    if (!unit) return closestUnitPosition(model, raw);
    return Math.max(unitStart(unit), Math.min(unitEnd(unit), raw));
  }

  /// The handle block's Markdown, for Copy in its menu.
  function blockMarkdown(model, target) {
    if (!target) return "";
    if (target.kind === "item") {
      const [start, end] = itemRange(model, target);
      return model.source.slice(start, end);
    }
    return topChunk(model, target.index);
  }

  /// The selection Turn Into works on for a handle's block: all of its text.
  function targetSelection(model, target) {
    if (!target) return null;
    const units = target.kind === "item"
      ? unitsOf(target.top).filter((unit) => unit.role === "item" && unit.item === target.item)
      : unitsOf(target.block);
    if (units.length === 0) return null;
    return withOrder(unitStart(units[0]), unitEnd(units[units.length - 1]));
  }

  /// Lines `[start, end)` replaced by `text`, with a blank line kept on each side.
  function replaceIsolated(model, start, end, text, prefix) {
    const source = model.source;
    const eol = model.eol;
    const blank = prefix.trimEnd();
    // An empty callout's or toggle's line is at the end of its marker line: the text starts a line.
    const before = start !== lineStartOf(source, start) ? eol
      : start > 0 && !isBlankLineIn(source, lineStartOf(source, previousLineEnd(source, start)), prefix) ? blank + eol : "";
    const next = nextLineStart(source, end);
    const after = next > end && next < source.length && !isBlankLineIn(source, next, prefix) ? eol + blank : "";
    return { from: start, to: end, insert: before + text + after, offset: before.length };
  }

  /// Turns the text block holding the caret into a toggle titled with its text, opened.
  function planWrapToggle(model, selection) {
    const unit = unitAt(model, selection.head, "left");
    if (!unit || !isConvertible(unit)) return null;
    const source = model.source;
    const eol = model.eol;
    const [start, end] = unitLineRange(model, unit);
    const prefix = quotePrefixOfLine(source, start);
    const title = unitContent(model, unit).split(eol).join(" ").replace(/^\s+/, "");
    const blank = prefix.trimEnd();
    const text = `${prefix}<details>${eol}${prefix}<summary>${title}</summary>${eol}${blank}${eol}${prefix}</details>`;
    const op = replaceIsolated(model, start, end, text, prefix);
    const openAt = op.from + op.offset;
    const caret = openAt + prefix.length + "<details>".length + eol.length + prefix.length + "<summary>".length + title.length;
    return { from: op.from, to: op.to, insert: op.insert, select: caretAt(caret), kind: "format", label: "Toggle List", openToggle: openAt };
  }

  /// Turns the text block holding the caret into a callout (`> [!NOTE]`); a quote's text makes the
  /// whole quote one.
  function planWrapCallout(model, selection, kind = "NOTE") {
    const unit = unitAt(model, selection.head, "left");
    if (!unit || !isConvertible(unit)) return null;
    const source = model.source;
    const eol = model.eol;
    const marker = `[!${kind}]`;
    if (calloutOf(unit)) return null;
    if (unit.container && unit.container.type === "quote" && !unit.container.callout) {
      const quote = unit.container;
      const lineStart = lineStartOf(source, bStart(quote));
      const prefix = (QUOTE_PREFIX.exec(source.slice(lineStart, lineEndOf(source, lineStart))) || ["> "])[0];
      const insert = prefix + marker + eol;
      return { from: lineStart, to: lineStart, insert, select: caretAt(selection.head + insert.length), kind: "format", label: "Callout" };
    }
    const [start, end] = unitLineRange(model, unit);
    const outer = quotePrefixOfLine(source, start);
    const prefix = `${outer}> `;
    const content = unitContent(model, unit);
    const body = content ? eol + prefixFollowingLines(prefix + content.replace(/^\s+/, ""), prefix, eol) : "";
    const text = `${prefix}${marker}${body}`;
    const op = replaceIsolated(model, start, end, text, outer);
    const textStart = op.from + op.offset;
    const caret = content ? textStart + text.length : textStart + prefix.length + marker.length;
    return { from: op.from, to: op.to, insert: op.insert, select: caretAt(caret), kind: "format", label: "Callout" };
  }

  /// A quote's or callout's text without its `>` (and the callout's `[!KIND]` line).
  function planUnwrapQuote(model, unit, selection) {
    const quote = unit && unit.container;
    if (!quote || quote.type !== "quote") return null;
    const source = model.source;
    const eol = model.eol;
    const from = bStart(quote);
    const to = bEnd(quote);
    const quoteLines = nodeLines(model, quote, parsedLineStart(source, from), lineAfter(source, to));
    const first = quote.callout ? 1 : 0;
    const lines = [];
    for (let index = first; index < quoteLines.length; index += 1) {
      const view = insideQuote(quoteLines[index]);
      let text = source.slice(view.start, view.end);
      if (lines.length > 0) {
        const lineStart = quoteLines[index].start;
        text = source.slice(lineStartOf(source, lineStart), lineStart) + text;
      }
      lines.push(text);
    }
    const units = unitsOf(unit.top).filter((candidate) => candidate.container === quote);
    const described = describeSelection(model, selection || caretAt(unitStart(unit)), units);
    return {
      from,
      to,
      insert: lines.join(eol),
      select: (next) => restoreDescribedSelection(next, described, from),
      kind: "format",
      label: "Paragraph"
    };
  }

  /// A new empty line above top-level block `index`.
  function insertEmptyBeforeBlock(model, index) {
    const source = model.source;
    const eol = model.eol;
    const at = lineStartOf(source, bStart(model.blocks[index]));
    const count = at === 0 || isLineBlank(source, previousLineEnd(source, at)) ? 1 : 2;
    return { from: at, to: at, insert: eol.repeat(count), select: (next) => caretOnFirstEmptyAfter(next, at) };
  }

  /// A new list item beside a handle's item: after it and the items nested under it, or before it.
  function insertItemNear(model, target, above) {
    const source = model.source;
    const eol = model.eol;
    const item = target.item;
    const contentLineStart = atNode(item, item.view.start);
    const prefix = quotePrefixOfLine(source, contentLineStart);
    const indent = source.slice(contentLineStart, atNode(item, item.markerStart));
    if (above) {
      const at = lineStartOf(source, contentLineStart);
      const insert = prefix + indent + item.marker + " " + (item.task ? "[ ] " : "") + eol;
      return { from: at, to: at, insert, select: caretAt(at + insert.length - eol.length) };
    }
    const end = itemSubtreeEnd(item);
    const insert = eol + prefix + indent + nextMarker(item);
    return { from: end, to: end, insert, select: caretAt(end + insert.length) };
  }

  /// Sets a callout's kind: `[!NOTE]` becomes `[!TIP]` and so on.
  function planCalloutKind(model, unit, kind) {
    const callout = unit && calloutOf(unit);
    if (!callout) return null;
    const marker = callout.callout.marker;
    const from = atNode(callout, marker.start);
    const to = atNode(callout, marker.end);
    const insert = `[!${kind.toUpperCase()}]`;
    return { from, to, insert, select: null, kind: "format", label: "Callout" };
  }

  // ---------------------------------------------------------------------
  // HTML to Markdown (paste from other apps)
  // ---------------------------------------------------------------------

  function htmlToMarkdown(html) {
    if (typeof DOMParser !== "function") return null;
    const parsed = new DOMParser().parseFromString(html, "text/html");
    const body = parsed.body;
    if (!body) return null;
    const blocks = convertBlocks(body);
    return blocks.join("\n\n").replace(/\n{3,}/g, "\n\n").trim();
  }

  const BLOCK_TAGS = new Set(["P", "DIV", "H1", "H2", "H3", "H4", "H5", "H6", "UL", "OL", "LI", "BLOCKQUOTE", "PRE", "TABLE", "HR", "SECTION", "ARTICLE", "HEADER", "FOOTER", "MAIN", "FIGURE"]);

  function convertBlocks(element) {
    const blocks = [];
    let inline = "";
    const flush = () => {
      const text = inline.replace(/[ \t]+/g, " ").replace(/ *\n */g, "\n").trim();
      if (text) blocks.push(text);
      inline = "";
    };
    for (const node of Array.from(element.childNodes)) {
      if (node.nodeType === 1 && BLOCK_TAGS.has(node.tagName)) {
        flush();
        const converted = convertBlock(node);
        if (converted) blocks.push(converted);
      } else if (node.nodeType === 1 && node.tagName === "BR") {
        inline += "\\\n";
      } else {
        inline += convertInline(node);
      }
    }
    flush();
    return blocks;
  }

  /// A backtick run longer than any in `text`, so `text` can sit inside it.
  function backtickFence(text, shortest) {
    const longest = Math.max(0, ...(text.match(/`+/g) || []).map((run) => run.length));
    return "`".repeat(Math.max(shortest, longest + 1));
  }

  function convertBlock(element) {
    const tag = element.tagName;
    switch (tag) {
      case "H1": case "H2": case "H3": case "H4": case "H5": case "H6":
        return "#".repeat(Number(tag[1])) + " " + inlineOf(element).replace(/\s+/g, " ").trim();
      case "UL":
      case "OL":
        return convertList(element, "");
      case "BLOCKQUOTE":
        return convertBlocks(element).join("\n\n").split("\n").map((line) => (line ? `> ${line}` : ">")).join("\n");
      case "PRE": {
        const code = element.textContent.replace(/\n$/, "");
        const language = ((element.querySelector("code") || element).className.match(/language-([\w.+-]+)/) || [])[1] || "";
        const fence = backtickFence(code, 3);
        return fence + language + "\n" + code + "\n" + fence;
      }
      case "TABLE":
        return convertTable(element);
      case "HR":
        return "---";
      default:
        return convertBlocks(element).join("\n\n");
    }
  }

  /// A list's items, each line after `indent`; a nested list goes under its item's text, as far in
  /// as the item's marker is wide.
  function convertList(element, indent) {
    const ordered = element.tagName === "OL";
    const lines = [];
    let number = Number(element.getAttribute("start")) || 1;
    for (const item of Array.from(element.children)) {
      if (item.tagName !== "LI") continue;
      const checkbox = item.querySelector(":scope > input[type=checkbox]");
      const marker = ordered ? `${number}. ` : "- ";
      number += 1;
      let text = "";
      const nested = [];
      for (const child of Array.from(item.childNodes)) {
        if (child.nodeType === 1 && (child.tagName === "UL" || child.tagName === "OL")) nested.push(convertList(child, indent + " ".repeat(marker.length)));
        else if (child.nodeType === 1 && child.tagName === "INPUT") continue;
        else if (child.nodeType === 1 && BLOCK_TAGS.has(child.tagName)) text += " " + convertBlocks(child).join(" ");
        else text += convertInline(child);
      }
      const task = checkbox ? (checkbox.checked ? "[x] " : "[ ] ") : "";
      lines.push(indent + marker + task + text.replace(/\s+/g, " ").trim());
      lines.push(...nested);
    }
    return lines.join("\n");
  }

  function convertTable(element) {
    const rows = Array.from(element.querySelectorAll("tr")).map((row) => Array.from(row.children).map((cell) => inlineOf(cell).replace(/\s+/g, " ").trim().replace(/\|/g, "\\|")));
    if (rows.length === 0) return "";
    const width = Math.max(...rows.map((row) => row.length));
    const line = (cells) => "| " + Array.from({ length: width }, (_, index) => cells[index] || "").join(" | ") + " |";
    const out = [line(rows[0]), "| " + Array.from({ length: width }, () => "---").join(" | ") + " |"];
    for (const row of rows.slice(1)) out.push(line(row));
    return out.join("\n");
  }

  function inlineOf(element) {
    return Array.from(element.childNodes).map(convertInline).join("");
  }

  function wrap(marker, text, closing = marker) {
    const match = /^(\s*)([\s\S]*?)(\s*)$/.exec(text);
    if (!match[2]) return text;
    return `${match[1]}${marker}${match[2]}${closing}${match[3]}`;
  }

  function convertInline(node) {
    if (node.nodeType === 3) return node.nodeValue.replace(/\s+/g, " ");
    if (node.nodeType !== 1) return "";
    const tag = node.tagName;
    const style = node.getAttribute("style") || "";
    const inner = () => inlineOf(node);
    switch (tag) {
      case "STRONG": case "B":
        if (/font-weight:\s*(normal|[1-5]00)/.test(style)) return inner();
        return wrap("**", inner());
      case "EM": case "I":
        return wrap("*", inner());
      case "DEL": case "S": case "STRIKE":
        return wrap("~~", inner());
      case "CODE": case "KBD": case "SAMP": {
        // A code span opens and closes with a backtick run longer than any inside it, and a space
        // keeps a backtick at its edge apart from the run.
        const code = node.textContent;
        const fence = backtickFence(code, 1);
        const pad = /^`|`$/.test(code) ? " " : "";
        return fence + pad + code + pad + fence;
      }
      case "A": {
        const href = node.getAttribute("href") || "";
        const text = inner().trim();
        if (!href || href.startsWith("javascript:")) return text;
        return `[${text || href}](${href.replace(/\s/g, "%20")})`;
      }
      case "IMG": {
        const src = node.getAttribute("src") || "";
        return src ? `![${(node.getAttribute("alt") || "").replace(/[[\]]/g, "")}](${src.replace(/\s/g, "%20")})` : "";
      }
      case "BR":
        return "\\\n";
      case "SCRIPT": case "STYLE": case "META": case "TITLE":
        return "";
      default: {
        let text = inner();
        if (/font-weight:\s*(bold|[6-9]00)/.test(style)) text = wrap("**", text);
        if (/font-style:\s*italic/.test(style)) text = wrap("*", text);
        if (/text-decoration[^;]*line-through/.test(style)) text = wrap("~~", text);
        return text;
      }
    }
  }

  const Core = {
    createModel,
    applyPatch,
    redrawStaleBlocks,
    unitAt,
    unitStart,
    unitEnd,
    rawOf,
    jOf,
    visibleMap,
    visibleText,
    visibleToRaw,
    rawToVisible,
    visibleRangeToRaw,
    previousUnit,
    nextUnit,
    allUnits,
    unitsBetween,
    blockTypeOf,
    inlineState,
    planInsertText,
    planDelete,
    planEnter,
    planLineBreak,
    planBackspaceAtStart,
    planDeleteForwardAtEnd,
    planInlineStyle,
    planBlockType,
    planIndent,
    planTable,
    planSlashCommand,
    planInsertBlock,
    planToggleTask,
    cellNeighbor,
    balancedMarkdown,
    htmlToMarkdown,
    bStart,
    bEnd,
    bLine,
    nodeShift,
    nodeLineShift,
    childNodes,
    itemSubtreeEnd,
    lineStartOf,
    lineEndOf,
    handleTargetOf,
    planMoveBlock,
    planMoveByStep,
    planDuplicateBlock,
    planDeleteBlock,
    blockMarkdown,
    targetSelection,
    planWrapToggle,
    planWrapCallout,
    planCalloutKind,
    planUnwrapQuote,
    insertEmptyBeforeBlock,
    insertItemNear
  };
  window.MonknotEditorCore = Core;

  if (typeof document === "undefined" || !document.createElement || typeof window.getSelection !== "function") return;

  // =====================================================================
  // Page
  // =====================================================================

  const TEXT = 3;
  const ELEMENT = 1;

  let root = null;
  let model = null;
  let active = false;
  let documentID = "";
  let renderID = 0;
  let version = 0;
  let unacknowledged = [];
  let sticky = null;
  let composing = false;
  let pendingRemote = [];
  let pendingMarks = null;
  let groupSequence = 0;
  let currentGroup = 0;
  let lastEditKind = "";
  let lastEditEnd = -1;
  let selectionFrame = 0;
  let lastReportedSelection = null;
  // A click below a last block that typing cannot continue (a table, code, a divider): the first
  // character typed at `at` opens a line after it, so the click alone changes nothing.
  let trailingLine = null;
  let footnotesElement = null;
  let footnotesHTML = null;
  let icons = {};
  let layer = null;
  const listeners = [];

  function post(message) {
    if (!documentID) return;
    window.webkit?.messageHandlers?.monknotEditor?.postMessage({ documentID, renderID, ...message });
  }

  let menuReportedOpen = false;
  /// Tells the app when a menu or the link field opens over the text, or the last one closes: it
  /// checks nothing and asks its models nothing meanwhile, since nothing could be shown.
  function noteMenuChange() {
    if (!active) return;
    const open = UI.anyMenuOpen;
    if (open === menuReportedOpen) return;
    menuReportedOpen = open;
    post({ type: "menu", open });
  }

  function listen(target, type, handler, options) {
    target.addEventListener(type, handler, options);
    listeners.push(() => target.removeEventListener(type, handler, options));
  }

  function activate(target, payload) {
    if (active && root === target && payload.documentID === documentID && payload.renderID === renderID) return;
    if (active) deactivate();
    root = target;
    active = true;
    documentID = payload.documentID || "";
    renderID = payload.renderID || 0;
    version = 0;
    unacknowledged = [];
    pendingRemote = [];
    menuReportedOpen = false;
    lastReportedSelection = null;
    trailingLine = null;
    document.documentElement.classList.add("mk-editing");
    root.setAttribute("contenteditable", "true");
    root.setAttribute("spellcheck", Flow.spellcheck ? "true" : "false");
    root.setAttribute("role", "textbox");
    root.setAttribute("aria-multiline", "true");
    root.setAttribute("aria-label", "Document");
    root.setAttribute("autocapitalize", "sentences");
    model = createModel(payload.markdown || "");
    fullRender();
    ensureLayer();
    listen(root, "beforeinput", onBeforeInput);
    listen(root, "input", onInput);
    listen(root, "keydown", onKeyDown);
    listen(root, "keyup", onKeyUp);
    listen(root, "compositionstart", onCompositionStart);
    listen(root, "compositionend", onCompositionEnd);
    listen(root, "paste", onPaste);
    listen(root, "copy", onCopy);
    listen(root, "cut", onCut);
    listen(root, "drop", onDrop);
    listen(root, "dragstart", (event) => event.preventDefault());
    listen(root, "mousedown", onMouseDown);
    listen(root, "mouseup", onMouseUp);
    listen(root, "click", onClick);
    listen(root, "focus", () => {
      post({ type: "focus", focused: true });
      scheduleSelectionReport();
    });
    listen(root, "blur", onBlur);
    listen(document, "selectionchange", scheduleSelectionReport);
    listen(document, "keydown", onDocumentKeyDown, true);
    listen(document, "keyup", onDocumentKeyUp, true);
    listen(window, "resize", () => {
      UI.reposition();
      Flow.onResize();
    });
    listen(window, "scroll", () => {
      UI.reposition();
      Handles.update();
      Flow.onScroll();
    }, { passive: true });
    listen(document, "mousemove", Handles.onPointerMove, { passive: true });
    listen(document.documentElement, "mouseleave", () => Handles.hide());
    listen(window, "blur", () => setCommandKey(false));
    // The web view became first responder (a click on its edge, the window regaining focus):
    // put the caret back where it was.
    listen(window, "focus", () => {
      if (document.activeElement === document.body || !document.activeElement) focus();
    });
    if (payload.selection) {
      // The selection the document was left with is restored, not made: no format bar for it.
      UI.hostWillSelect();
      setSelection(payload.selection.anchor, payload.selection.head, { reveal: false });
    }
    if (payload.focus) focus();
    post({ type: "ready", v: version, focused: document.activeElement === root });
  }

  function deactivate() {
    if (!active) return;
    Handles.cancelDrag();
    Handles.hide();
    UI.closeAll();
    Flow.forget();
    while (listeners.length) listeners.pop()();
    if (root) {
      root.removeAttribute("contenteditable");
      root.removeAttribute("role");
      root.removeAttribute("aria-multiline");
    }
    document.documentElement.classList.remove("mk-editing");
    active = false;
    model = null;
    sticky = null;
  }

  function isActive() {
    return active;
  }

  function focus() {
    if (!root) return;
    if (document.activeElement !== root) root.focus({ preventScroll: true });
    const selection = window.getSelection();
    if (!selection.rangeCount || !root.contains(selection.anchorNode)) {
      const first = firstUnitFrom(model, 0);
      if (first) setSelection(unitStart(first), unitStart(first), { reveal: false });
    }
  }

  // Rendering ---------------------------------------------------------

  function fullRender() {
    Flow.forget();
    redrawStaleBlocks(model);
    root.innerHTML = model.blocks.map((block) => block.html).join("");
    const children = Array.from(root.children);
    model.blocks.forEach((block, index) => {
      bindElements(block, children[index]);
      bindUnits(block);
    });
    footnotesElement = null;
    footnotesHTML = null;
    refreshFootnotes();
    markEmptyDocument();
  }

  function bindUnits(block) {
    if (!block.el) return;
    const elements = block.el.hasAttribute("data-mk-u") ? [block.el] : [];
    elements.push(...block.el.querySelectorAll("[data-mk-u]"));
    for (const element of elements) {
      const unit = model.units.get(Number(element.getAttribute("data-mk-u")));
      if (unit) unit.el = element;
    }
  }

  /// Gives a node and every node under it its element: each block in a quote or toggle, each list
  /// and item renders as one element, in order, so an edit inside replaces only its own.
  function bindElements(node, element) {
    node.el = element || null;
    if (!element) return;
    const kids = childNodes(node);
    if (kids.length === 0) return;
    const elements = childElements(node);
    for (let index = 0; index < kids.length; index += 1) bindElements(kids[index], elements[index]);
  }

  /// The elements of a node's children: in a toggle's body, a quote (after a callout's title), a
  /// list, or after an item's text (and a to-do's box).
  function childElements(node) {
    const element = node.el;
    if (node.type === "toggle") return element.lastElementChild ? element.lastElementChild.children : [];
    if (node.type === "quote") return node.callout ? Array.prototype.slice.call(element.children, 1) : element.children;
    if (node.type === "list") return element.children;
    return Array.prototype.slice.call(element.children, node.task ? 2 : 1);
  }

  function applyUpdate(update) {
    if (update.full) {
      fullRender();
      return;
    }
    if (update.container) {
      applyUpdateInside(update);
      return;
    }
    const { index, removed, inserted } = update;
    for (const block of removed) block.el?.remove();
    if (inserted.length) {
      const template = document.createElement("template");
      template.innerHTML = inserted.map((block) => block.html).join("");
      const elements = Array.from(template.content.children);
      inserted.forEach((block, position) => bindElements(block, elements[position]));
      const next = model.blocks[index + inserted.length];
      root.insertBefore(template.content, next?.el || footnotesElement || null);
      inserted.forEach(bindUnits);
    }
    if (removed.some(changesContents) || inserted.some(changesContents)) refreshTablesOfContents();
    Handles.hide();
    if (removed.some(holdsFootnotes) || inserted.some(holdsFootnotes)) refreshFootnotes();
    markEmptyDocument();
  }

  /// An edit re-parsed inside a toggle, quote or list: only the blocks or items it replaced change
  /// on the page. A heading in there is not in a table of contents, which lists the top level's.
  function applyUpdateInside(update) {
    const { container, index, removed, inserted } = update;
    const kids = childNodes(container);
    const next = kids[index + inserted.length];
    const host = container.type === "toggle" ? container.el && container.el.lastElementChild : container.el;
    if (!host || (next && !next.el) || removed.some((node) => !node.el)) {
      fullRender();
      return;
    }
    const template = document.createElement("template");
    template.innerHTML = inserted.map((node) => node.html).join("");
    const elements = Array.from(template.content.children);
    // An item replaced by an item keeps its <li>: a new one would have WebKit number and lay out
    // every item after it again, which in a long list costs far more than the edit.
    const kept = container.type === "list" ? Math.min(removed.length, inserted.length) : 0;
    for (let position = 0; position < kept; position += 1) {
      const element = removed[position].el;
      const replacement = elements[position];
      for (const attribute of Array.from(element.attributes)) {
        if (!replacement.hasAttribute(attribute.name)) element.removeAttribute(attribute.name);
      }
      for (const attribute of Array.from(replacement.attributes)) element.setAttribute(attribute.name, attribute.value);
      element.replaceChildren(...replacement.childNodes);
      replacement.remove();
      bindElements(inserted[position], element);
    }
    for (let position = kept; position < removed.length; position += 1) removed[position].el?.remove();
    for (let position = kept; position < inserted.length; position += 1) bindElements(inserted[position], elements[position]);
    host.insertBefore(template.content, next ? next.el : null);
    inserted.forEach(bindUnits);
    if (container.type === "list") host.classList.toggle("contains-task-list", container.items.some((item) => item.task));
    Handles.hide();
    if (removed.some(holdsFootnotes) || inserted.some(holdsFootnotes)) refreshFootnotes();
    markEmptyDocument();
  }

  function changesContents(block) {
    return block.type === "heading" || block.type === "toc";
  }

  /// Only an edit to a block with a footnote reference, or to a footnote's definition, can change
  /// the numbers or the notes under the document. A block an edit inside re-rendered in parts, or
  /// one rendered as part of its container, is asked its element.
  function holdsFootnotes(block) {
    if (block.type === "definition") return Boolean(block.definition && block.definition.kind === "footnote");
    if (typeof block.html === "string") return block.html.includes("footnote-ref");
    return Boolean(block.el && block.el.querySelector("sup.footnote-ref"));
  }

  /// A table of contents lists the headings as they are now; after a heading changes it is drawn
  /// again (a document seldom has more than one).
  function refreshTablesOfContents() {
    for (const block of model.blocks) {
      if (block.type !== "toc" || !block.el) continue;
      const html = MD.renderBlock(block, MD.newRender(model.doc, { editing: true, unitSequence: model.unitSequence }), null);
      if (html === block.html) continue;
      const template = document.createElement("template");
      template.innerHTML = html;
      const element = template.content.firstElementChild;
      if (!element) continue;
      block.el.replaceWith(element);
      block.el = element;
      block.html = html;
    }
  }

  /// Footnote numbers follow the order the references appear in, as in
  /// export; after an edit they are renumbered on the page.
  function refreshFootnotes() {
    const doc = model.doc;
    if (footnotesElement && !footnotesElement.isConnected) {
      footnotesElement = null;
      footnotesHTML = null;
    }
    const numbers = new Map();
    if (doc.footnotes && doc.footnotes.size) {
      const keys = new Map();
      for (const key of doc.footnoteOrder) {
        const id = `fnref-${MD.slug(key)}`;
        if (!keys.has(id)) keys.set(id, key);
      }
      for (const element of root.querySelectorAll("sup.footnote-ref")) {
        const key = keys.get(element.id || "") ?? (element.id || "");
        if (!numbers.has(key)) numbers.set(key, numbers.size + 1);
        const anchor = element.querySelector("a");
        const label = String(numbers.get(key));
        if (anchor && anchor.textContent !== label) anchor.textContent = label;
      }
    }
    const html = numbers.size ? MD.renderFootnotes(doc, { ...MD.newRender(doc, { editing: true }), refNumbers: numbers }) : "";
    if (html === footnotesHTML && (footnotesElement || !html)) return;
    footnotesHTML = html;
    if (!html) {
      footnotesElement?.remove();
      footnotesElement = null;
      return;
    }
    const template = document.createElement("template");
    template.innerHTML = html;
    const section = template.content.firstElementChild;
    if (footnotesElement) footnotesElement.replaceWith(section);
    else root.appendChild(section);
    footnotesElement = section;
  }

  let onlyElement = null;
  /// An empty document shows its one placeholder line even before it has focus. Checked without
  /// walking the document: an empty one has a single block.
  function markEmptyDocument() {
    let only = null;
    if (model.blocks.length === 1) {
      const units = unitsOf(model.blocks[0]);
      if (units.length === 1 && units[0].kind === "empty") only = units[0];
    }
    const element = only && only.el ? only.el : null;
    if (element === onlyElement) return;
    onlyElement?.classList.remove("mk-only");
    onlyElement = element;
    root.classList.toggle("mk-document-empty", Boolean(element));
    element?.classList.add("mk-only");
  }

  // DOM ↔ source --------------------------------------------------------

  function isAtom(element) {
    if (element.hasAttribute("data-mk-atom")) return true;
    if (element.tagName === "BR") return !element.hasAttribute("data-mk-filler");
    return element.tagName === "IMG";
  }

  function isSkipped(element, unitElement) {
    if (element === unitElement) return false;
    if (element.hasAttribute("data-mk-skip")) return true;
    if (element.hasAttribute("data-mk-u")) return true;
    return element.tagName === "BR" && element.hasAttribute("data-mk-filler");
  }

  /// Counts the visible characters in `unitElement` before the DOM point.
  function visibleOffsetOf(unitElement, node, offset) {
    let count = 0;
    let found = false;
    const visit = (current) => {
      if (found) return;
      if (current.nodeType === TEXT) {
        if (current === node) {
          count += Math.min(offset, current.data.length);
          found = true;
          return;
        }
        count += current.data.length;
        return;
      }
      if (current.nodeType !== ELEMENT) return;
      if (isSkipped(current, unitElement)) {
        if (current === node || current.contains(node)) found = true;
        return;
      }
      if (current !== unitElement && isAtom(current)) {
        if (current === node || current.contains(node)) {
          if (current === node && offset === 0) {
            found = true;
            return;
          }
          count += 1;
          found = true;
          return;
        }
        count += 1;
        return;
      }
      if (current === node) {
        const children = current.childNodes;
        for (let index = 0; index < Math.min(offset, children.length); index += 1) visit(children[index]);
        found = true;
        return;
      }
      for (const child of current.childNodes) {
        visit(child);
        if (found) return;
      }
    };
    visit(unitElement);
    return found ? count : null;
  }

  function visibleTextOfElement(unitElement) {
    let text = "";
    const visit = (current) => {
      if (current.nodeType === TEXT) {
        text += current.data;
        return;
      }
      if (current.nodeType !== ELEMENT) return;
      if (isSkipped(current, unitElement)) return;
      if (current !== unitElement && isAtom(current)) {
        text += "\uFFFC";
        return;
      }
      for (const child of current.childNodes) visit(child);
    };
    visit(unitElement);
    return text;
  }

  function unitElementFor(node) {
    let element = node && node.nodeType === TEXT ? node.parentElement : node;
    while (element && element !== root) {
      if (element.hasAttribute && element.hasAttribute("data-mk-skip")) return null;
      if (element.hasAttribute && element.hasAttribute("data-mk-u")) return element;
      element = element.parentElement;
    }
    return null;
  }

  function unitForElement(element) {
    return element ? model.units.get(Number(element.getAttribute("data-mk-u"))) || null : null;
  }

  /// The source offset of a DOM point.
  function domToRaw(node, offset, side) {
    if (!node || !root.contains(node) && node !== root) return null;
    const unitElement = unitElementFor(node);
    if (unitElement) {
      const unit = unitForElement(unitElement);
      if (!unit) return null;
      const v = visibleOffsetOf(unitElement, node, offset);
      if (v === null) return side === "right" ? unitStart(unit) : unitEnd(unit);
      return visibleToRaw(model, unit, v, v === 0 ? "right" : side);
    }
    // Outside any unit (a margin, a list marker, between blocks): the nearest unit, found by
    // walking from the point to the unit elements that start on either side of it.
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, {
      acceptNode: (element) => (element.hasAttribute("data-mk-u") ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP)
    });
    // The first node after the point, in document order; null at the very end.
    let next = node.nodeType === ELEMENT ? node.childNodes[offset] || null : node;
    if (!next && node.nodeType === ELEMENT) {
      let current = node;
      while (current !== root && !current.nextSibling) current = current.parentNode;
      next = current === root ? null : current.nextSibling;
    }
    let after = null;
    let before = null;
    if (next) {
      walker.currentNode = next;
      after = next.nodeType === ELEMENT && next.hasAttribute("data-mk-u") ? next : walker.nextNode();
      walker.currentNode = next;
      before = walker.previousNode();
    } else {
      let last = root;
      while (last.lastChild) last = last.lastChild;
      walker.currentNode = last;
      before = last.nodeType === ELEMENT && last.hasAttribute("data-mk-u") ? last : walker.previousNode();
    }
    const choice = side === "right" ? after || before : before || after;
    const unit = unitForElement(choice);
    if (!unit) return null;
    return choice === before ? unitEnd(unit) : unitStart(unit);
  }

  /// The DOM point for a visible offset in a unit element.
  function domPointAt(unitElement, v, side) {
    let remaining = v;
    let previousText = null;
    let result = null;
    const visit = (current) => {
      if (result) return;
      if (current.nodeType === TEXT) {
        const length = current.data.length;
        if (remaining < length || (remaining === length && side === "left")) {
          result = { node: current, offset: remaining };
          return;
        }
        if (remaining === length) {
          previousText = { node: current, offset: length };
        }
        remaining -= length;
        if (remaining === 0 && side === "left") result = { node: current, offset: length };
        return;
      }
      if (current.nodeType !== ELEMENT) return;
      if (isSkipped(current, unitElement)) return;
      if (current !== unitElement && isAtom(current)) {
        const parent = current.parentNode;
        const index = Array.prototype.indexOf.call(parent.childNodes, current);
        if (remaining === 0) {
          result = { node: parent, offset: index };
          return;
        }
        remaining -= 1;
        if (remaining === 0 && side === "left") result = { node: parent, offset: index + 1 };
        return;
      }
      for (const child of current.childNodes) {
        visit(child);
        if (result) return;
      }
    };
    if (v === 0) {
      const firstText = firstTextNode(unitElement);
      if (firstText) return { node: firstText, offset: 0 };
      return { node: unitElement, offset: 0 };
    }
    visit(unitElement);
    if (result) return result;
    if (previousText) return previousText;
    const lastText = lastTextNode(unitElement);
    if (lastText) return { node: lastText, offset: lastText.data.length };
    return { node: unitElement, offset: unitElement.childNodes.length };
  }

  function firstTextNode(unitElement) {
    let found = null;
    const visit = (current) => {
      if (found) return;
      if (current.nodeType === TEXT) {
        found = current;
        return;
      }
      if (current.nodeType !== ELEMENT || isSkipped(current, unitElement)) return;
      if (current !== unitElement && isAtom(current)) {
        found = false;
        return;
      }
      for (const child of current.childNodes) {
        visit(child);
        if (found !== null) return;
      }
    };
    visit(unitElement);
    return found || null;
  }

  function lastTextNode(unitElement) {
    let found = null;
    const visit = (current) => {
      if (current.nodeType === TEXT) {
        found = current;
        return;
      }
      if (current.nodeType !== ELEMENT || isSkipped(current, unitElement)) return;
      if (current !== unitElement && isAtom(current)) return;
      for (const child of current.childNodes) visit(child);
    };
    visit(unitElement);
    return found;
  }

  function rawToDom(raw, side) {
    const unit = unitAt(model, raw, side);
    if (!unit || !unit.el) return null;
    const v = rawToVisible(model, unit, raw, side);
    return domPointAt(unit.el, v, side);
  }

  function readSelection() {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) return null;
    if (!root.contains(selection.anchorNode) || !root.contains(selection.focusNode)) return null;
    if (sticky
      && selection.anchorNode === sticky.anchorNode && selection.anchorOffset === sticky.anchorOffset
      && selection.focusNode === sticky.focusNode && selection.focusOffset === sticky.focusOffset) {
      return withOrder(sticky.anchor, sticky.head);
    }
    if (selection.isCollapsed) {
      const raw = domToRaw(selection.anchorNode, selection.anchorOffset, "left");
      if (raw === null) return null;
      return withOrder(raw, raw);
    }
    const range = selection.getRangeAt(0);
    const start = domToRaw(range.startContainer, range.startOffset, "right");
    const end = domToRaw(range.endContainer, range.endOffset, "left");
    if (start === null || end === null) return null;
    const backward = selection.anchorNode === range.endContainer && selection.anchorOffset === range.endOffset && !selection.isCollapsed;
    return backward ? withOrder(end, start) : withOrder(start, end);
  }

  function setSelection(anchor, head, options = {}) {
    if (!model) return;
    const length = model.source.length;
    const a = Math.max(0, Math.min(anchor, length));
    const h = Math.max(0, Math.min(head ?? anchor, length));
    const collapsed = a === h;
    const anchorPoint = rawToDom(a, collapsed ? "left" : (a <= h ? "right" : "left"));
    const headPoint = rawToDom(h, collapsed ? "left" : (h >= a ? "left" : "right"));
    if (!anchorPoint || !headPoint) return;
    const selection = window.getSelection();
    try {
      selection.setBaseAndExtent(anchorPoint.node, anchorPoint.offset, headPoint.node, headPoint.offset);
    } catch {
      return;
    }
    sticky = {
      anchorNode: selection.anchorNode,
      anchorOffset: selection.anchorOffset,
      focusNode: selection.focusNode,
      focusOffset: selection.focusOffset,
      anchor: a,
      head: h
    };
    if (options.reveal !== false) scheduleReveal();
  }

  /// Scrolls the caret into view just before the next paint, so a keystroke never waits for a
  /// layout of the whole page.
  let revealFrame = 0;
  function scheduleReveal() {
    if (revealFrame) return;
    revealFrame = window.requestAnimationFrame(() => {
      revealFrame = 0;
      revealSelection();
    });
  }

  function revealSelection() {
    const selection = window.getSelection();
    if (!selection.rangeCount) return;
    const range = selection.getRangeAt(0).cloneRange();
    range.collapse(false);
    let rect = range.getClientRects()[0] || null;
    if (!rect) {
      const element = unitElementFor(selection.focusNode) || (selection.focusNode.nodeType === ELEMENT ? selection.focusNode : selection.focusNode.parentElement);
      rect = element ? element.getBoundingClientRect() : null;
    }
    if (!rect) return;
    const margin = 48;
    if (rect.bottom > window.innerHeight - margin) window.scrollBy(0, rect.bottom - window.innerHeight + margin);
    else if (rect.top < margin) window.scrollBy(0, rect.top - margin);
  }

  // Applying edits ----------------------------------------------------

  function apply(op, meta = {}) {
    if (!op || !model) return false;
    if (op.move) {
      if (op.select) setSelection(op.select.anchor, op.select.head);
      return false;
    }
    if (op.from === undefined) return false;
    trailingLine = null;
    const before = meta.selectionBefore || readSelection() || withOrder(op.from, op.from);
    const removed = model.source.slice(op.from, op.to);
    if (removed === op.insert) {
      const selection = typeof op.select === "function" ? op.select(model) : op.select;
      if (selection) setSelection(selection.anchor, selection.head);
      return false;
    }
    const profile = window.MonknotEditor && window.MonknotEditor.profile;
    const t0 = profile ? performance.now() : 0;
    model.pendingToggleOpen = op.openToggle ?? null;
    const update = applyPatch(model, op.from, op.to, op.insert);
    const t1 = profile ? performance.now() : 0;
    applyUpdate(update);
    const t2 = profile ? performance.now() : 0;
    version += 1;
    const end = op.from + op.insert.length;
    const kind = meta.kind || op.kind || "typing";
    const coalesce = meta.coalesce ?? ((kind === "typing" && lastEditKind === "typing" && op.to === op.from && op.from === lastEditEnd && removed === "")
      || (kind === "delete" && lastEditKind === "delete" && op.insert === "" && (op.to === lastEditEnd || op.from === lastEditEnd)));
    if (!meta.group && !coalesce) currentGroup = ++groupSequence;
    lastEditKind = kind;
    lastEditEnd = kind === "delete" ? op.from : end;
    unacknowledged.push({ v: version, from: op.from, to: op.to, length: op.insert.length, local: !meta.remote });
    if (unacknowledged.length > 200) unacknowledged.splice(0, unacknowledged.length - 200);
    let after = typeof op.select === "function" ? op.select(model) : op.select;
    if (!after) after = mapSelectionThrough(before, op);
    if (meta.selection !== false && after) setSelection(after.anchor, after.head);
    // The page's selection stays where it was; the offsets kept for it moved with the text.
    else sticky = null;
    if (profile) profile.push({ patch: t1 - t0, dom: t2 - t1, selection: performance.now() - t2 });
    post({
      type: "edit",
      v: version,
      from: op.from,
      to: op.to,
      removed,
      inserted: op.insert,
      selectionBefore: { anchor: before.anchor, head: before.head },
      selectionAfter: after ? { anchor: after.anchor, head: after.head } : null,
      kind: meta.reason || kind,
      group: meta.group || currentGroup,
      coalesce: Boolean(coalesce),
      label: op.label || meta.label || "",
      cell: caretInTableCell(after)
    });
    Flow.afterEdit(op);
    UI.afterEdit(op);
    scheduleSelectionReport();
    return true;
  }

  /// Whether the caret is in a table cell, where the app's writing assistance does not run: a
  /// sentence there starts in another cell, so a reviewed fix could not be drawn.
  function caretInTableCell(selection) {
    if (!selection || !model) return false;
    const unit = unitAt(model, selection.head, "left");
    return Boolean(unit && unit.role === "cell");
  }

  function mapSelectionThrough(selection, op) {
    const map = (position) => {
      if (position <= op.from) return position;
      if (position >= op.to) return position + op.insert.length - (op.to - op.from);
      return op.from + op.insert.length;
    };
    return { anchor: map(selection.anchor), head: map(selection.head) };
  }

  function newGroup() {
    currentGroup = ++groupSequence;
    lastEditKind = "";
    return currentGroup;
  }

  // Input -------------------------------------------------------------

  function onBeforeInput(event) {
    if (!active) return;
    const type = event.inputType;
    if (type === "insertCompositionText" || composing) return;
    if (type === "historyUndo" || type === "historyRedo") {
      event.preventDefault();
      post({ type: type === "historyUndo" ? "undo" : "redo" });
      return;
    }
    event.preventDefault();
    const selection = readSelection();
    if (!selection) return;
    switch (type) {
      case "insertText":
      case "insertReplacementText": {
        const text = event.data ?? event.dataTransfer?.getData("text/plain") ?? "";
        if (!text) return;
        let target = selection;
        if (type === "insertReplacementText") {
          const ranges = event.getTargetRanges ? event.getTargetRanges() : [];
          if (ranges.length) {
            const start = domToRaw(ranges[0].startContainer, ranges[0].startOffset, "right");
            const end = domToRaw(ranges[0].endContainer, ranges[0].endOffset, "left");
            if (start !== null && end !== null) target = withOrder(start, end);
          }
          // macOS turns typed quotes and dashes into curly ones by replacing them; in code the
          // replacement is cancelled, so "--" stays as typed.
          if (/^[\u2013\u2014\u2018\u2019\u201C\u201D]+$/.test(text) && insideCode(target.from)) return;
        }
        typeText(target, text, type === "insertText");
        return;
      }
      case "insertParagraph":
        enter(selection, {});
        return;
      case "insertLineBreak":
        lineBreak(selection);
        return;
      case "deleteContentBackward":
      case "deleteWordBackward":
      case "deleteSoftLineBackward":
      case "deleteHardLineBackward":
      case "deleteContentForward":
      case "deleteWordForward":
      case "deleteSoftLineForward":
      case "deleteHardLineForward":
      case "deleteByCut":
      case "deleteContent":
        deleteWith(event, selection, type);
        return;
      case "formatBold":
        command("bold");
        return;
      case "formatItalic":
        command("italic");
        return;
      case "formatStrikeThrough":
        command("strikethrough");
        return;
      default:
        return;
    }
  }

  const STRAIGHT = { "\u201C": "\"", "\u201D": "\"", "\u2018": "'", "\u2019": "'", "\u2013": "--", "\u2014": "---" };

  /// Code keeps the characters typed: macOS substitutes curly quotes and dashes in text fields,
  /// and the source editor turns that off for code.
  function insideCode(position) {
    const unit = unitAt(model, position, "left");
    if (!unit) return false;
    if (unit.kind === "code" || unit.kind === "raw") return true;
    if (unit.kind !== "inline") return false;
    const j = jOf(unit, position);
    return visibleMap(model, unit).constructs.some((construct) => construct.type === "code" && construct.cs <= j && j <= construct.ce);
  }

  function typeText(selection, text, typing) {
    let group = 0;
    if (typing && trailingLine && selection.from === trailingLine.at && selection.to === trailingLine.at) {
      // The first character after a click below the last block opens the line it goes on.
      trailingLine = null;
      group = newGroup();
      const last = model.blocks[model.blocks.length - 1];
      if (!last || !apply({ ...insertEmptyAfterBlock(model, last), kind: "typing" }, { group })) return;
      selection = readSelection();
      if (!selection) return;
    }
    if (/[\u2013\u2014\u2018\u2019\u201C\u201D]/.test(text) && insideCode(selection.from)) {
      text = text.replace(/[\u2013\u2014\u2018\u2019\u201C\u201D]/g, (character) => STRAIGHT[character]);
    }
    let op = planInsertText(model, selection, text, { typing });
    if (!op) return;
    if (pendingMarks && selection.from === selection.to && typing) {
      const unit = unitAt(model, selection.from, "left");
      if (unit && unit.kind === "inline" && unit.role !== "cell") {
        const markers = pendingMarks.map((style) => STYLE_MARKERS[style]);
        const open = markers.join("");
        const close = markers.slice().reverse().join("");
        op = { from: selection.from, to: selection.from, insert: open + text + close, select: caretAt(selection.from + open.length + text.length), kind: "typing" };
      }
      pendingMarks = null;
    }
    if (typing) Flow.prepareCarry(selection, text, op);
    apply(op, group ? { group } : {});
    UI.afterTyping(text);
  }

  const STYLE_MARKERS = { strong: "**", em: "*", del: "~~", code: "`" };

  function enter(selection, options) {
    const group = newGroup();
    if (selection.from !== selection.to) {
      apply(planDelete(model, selection.from, selection.to), { group });
      selection = readSelection() || withOrder(selection.from, selection.from);
    }
    const op = planEnter(model, selection, options);
    if (!op) return;
    if (op.cellMove) {
      moveCell(op.unit, "down", true);
      return;
    }
    apply(op, { group, coalesce: false });
  }

  function lineBreak(selection) {
    const group = newGroup();
    if (selection.from !== selection.to) {
      apply(planDelete(model, selection.from, selection.to), { group });
      selection = readSelection() || withOrder(selection.from, selection.from);
    }
    const op = planLineBreak(model, selection);
    if (op && op.cellMove) return;
    apply(op, { group });
  }

  function deleteWith(event, selection, type) {
    if (selection.from !== selection.to) {
      apply(planDelete(model, selection.from, selection.to));
      return;
    }
    const backward = type.includes("Backward");
    const unit = unitAt(model, selection.head, "left");
    if (!unit) return;
    const visible = visibleText(model, unit);
    const v = rawToVisible(model, unit, selection.head, "left");
    if (backward && v === 0) {
      apply(planBackspaceAtStart(model, unit));
      return;
    }
    if (!backward && v >= visible.length) {
      apply(planDeleteForwardAtEnd(model, unit));
      return;
    }
    let v0;
    let v1;
    const ranges = event.getTargetRanges ? event.getTargetRanges() : [];
    if (ranges.length && type !== "deleteContentBackward" && type !== "deleteContentForward") {
      const range = ranges[0];
      const startElement = unitElementFor(range.startContainer);
      const endElement = unitElementFor(range.endContainer);
      if (startElement === unit.el && endElement === unit.el) {
        v0 = visibleOffsetOf(unit.el, range.startContainer, range.startOffset);
        v1 = visibleOffsetOf(unit.el, range.endContainer, range.endOffset);
      }
    }
    if (v0 === undefined || v0 === null || v1 === null || v0 === v1) {
      if (backward) {
        v1 = v;
        v0 = v - lastGraphemeLength(visible.slice(0, v));
      } else {
        v0 = v;
        v1 = v + firstGraphemeLength(visible.slice(v));
      }
    }
    const [from, to] = visibleRangeToRaw(model, unit, Math.min(v0, v1), Math.max(v0, v1));
    const op = planDelete(model, from, to);
    if (op) apply(op);
  }

  const segmenter = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;

  function lastGraphemeLength(text) {
    if (!text) return 0;
    if (!segmenter) return /[\uDC00-\uDFFF]$/.test(text) && text.length > 1 ? 2 : 1;
    let last = 1;
    for (const part of segmenter.segment(text)) last = part.segment.length;
    return last;
  }

  function firstGraphemeLength(text) {
    if (!text) return 0;
    if (!segmenter) return /^[\uD800-\uDBFF]/.test(text) ? 2 : 1;
    for (const part of segmenter.segment(text)) return part.segment.length;
    return 1;
  }

  function onInput(event) {
    if (!active || composing) return;
    // Anything the browser changed without a cancelable event (dictation,
    // some system text replacements) is turned into a patch here.
    reconcile();
  }

  function onCompositionStart() {
    Flow.compositionStarted();
    const selection = readSelection();
    if (selection && selection.from !== selection.to) {
      const first = unitAt(model, selection.from, "right");
      const last = unitAt(model, selection.to, "left");
      if (first !== last) apply(planDelete(model, selection.from, selection.to));
    }
    composing = true;
    UI.closeTransient();
  }

  function onCompositionEnd() {
    composing = false;
    window.setTimeout(() => {
      // A new composition already started (Korean starts the next syllable at once): its own end
      // reconciles both.
      if (composing) return;
      reconcile();
      const queued = pendingRemote;
      pendingRemote = [];
      queued.forEach((payload) => applyRemote(payload));
      Flow.compositionEnded();
    }, 0);
  }

  /// Compares a unit's text on the page with the model and turns the
  /// difference into a patch.
  function reconcile() {
    if (!model) return;
    const selection = window.getSelection();
    const element = unitElementFor(selection && selection.anchorNode);
    const unit = unitForElement(element);
    if (!unit || !element.isConnected) {
      const changed = allUnits(model).find((candidate) => candidate.el && candidate.el.isConnected && visibleTextOfElement(candidate.el) !== visibleText(model, candidate));
      if (!changed) {
        if (Array.from(root.children).length !== model.blocks.length + (footnotesElement ? 1 : 0)) fullRender();
        return;
      }
      reconcileUnit(changed, changed.el);
      return;
    }
    reconcileUnit(unit, element);
  }

  function reconcileUnit(unit, element) {
    const pageText = visibleTextOfElement(element).replace(/\u00A0/g, " ");
    const modelText = visibleText(model, unit);
    if (pageText === modelText) return;
    let start = 0;
    while (start < pageText.length && start < modelText.length && pageText[start] === modelText[start]) start += 1;
    let endPage = pageText.length;
    let endModel = modelText.length;
    while (endPage > start && endModel > start && pageText[endPage - 1] === modelText[endModel - 1]) {
      endPage -= 1;
      endModel -= 1;
    }
    const inserted = pageText.slice(start, endPage).replace(/\uFFFC/g, "");
    let from;
    let to;
    if (endModel > start) [from, to] = visibleRangeToRaw(model, unit, start, endModel);
    else from = to = visibleToRaw(model, unit, start, "left");
    sticky = null;
    let op;
    if (from === to) {
      op = insertionAt(model, unit, from, unit.role === "cell" ? escapeCell(inserted) : inserted);
    } else {
      const parts = markupAwareParts(model, unit, from, to, true);
      op = compose(model.source, parts, unit.role === "cell" ? escapeCell(inserted) : inserted);
    }
    if (!op) return;
    op.kind = "typing";
    apply(op, { selectionBefore: withOrder(from, from) });
  }

  // Keys ----------------------------------------------------------------

  function onKeyDown(event) {
    if (!active) return;
    if (!["Meta", "Shift", "Alt", "Control", "CapsLock"].includes(event.key)) Handles.suppress();
    // Keys that pick or commit marked text belong to the input method.
    if (composing || event.isComposing) return;
    if (UI.handleKeyDown(event)) return;
    if (Flow.handleKeyDown(event)) return;
    const mod = event.metaKey && !event.ctrlKey;
    const key = event.key;
    if (mod && event.shiftKey && !event.altKey && (key === "ArrowUp" || key === "ArrowDown")) {
      event.preventDefault();
      runBlockMenuShortcut(key === "ArrowUp" ? "up" : "down");
      return;
    }
    if (mod && !event.altKey) {
      const lower = key.toLowerCase();
      if (lower === "d" && !event.shiftKey) {
        event.preventDefault();
        runBlockMenuShortcut("duplicate");
        return;
      }
      if (key === "/" && !event.shiftKey) {
        event.preventDefault();
        const selection = readSelection();
        const target = selection && handleTargetOf(model, unitAt(model, selection.head, "left"));
        if (target) UI.openBlockMenu(target, caretRect() || ZERO_RECT, false);
        return;
      }
      if (lower === "z") {
        event.preventDefault();
        post({ type: event.shiftKey ? "redo" : "undo" });
        return;
      }
      if (lower === "b" && !event.shiftKey) {
        event.preventDefault();
        command("bold");
        return;
      }
      if (lower === "i" && !event.shiftKey) {
        event.preventDefault();
        command("italic");
        return;
      }
      if (lower === "e" && !event.shiftKey) {
        event.preventDefault();
        command("code");
        return;
      }
      if (lower === "k" && !event.shiftKey) {
        event.preventDefault();
        command("link");
        return;
      }
      if (lower === "x" && event.shiftKey) {
        event.preventDefault();
        command("strikethrough");
        return;
      }
      if (key === "Enter") {
        event.preventDefault();
        const selection = readSelection();
        if (selection) enter(selection, { exitBlock: true });
        return;
      }
    }
    if (mod && event.altKey && /^[0-6]$/.test(key)) {
      event.preventDefault();
      command(key === "0" ? "paragraph" : "heading", Number(key));
      return;
    }
    if (key === "Tab" && !event.metaKey && !event.ctrlKey && !event.altKey) {
      event.preventDefault();
      tab(event.shiftKey);
      return;
    }
    if ((key === "ArrowDown" || key === "ArrowRight") && !event.shiftKey && !mod) {
      if (createLineAfterLastStructuralBlock(key)) event.preventDefault();
    }
  }

  function onKeyUp(event) {
    if (!active) return;
    Flow.handleKeyUp(event);
  }

  function tab(backward) {
    const selection = readSelection();
    if (!selection) return;
    const unit = unitAt(model, selection.head, "left");
    if (!unit) return;
    if (unit.role === "cell") {
      moveCell(unit, backward ? "previous" : "next", !backward);
      return;
    }
    if (unit.role === "item") {
      const op = planIndent(model, selection, backward ? -1 : 1);
      if (op) apply(op);
      return;
    }
    if (unit.kind === "code") {
      if (backward) {
        const lineStart = lineStartOf(model.source, selection.head);
        const prefix = quotePrefixOfLine(model.source, lineStart);
        const text = model.source.slice(lineStart + prefix.length, lineStart + prefix.length + 2);
        const remove = text.startsWith("\t") ? 1 : text === "  " ? 2 : text.startsWith(" ") ? 1 : 0;
        if (remove) apply({ from: lineStart + prefix.length, to: lineStart + prefix.length + remove, insert: "", select: caretAt(Math.max(lineStart + prefix.length, selection.head - remove)), kind: "typing" });
        return;
      }
      apply(planInsertText(model, selection, "  ", {}));
    }
  }

  function moveCell(unit, direction, createRow) {
    let target = cellNeighbor(model, unit, direction);
    if (!target && createRow && (direction === "next" || direction === "down")) {
      const last = tableCells(model, unit.table).slice(-1)[0];
      const op = planTable(model, last || unit, "rowBelow");
      if (op) {
        apply(op);
        return;
      }
    }
    if (target) setSelection(unitStart(target), unitEnd(target) > unitStart(target) && direction !== "down" ? unitEnd(target) : unitStart(target));
  }

  /// ↓ or → at the very end of a document that ends in a block the caret cannot leave by typing (a
  /// code block, table, quote, callout, toggle, divider or table of contents) opens a line after it.
  function createLineAfterLastStructuralBlock(key) {
    const selection = readSelection();
    if (!selection || selection.from !== selection.to) return false;
    const unit = unitAt(model, selection.head, "left");
    const lastBlock = model.blocks[model.blocks.length - 1];
    if (!unit || !lastBlock || lastBlock.type === "empty") return false;
    let last = lastUnitUpTo(model, model.blocks.length - 1);
    while (last && isHiddenUnit(last)) last = previousUnit(model, last);
    if (unit !== last) return false;
    if (!isStructural(unit) && !unit.container && unit.role !== "summary" && !isAtomBlock(lastBlock)) return false;
    if (key === "ArrowRight" && selection.head !== unitEnd(unit)) return false;
    if (key === "ArrowDown") {
      if (unit.role === "cell") {
        if (cellNeighbor(model, unit, "down")) return false;
      } else {
        const after = model.source.slice(selection.head, unitEnd(unit));
        if (/[\r\n]/.test(after)) return false;
        // A wrapped paragraph: ↓ first walks its visual lines.
        const caret = caretRect();
        const box = unit.el && unit.el.getBoundingClientRect();
        if (caret && box && caret.bottom < box.bottom - caret.height / 2) return false;
      }
    }
    apply({ ...insertEmptyAfterBlock(model, lastBlock), kind: "enter" });
    return true;
  }

  let commandKeyDown = false;
  function setCommandKey(down) {
    if (commandKeyDown === down) return;
    commandKeyDown = down;
    document.documentElement.classList.toggle("mk-command-key", down);
  }

  function onDocumentKeyDown(event) {
    if (event.key === "Meta") setCommandKey(true);
  }

  function onDocumentKeyUp(event) {
    if (event.key === "Meta") setCommandKey(false);
  }

  // Commands ----------------------------------------------------------

  /// Runs a formatting command on the current selection: from the format bar, a menu or a
  /// shortcut.
  function command(name, value) {
    if (!active || !model) return false;
    const selection = readSelection() || lastSelection;
    if (!selection) return false;
    const styleFor = { bold: "strong", italic: "em", strikethrough: "del", code: "code" };
    if (styleFor[name]) {
      const style = styleFor[name];
      if (selection.from === selection.to) {
        togglePendingMark(style);
        return true;
      }
      const op = planInlineStyle(model, selection, style);
      if (op) return apply(op, { coalesce: false });
      return false;
    }
    switch (name) {
      case "link":
        UI.openLinkEditor(selection);
        return true;
      case "removeLink": {
        const state = inlineState(model, selection);
        const target = state.link ? withOrder(state.link.contentFrom, state.link.contentTo) : selection;
        if (state.link && state.link.kind !== "link") {
          return apply({ from: state.link.from, to: state.link.to, insert: model.source.slice(state.link.contentFrom, state.link.contentTo), select: caretAt(selection.head), kind: "format", label: "Remove Link" });
        }
        return apply(planInlineStyle(model, target, "link", null));
      }
      case "setLink": {
        const url = String(value || "").trim();
        if (!url) return false;
        const state = inlineState(model, selection);
        if (state.link && state.link.kind === "link" && selection.from === selection.to) {
          return apply(planInlineStyle(model, withOrder(state.link.contentFrom, state.link.contentTo), "link", url.replace(/\s/g, "%20")));
        }
        if (selection.from === selection.to) {
          const label = url;
          return apply({ ...planInsertText(model, selection, `[${label}](${url.replace(/\s/g, "%20")})`, {}), kind: "format", label: "Link" });
        }
        return apply(planInlineStyle(model, selection, "link", url.replace(/\s/g, "%20")));
      }
      case "paragraph":
        return apply(planBlockType(model, selection, "paragraph"));
      case "heading":
        return apply(planBlockType(model, selection, `heading${Math.max(1, Math.min(6, Number(value) || 1))}`, { toggle: true }));
      case "bulletList":
        return apply(planBlockType(model, selection, "bullet", { toggle: true }));
      case "numberedList":
        return apply(planBlockType(model, selection, "numbered", { toggle: true }));
      case "taskList":
        return apply(planBlockType(model, selection, "todo", { toggle: true }));
      case "quote":
        return apply(planBlockType(model, selection, "quote", { toggle: true }));
      case "codeBlock":
        return apply(planBlockType(model, selection, "code", { toggle: true }));
      case "horizontalRule":
      case "table": {
        const unit = unitAt(model, selection.head, "left");
        if (!unit) return false;
        const eol = model.eol;
        const text = name === "table" ? tableTemplate(eol, "") : "---";
        const op = planInsertBlock(model, unit, text, name === "table" ? 2 : 3, name === "table" ? "Table" : "Divider");
        if (name === "horizontalRule") op.select = (next) => caretOnFirstEmptyAfter(next, op.from + 1);
        return apply(op);
      }
      case "image":
        post({ type: "requestFile", kind: "image", selection: { anchor: selection.anchor, head: selection.head } });
        return true;
      case "indent":
        return apply(planIndent(model, selection, 1));
      case "outdent":
        return apply(planIndent(model, selection, -1));
      case "selectAll":
        setSelection(0, model.source.length);
        return true;
      default:
        return false;
    }
  }

  function togglePendingMark(style) {
    const selection = readSelection();
    const state = selection ? inlineState(model, selection) : {};
    const marks = new Set(pendingMarks || []);
    if (marks.has(style)) marks.delete(style);
    else if (!state[style]) marks.add(style);
    pendingMarks = marks.size ? STYLE_ORDER.filter((candidate) => marks.has(candidate)) : null;
    reportSelectionNow();
  }

  let lastSelection = null;

  // Selection reporting ------------------------------------------------

  /// Selection changes arrive in bursts while dragging; report at most once per frame's worth of
  /// time. A timer, unlike an animation frame, also runs while the window is in the background.
  function scheduleSelectionReport() {
    if (!active || selectionFrame) return;
    selectionFrame = window.setTimeout(() => {
      selectionFrame = 0;
      reportSelectionNow();
    }, 16);
  }

  function reportSelectionNow() {
    if (!active || !model || composing) return;
    const selection = readSelection();
    if (!selection) {
      UI.selectionChanged(null);
      return;
    }
    if (sticky && (selection.anchor !== sticky.anchor || selection.head !== sticky.head)) sticky = null;
    if (trailingLine && (selection.from !== trailingLine.at || selection.to !== trailingLine.at)) trailingLine = null;
    if (pendingMarks && lastSelection && (selection.head !== lastSelection.head || selection.from !== selection.to)) pendingMarks = null;
    lastSelection = selection;
    markCurrentUnit(selection);
    Flow.selectionChanged(selection);
    const unit = unitAt(model, selection.head, "left");
    const state = inlineState(model, selection);
    for (const style of pendingMarks || []) state[style] = !state[style];
    const report = {
      anchor: selection.anchor,
      head: selection.head,
      block: blockTypeOf(unit),
      strong: state.strong,
      em: state.em,
      del: state.del,
      code: state.code,
      link: Boolean(state.link),
      canFormat: Boolean(unit && unit.kind === "inline"),
      v: version,
      focused: document.activeElement === root,
      cell: Boolean(unit && unit.role === "cell"),
      selectedMarkdown: selection.from === selection.to ? "" : model.source.slice(selection.from, Math.min(selection.to, selection.from + 4000))
    };
    UI.selectionChanged(selection, unit, state, report);
    // The app needs the selection, its Markdown and what the writing assistance asks for.
    const { anchor, head, v, focused, cell, selectedMarkdown } = report;
    const message = { type: "selection", anchor, head, v, focused, cell, selectedMarkdown };
    const key = JSON.stringify(message);
    if (key === lastReportedSelection) return;
    lastReportedSelection = key;
    post(message);
  }

  let currentUnitElement = null;
  function markCurrentUnit(selection) {
    const unit = unitAt(model, selection.head, "left");
    const element = unit && unit.el;
    if (element === currentUnitElement) return;
    currentUnitElement?.classList.remove("mk-current");
    currentUnitElement = element || null;
    if (element) element.classList.add("mk-current");
  }

  function onBlur() {
    Flow.blur();
    post({ type: "focus", focused: false });
    currentUnitElement?.classList.remove("mk-current");
    currentUnitElement = null;
    window.setTimeout(() => {
      if (!layer || !layer.contains(document.activeElement)) UI.closeTransient();
    }, 0);
  }

  // Mouse ---------------------------------------------------------------

  function onMouseDown(event) {
    Flow.pointerDown();
    const target = event.target instanceof Element ? event.target : null;
    if (!target) return;
    const checkbox = target.closest('input[type="checkbox"][data-monknot-task]');
    if (checkbox) {
      event.preventDefault();
      const item = checkbox.closest("li");
      const textElement = item && item.querySelector(":scope > [data-mk-u]");
      const unit = unitForElement(textElement);
      const op = planToggleTask(model, unit);
      if (op) {
        const selection = readSelection();
        op.select = selection ? { anchor: selection.anchor, head: selection.head } : null;
        apply(op, { coalesce: false, selection: Boolean(selection) });
      }
      return;
    }
    const languageButton = target.closest("[data-mk-action='code-language']");
    if (languageButton) {
      event.preventDefault();
      UI.openLanguageMenu(languageButton);
      return;
    }
    const arrow = target.closest("[data-mk-action='toggle']");
    if (arrow) {
      event.preventDefault();
      flipToggle(arrow.closest(".mk-toggle"));
      return;
    }
    const calloutTitle = target.closest("[data-mk-action='callout-kind']");
    if (calloutTitle) {
      event.preventDefault();
      UI.openCalloutMenu(calloutTitle);
      return;
    }
    if (target.closest("a[data-mk-toc]")) {
      event.preventDefault();
      return;
    }
    const image = target.closest("img[data-mk-atom]");
    if (image) {
      event.preventDefault();
      const range = document.createRange();
      range.selectNode(image);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      root.focus({ preventScroll: true });
      return;
    }
    const anchor = target.closest("a");
    if (anchor && event.metaKey) {
      event.preventDefault();
      openLink(anchor);
      return;
    }
    if (target === root && model) {
      // A click below the last block puts the caret at the end, and the file changes only once a
      // character is typed: after text typing continues it; after a block it cannot continue (a
      // table, code, a quote, a divider) that character opens a line below the block.
      const last = model.blocks[model.blocks.length - 1];
      if (last && last.el && last.type !== "empty" && event.clientY > last.el.getBoundingClientRect().bottom) {
        event.preventDefault();
        root.focus({ preventScroll: true });
        let unit = lastUnitUpTo(model, model.blocks.length - 1);
        while (unit && isHiddenUnit(unit)) unit = previousUnit(model, unit);
        if (!unit) {
          // Nowhere for the caret to wait (a document of dividers): the line is made now.
          apply({ ...insertEmptyAfterBlock(model, last), kind: "enter" });
          return;
        }
        const end = unitEnd(unit);
        setSelection(end, end);
        if (unit.top !== last || isStructural(unit) || unit.kind === "raw" || unit.container || unit.role === "summary") {
          trailingLine = { at: end };
        }
      }
    }
  }

  /// Opens or closes a toggle on the page. The file does not change; a caret in the body it hides
  /// moves to the title.
  function flipToggle(element) {
    const summaryElement = element && element.querySelector(":scope > .mk-toggle-head > [data-mk-u]");
    const summary = unitForElement(summaryElement);
    if (!summary) return;
    const toggle = summary.block;
    const open = !isOpenToggle(toggle);
    toggle.viewOpen = open;
    element.dataset.open = String(open);
    const arrowButton = element.querySelector(":scope > .mk-toggle-head > .mk-toggle-arrow");
    if (arrowButton) {
      arrowButton.setAttribute("aria-expanded", String(open));
      arrowButton.setAttribute("aria-label", open ? "Collapse" : "Expand");
    }
    const selection = readSelection();
    if (!open && selection) {
      const unit = unitAt(model, selection.head, "left");
      if (unit && isHiddenUnit(unit)) {
        root.focus({ preventScroll: true });
        setSelection(unitEnd(summary), unitEnd(summary), { reveal: false });
      }
    }
    UI.reposition();
  }

  function onMouseUp() {
    window.setTimeout(() => UI.showFormatBarIfNeeded(true), 0);
  }

  function onClick(event) {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) return;
    const anchor = target.closest("a");
    if (anchor) event.preventDefault();
  }

  function openLink(anchor) {
    const destination = anchor.dataset.monknotDestination || anchor.getAttribute("href") || "";
    if (!destination) return;
    const href = anchor.getAttribute("href") || "";
    if (href.startsWith("#fn") || anchor.closest(".footnote-ref") || anchor.classList.contains("footnote-backref")) return;
    window.monknotPostLinkInteraction?.(anchor.dataset.monknotLinkKind === "wikilink" ? "wikilink" : "markdown", destination);
  }

  // Clipboard ------------------------------------------------------------

  function onCopy(event) {
    const selection = readSelection();
    if (!selection || selection.from === selection.to) return;
    event.preventDefault();
    writeClipboard(event.clipboardData, selection);
  }

  function onCut(event) {
    const selection = readSelection();
    if (!selection || selection.from === selection.to) return;
    event.preventDefault();
    writeClipboard(event.clipboardData, selection);
    apply({ ...planDelete(model, selection.from, selection.to), label: "Cut" }, { coalesce: false });
  }

  function writeClipboard(data, selection) {
    const markdown = balancedMarkdown(model, selection.from, selection.to);
    data.setData("text/plain", markdown);
    data.setData("application/x-monknot-markdown", markdown);
    const range = window.getSelection().getRangeAt(0);
    const container = document.createElement("div");
    container.appendChild(range.cloneContents());
    container.querySelectorAll("[data-mk-skip], .mk-code-language").forEach((element) => element.remove());
    container.querySelectorAll("*").forEach((element) => {
      for (const attribute of Array.from(element.attributes)) {
        if (attribute.name.startsWith("data-mk") || attribute.name === "contenteditable" || attribute.name === "data-source-line" || attribute.name === "data-placeholder") {
          element.removeAttribute(attribute.name);
        }
      }
    });
    data.setData("text/html", container.innerHTML);
  }

  function onPaste(event) {
    event.preventDefault();
    const selection = readSelection();
    if (!selection) return;
    const data = event.clipboardData;
    if (!data) return;
    const types = Array.from(data.types || []);
    const files = Array.from(data.files || []);
    if (files.some((file) => /^image\//.test(file.type)) && !data.getData("text/plain")) {
      post({ type: "pasteImage", selection: { anchor: selection.anchor, head: selection.head } });
      return;
    }
    const unit = unitAt(model, selection.from, "right");
    const plain = data.getData("text/plain") || "";
    let text = data.getData("application/x-monknot-markdown");
    if (!text) {
      const html = types.includes("text/html") ? data.getData("text/html") : "";
      const literal = unit && (unit.kind === "code" || unit.kind === "raw");
      if (html && !literal && !looksLikeCodeHTML(html)) {
        text = htmlToMarkdown(html) ?? plain;
      } else {
        text = plain;
      }
    }
    if (!text) return;
    const group = newGroup();
    apply(planInsertText(model, selection, text, { kind: "paste" }), { group, coalesce: false, label: "Paste" });
  }

  function looksLikeCodeHTML(html) {
    return /monospace|vscode|white-space:\s*pre|<pre[\s>]/i.test(html) && !/<(p|h[1-6]|li|table)[\s>]/i.test(html);
  }

  function onDrop(event) {
    event.preventDefault();
    const data = event.dataTransfer;
    if (!data) return;
    const caret = document.caretRangeFromPoint ? document.caretRangeFromPoint(event.clientX, event.clientY) : null;
    const raw = caret ? domToRaw(caret.startContainer, caret.startOffset, "left") : null;
    if (data.files && data.files.length) {
      // Files: the app reads their URLs from the drag and imports them as Source does.
      if (raw !== null) post({ type: "dropFiles", selection: { anchor: raw, head: raw } });
      return;
    }
    const text = data.getData("application/x-monknot-markdown") || data.getData("text/plain");
    if (!text || raw === null) return;
    apply(planInsertText(model, withOrder(raw, raw), text, { kind: "paste" }), { coalesce: false, label: "Drop" });
  }

  // Messages from the app ----------------------------------------------

  /// Applies a change the app asks for (undo, redo, the file changed on
  /// disk) or a writing-assistance fix. `base` is the last version the app
  /// has seen; local edits it has not seen yet move the request first, and
  /// those after it move past it in turn: the app's next request is made on
  /// its text with this one applied, and the app moves those edits the same
  /// way when they reach it.
  function applyRemote(payload) {
    if (!active || !model) return { applied: false };
    if (composing) {
      pendingRemote.push(payload);
      return { applied: true, queued: true };
    }
    const base = Number(payload.base) || 0;
    unacknowledged = unacknowledged.filter((entry) => entry.v > base);
    let from = Number(payload.from);
    let to = Number(payload.to);
    let selection = payload.selection ? { anchor: payload.selection.anchor, head: payload.selection.head } : null;
    // The app's request already accounts for every change it asked for itself; only local edits
    // it has not seen yet move the request.
    const later = [];
    for (const entry of unacknowledged) {
      if (!entry.local) continue;
      const entryDelta = entry.length - (entry.to - entry.from);
      if (entry.to <= from) {
        from += entryDelta;
        to += entryDelta;
        if (selection) selection = { anchor: selection.anchor + entryDelta, head: selection.head + entryDelta };
      } else if (entry.from >= to) {
        later.push(entry);
      } else {
        post({ type: "conflict", reason: payload.reason || "" });
        return { applied: false };
      }
    }
    if (!(from >= 0 && to >= from && to <= model.source.length)) {
      post({ type: "conflict", reason: payload.reason || "" });
      return { applied: false };
    }
    if (typeof payload.expected === "string" && model.source.slice(from, to) !== payload.expected) {
      post({ type: "conflict", reason: payload.reason || "" });
      return { applied: false };
    }
    const insert = typeof payload.insert === "string" ? payload.insert : "";
    const keepSelection = readSelection();
    const op = { from, to, insert, select: selection || null };
    const applied = apply(op, {
      // The app applies a fix it sent to the document only when the page reports it, as it does
      // the page's own edits; its other requests are in the document already.
      remote: payload.reason !== "flow",
      reason: payload.reason || "remote",
      kind: payload.reason || "remote",
      label: typeof payload.label === "string" ? payload.label : "",
      coalesce: false,
      group: ++groupSequence,
      selectionBefore: keepSelection || undefined,
      selection: payload.reason === "external" ? (document.activeElement === root) : true
    });
    if (applied) {
      const delta = insert.length - (to - from);
      for (const entry of later) {
        entry.from += delta;
        entry.to += delta;
      }
    }
    return { applied, from };
  }

  function reset(payload) {
    if (!active) return;
    const keep = readSelection();
    model = createModel(typeof payload.text === "string" ? payload.text : "");
    fullRender();
    version += 1;
    unacknowledged = [];
    // Everything the app sent before is in the text it resets to.
    pendingRemote = [];
    sticky = null;
    trailingLine = null;
    post({ type: "reset", v: version });
    const selection = payload.selection || keep;
    if (selection && document.activeElement === root) setSelection(selection.anchor, selection.head, { reveal: false });
  }

  function insertMarkdownAt(payload) {
    if (!active || !model) return false;
    const selection = payload.selection ? withOrder(payload.selection.anchor, payload.selection.head) : readSelection();
    if (!selection) return false;
    if (typeof payload.expectedLength === "number" && payload.expectedLength !== model.source.length) {
      // The document changed since the request; insert at the caret instead.
      const current = readSelection();
      if (current) return apply({ ...planInsertText(model, current, payload.markdown || "", { kind: "paste" }), label: payload.label || "Insert" }, { coalesce: false });
    }
    return apply({ ...planInsertText(model, selection, payload.markdown || "", { kind: "paste" }), label: payload.label || "Insert" }, { coalesce: false });
  }

  function sourceLineElements() {
    if (!model) return [];
    const result = [];
    for (const block of model.blocks) {
      if (block.el && block.type !== "empty") result.push({ element: block.el, line: bLine(block) + 1 });
    }
    return result;
  }

  function currentSelectionForApp() {
    const selection = readSelection() || lastSelection;
    return selection ? { anchor: selection.anchor, head: selection.head } : null;
  }

  // =====================================================================
  // Menus and toolbars
  // =====================================================================

  function ensureLayer() {
    if (layer && layer.isConnected) return;
    layer = document.createElement("div");
    layer.className = "mk-layer";
    layer.setAttribute("contenteditable", "false");
    document.body.appendChild(layer);
  }

  /// An SF Symbol drawn by the app; `context` picks its size: "menu" beside a label (15),
  /// "tool" alone in a button (17), "small" for a check (11).
  function icon(name, context = "menu") {
    const span = document.createElement("span");
    span.className = "mk-icon";
    span.setAttribute("aria-hidden", "true");
    span.dataset.mkIcon = `${context}:${name}`;
    applyIcon(span);
    return span;
  }

  /// Draws a glyph once the app has sent it. Bars built before the glyphs arrive keep their spans,
  /// which `setIcons` fills in; until then a span draws nothing rather than a solid square.
  function applyIcon(span) {
    const glyph = icons[span.dataset.mkIcon];
    if (!glyph) {
      span.classList.add("mk-icon-pending");
      return;
    }
    span.classList.remove("mk-icon-pending");
    span.style.webkitMaskImage = `url("${glyph.url}")`;
    span.style.maskImage = `url("${glyph.url}")`;
    span.style.setProperty("--mk-icon-width", `${glyph.width}px`);
    span.style.setProperty("--mk-icon-height", `${glyph.height}px`);
  }

  /// Glyphs drawn by a pseudo-element (a callout title's chevron), which reach it as a variable.
  const CSS_ICONS = { "--mk-chevron-down": "small:chevron.down" };

  function setIcons(map) {
    icons = map && typeof map === "object" ? map : {};
    document.querySelectorAll(".mk-icon[data-mk-icon]").forEach(applyIcon);
    for (const [variable, key] of Object.entries(CSS_ICONS)) {
      if (icons[key]) document.documentElement.style.setProperty(variable, `url("${icons[key].url}")`);
      else document.documentElement.style.removeProperty(variable);
    }
  }

  /// The workspace zoom every chrome metric scales with (design.md §9).
  function zoom() {
    return parseFloat(window.getComputedStyle(document.documentElement).getPropertyValue("--mk-z")) || 1;
  }

  function caretRect() {
    const selection = window.getSelection();
    if (!selection.rangeCount) return null;
    const range = selection.getRangeAt(0).cloneRange();
    range.collapse(true);
    const rects = range.getClientRects();
    if (rects.length) return rects[0];
    const element = unitElementFor(selection.anchorNode);
    if (element) {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      const lineHeight = parseFloat(style.lineHeight) || rect.height;
      return { left: rect.left, right: rect.left, top: rect.top, bottom: rect.top + Math.min(rect.height, lineHeight), width: 0, height: Math.min(rect.height, lineHeight) };
    }
    return null;
  }

  function selectionRect() {
    const selection = window.getSelection();
    if (!selection.rangeCount) return null;
    const range = selection.getRangeAt(0);
    const rects = Array.from(range.getClientRects()).filter((rect) => rect.width > 0 || rect.height > 0);
    if (!rects.length) return range.getBoundingClientRect();
    const first = rects[0];
    let left = Infinity;
    let right = -Infinity;
    for (const rect of rects) {
      if (Math.abs(rect.top - first.top) < 4) {
        left = Math.min(left, rect.left);
        right = Math.max(right, rect.right);
      }
    }
    return { left, right, top: first.top, bottom: first.bottom, width: right - left, height: first.height };
  }

  /// Places a floating element beside an anchor rect (viewport coordinates): below or above it,
  /// flipping when there is no room, or to its right for a submenu; never over the anchor. `align`
  /// sets the horizontal edge: "caret" (just left of the anchor, so row text lines up with typed
  /// text), "start" (the anchor's left edge) or "center". The element grows from the side that
  /// faces its anchor.
  function place(element, rect, preference = "below", align = "caret") {
    element.style.visibility = "hidden";
    element.style.left = "0px";
    element.style.top = "0px";
    const width = element.offsetWidth;
    const height = element.offsetHeight;
    const z = zoom();
    const gap = 6 * z;
    const margin = 8 * z;
    const viewportWidth = document.documentElement.clientWidth;
    const viewportHeight = window.innerHeight;
    let left;
    let top;
    let origin;
    if (preference === "right") {
      left = rect.right + 4 * z;
      if (left + width > viewportWidth - margin) left = rect.left - width - 4 * z;
      left = Math.max(margin, left);
      top = Math.max(margin, Math.min(rect.top - 6 * z, viewportHeight - height - margin));
      origin = `${left < rect.left ? "100%" : "0"} ${Math.round(Math.max(0, Math.min(height, rect.top - top + rect.height / 2)))}px`;
    } else {
      const above = rect.top - height - gap;
      const below = rect.bottom + gap;
      if (preference === "above") top = above >= margin ? above : below;
      else top = below + height <= viewportHeight - margin || above < margin ? below : above;
      if (align === "start") left = rect.left;
      else if (align === "center") left = rect.left + (rect.width || 0) / 2 - width / 2;
      else left = rect.left - 10 * z;
      left = Math.max(margin, Math.min(left, viewportWidth - width - margin));
      const anchorX = Math.round(Math.max(0, Math.min(width, rect.left + (rect.width || 0) / 2 - left)));
      origin = `${anchorX}px ${top < rect.top ? "100%" : "0"}`;
    }
    element.style.left = `${Math.round(left + window.scrollX)}px`;
    element.style.top = `${Math.round(top + window.scrollY)}px`;
    element.style.transformOrigin = origin;
    element.style.visibility = "";
    element.dataset.placement = preference === "right" ? "right" : top < rect.top ? "above" : "below";
  }

  /// Shows a floating surface. `animate` (a surface opened by the pointer) grows it in from its
  /// trigger; without it (opened from the keyboard) it appears at once.
  function show(element, animate = false) {
    const wasVisible = element.classList.contains("mk-visible");
    element.classList.remove("mk-hidden");
    if (!wasVisible) {
      element.classList.remove("mk-animate");
      if (animate) {
        void element.offsetWidth;
        element.classList.add("mk-animate");
      }
    }
    element.classList.add("mk-visible");
  }

  function hide(element) {
    if (!element) return;
    element.classList.remove("mk-visible");
    element.classList.add("mk-hidden");
  }

  const ZERO_RECT = { left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0 };

  /// The anchor of a surface that stays beside `element` while the column reflows (a resize, a side
  /// pane moving): `rect` moved by as much as the element has moved since it was measured.
  function following(element, rect) {
    if (!element || !rect) return null;
    const start = element.getBoundingClientRect();
    return () => {
      if (!element.isConnected) return null;
      const now = element.getBoundingClientRect();
      const dx = now.left - start.left;
      const dy = now.top - start.top;
      return { left: rect.left + dx, right: rect.right + dx, top: rect.top + dy, bottom: rect.bottom + dy, width: rect.width, height: rect.height };
    };
  }

  // Menu ----------------------------------------------------------------

  /// A list of choices with keyboard and pointer selection: the slash menu, the block menu and its
  /// Turn Into submenu, wikilinks, callout kinds, table actions and code languages. An item is
  /// { id, label, icon | tag, hint, checked, destructive, keywords, group, submenu } or
  /// { separator: true }. With `ranked`, items arrive already ranked for the query.
  function createMenu(options) {
    const element = document.createElement("div");
    element.className = `mk-floating mk-menu mk-hidden${options.narrow ? " mk-menu-narrow" : ""}`;
    element.setAttribute("role", "listbox");
    element.setAttribute("aria-label", options.label || "Menu");
    element.id = `mk-menu-${Math.random().toString(36).slice(2)}`;
    let field = null;
    if (options.searchField) {
      const header = document.createElement("div");
      header.className = "mk-menu-search";
      header.appendChild(icon("magnifyingglass"));
      field = document.createElement("input");
      field.type = "text";
      field.placeholder = options.searchPlaceholder || "Search";
      field.setAttribute("aria-label", options.searchPlaceholder || "Search");
      field.setAttribute("aria-controls", element.id);
      field.spellcheck = false;
      header.appendChild(field);
      element.appendChild(header);
    }
    const list = document.createElement("div");
    list.className = "mk-menu-list";
    element.appendChild(list);
    // The scroll thumb shows while the list scrolls, never merely under the pointer (design.md §5.7).
    let scrollingTimer = 0;
    list.addEventListener("scroll", () => {
      list.classList.add("mk-scrolling");
      window.clearTimeout(scrollingTimer);
      scrollingTimer = window.setTimeout(() => list.classList.remove("mk-scrolling"), 700);
    }, { passive: true });
    if (options.footer) {
      const footer = document.createElement("div");
      footer.className = "mk-menu-footer";
      footer.setAttribute("aria-hidden", "true");
      for (const [keys, action] of options.footer) {
        const pair = document.createElement("span");
        const key = document.createElement("kbd");
        key.textContent = keys;
        pair.append(key, document.createTextNode(action));
        footer.appendChild(pair);
      }
      element.appendChild(footer);
    }
    layer.appendChild(element);
    const state = { items: [], visible: [], index: 0, open: false, query: "", preference: "below", align: "caret", owner: null, follow: null };
    let hoverTimer = 0;

    const selectable = (item) => Boolean(item) && !item.separator;
    const rows = () => list.querySelectorAll(".mk-menu-row");

    const render = () => {
      // A submenu the pointer was about to open belongs to rows that are about to go.
      window.clearTimeout(hoverTimer);
      list.textContent = "";
      const query = state.query.trim().toLowerCase();
      const pool = query && options.searchItems ? options.searchItems(state.items) : state.items;
      state.visible = query && !options.ranked ? rankItems(pool.filter(selectable), query) : pool.slice();
      if (!state.visible.some(selectable)) {
        const empty = document.createElement("div");
        empty.className = "mk-menu-empty";
        empty.textContent = options.emptyText || "No matches";
        list.appendChild(empty);
        return;
      }
      let group = null;
      // A menu of plain names (code languages) starts its labels at the row's edge.
      const glyphs = state.visible.some((item) => item.icon || item.tag);
      state.visible.forEach((item, index) => {
        if (item.separator) {
          if (query || index === 0 || index === state.visible.length - 1) return;
          const rule = document.createElement("div");
          rule.className = "mk-menu-separator";
          rule.setAttribute("role", "separator");
          list.appendChild(rule);
          return;
        }
        if (!query && item.group && item.group !== group) {
          group = item.group;
          const heading = document.createElement("div");
          heading.className = "mk-menu-group";
          heading.textContent = group;
          heading.setAttribute("role", "presentation");
          list.appendChild(heading);
        }
        const row = document.createElement("div");
        row.className = "mk-menu-row";
        row.setAttribute("role", "option");
        row.id = `${element.id}-${index}`;
        row.dataset.index = String(index);
        if (item.destructive) row.classList.add("mk-destructive");
        const glyph = document.createElement("span");
        glyph.className = "mk-row-glyph";
        if (item.tag) {
          glyph.classList.add("mk-row-tag");
          glyph.textContent = item.tag;
        } else if (item.icon) {
          glyph.appendChild(icon(item.icon));
        }
        if (glyphs) row.appendChild(glyph);
        const label = document.createElement("span");
        label.className = "mk-row-label";
        label.textContent = item.label;
        row.appendChild(label);
        if (item.hint) {
          const hint = document.createElement("span");
          hint.className = "mk-row-hint";
          hint.textContent = item.hint;
          row.appendChild(hint);
        }
        if (item.checked) {
          const check = document.createElement("span");
          check.className = "mk-row-check";
          check.appendChild(icon("checkmark", "small"));
          row.appendChild(check);
        }
        if (item.submenu) {
          row.setAttribute("aria-haspopup", "listbox");
          const more = document.createElement("span");
          more.className = "mk-row-more";
          more.appendChild(icon("chevron.right", "small"));
          row.appendChild(more);
        }
        row.addEventListener("mousedown", (event) => event.preventDefault());
        row.addEventListener("mousemove", () => {
          if (state.index !== index) setIndex(index, false);
          window.clearTimeout(hoverTimer);
          options.onHoverRow?.(item);
          if (item.submenu && !row.classList.contains("mk-open-submenu")) {
            hoverTimer = window.setTimeout(() => {
              if (state.open && state.visible[index] === item) choose(index, true);
            }, 120);
          }
        });
        row.addEventListener("click", (event) => {
          event.preventDefault();
          choose(index, true);
        });
        list.appendChild(row);
      });
      setIndex(nearestSelectable(Math.min(state.index, state.visible.length - 1), 1), true);
    };

    const nearestSelectable = (index, direction) => {
      const count = state.visible.length;
      for (let step = 0; step < count; step += 1) {
        const candidate = ((index + step * direction) % count + count) % count;
        if (selectable(state.visible[candidate])) return candidate;
      }
      return 0;
    };

    const setIndex = (index, scroll) => {
      state.index = Math.max(0, index);
      rows().forEach((row) => {
        const selected = Number(row.dataset.index) === state.index;
        row.classList.toggle("mk-selected", selected);
        row.setAttribute("aria-selected", selected ? "true" : "false");
        if (selected) {
          element.setAttribute("aria-activedescendant", row.id);
          field?.setAttribute("aria-activedescendant", row.id);
          if (scroll) revealRow(row);
        }
      });
    };

    /// Scrolls the list, and only the list, so the highlighted row is in view.
    const revealRow = (row) => {
      const padding = 6;
      const top = row.offsetTop - padding;
      const bottom = row.offsetTop + row.offsetHeight + padding;
      if (top < list.scrollTop) list.scrollTop = Math.max(0, top);
      else if (bottom > list.scrollTop + list.clientHeight) list.scrollTop = bottom - list.clientHeight;
    };

    /// Chooses a row; `pointer` when a click or a hover chose it rather than a key.
    const choose = (index, pointer = false) => {
      const at = index ?? state.index;
      const item = state.visible[at];
      if (!selectable(item)) return;
      if (item.submenu) {
        rows().forEach((row) => row.classList.toggle("mk-open-submenu", Number(row.dataset.index) === at));
        options.onSubmenu?.(item, list.querySelector(`.mk-menu-row[data-index="${at}"]`) || element, pointer);
        return;
      }
      close("choose");
      options.onChoose(item, pointer);
    };

    const open = (items, rect, settings = {}) => {
      state.items = items;
      state.query = settings.query || "";
      const checked = items.findIndex((item) => item.checked);
      state.index = checked >= 0 ? checked : 0;
      state.preference = settings.preference || "below";
      state.align = settings.align || "caret";
      state.anchor = rect ? { rect, scrollX: window.scrollX, scrollY: window.scrollY } : null;
      // Where the menu goes when the column reflows: beside the control that opened it, unless the
      // opener says otherwise.
      state.follow = settings.follow || following(settings.owner, rect);
      // The control that opened the menu shows it is open until the menu closes.
      state.owner?.classList.remove("mk-open");
      state.owner = settings.owner || null;
      state.owner?.classList.add("mk-open");
      state.owner?.setAttribute("aria-expanded", "true");
      if (field) field.value = state.query;
      render();
      state.open = true;
      element.classList.add("mk-measuring");
      place(element, rect || ZERO_RECT, state.preference, state.align);
      element.classList.remove("mk-measuring");
      show(element, settings.animate);
      if (field) window.setTimeout(() => field.focus({ preventScroll: true }), 0);
      noteMenuChange();
    };

    /// A menu above its anchor stays attached by its bottom edge while filtering changes its height.
    const keepAttached = () => {
      if (!state.open || !state.anchor || element.dataset.placement !== "above") return;
      const { rect, scrollX, scrollY } = state.anchor;
      const dx = window.scrollX - scrollX;
      const dy = window.scrollY - scrollY;
      const moved = { left: rect.left - dx, right: rect.right - dx, top: rect.top - dy, bottom: rect.bottom - dy, width: rect.width, height: rect.height };
      place(element, moved, "above", state.align);
    };

    const close = (reason) => {
      if (!state.open) return;
      state.open = false;
      window.clearTimeout(hoverTimer);
      rows().forEach((row) => row.classList.remove("mk-open-submenu"));
      state.owner?.classList.remove("mk-open");
      state.owner?.setAttribute("aria-expanded", "false");
      state.owner = null;
      state.follow = null;
      hide(element);
      options.onClose?.(reason);
      noteMenuChange();
    };

    const handleNavigation = (event) => {
      if (!state.open) return false;
      const count = Math.max(1, state.visible.length);
      if (event.key === "ArrowDown" || (event.key === "n" && event.ctrlKey)) {
        event.preventDefault();
        setIndex(nearestSelectable((state.index + 1) % count, 1), true);
        return true;
      }
      if (event.key === "ArrowUp" || (event.key === "p" && event.ctrlKey)) {
        event.preventDefault();
        setIndex(nearestSelectable((state.index - 1 + count) % count, -1), true);
        return true;
      }
      if (event.key === "ArrowRight" && state.visible[state.index]?.submenu) {
        event.preventDefault();
        choose();
        return true;
      }
      if (event.key === "Enter" || event.key === "Tab") {
        if (!state.visible.some(selectable)) return false;
        event.preventDefault();
        choose();
        return true;
      }
      return false;
    };

    if (field) {
      field.addEventListener("input", () => {
        state.query = field.value;
        state.index = 0;
        options.onQuery?.();
        render();
        keepAttached();
      });
      field.addEventListener("keydown", (event) => {
        if (options.onFieldKey && options.onFieldKey(event)) return;
        if (handleNavigation(event)) return;
        if (event.key === "Escape") {
          event.preventDefault();
          close("escape");
        }
      });
      field.addEventListener("blur", () => window.setTimeout(() => {
        if (state.open && !element.contains(document.activeElement) && !options.keepsFocus?.()) close("blur");
      }, 0));
    }

    return {
      element,
      open,
      close,
      handleNavigation,
      setQuery(query) {
        state.query = query;
        state.index = 0;
        render();
        keepAttached();
      },
      setItems(items) {
        state.items = items;
        state.index = 0;
        render();
        keepAttached();
      },
      closeSubmenuMark() {
        rows().forEach((row) => row.classList.remove("mk-open-submenu"));
      },
      focusField() {
        field?.focus({ preventScroll: true });
      },
      get isOpen() { return state.open; },
      get matchCount() { return state.visible.filter(selectable).length; },
      get query() { return state.query; },
      /// Moves the menu to `rect`, or beside whatever it follows.
      reposition(anchor) {
        const rect = state.open ? anchor || state.follow?.() : null;
        if (!rect) return;
        state.anchor = { rect, scrollX: window.scrollX, scrollY: window.scrollY };
        place(element, rect, state.preference === "right" ? "right" : element.dataset.placement === "above" ? "above" : "below", state.align);
      }
    };
  }

  function rankItems(items, query) {
    const scored = [];
    for (const item of items) {
      const label = item.label.toLowerCase();
      const words = label.split(/\s+/);
      const keywords = (item.keywords || []).map((keyword) => keyword.toLowerCase());
      let score = -1;
      if (label === query) score = 100;
      else if (label.startsWith(query)) score = 80;
      else if (words.some((word) => word.startsWith(query))) score = 60;
      else if (keywords.some((keyword) => keyword === query)) score = 55;
      else if (keywords.some((keyword) => keyword.startsWith(query))) score = 45;
      else if (label.includes(query)) score = 30;
      else if (isSubsequence(query, label.replace(/\s+/g, ""))) score = 10;
      if (score >= 0) scored.push({ item, score });
    }
    scored.sort((a, b) => b.score - a.score || items.indexOf(a.item) - items.indexOf(b.item));
    return scored.map((entry) => entry.item);
  }

  function isSubsequence(needle, haystack) {
    let position = 0;
    for (const character of haystack) {
      if (character === needle[position]) position += 1;
      if (position === needle.length) return true;
    }
    return position === needle.length;
  }

  // Blocks the menus offer ------------------------------------------------

  /// The slash menu: Notion's block menu, less what a Markdown file cannot hold (databases,
  /// columns, synced blocks, embeds). Each row's hint is the Markdown to type instead.
  const SLASH_COMMANDS = [
    { id: "text", label: "Text", icon: "textformat", group: "Basic blocks", keywords: ["paragraph", "plain", "body"] },
    { id: "h1", label: "Heading 1", tag: "H1", hint: "#", group: "Basic blocks", keywords: ["title", "h1", "large", "big"] },
    { id: "h2", label: "Heading 2", tag: "H2", hint: "##", group: "Basic blocks", keywords: ["subtitle", "h2", "medium"] },
    { id: "h3", label: "Heading 3", tag: "H3", hint: "###", group: "Basic blocks", keywords: ["h3", "small"] },
    { id: "bullet", label: "Bulleted list", icon: "list.bullet", hint: "-", group: "Basic blocks", keywords: ["unordered", "ul", "bullet", "points"] },
    { id: "numbered", label: "Numbered list", icon: "list.number", hint: "1.", group: "Basic blocks", keywords: ["ordered", "ol", "numbers", "steps"] },
    { id: "todo", label: "To-do list", icon: "checklist", hint: "[]", group: "Basic blocks", keywords: ["task", "todo", "checkbox", "check"] },
    { id: "toggle", label: "Toggle list", icon: "arrowtriangle.right", group: "Basic blocks", keywords: ["details", "collapse", "expand", "disclosure", "summary"] },
    { id: "page", label: "Page", icon: "doc", group: "Basic blocks", keywords: ["new", "note", "file", "subpage", "document"] },
    { id: "callout", label: "Callout", icon: "text.bubble", group: "Basic blocks", keywords: ["note", "tip", "warning", "important", "caution", "alert", "admonition"] },
    { id: "quote", label: "Quote", icon: "text.quote", hint: ">", group: "Basic blocks", keywords: ["blockquote", "citation"] },
    { id: "table", label: "Table", icon: "tablecells", group: "Basic blocks", keywords: ["grid", "columns", "rows", "spreadsheet"] },
    { id: "divider", label: "Divider", icon: "minus", hint: "---", group: "Basic blocks", keywords: ["line", "separator", "hr", "horizontal rule"] },
    { id: "pageLink", label: "Link to page", icon: "arrow.up.right.square", hint: "[[", group: "Basic blocks", keywords: ["wikilink", "note", "reference", "mention"] },
    { id: "image", label: "Image", icon: "photo", group: "Media", keywords: ["picture", "photo", "png", "jpg", "screenshot"] },
    { id: "video", label: "Video", icon: "play.rectangle", group: "Media", keywords: ["movie", "mp4", "mov", "clip"] },
    { id: "audio", label: "Audio", icon: "speaker.wave.2", group: "Media", keywords: ["sound", "music", "mp3", "recording", "podcast"] },
    { id: "code", label: "Code", icon: "chevron.left.forwardslash.chevron.right", hint: "```", group: "Media", keywords: ["code block", "snippet", "pre", "program", "fence"] },
    { id: "file", label: "File", icon: "paperclip", group: "Media", keywords: ["attachment", "upload", "document", "pdf"] },
    { id: "bookmark", label: "Web bookmark", icon: "bookmark", group: "Media", keywords: ["link", "url", "website", "web"] },
    { id: "toc", label: "Table of contents", icon: "list.bullet.rectangle", hint: "[TOC]", group: "Advanced blocks", keywords: ["toc", "outline", "headings", "contents"] },
    { id: "date", label: "Date", icon: "calendar", group: "Inline", keywords: ["today", "now", "time", "day"] },
    { id: "emoji", label: "Emoji", icon: "face.smiling", group: "Inline", keywords: ["emoticon", "smiley", "symbol"] }
  ];

  const TURN_INTO = [
    { id: "paragraph", label: "Text", icon: "textformat" },
    { id: "heading1", label: "Heading 1", tag: "H1" },
    { id: "heading2", label: "Heading 2", tag: "H2" },
    { id: "heading3", label: "Heading 3", tag: "H3" },
    { id: "bullet", label: "Bulleted list", icon: "list.bullet" },
    { id: "numbered", label: "Numbered list", icon: "list.number" },
    { id: "todo", label: "To-do list", icon: "checklist" },
    { id: "toggle", label: "Toggle list", icon: "arrowtriangle.right" },
    { id: "code", label: "Code", icon: "chevron.left.forwardslash.chevron.right" },
    { id: "quote", label: "Quote", icon: "text.quote" },
    { id: "callout", label: "Callout", icon: "text.bubble" }
  ];

  const CALLOUT_KINDS = [
    { id: "note", label: "Note", icon: "info.circle" },
    { id: "tip", label: "Tip", icon: "lightbulb" },
    { id: "important", label: "Important", icon: "exclamationmark.bubble" },
    { id: "warning", label: "Warning", icon: "exclamationmark.triangle" },
    { id: "caution", label: "Caution", icon: "exclamationmark.octagon" }
  ];

  const LANGUAGES = [
    ["", "Plain text"], ["bash", "Bash"], ["c", "C"], ["cpp", "C++"], ["csharp", "C#"], ["css", "CSS"],
    ["diff", "Diff"], ["go", "Go"], ["html", "HTML"], ["java", "Java"], ["javascript", "JavaScript"],
    ["json", "JSON"], ["kotlin", "Kotlin"], ["markdown", "Markdown"], ["objectivec", "Objective-C"],
    ["php", "PHP"], ["python", "Python"], ["ruby", "Ruby"], ["rust", "Rust"], ["shell", "Shell"],
    ["sql", "SQL"], ["swift", "Swift"], ["toml", "TOML"], ["typescript", "TypeScript"], ["xml", "XML"], ["yaml", "YAML"]
  ];

  const BLOCK_NAMES = {
    paragraph: "Text", heading1: "Heading 1", heading2: "Heading 2", heading3: "Heading 3",
    heading4: "Heading 4", heading5: "Heading 5", heading6: "Heading 6", bullet: "Bulleted list",
    numbered: "Numbered list", todo: "To-do list", toggle: "Toggle list", quote: "Quote",
    callout: "Callout", code: "Code", table: "Table"
  };

  const SLASH_ROLES = new Set(["paragraph", "heading", "item"]);

  // Block actions shared by the menus, the handles and the keyboard ------------

  /// Turns the block at `selection` into `id`, the way Notion's Turn Into does: a quote or callout
  /// turned into another kind gives up its container, a toggle its markup.
  function turnInto(id, selection) {
    if (!selection) return false;
    const unit = unitAt(model, selection.head, "left");
    if (!unit) return false;
    const current = blockTypeOf(unit);
    if (current === id) return false;
    const group = newGroup();
    const meta = { group, coalesce: false };
    if (id === "toggle") return apply(planWrapToggle(model, selection), meta);
    if (id === "callout") return apply(planWrapCallout(model, selection), meta);
    if (current === "callout" && id === "quote") return apply(calloutToQuote(model, unit, calloutOf(unit)), meta);
    if (current === "toggle" && unit.role === "summary") {
      apply(unwrapToggle(model, unit), meta);
    } else if ((current === "quote" || current === "callout") && unit.container) {
      apply(planUnwrapQuote(model, unit, selection), meta);
    }
    if (id === "paragraph" && (current === "toggle" || current === "quote" || current === "callout")) return true;
    const next = readSelection() || selection;
    return apply(planBlockType(model, next, id), meta);
  }

  function blockTarget(target) {
    if (!target || !model) return null;
    if (target.kind === "item") return target.item && unitsOf(target.top).some((unit) => unit.role === "item" && unit.item === target.item) ? target : null;
    return model.blocks[target.index] === target.block ? target : null;
  }

  /// The <li> of `item`, a list item in the top-level block `top`.
  function itemElement(top, item) {
    const unit = unitsOf(top).find((candidate) => candidate.role === "item" && candidate.item === item);
    return unit && unit.el ? unit.el.closest("li") : null;
  }

  function targetElement(target) {
    if (!target) return null;
    return target.kind === "item" ? itemElement(target.top, target.item) : target.block.el || null;
  }

  function targetCaret(target) {
    const selection = targetSelection(model, target);
    return selection ? caretAt(selection.from) : null;
  }

  /// A short highlight on a block that just moved or was duplicated, so the eye finds it.
  function flashBlockAt(position) {
    const unit = unitAt(model, position, "right");
    if (!unit) return;
    const element = unit.role === "item" ? itemElement(unit.top, unit.item) : unit.top.el;
    if (!element) return;
    element.classList.remove("mk-block-moved");
    void element.offsetWidth;
    element.classList.add("mk-block-moved");
    window.setTimeout(() => element.classList.remove("mk-block-moved"), 950);
  }

  function moveTarget(target, direction) {
    const selection = readSelection();
    const keep = selection && handleTargetMatches(target, selection) ? selection : null;
    const op = planMoveByStep(model, target, direction, keep);
    if (!op) return false;
    if (!keep && op.movedStart !== undefined) op.select = (next) => caretAt(closestUnitPosition(next, op.movedStart));
    const applied = apply(op, { coalesce: false });
    if (applied) flashBlockAt(op.movedStart ?? (readSelection() || {}).head ?? op.from);
    return applied;
  }

  function handleTargetMatches(target, selection) {
    const current = handleTargetOf(model, unitAt(model, selection.head, "left"));
    if (!current || current.kind !== target.kind) return false;
    return target.kind === "item" ? current.item === target.item : current.index === target.index;
  }

  function duplicateTarget(target) {
    const op = planDuplicateBlock(model, target);
    if (!op) return false;
    const applied = apply(op, { coalesce: false });
    if (applied && op.movedStart !== undefined) flashBlockAt(op.movedStart);
    else if (applied) flashBlockAt((readSelection() || {}).head ?? op.from);
    return applied;
  }

  /// + beside a block: a new line below it (above with ⌥), with the slash menu open on it.
  function addBlockNear(target, above) {
    if (!target || !model) return;
    root.focus({ preventScroll: true });
    const group = newGroup();
    if (target.kind === "block") {
      const block = model.blocks[target.index];
      const units = unitsOf(block);
      if (block.type === "empty" && units[0]) {
        setSelection(unitStart(units[0]), unitStart(units[0]), { reveal: false });
      } else {
        apply({ ...(above ? insertEmptyBeforeBlock(model, target.index) : insertEmptyAfterBlock(model, block)), kind: "enter", label: "New Block" }, { group, coalesce: false });
      }
    } else {
      apply({ ...insertItemNear(model, target, above), kind: "enter", label: "New Block" }, { group, coalesce: false });
    }
    const selection = readSelection();
    if (!selection) return;
    const op = planInsertText(model, selection, "/", { typing: true });
    if (!op) return;
    // Esc on the menu this opens puts the line back exactly as + left it.
    const inverse = { from: op.from, to: op.from + op.insert.length, insert: model.source.slice(op.from, op.to), text: op.insert };
    if (!apply(op, { group: newGroup(), coalesce: false })) return;
    UI.expectSlashFromPlus(inverse);
    UI.afterTyping("/");
  }

  function runBlockMenuShortcut(name) {
    const selection = readSelection();
    if (!selection) return false;
    const target = handleTargetOf(model, unitAt(model, selection.head, "left"));
    if (!target) return false;
    if (name === "duplicate") return duplicateTarget(target);
    if (name === "up") return moveTarget(target, -1);
    if (name === "down") return moveTarget(target, 1);
    return false;
  }

  // Block handles ------------------------------------------------------------

  /// + and the six-dot grip in the left gutter of the block under the pointer. They follow the
  /// pointer, hide while typing, and never take focus.
  const Handles = (() => {
    let element = null;
    let addButton = null;
    let grip = null;
    let tooltip = null;
    let dropLine = null;
    let tooltipTimer = 0;
    let current = null;
    let pointer = null;
    let frame = 0;
    let suppressed = false;
    let drag = null;
    let pinned = false;

    function build() {
      if (element) return;
      ensureLayer();
      element = document.createElement("div");
      element.className = "mk-handles";
      addButton = document.createElement("button");
      addButton.type = "button";
      addButton.className = "mk-handle mk-handle-add";
      addButton.tabIndex = -1;
      addButton.setAttribute("aria-label", "Add a block below");
      const plus = document.createElement("span");
      plus.className = "mk-handle-glyph mk-handle-plus";
      addButton.appendChild(plus);
      grip = document.createElement("button");
      grip.type = "button";
      grip.className = "mk-handle mk-handle-drag";
      grip.tabIndex = -1;
      grip.setAttribute("aria-label", "Drag to move, or click for the block menu");
      const dots = document.createElement("span");
      dots.className = "mk-handle-glyph mk-grip";
      grip.appendChild(dots);
      element.append(addButton, grip);
      tooltip = document.createElement("div");
      tooltip.className = "mk-tooltip";
      tooltip.setAttribute("role", "tooltip");
      dropLine = document.createElement("div");
      dropLine.className = "mk-drop-line";
      layer.append(element, tooltip, dropLine);

      addButton.addEventListener("mousedown", (event) => event.preventDefault());
      addButton.addEventListener("click", (event) => {
        event.preventDefault();
        hideTooltip();
        const target = current && blockTarget(current.target);
        if (target) addBlockNear(target, event.altKey);
      });
      grip.addEventListener("mousedown", startPress);
      const tip = (button, html) => {
        button.addEventListener("mouseenter", () => scheduleTooltip(button, html));
        button.addEventListener("mouseleave", hideTooltip);
      };
      tip(addButton, "<strong>Click</strong> to add below<br><strong>⌥-click</strong> to add above");
      tip(grip, "<strong>Drag</strong> to move<br><strong>Click</strong> to open menu");
    }

    function scheduleTooltip(button, html) {
      window.clearTimeout(tooltipTimer);
      tooltipTimer = window.setTimeout(() => {
        if (drag || !element.classList.contains("mk-visible")) return;
        tooltip.innerHTML = html;
        const rect = button.getBoundingClientRect();
        tooltip.style.left = "0px";
        tooltip.style.top = "0px";
        const width = tooltip.offsetWidth;
        const z = zoom();
        const left = Math.max(8 * z, rect.left + rect.width / 2 - width / 2);
        tooltip.style.left = `${Math.round(left + window.scrollX)}px`;
        tooltip.style.top = `${Math.round(rect.bottom + 6 * z + window.scrollY)}px`;
        tooltip.classList.add("mk-visible");
      }, 450);
    }

    function hideTooltip() {
      window.clearTimeout(tooltipTimer);
      tooltip?.classList.remove("mk-visible");
    }

    function onPointerMove(event) {
      if (!active || drag) return;
      if (suppressed && pointer && Math.abs(event.clientX - pointer.x) + Math.abs(event.clientY - pointer.y) < 3) return;
      suppressed = false;
      pointer = { x: event.clientX, y: event.clientY };
      scheduleUpdate();
    }

    /// Follows the pointer and the scroll at most once a frame. A timer, unlike an animation frame,
    /// also runs while the window is in the background.
    function scheduleUpdate() {
      if (frame) return;
      frame = window.setTimeout(() => {
        frame = 0;
        update();
      }, 16);
    }

    function update() {
      build();
      if (!active || !model || !pointer || suppressed || drag) return;
      if (pinned) return;
      const bounds = root.getBoundingClientRect();
      if (pointer.x < bounds.left - 64 || pointer.x > bounds.right + 8 || pointer.y < bounds.top || pointer.y > bounds.bottom) {
        hideHandles();
        return;
      }
      const found = hitTest(pointer.y);
      if (!found) {
        hideHandles();
        return;
      }
      current = found;
      position(found);
      grip.style.display = found.empty ? "none" : "";
      element.classList.add("mk-visible");
    }

    /// The handle block at a height on the page: a top-level block, or the innermost list item
    /// whose own line holds `y`.
    function hitTest(y) {
      const blocks = model.blocks;
      if (blocks.length === 0) return null;
      let low = 0;
      let high = blocks.length - 1;
      while (low < high) {
        const middle = (low + high + 1) >> 1;
        const el = blocks[middle].el;
        if (el && el.getBoundingClientRect().top <= y) low = middle;
        else high = middle - 1;
      }
      let index = low;
      const rect = blocks[index].el && blocks[index].el.getBoundingClientRect();
      if (!rect) return null;
      // Between two blocks the nearer one wins.
      if (y > rect.bottom && index + 1 < blocks.length && blocks[index + 1].el) {
        const next = blocks[index + 1].el.getBoundingClientRect();
        if (next.top - y < y - rect.bottom) index += 1;
      }
      const block = blocks[index];
      if (!block.el) return null;
      if (block.type === "list") {
        let best = null;
        for (const li of block.el.querySelectorAll("li")) {
          const box = li.getBoundingClientRect();
          if (y < box.top - 2 || y > box.bottom + 2) continue;
          const nested = li.querySelector(":scope > ul, :scope > ol");
          const headBottom = nested ? nested.getBoundingClientRect().top : box.bottom;
          if (y <= headBottom + 2) best = li;
        }
        if (!best) best = block.el.querySelector("li");
        const text = best && best.querySelector(":scope > [data-mk-u]");
        const unit = unitForElement(text);
        const target = handleTargetOf(model, unit);
        if (!target) return null;
        return { target, el: best, line: text, item: true, empty: false };
      }
      const unit = unitsOf(block)[0];
      const target = { kind: "block", index, block };
      return { target, el: block.el, line: lineElementOf(block, unit), item: false, empty: block.type === "empty" };
    }

    function lineElementOf(block, unit) {
      if (block.type === "quote" && block.callout) return block.el.querySelector(".callout-title") || block.el;
      if (block.type === "toggle") return block.el.querySelector(".mk-toggle-summary") || block.el;
      if (block.type === "toc") return block.el.querySelector("a, p") || block.el;
      if (block.type === "table") return block.el.querySelector("th, td") || block.el;
      if (block.type === "hr") return null;
      return (unit && unit.el) || block.el;
    }

    function position(found) {
      const width = element.offsetWidth || 42;
      const height = element.offsetHeight || 24;
      let top;
      if (found.line) {
        const box = found.line.getBoundingClientRect();
        const style = window.getComputedStyle(found.line);
        const lineHeight = parseFloat(style.lineHeight) || box.height;
        top = box.top + (parseFloat(style.paddingTop) || 0) + (lineHeight - height) / 2;
      } else {
        const box = found.el.getBoundingClientRect();
        top = box.top + box.height / 2 - height / 2;
      }
      let right;
      const z = zoom();
      if (found.item) {
        const list = found.el.parentElement;
        const marker = list ? parseFloat(window.getComputedStyle(list).paddingLeft) || 24 : 24;
        right = found.el.getBoundingClientRect().left - marker - 2 * z;
      } else {
        right = found.el.getBoundingClientRect().left - 6 * z;
      }
      element.style.left = `${Math.round(right - width + window.scrollX)}px`;
      element.style.top = `${Math.round(top + window.scrollY)}px`;
    }

    function hideHandles() {
      current = null;
      hideTooltip();
      element?.classList.remove("mk-visible");
    }

    // Press, drag and drop ---------------------------------------------------

    function startPress(event) {
      if (event.button !== 0) return;
      event.preventDefault();
      hideTooltip();
      const found = current;
      const target = found && blockTarget(found.target);
      if (!target) return;
      const start = { x: event.clientX, y: event.clientY };
      let moved = false;
      const onMove = (moveEvent) => {
        if (!moved && Math.hypot(moveEvent.clientX - start.x, moveEvent.clientY - start.y) < 4) return;
        if (!moved) {
          moved = true;
          beginDrag(found, target, start);
        }
        updateDrag(moveEvent.clientX, moveEvent.clientY);
      };
      const onUp = () => {
        document.removeEventListener("mousemove", onMove, true);
        document.removeEventListener("mouseup", onUp, true);
        if (moved) finishDrag(true);
        else UI.openBlockMenu(target, grip.getBoundingClientRect(), true);
      };
      document.addEventListener("mousemove", onMove, true);
      document.addEventListener("mouseup", onUp, true);
    }

    function beginDrag(found, target, start) {
      const box = found.el.getBoundingClientRect();
      const ghost = document.createElement("div");
      ghost.className = "mk-drag-ghost";
      ghost.style.width = `${Math.round(box.width)}px`;
      let clone = found.el.cloneNode(true);
      if (found.item) {
        const list = found.el.parentElement.cloneNode(false);
        list.appendChild(clone);
        clone = list;
      }
      clone.querySelectorAll("[contenteditable], [data-mk-u]").forEach((node) => {
        node.removeAttribute("contenteditable");
        node.removeAttribute("data-mk-u");
      });
      ghost.appendChild(clone);
      document.body.appendChild(ghost);
      // Only a block taller than the ghost fades out at its cut edge.
      if (box.height > 160) ghost.classList.add("mk-drag-ghost-tall");
      found.el.classList.add("mk-block-dragging");
      document.documentElement.classList.add("mk-dragging");
      hideHandles();
      UI.closeTransient();
      drag = {
        target,
        el: found.el,
        ghost,
        source: model.source,
        offset: { x: start.x - box.left, y: start.y - box.top },
        gaps: dropGaps(target),
        gap: null,
        pointer: { ...start },
        scrollFrame: 0
      };
      document.addEventListener("keydown", onDragKey, true);
    }

    /// Where the block can land, in page coordinates: between top-level blocks for a block, between
    /// the items of its own list for an item.
    function dropGaps(target) {
      const gaps = [];
      const scrollY = window.scrollY;
      const content = root.getBoundingClientRect();
      const style = window.getComputedStyle(root);
      const contentLeft = content.left + (parseFloat(style.paddingLeft) || 0);
      const contentRight = content.right - (parseFloat(style.paddingRight) || 0);
      if (target.kind === "item") {
        const elements = target.list.items.map((item) => itemElement(target.top, item));
        if (elements.some((li) => !li)) return gaps;
        const rects = elements.map((li) => li.getBoundingClientRect());
        const list = elements[0].parentElement;
        const marker = parseFloat(window.getComputedStyle(list).paddingLeft) || 24;
        const left = rects[0].left - marker;
        for (let index = 0; index <= rects.length; index += 1) {
          const y = index === 0 ? rects[0].top - 2
            : index === rects.length ? rects[rects.length - 1].bottom + 2
            : (rects[index - 1].bottom + rects[index].top) / 2;
          gaps.push({ gap: index, y: y + scrollY, left, right: contentRight });
        }
        return gaps;
      }
      const blocks = model.blocks;
      const rects = blocks.map((block) => (block.el ? block.el.getBoundingClientRect() : null));
      for (let index = 0; index <= blocks.length; index += 1) {
        const before = rects[index - 1];
        const after = rects[index];
        let y;
        if (before && after) y = (before.bottom + after.top) / 2;
        else if (after) y = after.top - 3;
        else if (before) y = before.bottom + 3;
        else continue;
        gaps.push({ gap: index, y: y + scrollY, left: contentLeft, right: contentRight });
      }
      return gaps;
    }

    function isNoOp(target, gap) {
      const index = target.kind === "item" ? target.list.items.indexOf(target.item) : target.index;
      return gap === index || gap === index + 1;
    }

    function updateDrag(x, y) {
      if (!drag) return;
      drag.pointer = { x, y };
      drag.ghost.style.transform = `translate(${Math.round(x - drag.offset.x)}px, ${Math.round(y - drag.offset.y)}px)`;
      const pageY = y + window.scrollY;
      let best = null;
      for (const gap of drag.gaps) {
        if (!best || Math.abs(gap.y - pageY) < Math.abs(best.y - pageY)) best = gap;
      }
      drag.gap = best && !isNoOp(drag.target, best.gap) ? best : null;
      if (drag.gap) {
        dropLine.style.left = `${Math.round(drag.gap.left + window.scrollX)}px`;
        dropLine.style.width = `${Math.round(Math.max(24, drag.gap.right - drag.gap.left))}px`;
        dropLine.style.top = `${Math.round(drag.gap.y - 1.5)}px`;
        dropLine.classList.add("mk-visible");
      } else {
        dropLine.classList.remove("mk-visible");
      }
      autoScroll();
    }

    /// Near the top or bottom edge of the window the page scrolls under the dragged block.
    function autoScroll() {
      if (!drag || drag.scrollFrame) return;
      const edge = 56;
      const y = drag.pointer.y;
      const speed = y < edge ? -(edge - y) / 3 : y > window.innerHeight - edge ? (y - (window.innerHeight - edge)) / 3 : 0;
      if (!speed) return;
      drag.scrollFrame = window.requestAnimationFrame(() => {
        if (!drag) return;
        drag.scrollFrame = 0;
        window.scrollBy(0, Math.round(speed));
        updateDrag(drag.pointer.x, drag.pointer.y);
      });
    }

    function onDragKey(event) {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        finishDrag(false);
      }
    }

    function finishDrag(commit) {
      if (!drag) return;
      const state = drag;
      drag = null;
      if (state.scrollFrame) window.cancelAnimationFrame(state.scrollFrame);
      document.removeEventListener("keydown", onDragKey, true);
      state.ghost.remove();
      state.el.classList.remove("mk-block-dragging");
      document.documentElement.classList.remove("mk-dragging");
      dropLine.classList.remove("mk-visible");
      if (!commit || !state.gap || model.source !== state.source) return;
      root.focus({ preventScroll: true });
      const selection = readSelection();
      const keep = selection && handleTargetMatches(state.target, selection) ? selection : null;
      const op = planMoveBlock(model, state.target, state.gap.gap, keep);
      if (!op) return;
      if (!keep) op.select = (next) => caretAt(closestUnitPosition(next, op.movedStart ?? op.from));
      if (apply(op, { coalesce: false })) flashBlockAt(op.movedStart ?? (readSelection() || {}).head ?? op.from);
    }

    return {
      build,
      onPointerMove,
      update: scheduleUpdate,
      hide: hideHandles,
      suppress() {
        suppressed = true;
        hideHandles();
      },
      pin(on) {
        pinned = on;
        if (current) grip?.classList.toggle("mk-on", on);
        if (!on) grip?.classList.remove("mk-on");
      },
      get dragging() { return Boolean(drag); },
      cancelDrag() { finishDrag(false); }
    };
  })();

  const UI = (() => {
    let slashMenu = null;
    let slash = null;
    let slashFromPlus = false;
    let wikilinkMenu = null;
    // `[[` being typed: where it starts, the query the app last ranked, and that request's serial.
    let wikilink = null;
    let wikilinkSerial = 0;
    let blockMenu = null;
    let blockMenuTarget = null;
    let pickedElement = null;
    let turnIntoMenu = null;
    let turnContext = null;
    // The pointer on its way from Turn into to its submenu crosses other rows: the submenu waits
    // this long before it closes for them, and stays once the pointer reaches it.
    let submenuCloseTimer = 0;
    let calloutMenu = null;
    let calloutUnit = null;
    let languageMenu = null;
    let languageTarget = null;
    let tableMenu = null;
    // The cell the table menu was opened for: its actions apply to that table only.
    let tableMenuUnit = null;
    let formatBar = null;
    let formatButtons = {};
    let turnIntoButton = null;
    let linkCard = null;
    let linkCardAnchor = null;
    let linkEditor = null;
    let linkField = null;
    let linkGlyph = null;
    let linkEditing = null;
    let tableBar = null;
    let tableUnit = null;
    // The source offset of the table the bar was placed for.
    let tableStart = -1;
    let lastState = null;
    let formatBarSuppressed = false;
    let typingTimer = 0;

    function build() {
      if (slashMenu) return;
      ensureLayer();
      slashMenu = createMenu({
        label: "Insert block",
        emptyText: "No matching blocks",
        footer: [["↑↓", "Choose"], ["↩", "Insert"], ["Esc", "Close"]],
        onChoose: (item, pointer) => runSlash(item.id, pointer),
        onClose: (reason) => {
          if (reason === "choose") return;
          const info = slash;
          slash = null;
          // Opened from +: dismissing it takes the `/` back out, leaving the empty line.
          const inverse = info && info.fromPlus && info.fromPlus.text !== undefined ? info.fromPlus : null;
          if (inverse && (reason === "escape" || reason === "blur") && model && model.source.slice(inverse.from, inverse.to) === inverse.text) {
            apply({ from: inverse.from, to: inverse.to, insert: inverse.insert, select: caretAt(inverse.from), kind: "typing" }, { coalesce: false, selection: reason === "escape" });
          }
        }
      });
      wikilinkMenu = createMenu({
        label: "Link to page",
        emptyText: "No matching pages",
        ranked: true,
        footer: [["↑↓", "Choose"], ["↩", "Link"], ["Esc", "Close"]],
        onChoose: (item) => runWikilink(item.label),
        onClose: (reason) => {
          if (reason !== "choose") wikilink = null;
        }
      });
      blockMenu = createMenu({
        label: "Block",
        searchField: true,
        searchPlaceholder: "Search actions",
        emptyText: "No matching actions",
        searchItems: (items) => [
          ...items.filter((item) => !item.separator && !item.submenu),
          ...(items.some((item) => item.submenu) ? TURN_INTO.map((item) => ({ ...item, id: `turn:${item.id}`, label: `Turn into ${item.label}`, keywords: [item.label] })) : [])
        ],
        onSubmenu: (item, row, pointer) => openTurnIntoForBlock(row, pointer),
        onHoverRow: (item) => {
          if (item.submenu || !turnIntoMenu.isOpen) {
            cancelSubmenuClose();
            return;
          }
          if (submenuCloseTimer) return;
          submenuCloseTimer = window.setTimeout(() => {
            submenuCloseTimer = 0;
            turnIntoMenu.close("back");
          }, 120);
        },
        onQuery: () => {
          if (turnIntoMenu.isOpen) turnIntoMenu.close("back");
        },
        onFieldKey: (event) => {
          if (!turnIntoMenu.isOpen) return false;
          if (turnIntoMenu.handleNavigation(event)) return true;
          if (event.key === "ArrowLeft" || event.key === "Escape") {
            event.preventDefault();
            turnIntoMenu.close("back");
            return true;
          }
          // → is the submenu's already: it must not choose Turn into again under it.
          if (event.key === "ArrowRight") {
            event.preventDefault();
            return true;
          }
          return false;
        },
        keepsFocus: () => turnIntoMenu.isOpen,
        onChoose: (item) => runBlockAction(item.id),
        onClose: (reason) => {
          if (turnIntoMenu.isOpen && reason !== "choose") turnIntoMenu.close("parent");
          endBlockMenu(reason);
        }
      });
      turnIntoMenu = createMenu({
        label: "Turn into",
        narrow: true,
        onChoose: (item) => {
          const context = turnContext;
          turnContext = null;
          if (blockMenu.isOpen) blockMenu.close("choose");
          if (!context) return;
          root.focus({ preventScroll: true });
          if (context.kind === "block") {
            const target = blockTarget(context.target);
            if (!target) return;
            const caret = targetCaret(target);
            if (caret) setSelection(caret.anchor, caret.head, { reveal: false });
            turnInto(item.id, readSelection() || caret);
          } else {
            const selection = context.selection;
            setSelection(selection.anchor, selection.head, { reveal: false });
            turnInto(item.id, readSelection() || selection);
          }
        },
        onClose: (reason) => {
          cancelSubmenuClose();
          blockMenu?.closeSubmenuMark();
          if (reason === "back" || reason === "parent") return;
          if (reason !== "choose") turnContext = null;
        }
      });
      turnIntoMenu.element.addEventListener("mouseenter", cancelSubmenuClose);
      calloutMenu = createMenu({
        label: "Callout type",
        narrow: true,
        onChoose: (item) => {
          const unit = calloutUnit;
          calloutUnit = null;
          root.focus({ preventScroll: true });
          if (unit && model.units.has(unit.id)) {
            const selection = readSelection();
            const op = planCalloutKind(model, unit, item.id);
            if (op) {
              op.select = selection ? { anchor: selection.anchor, head: selection.head } : null;
              apply(op, { coalesce: false, selection: Boolean(selection) });
            }
          }
        },
        onClose: (reason) => {
          if (reason !== "choose") calloutUnit = null;
        }
      });
      languageMenu = createMenu({
        label: "Code language",
        searchField: true,
        searchPlaceholder: "Search languages",
        emptyText: "No matching languages",
        narrow: true,
        onChoose: (item) => setCodeLanguage(item.id),
        onClose: () => {
          root.focus({ preventScroll: true });
        }
      });
      tableMenu = createMenu({
        label: "Table",
        narrow: true,
        onChoose: (item) => {
          const unit = tableMenuUnit;
          tableMenuUnit = null;
          root.focus({ preventScroll: true });
          if (unit && model.units.has(unit.id)) apply(planTable(model, unit, item.id), { coalesce: false });
        },
        onClose: (reason) => {
          if (reason !== "choose") tableMenuUnit = null;
        }
      });
      buildFormatBar();
      buildLinkCard();
      buildLinkEditor();
      buildTableBar();
    }

    function cancelSubmenuClose() {
      window.clearTimeout(submenuCloseTimer);
      submenuCloseTimer = 0;
    }

    /// One menu at a time: opening `menu` closes every other one and the link field. (Turn Into
    /// opened from the block menu is its submenu and leaves it open.)
    function closeMenusFor(menu) {
      for (const other of [blockMenu, turnIntoMenu, calloutMenu, languageMenu, tableMenu, slashMenu]) {
        if (other !== menu) other.close("menu");
      }
      if (menu !== wikilinkMenu) endWikilink("menu");
      closeLinkEditor(false);
    }

    function button(name, label, shortcut, onPress) {
      const element = document.createElement("button");
      element.type = "button";
      element.className = "mk-tool";
      element.tabIndex = -1;
      element.title = shortcut ? `${label} (${shortcut})` : label;
      element.setAttribute("aria-label", label);
      element.appendChild(icon(name, "tool"));
      element.addEventListener("mousedown", (event) => event.preventDefault());
      element.addEventListener("click", (event) => {
        event.preventDefault();
        onPress(element);
      });
      return element;
    }

    function menuButton(text, onPress) {
      const element = document.createElement("button");
      element.type = "button";
      element.className = "mk-tool mk-tool-menu";
      element.tabIndex = -1;
      element.setAttribute("aria-haspopup", "listbox");
      const label = document.createElement("span");
      label.className = "mk-tool-label";
      label.textContent = text;
      const chevron = document.createElement("span");
      chevron.className = "mk-tool-chevron";
      chevron.appendChild(icon("chevron.down", "small"));
      element.append(label, chevron);
      element.addEventListener("mousedown", (event) => event.preventDefault());
      element.addEventListener("click", (event) => {
        event.preventDefault();
        onPress(element);
      });
      return element;
    }

    function divider() {
      const element = document.createElement("span");
      element.className = "mk-tool-divider";
      element.setAttribute("aria-hidden", "true");
      return element;
    }

    function buildFormatBar() {
      formatBar = document.createElement("div");
      formatBar.className = "mk-floating mk-toolbar mk-hidden";
      formatBar.setAttribute("role", "toolbar");
      formatBar.setAttribute("aria-label", "Format");
      turnIntoButton = menuButton("Text", (element) => {
        const selection = lastSelection;
        if (!selection) return;
        closeMenusFor(turnIntoMenu);
        turnContext = { kind: "selection", selection: { anchor: selection.anchor, head: selection.head } };
        const current = lastState ? lastState.block : "paragraph";
        turnIntoMenu.open(TURN_INTO.map((item) => ({ ...item, checked: item.id === current })), element.getBoundingClientRect(), { preference: "below", align: "start", animate: true, owner: element });
      });
      turnIntoButton.title = "Turn into";
      formatBar.appendChild(turnIntoButton);
      formatBar.appendChild(divider());
      formatButtons.strong = button("bold", "Bold", "⌘B", () => command("bold"));
      formatButtons.em = button("italic", "Italic", "⌘I", () => command("italic"));
      formatButtons.del = button("strikethrough", "Strikethrough", "⇧⌘X", () => command("strikethrough"));
      formatButtons.code = button("curlybraces", "Inline code", "⌘E", () => command("code"));
      formatBar.append(formatButtons.strong, formatButtons.em, formatButtons.del, formatButtons.code, divider());
      formatButtons.link = button("link", "Link", "⌘K", () => {
        const selection = readSelection() || lastSelection;
        if (selection) openLinkEditor(selection, "link", true);
      });
      formatBar.appendChild(formatButtons.link);
      layer.appendChild(formatBar);
    }

    function buildLinkCard() {
      linkCard = document.createElement("div");
      linkCard.className = "mk-floating mk-link-card mk-hidden";
      linkCard.setAttribute("role", "toolbar");
      linkCard.setAttribute("aria-label", "Link");
      const glyph = icon("link");
      glyph.classList.add("mk-link-glyph");
      const text = document.createElement("span");
      text.className = "mk-link-url";
      linkCard.append(glyph, text, divider());
      linkCard.appendChild(button("arrow.up.right.square", "Open link", "⌘-click", () => {
        if (!lastState || !lastState.link) return;
        const kind = lastState.link.kind === "wikilink" ? "wikilink" : "markdown";
        window.monknotPostLinkInteraction?.(kind, lastState.link.href);
      }));
      linkCard.appendChild(button("pencil", "Edit link", "⌘K", () => {
        const selection = lastSelection;
        if (selection) openLinkEditor(selection, "link", true);
      }));
      linkCard.appendChild(button("link.badge.minus", "Remove link", "", () => command("removeLink")));
      layer.appendChild(linkCard);
    }

    function buildLinkEditor() {
      linkEditor = document.createElement("form");
      linkEditor.className = "mk-floating mk-link-editor mk-hidden";
      linkEditor.setAttribute("role", "dialog");
      linkEditor.setAttribute("aria-label", "Edit link");
      linkGlyph = document.createElement("span");
      linkGlyph.className = "mk-link-glyph";
      linkField = document.createElement("input");
      linkField.type = "text";
      linkField.className = "mk-field";
      linkField.spellcheck = false;
      linkField.autocapitalize = "off";
      linkEditor.append(linkGlyph, linkField);
      // A form with one field submits on Return.
      linkEditor.addEventListener("submit", (event) => {
        event.preventDefault();
        commitLink();
      });
      linkField.addEventListener("keydown", (event) => {
        if (event.key === "Escape") {
          event.preventDefault();
          closeLinkEditor(true);
        }
      });
      linkField.addEventListener("blur", () => window.setTimeout(() => {
        if (!linkEditor.contains(document.activeElement)) closeLinkEditor(false);
      }, 0));
      layer.appendChild(linkEditor);
    }

    function buildTableBar() {
      tableBar = document.createElement("div");
      tableBar.className = "mk-floating mk-toolbar mk-table-bar mk-hidden";
      tableBar.setAttribute("role", "toolbar");
      tableBar.setAttribute("aria-label", "Table");
      const open = (items) => (element) => {
        closeMenusFor(tableMenu);
        tableMenuUnit = tableUnit;
        tableMenu.open(items(), element.getBoundingClientRect(), { preference: "below", align: "start", animate: true, owner: element });
      };
      tableBar.appendChild(menuButton("Row", open(() => [
        { id: "rowAbove", label: "Insert row above", icon: "arrow.up.to.line" },
        { id: "rowBelow", label: "Insert row below", icon: "arrow.down.to.line" },
        { separator: true },
        { id: "deleteRow", label: "Delete row", icon: "trash", destructive: true }
      ])));
      tableBar.appendChild(menuButton("Column", open(() => [
        { id: "columnLeft", label: "Insert column left", icon: "arrow.left.to.line" },
        { id: "columnRight", label: "Insert column right", icon: "arrow.right.to.line" },
        { separator: true },
        { id: "deleteColumn", label: "Delete column", icon: "trash", destructive: true }
      ])));
      tableBar.appendChild(divider());
      tableBar.appendChild(button("trash", "Delete table", "", () => {
        if (tableUnit) apply(planTable(model, tableUnit, "deleteTable"), { coalesce: false });
      }));
      layer.appendChild(tableBar);
    }

    // Slash menu ----------------------------------------------------------

    function expectSlashFromPlus(inverse) {
      slashFromPlus = inverse || true;
    }

    function afterTyping(text) {
      build();
      hideFormatBar();
      formatBarSuppressed = true;
      window.clearTimeout(typingTimer);
      typingTimer = window.setTimeout(() => {
        formatBarSuppressed = false;
      }, 400);
      const fromPlus = slashFromPlus;
      slashFromPlus = false;
      const selection = readSelection();
      if (!selection) return;
      if (text === "[" && !wikilink && !slash && startWikilink(selection)) return;
      if (text === "/" && !slash && !wikilink) {
        // Only at the start of a text block, as in Notion: never mid-sentence, in code or a cell.
        const unit = unitAt(model, selection.head, "left");
        if (!unit || unit.kind !== "inline" || !SLASH_ROLES.has(unit.role)) return;
        const v = rawToVisible(model, unit, selection.head, "left");
        if (visibleText(model, unit).slice(0, Math.max(0, v - 1)).trim() !== "") return;
        closeMenusFor(slashMenu);
        slash = { unit: unit.id, from: selection.head - 1, to: selection.head, fromPlus };
        slashMenu.open(SLASH_COMMANDS, caretRect() || ZERO_RECT, { preference: "below" });
        return;
      }
      updateSlash();
      updateWikilink();
    }

    function updateSlash() {
      if (!slash || !slashMenu.isOpen) return;
      const selection = readSelection();
      if (!selection || selection.from !== selection.to) {
        slashMenu.close("selection");
        return;
      }
      const unit = unitAt(model, selection.head, "left");
      const slashChar = model.source[slash.from];
      if (!unit || slashChar !== "/" || selection.head <= slash.from || unitStart(unit) > slash.from || unitEnd(unit) < selection.head) {
        slashMenu.close("moved");
        return;
      }
      slash.unit = unit.id;
      slash.to = selection.head;
      const query = model.source.slice(slash.from + 1, selection.head);
      if (/\s{2}|^\s/.test(query) || query.length > 32) {
        slashMenu.close("query");
        return;
      }
      slashMenu.setQuery(query);
      if (slashMenu.matchCount === 0 && query.length > 3) slashMenu.close("empty");
    }

    function runSlash(id, pointer) {
      if (!slash) return;
      const info = slash;
      slash = null;
      const unit = model.units.get(info.unit) || unitAt(model, info.from, "right");
      const end = Math.max(info.to, info.from + 1);
      const group = newGroup();
      const removeQuery = () => apply({ from: info.from, to: end, insert: "", select: caretAt(info.from), kind: "typing" }, { group, coalesce: false });
      switch (id) {
        case "image":
        case "video":
        case "audio":
        case "file": {
          removeQuery();
          const selection = readSelection();
          if (selection) post({ type: "requestFile", kind: id, selection: { anchor: selection.anchor, head: selection.head } });
          return;
        }
        case "date": {
          removeQuery();
          const date = new Date().toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });
          const selection = readSelection();
          if (selection) apply({ ...planInsertText(model, selection, date, {}), label: "Insert Date" }, { group, coalesce: false });
          return;
        }
        case "emoji":
          removeQuery();
          post({ type: "showEmoji" });
          return;
        case "bookmark":
        case "page": {
          removeQuery();
          const selection = readSelection();
          if (selection) openLinkEditor(selection, id, pointer);
          return;
        }
        case "pageLink": {
          apply({ from: info.from, to: end, insert: "[[", select: caretAt(info.from + 2), kind: "typing" }, { group, coalesce: false });
          const selection = readSelection();
          if (selection) startWikilink(selection);
          return;
        }
        case "toggle":
        case "callout": {
          removeQuery();
          const selection = readSelection();
          if (selection) apply(id === "toggle" ? planWrapToggle(model, selection) : planWrapCallout(model, selection), { group, coalesce: false });
          return;
        }
        default: {
          const op = planSlashCommand(model, unit, info.from, end, id);
          if (op) apply(op, { group, coalesce: false });
        }
      }
    }

    // Wikilinks -------------------------------------------------------------

    /// `[[` just typed in text: the app ranks the workspace's notes for what
    /// follows, as Source's wikilink completion does, and the menu lists them.
    function startWikilink(selection) {
      if (selection.from !== selection.to) return false;
      const head = selection.head;
      const source = model.source;
      if (source.slice(head - 2, head) !== "[[" || source[head - 3] === "[" || source[head - 3] === "\\") return false;
      const unit = unitAt(model, head, "left");
      if (!unit || unit.kind !== "inline" || unitStart(unit) > head - 2 || insideCode(head - 1)) return false;
      wikilink = { unit: unit.id, from: head - 2, query: null, serial: 0 };
      requestWikilinks("");
      return true;
    }

    function requestWikilinks(query) {
      if (!wikilink || wikilink.query === query) return;
      wikilink.query = query;
      wikilink.serial = ++wikilinkSerial;
      post({ type: "wikilinkQuery", query, serial: wikilink.serial });
    }

    /// The app's ranked titles for a query; an answer to an older query is dropped.
    function showWikilinks(payload) {
      if (!active || !wikilink || !payload || payload.serial !== wikilink.serial) return;
      build();
      const titles = Array.isArray(payload.titles) ? payload.titles.filter((title) => typeof title === "string" && title) : [];
      if (titles.length === 0 && wikilink.query.length > 3) {
        endWikilink("empty");
        return;
      }
      const items = titles.map((title) => ({ id: title, label: title, icon: "doc.text" }));
      // Like the slash menu, it stays where it opened while the query grows.
      if (wikilinkMenu.isOpen) wikilinkMenu.setItems(items);
      else {
        closeMenusFor(wikilinkMenu);
        wikilinkMenu.open(items, caretRect() || ZERO_RECT, { preference: "below" });
      }
    }

    function endWikilink(reason) {
      if (wikilinkMenu && wikilinkMenu.isOpen) wikilinkMenu.close(reason);
      else wikilink = null;
    }

    function updateWikilink() {
      if (!wikilink) return;
      const selection = readSelection();
      if (!selection || selection.from !== selection.to) {
        endWikilink("selection");
        return;
      }
      const from = wikilink.from;
      const unit = unitAt(model, selection.head, "left");
      if (!unit || model.source.slice(from, from + 2) !== "[[" || selection.head < from + 2 || unitStart(unit) > from || unitEnd(unit) < selection.head) {
        endWikilink("moved");
        return;
      }
      const query = model.source.slice(from + 2, selection.head);
      if (/[[\]|\r\n]/.test(query) || query.length > 64) {
        endWikilink("query");
        return;
      }
      wikilink.unit = unit.id;
      requestWikilinks(query);
    }

    /// Replaces `[[` and the query with `[[Title]]` in one patch, caret after it.
    function runWikilink(title) {
      const info = wikilink;
      wikilink = null;
      if (!info || !model || model.source.slice(info.from, info.from + 2) !== "[[") return;
      const selection = readSelection();
      let to = Math.max(selection ? selection.head : info.from + 2, info.from + 2);
      if (model.source.startsWith("]]", to)) to += 2;
      const unit = model.units.get(info.unit) || unitAt(model, info.from + 2, "left");
      const link = `[[${title}]]`;
      const insert = unit && unit.role === "cell" ? escapeCell(link) : link;
      apply({ from: info.from, to, insert, select: caretAt(info.from + insert.length), kind: "format", label: "Insert Link" }, { coalesce: false });
    }

    // Block menu ------------------------------------------------------------

    /// The grip's menu (or ⌘/): Turn Into, Duplicate, Copy, Move and Delete for one block, which
    /// stays tinted while the menu is open.
    function openBlockMenu(target, rect, animate) {
      build();
      if (!target) return;
      closeMenusFor(blockMenu);
      hideFormatBar();
      hide(linkCard);
      blockMenuTarget = target;
      pickedElement?.classList.remove("mk-block-picked");
      pickedElement = targetElement(target);
      pickedElement?.classList.add("mk-block-picked");
      Handles.pin(true);
      const block = target.kind === "block" ? target.block : null;
      const canTurn = !block || !["table", "hr", "toc", "definition", "empty"].includes(block.type);
      const first = target.kind === "item" ? target.list.items.indexOf(target.item) === 0 : target.index === 0;
      const last = target.kind === "item" ? target.list.items.indexOf(target.item) === target.list.items.length - 1 : target.index === model.blocks.length - 1;
      const items = [];
      if (canTurn) items.push({ id: "turnInto", label: "Turn into", icon: "arrow.triangle.2.circlepath", submenu: true });
      items.push({ id: "duplicate", label: "Duplicate", icon: "plus.square.on.square", hint: "⌘D" });
      items.push({ id: "copy", label: "Copy", icon: "doc.on.doc" });
      if (!first || !last) items.push({ separator: true });
      if (!first) items.push({ id: "moveUp", label: "Move up", icon: "arrow.up", hint: "⇧⌘↑" });
      if (!last) items.push({ id: "moveDown", label: "Move down", icon: "arrow.down", hint: "⇧⌘↓" });
      items.push({ separator: true });
      items.push({ id: "delete", label: "Delete", icon: "trash", destructive: true });
      // While the column reflows the menu stays beside the block, as it opened.
      blockMenu.open(items, rect, { preference: "below", align: "start", animate, follow: following(pickedElement, rect) });
    }

    /// Turn Into beside the block menu's row: grown from it when the pointer opened it, at once
    /// from → or ↩.
    function openTurnIntoForBlock(row, animate) {
      const target = blockTarget(blockMenuTarget);
      if (!target) return;
      cancelSubmenuClose();
      turnContext = { kind: "block", target };
      const caret = targetCaret(target);
      const unit = caret ? unitAt(model, caret.head, "right") : null;
      const current = blockTypeOf(unit);
      const items = TURN_INTO.map((item) => ({ ...item, checked: item.id === current }));
      turnIntoMenu.open(items, row.getBoundingClientRect(), { preference: "right", animate, follow: () => (row.isConnected ? row.getBoundingClientRect() : null) });
    }

    function endBlockMenu(reason) {
      pickedElement?.classList.remove("mk-block-picked");
      pickedElement = null;
      Handles.pin(false);
      if (reason !== "choose") {
        blockMenuTarget = null;
        if (reason === "escape") {
          root.focus({ preventScroll: true });
          const selection = lastSelection;
          if (selection) setSelection(selection.anchor, selection.head, { reveal: false });
        }
      }
    }

    function runBlockAction(id) {
      const target = blockTarget(blockMenuTarget);
      blockMenuTarget = null;
      if (!target) return;
      root.focus({ preventScroll: true });
      if (id.startsWith("turn:")) {
        const caret = targetCaret(target);
        if (caret) setSelection(caret.anchor, caret.head, { reveal: false });
        turnInto(id.slice(5), readSelection() || caret);
        return;
      }
      switch (id) {
        case "duplicate":
          duplicateTarget(target);
          return;
        case "copy": {
          post({ type: "copyText", text: blockMarkdown(model, target) });
          const caret = targetCaret(target);
          if (caret && !readSelection()) setSelection(caret.anchor, caret.head, { reveal: false });
          return;
        }
        case "moveUp":
          moveTarget(target, -1);
          return;
        case "moveDown":
          moveTarget(target, 1);
          return;
        case "delete":
          apply(planDeleteBlock(model, target), { coalesce: false });
          return;
        default:
      }
    }

    function openCalloutMenu(titleElement) {
      build();
      const callout = titleElement.closest(".callout");
      const unitElement = callout && callout.querySelector("[data-mk-u]");
      const unit = unitForElement(unitElement);
      if (!unit || !calloutOf(unit)) return;
      closeMenusFor(calloutMenu);
      calloutUnit = unit;
      const current = calloutOf(unit).callout.kind;
      calloutMenu.open(CALLOUT_KINDS.map((item) => ({ ...item, checked: item.id === current })), titleElement.getBoundingClientRect(), { preference: "below", align: "start", animate: true, owner: titleElement });
    }

    // Floating format bar --------------------------------------------------

    function selectionChanged(selection, unit, state, report) {
      build();
      lastState = report ? { ...report, link: state && state.link } : null;
      if (!selection) {
        hideFormatBar();
        hide(linkCard);
        updateTableBar(null);
        return;
      }
      updateSlash();
      updateWikilink();
      updateTableBar(unit);
      if (selection.from === selection.to) {
        hideFormatBar();
        updateLinkCard(selection, state);
      } else {
        hide(linkCard);
        if (formatBar.classList.contains("mk-visible")) refreshFormatBar(report);
        else if (!mouseSelecting && !hostSelected) showFormatBarIfNeeded(false);
      }
    }

    // A selection the app sets (a restored caret, a search match it reveals) is not a gesture: the
    // format bar waits until the person selects something themselves.
    let hostSelected = false;
    function hostWillSelect() {
      build();
      hostSelected = true;
      hideFormatBar();
    }
    document.addEventListener("keydown", () => {
      hostSelected = false;
    }, true);

    let mouseSelecting = false;
    document.addEventListener("mousedown", (event) => {
      hostSelected = false;
      if (layer && layer.contains(event.target)) return;
      mouseSelecting = true;
      hideFormatBar();
      if (blockMenu && blockMenu.isOpen) blockMenu.close("outside");
      if (calloutMenu && calloutMenu.isOpen) calloutMenu.close("outside");
      if (tableMenu && tableMenu.isOpen) tableMenu.close("outside");
    }, true);
    document.addEventListener("mouseup", () => {
      mouseSelecting = false;
    }, true);

    /// Shows the format bar over a selection; `animate` when the pointer made the selection.
    function showFormatBarIfNeeded(animate) {
      build();
      if (!active || formatBarSuppressed || slash || wikilink || blockMenu.isOpen || Handles.dragging) return;
      const selection = readSelection();
      if (!selection || selection.from === selection.to) return;
      const first = unitAt(model, selection.from, "right");
      const last = unitAt(model, selection.to, "left");
      if (!first || !last) return;
      if (first.kind === "code" || first.kind === "raw" || last.kind === "code") return;
      const rect = selectionRect();
      if (!rect) return;
      refreshFormatBar(lastState);
      place(formatBar, rect, "above", "center");
      show(formatBar, animate === true);
    }

    function refreshFormatBar(report) {
      if (!report) return;
      const singleUnit = (() => {
        const selection = lastSelection;
        if (!selection) return false;
        return unitAt(model, selection.from, "right") === unitAt(model, selection.to, "left");
      })();
      for (const [style, element] of Object.entries(formatButtons)) {
        const on = style === "link" ? Boolean(report.link) : Boolean(report[style]);
        element.classList.toggle("mk-on", on);
        element.setAttribute("aria-pressed", on ? "true" : "false");
        element.disabled = !(report.canFormat && singleUnit);
      }
      turnIntoButton.querySelector(".mk-tool-label").textContent = BLOCK_NAMES[report.block] || "Text";
      turnIntoButton.disabled = report.block === "table";
    }

    function hideFormatBar() {
      if (formatBar) hide(formatBar);
      if (turnIntoMenu && turnIntoMenu.isOpen && turnContext && turnContext.kind === "selection") turnIntoMenu.close("hide");
    }

    // Link card and editor ------------------------------------------------

    function updateLinkCard(selection, state) {
      if (!state || !state.link || linkEditor.classList.contains("mk-visible")) {
        hide(linkCard);
        return;
      }
      const unit = unitAt(model, selection.head, "left");
      const element = unit && unit.el;
      if (!element) return;
      const url = linkCard.querySelector(".mk-link-url");
      url.textContent = state.link.href || "";
      url.title = state.link.href || "";
      linkCardAnchor = linkAnchorElement() || element;
      place(linkCard, linkCardAnchor.getBoundingClientRect(), "below");
      show(linkCard);
    }

    function linkAnchorElement() {
      const dom = window.getSelection();
      const node = dom.anchorNode;
      const parent = node && (node.nodeType === TEXT ? node.parentElement : node);
      return parent ? parent.closest("a") : null;
    }

    const EDITOR_MODES = {
      link: { placeholder: "Paste or type a link", label: "Link address", glyph: "link", type: "url" },
      bookmark: { placeholder: "Paste a link to bookmark", label: "Bookmark address", glyph: "bookmark", type: "url" },
      page: { placeholder: "Name the new page", label: "Page name", glyph: "doc", type: "text" }
    };

    /// One field over the text: a link's address (⌘K), a web bookmark's address, or the name of a
    /// new page, which the app creates as a Markdown file next to this one and links here. `animate`
    /// when the pointer opened it.
    function openLinkEditor(selection, mode = "link", animate = false) {
      build();
      closeMenusFor(null);
      const settings = EDITOR_MODES[mode] || EDITOR_MODES.link;
      const state = inlineState(model, selection);
      linkEditing = { selection, state, mode, follow: null };
      linkField.value = mode === "link" && state.link && state.link.kind === "link" ? state.link.href : "";
      linkField.placeholder = settings.placeholder;
      linkField.type = settings.type;
      linkField.setAttribute("aria-label", settings.label);
      linkEditor.setAttribute("aria-label", settings.label);
      linkGlyph.textContent = "";
      linkGlyph.appendChild(icon(settings.glyph));
      hideFormatBar();
      hide(linkCard);
      const collapsed = selection.from === selection.to;
      const rect = collapsed ? caretRect() : selectionRect();
      // The field takes the focus, and the text's selection with it: the editor follows the unit.
      const unit = unitAt(model, selection.from, collapsed ? "left" : "right");
      linkEditing.follow = following(unit && unit.el, rect);
      place(linkEditor, rect || ZERO_RECT, "below");
      show(linkEditor, animate);
      noteMenuChange();
      window.setTimeout(() => {
        linkField.focus();
        linkField.select();
      }, 0);
    }

    function commitLink() {
      const editing = linkEditing;
      const value = linkField.value.trim();
      closeLinkEditor(true);
      if (!editing) return;
      if (editing.mode === "page") {
        if (!value) return;
        const selection = readSelection() || editing.selection;
        post({ type: "createPage", name: value, selection: { anchor: selection.anchor, head: selection.head } });
        return;
      }
      if (editing.mode === "bookmark") {
        if (!value) return;
        const url = /^[a-z][a-z0-9+.-]*:/i.test(value) ? value : `https://${value}`;
        const label = url.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "").replace(/\/$/, "");
        const selection = readSelection() || editing.selection;
        apply({ ...planInsertText(model, selection, `[${label.replace(/([[\]])/g, "\\$1")}](${url.replace(/\s/g, "%20")})`, {}), kind: "format", label: "Web Bookmark" }, { coalesce: false });
        return;
      }
      if (!value) {
        if (editing.state.link) command("removeLink");
        return;
      }
      command("setLink", value);
    }

    function closeLinkEditor(restoreFocus) {
      if (!linkEditor || !linkEditor.classList.contains("mk-visible")) return;
      hide(linkEditor);
      noteMenuChange();
      const editing = linkEditing;
      linkEditing = null;
      if (restoreFocus) {
        root.focus({ preventScroll: true });
        if (editing) setSelection(editing.selection.anchor, editing.selection.head, { reveal: false });
      }
    }

    // Tables ----------------------------------------------------------------

    /// The table bar follows the caret's table. It is measured only when the caret enters another
    /// table (and on scroll and resize), never on each keystroke in a cell; its menu closes with it.
    function updateTableBar(unit) {
      if (!unit || unit.role !== "cell" || !unit.top.el) {
        tableUnit = null;
        tableStart = -1;
        tableMenu.close("table");
        hide(tableBar);
        return;
      }
      tableUnit = unit;
      if (bStart(unit.top) === tableStart && tableBar.classList.contains("mk-visible")) return;
      tableStart = bStart(unit.top);
      tableMenu.close("table");
      placeTableBar();
      show(tableBar);
    }

    /// Above the table, below it where there is no room, and on screen while any of the table is.
    function placeTableBar() {
      const table = tableUnit && tableUnit.top.el;
      if (!table || !table.isConnected) return;
      const rect = table.getBoundingClientRect();
      place(tableBar, rect, "above", "start");
      const viewportHeight = window.innerHeight;
      if (rect.bottom <= 0 || rect.top >= viewportHeight) return;
      const limit = Math.max(0, viewportHeight - tableBar.offsetHeight - 8 * zoom());
      if (parseFloat(tableBar.style.top) - window.scrollY > limit) tableBar.style.top = `${Math.round(limit + window.scrollY)}px`;
    }

    // Code language ---------------------------------------------------------

    function openLanguageMenu(buttonElement) {
      build();
      const block = buttonElement.closest(".mk-code-block");
      const unitElement = block && block.querySelector("[data-mk-u]");
      const unit = unitForElement(unitElement);
      if (!unit) return;
      closeMenusFor(languageMenu);
      languageTarget = unit;
      const current = unit.block.fence.language;
      const items = LANGUAGES.map(([id, label]) => ({ id, label, checked: id === current, keywords: [id] }));
      if (current && !LANGUAGES.some(([id]) => id === current)) items.unshift({ id: current, label: current, checked: true });
      languageMenu.open(items, buttonElement.getBoundingClientRect(), { preference: "below", align: "start", animate: true, owner: buttonElement });
    }

    function setCodeLanguage(language) {
      const unit = languageTarget;
      languageTarget = null;
      if (!unit || !model.units.has(unit.id)) return;
      const open = unit.block.open;
      const text = open.text;
      const match = /^( {0,3})(```+|~~~+)\s*([\w.+-]*)\s*$/.exec(text);
      if (!match) return;
      const from = S(unit, open.start);
      const to = S(unit, open.end);
      const insert = match[1] + match[2] + language;
      const caret = unitStart(unit);
      apply({ from, to, insert, select: caretAt(caret + insert.length - text.length), kind: "format", label: "Code Language" }, { coalesce: false });
      root.focus({ preventScroll: true });
    }

    // Shared --------------------------------------------------------------

    function handleKeyDown(event) {
      build();
      for (const menu of [turnIntoMenu, calloutMenu, slashMenu, wikilinkMenu, tableMenu]) {
        if (!menu.isOpen) continue;
        if (menu.handleNavigation(event)) return true;
        if (event.key === "Escape" || (menu === turnIntoMenu && event.key === "ArrowLeft" && blockMenu.isOpen)) {
          event.preventDefault();
          menu.close(menu === turnIntoMenu && blockMenu.isOpen ? "back" : "escape");
          if (menu === turnIntoMenu && blockMenu.isOpen) blockMenu.focusField();
          return true;
        }
        if (menu === turnIntoMenu || menu === calloutMenu || menu === tableMenu) {
          // A pointer-opened menu takes the keys meant for it and lets typing close it.
          menu.close("typing");
        }
        break;
      }
      if (event.key === "Escape" && formatBar.classList.contains("mk-visible")) {
        event.preventDefault();
        hideFormatBar();
        return true;
      }
      return false;
    }

    function afterEdit() {
      if (formatBar && formatBar.classList.contains("mk-visible")) hideFormatBar();
    }

    function closeTransient() {
      if (!slashMenu) return;
      slashMenu.close("blur");
      endWikilink("blur");
      turnIntoMenu.close("blur");
      calloutMenu.close("blur");
      tableMenu.close("blur");
      if (blockMenu.isOpen && !blockMenu.element.contains(document.activeElement)) blockMenu.close("blur");
      hideFormatBar();
      hide(linkCard);
    }

    function closeAll() {
      if (!slashMenu) return;
      closeTransient();
      blockMenu.close("blur");
      languageMenu.close("blur");
      closeLinkEditor(false);
      updateTableBar(null);
    }

    /// Keeps every open surface beside its anchor as the page scrolls or the column reflows (a
    /// resize, a side pane moving), once a frame however often it is asked; a timer stands in where
    /// the page gets no frames.
    let repositionPending = false;
    function reposition() {
      if (!slashMenu || repositionPending) return;
      repositionPending = true;
      window.requestAnimationFrame(repositionNow);
      window.setTimeout(repositionNow, 50);
    }

    function repositionNow() {
      if (!repositionPending) return;
      repositionPending = false;
      const visible = (element) => element.classList.contains("mk-visible");
      if (visible(formatBar)) {
        const rect = selectionRect();
        if (rect) place(formatBar, rect, "above", "center");
      }
      if (visible(linkCard) && linkCardAnchor && linkCardAnchor.isConnected) place(linkCard, linkCardAnchor.getBoundingClientRect(), "below");
      if (visible(linkEditor) && linkEditing && linkEditing.follow) {
        const rect = linkEditing.follow();
        if (rect) place(linkEditor, rect, "below");
      }
      if (tableUnit && visible(tableBar)) placeTableBar();
      if (slashMenu.isOpen) slashMenu.reposition(caretRect());
      if (wikilinkMenu.isOpen) wikilinkMenu.reposition(caretRect());
      // Turn Into last: it sits beside the block menu's row, or below the format bar's selector.
      for (const menu of [blockMenu, calloutMenu, languageMenu, tableMenu, turnIntoMenu]) menu.reposition();
    }

    return {
      afterTyping,
      afterEdit,
      selectionChanged,
      hostWillSelect,
      showFormatBarIfNeeded,
      handleKeyDown,
      openLinkEditor,
      openLanguageMenu,
      openCalloutMenu,
      openBlockMenu,
      expectSlashFromPlus,
      closeTransient,
      closeAll,
      reposition,
      showWikilinks,
      get blockMenuOpen() { return Boolean(blockMenu && blockMenu.isOpen); },
      get anyMenuOpen() {
        if (!slashMenu) return false;
        return [slashMenu, wikilinkMenu, blockMenu, turnIntoMenu, calloutMenu, languageMenu, tableMenu].some((menu) => menu.isOpen)
          || linkEditor.classList.contains("mk-visible");
      }
    };
  })();

  // =====================================================================
  // Writing assistance
  //
  // The app checks the sentence before the caret with macOS spelling and grammar, and with Apple's
  // on-device model when the user allows it, exactly as Source does. It decides; the page only
  // shows what it sends (a reviewed correction in place of the words it changes, a completion after
  // the caret, the shimmer of a fix just applied) and reports the keys that act on them. What the
  // user takes arrives as an ordinary source patch, so nothing reaches the file that the page did
  // not show. Everything drawn here is a skipped, non-editable element or a wrapper around existing
  // text, which the text model never sees, and it comes out again before the next edit.
  // =====================================================================

  const Flow = (() => {
    const TAB_HOLD_MS = 350;
    const WRAP = "data-mk-flow-wrap";
    const MODIFIER_KEYS = new Set(["Meta", "Shift", "Alt", "Control", "CapsLock", "Fn"]);
    let spellcheck = true;
    // A reviewed correction: { serial, v, caret, sentence, variants, index, decorations, rendered }.
    let review = null;
    // A completion after the caret: { serial, v, at, text, element, rendered }.
    let ghost = null;
    // A fix just applied: { serial, v, caret, decorations, revertible }. ⌫ right after it takes it
    // back only while `revertible`, which is while its ⌫ undo hint shows.
    let settle = null;
    // ⌫ sent to the app to take a fix back: { serial, v, anchor, head }. If the app cannot, the page
    // deletes as ⌫ would have, provided nothing has changed since.
    let revertRequest = null;
    // A held Tab: { serial, armed, timer }; armed until it is released or held past 350 ms.
    let tab = null;
    // A keystroke that types what the completion shows, or a space after the reviewed sentence.
    let carry = null;
    // The tint on words a completion just inserted: { wrappers, timer }.
    let flashing = null;
    // Decorations to take out once a composition ends: the page changes nothing around the caret
    // while an input method or a dead key has marked text there.
    let deferred = [];
    let scrollFrame = 0;

    function report(action, fields = {}) {
      post({ type: "flow", action, ...fields });
    }

    function configure(message) {
      spellcheck = message.spellcheck !== false;
      if (root) root.setAttribute("spellcheck", spellcheck ? "true" : "false");
    }

    // Drawing in the text ------------------------------------------------

    /// The unit's text nodes with their visible offsets, counted as `visibleOffsetOf` counts them.
    function textNodesOf(unitElement) {
      const nodes = [];
      let position = 0;
      const visit = (node) => {
        if (node.nodeType === TEXT) {
          nodes.push({ node, start: position, end: position + node.data.length });
          position += node.data.length;
          return;
        }
        if (node.nodeType !== ELEMENT || isSkipped(node, unitElement)) return;
        if (node !== unitElement && isAtom(node)) {
          position += 1;
          return;
        }
        for (const child of Array.from(node.childNodes)) visit(child);
      };
      visit(unitElement);
      return nodes;
    }

    /// Wraps the unit's visible text [v0, v1) in spans of `className`, one per text node it crosses.
    function wrapVisible(unitElement, v0, v1, className) {
      const wrappers = [];
      if (!(v1 > v0)) return wrappers;
      for (const entry of textNodesOf(unitElement)) {
        const from = Math.max(v0, entry.start);
        const to = Math.min(v1, entry.end);
        if (from >= to) continue;
        let node = entry.node;
        if (from > entry.start) node = node.splitText(from - entry.start);
        if (to - from < node.data.length) node.splitText(to - from);
        const wrapper = document.createElement("span");
        wrapper.className = className;
        wrapper.setAttribute(WRAP, "");
        node.parentNode.insertBefore(wrapper, node);
        wrapper.appendChild(node);
        wrappers.push(wrapper);
      }
      return wrappers;
    }

    /// Puts `element` at a visible offset, after the text before it (inside bold text that ends
    /// there, as typing would continue it).
    function insertAtVisible(unitElement, v, element) {
      const point = domPointAt(unitElement, v, "left");
      if (!point || !point.node) return false;
      const { node, offset } = point;
      if (node.nodeType === TEXT) {
        if (offset <= 0) node.parentNode.insertBefore(element, node);
        else if (offset >= node.data.length) node.parentNode.insertBefore(element, node.nextSibling);
        else node.parentNode.insertBefore(element, node.splitText(offset));
      } else {
        node.insertBefore(element, node.childNodes[offset] || null);
      }
      return true;
    }

    function skipElement(className, text) {
      const element = document.createElement("span");
      element.className = className;
      element.setAttribute("contenteditable", "false");
      element.setAttribute("data-mk-skip", "");
      if (text) element.textContent = text;
      return element;
    }

    /// The shortcut hint after a suggestion: each key on a cap with its action beside it.
    function hintElement(groups, trailing) {
      const element = skipElement("mk-flow-hint", "");
      element.setAttribute("aria-hidden", "true");
      for (const [key, action] of groups) {
        const group = document.createElement("span");
        group.className = "mk-flow-hint-group";
        const cap = document.createElement("kbd");
        cap.textContent = key;
        group.append(cap, document.createTextNode(action));
        element.appendChild(group);
      }
      if (trailing) {
        const extra = document.createElement("span");
        extra.className = "mk-flow-hint-group";
        extra.textContent = trailing;
        element.appendChild(extra);
      }
      return element;
    }

    /// Takes drawn elements out again and unwraps wrapped text, keeping the caret where it was.
    /// During a composition it waits for the composition to end: unwrapping, merging text nodes or
    /// placing the caret there would commit, cancel or repeat the marked text.
    function undecorate(decorations) {
      const connected = (decorations || []).filter((element) => element && element.isConnected);
      if (!connected.length) return;
      if (composing) {
        deferred.push(...connected);
        return;
      }
      const keep = document.activeElement === root ? readSelection() : null;
      const parents = new Set();
      for (const element of connected) {
        const parent = element.parentNode;
        if (!parent) continue;
        if (element.hasAttribute(WRAP)) {
          while (element.firstChild) parent.insertBefore(element.firstChild, element);
        }
        element.remove();
        parents.add(parent);
      }
      for (const parent of parents) {
        if (parent.isConnected) parent.normalize();
      }
      if (keep) setSelection(keep.anchor, keep.head, { reveal: false });
    }

    /// Runs once what was just drawn has reached the screen: after the next frame, or after a
    /// tenth of a second where the page gets no frames (a window behind others).
    function afterPaint(callback) {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        callback();
      };
      window.requestAnimationFrame(() => window.requestAnimationFrame(finish));
      window.setTimeout(finish, 100);
    }

    function rectInView(rect) {
      if (!rect || (!rect.width && !rect.height)) return false;
      return rect.top >= -1 && rect.left >= -1
        && rect.bottom <= window.innerHeight + 1
        && rect.right <= document.documentElement.clientWidth + 1;
    }

    function caretInView() {
      const rect = caretRect();
      return Boolean(rect) && rect.bottom > 0 && rect.top < window.innerHeight;
    }

    function collapsedAt(position) {
      const selection = readSelection();
      return Boolean(selection && selection.from === selection.to && selection.head === position);
    }

    /// A suggestion shows only for the text and caret it was made for, with the text focused and
    /// no menu over it.
    function canPresent(v, caret) {
      return Boolean(active && model && !composing && v === version && document.activeElement === root
        && !UI.anyMenuOpen && !Handles.dragging && collapsedAt(caret));
    }

    // A reviewed correction ----------------------------------------------

    function showReview(message) {
      dropPresentation();
      clearSettle();
      const target = {
        serial: message.serial,
        v: message.v,
        caret: Number(message.caret),
        sentence: Array.isArray(message.sentence) ? message.sentence.map(Number) : [0, 0],
        variants: Array.isArray(message.variants) ? message.variants : [],
        index: Number(message.index) || 0,
        decorations: [],
        rendered: false
      };
      review = target;
      presented(target, drawReview(target));
    }

    /// After drawing a review or a completion: one drawn takes ⇥ once it has reached the screen; one
    /// that could not be drawn goes, and the app hears so.
    function presented(target, drawn) {
      if (!drawn) {
        if (review === target) review = null;
        if (ghost === target) ghost = null;
        report("unrendered", { serial: target.serial });
        return false;
      }
      afterPaint(() => {
        if (target === review || target === ghost) target.rendered = true;
      });
      return true;
    }

    /// Draws the corrected sentence over the original: each changed word hidden and its
    /// replacement shown in its place, highlighted, with the hint after the sentence.
    function drawReview(target) {
      if (!canPresent(target.v, target.caret) || !caretInView()) return false;
      const [from, to] = target.sentence;
      const unit = unitAt(model, from, "right");
      if (!unit || unit !== unitAt(model, to, "left") || unit.kind !== "inline" || !unit.el || !unit.el.isConnected) return false;
      const variant = target.variants[target.index];
      if (!variant || !Array.isArray(variant.changes) || !variant.changes.length) return false;
      const visible = visibleText(model, unit);
      // A visible range for source [start, end), or null where markup sits inside it.
      const span = (start, end) => {
        const v0 = rawToVisible(model, unit, start, "right");
        const v1 = end > start ? rawToVisible(model, unit, end, "left") : v0;
        return visible.slice(v0, v1) === model.source.slice(start, end) ? [v0, v1] : null;
      };
      const steps = [];
      for (const change of variant.changes) {
        const hidden = span(Number(change.from), Number(change.to));
        if (!hidden) return false;
        let mark = null;
        if (Array.isArray(change.mark)) {
          mark = span(Number(change.mark[0]), Number(change.mark[1]));
          if (!mark) return false;
        }
        steps.push({ hidden, insert: typeof change.insert === "string" ? change.insert : "", mark });
      }
      const decorations = [];
      const groups = target.variants.length > 1
        ? [["⇥", "apply"], ["→", "next"], ["Esc", "dismiss"]]
        : [["⇥", "apply"], ["Esc", "dismiss"]];
      const hint = hintElement(groups);
      if (insertAtVisible(unit.el, rawToVisible(model, unit, to, "left"), hint)) decorations.push(hint);
      for (const step of steps) {
        const wrappers = wrapVisible(unit.el, step.hidden[0], step.hidden[1], "mk-flow-hidden");
        decorations.push(...wrappers);
        if (step.insert) {
          const inserted = skipElement("mk-flow-insert", step.insert);
          if (wrappers.length) wrappers[0].before(inserted);
          else insertAtVisible(unit.el, step.hidden[0], inserted);
          decorations.push(inserted);
        }
        if (step.mark) decorations.push(...wrapVisible(unit.el, step.mark[0], step.mark[1], "mk-flow-mark"));
      }
      target.decorations = decorations;
      setSelection(target.caret, target.caret, { reveal: false });
      return true;
    }

    /// → shows the next of Apple's alternatives for the same word.
    function cycleReview() {
      const target = review;
      if (!target || target.variants.length < 2) return false;
      undecorate(target.decorations);
      target.decorations = [];
      target.index = (target.index + 1) % target.variants.length;
      if (!drawReview(target)) {
        review = null;
        report("cancel", { serial: target.serial, scope: "repair" });
      }
      return true;
    }

    function reviewAcceptable() {
      return Boolean(review && review.rendered && version === review.v && document.activeElement === root
        && review.decorations.some((element) => element.isConnected) && collapsedAt(review.caret));
    }

    // A completion after the caret -----------------------------------------

    function showGhost(message) {
      dropPresentation();
      clearSettle();
      const target = {
        serial: message.serial,
        v: message.v,
        at: Number(message.at),
        text: typeof message.text === "string" ? message.text : "",
        element: null,
        rendered: false
      };
      ghost = target;
      // A remainder the user already saw takes Tab at once, as in Source.
      if (presented(target, drawGhost(target)) && message.rendered === true) target.rendered = true;
    }

    function drawGhost(target) {
      if (!target.text || /[\r\n]/.test(target.text) || !canPresent(target.v, target.at)) return false;
      const unit = unitAt(model, target.at, "left");
      if (!unit || unit.kind !== "inline" || !unit.el || !unit.el.isConnected || insideCode(target.at)) return false;
      const element = skipElement("mk-flow-ghost", "");
      element.setAttribute("aria-hidden", "true");
      const text = document.createElement("span");
      text.className = "mk-flow-ghost-text";
      text.textContent = target.text;
      element.append(text, hintElement([["⇥", "word"]], "· hold for all"));
      if (!insertAtVisible(unit.el, rawToVisible(model, unit, target.at, "left"), element)) return false;
      if (!rectInView(text.getBoundingClientRect())) {
        undecorate([element]);
        return false;
      }
      target.element = element;
      setSelection(target.at, target.at, { reveal: false });
      return true;
    }

    function ghostAcceptable() {
      if (!ghost || !ghost.rendered || !ghost.element || !ghost.element.isConnected) return false;
      if (version !== ghost.v || document.activeElement !== root || !collapsedAt(ghost.at)) return false;
      const text = ghost.element.querySelector(".mk-flow-ghost-text");
      return Boolean(text) && rectInView(text.getBoundingClientRect());
    }

    function armTab(target) {
      tab = {
        serial: target.serial,
        armed: true,
        timer: window.setTimeout(() => {
          if (!tab || !tab.armed || tab.serial !== target.serial) return;
          tab.armed = false;
          if (ghost !== target) return;
          report("accept", { kind: "completion", serial: target.serial, text: target.text, nextWordOnly: false });
        }, TAB_HOLD_MS)
      };
    }

    // A fix just applied -----------------------------------------------------

    /// Highlights the corrected words (a shimmer that settles) and, where the caret is in a line of
    /// text, shows ⌫ undo beside it. ⌫ takes the fix back only while that hint shows, so on an empty
    /// line (after ↩) ⌫ keeps deleting. Returns whether ⌫ takes it back.
    function showSettle(serial, from, marks) {
      clearSettle();
      const selection = readSelection();
      if (!selection || selection.from !== selection.to) return false;
      const decorations = [];
      let revertible = false;
      const caretUnit = unitAt(model, selection.head, "left");
      if (caretUnit && caretUnit.el && caretUnit.kind === "inline") {
        const hint = hintElement([["⌫", "undo"]]);
        if (insertAtVisible(caretUnit.el, rawToVisible(model, caretUnit, selection.head, "left"), hint)) {
          decorations.push(hint);
          revertible = true;
        }
      }
      for (const mark of marks) {
        if (!Array.isArray(mark)) continue;
        const start = from + Number(mark[0]);
        const end = start + Number(mark[1]);
        if (!(start >= 0 && end > start && end <= model.source.length)) continue;
        const unit = unitAt(model, start, "right");
        if (!unit || unit !== unitAt(model, end, "left") || !unit.el) continue;
        const v0 = rawToVisible(model, unit, start, "right");
        const v1 = rawToVisible(model, unit, end, "left");
        if (visibleText(model, unit).slice(v0, v1) !== model.source.slice(start, end)) continue;
        decorations.push(...wrapVisible(unit.el, v0, v1, "mk-flow-settled"));
      }
      settle = { serial, v: version, caret: selection.head, decorations, revertible };
      setSelection(selection.head, selection.head, { reveal: false });
      return revertible;
    }

    /// The app could not take the fix back (it changed since, or its undo step is no longer the
    /// last): ⌫ deletes as it would have without the fix, unless the text or caret moved meanwhile.
    function revertRefused(serial) {
      const request = revertRequest;
      revertRequest = null;
      if (!request || request.serial !== serial || request.v !== version || composing || document.activeElement !== root) return;
      const selection = readSelection();
      if (!selection || selection.anchor !== request.anchor || selection.head !== request.head) return;
      deleteWith({ getTargetRanges: () => [] }, selection, "deleteContentBackward");
    }

    function settleMatches() {
      return Boolean(settle && settle.v === version && collapsedAt(settle.caret));
    }

    function clearSettle() {
      if (!settle) return;
      const current = settle;
      settle = null;
      undecorate(current.decorations);
    }

    /// The words a completion just inserted fade from a tint. A composition that starts meanwhile
    /// takes the tint off first (`compositionStarted`).
    function flash(start, length) {
      clearFlash();
      const end = start + length;
      if (!(length > 0 && start >= 0 && end <= model.source.length)) return;
      const unit = unitAt(model, start, "right");
      if (!unit || unit !== unitAt(model, end, "left") || !unit.el) return;
      const keep = readSelection();
      const v0 = rawToVisible(model, unit, start, "right");
      const v1 = rawToVisible(model, unit, end, "left");
      const wrappers = wrapVisible(unit.el, v0, v1, "mk-flow-flash");
      if (!wrappers.length) return;
      if (keep) setSelection(keep.anchor, keep.head, { reveal: false });
      const current = { wrappers, timer: 0 };
      current.timer = window.setTimeout(() => {
        if (flashing === current) clearFlash();
      }, 600);
      flashing = current;
    }

    function clearFlash() {
      if (!flashing) return;
      const current = flashing;
      flashing = null;
      window.clearTimeout(current.timer);
      undecorate(current.wrappers);
    }

    // What the app sends ------------------------------------------------------

    /// A fix or completion the app sends applies only to the text and selection it was made for:
    /// nothing typed or moved since.
    function applyFromApp(message) {
      const serial = message.serial;
      const expected = message.expectedSelection;
      const selection = readSelection();
      const unchanged = Number(message.base) === version && selection && expected
        && selection.from === Math.min(expected.anchor, expected.head)
        && selection.to === Math.max(expected.anchor, expected.head);
      if (composing || !unchanged
        || (message.requireVisible && (document.activeElement !== root || UI.anyMenuOpen || !caretInView()))) {
        report("declined", { serial });
        return;
      }
      const result = applyRemote({
        base: message.base,
        from: message.from,
        to: message.to,
        expected: message.expected,
        insert: message.insert,
        selection: message.selection,
        reason: "flow",
        label: message.label
      });
      if (!result || !result.applied) return;
      if (message.settle) {
        // The app says the fix aloud, with "Delete to undo" only when ⌫ will.
        const revertible = document.activeElement === root
          && showSettle(serial, result.from, Array.isArray(message.settle.marks) ? message.settle.marks : []);
        report("settled", { serial, revertible: Boolean(revertible) });
      } else if (Array.isArray(message.flash)) {
        flash(result.from + Number(message.flash[0]), Number(message.flash[1]));
      }
    }

    function clearFromApp(scope) {
      if (scope === "settle") {
        clearSettle();
        return;
      }
      if (scope === "completion") {
        dropGhost();
        return;
      }
      dropPresentation();
    }

    function receive(message) {
      if (!message) return;
      if (message.type === "configure") {
        configure(message);
        return;
      }
      if (!active || !model) return;
      switch (message.type) {
        case "review":
          showReview(message);
          return;
        case "ghost":
          showGhost(message);
          return;
        case "clear":
          clearFromApp(message.scope);
          return;
        case "apply":
          applyFromApp(message);
          return;
        case "revertRefused":
          revertRefused(message.serial);
          return;
        default:
      }
    }

    // What the user does ------------------------------------------------------

    /// Takes the review or completion off the page without telling the app.
    function dropPresentation() {
      if (tab) {
        window.clearTimeout(tab.timer);
        tab.armed = false;
      }
      if (review) {
        const current = review;
        review = null;
        undecorate(current.decorations);
      }
      dropGhost();
    }

    function dropGhost() {
      if (!ghost) return;
      const current = ghost;
      ghost = null;
      undecorate([current.element]);
    }

    function cancel(scope) {
      const current = review || ghost;
      if (!current) return;
      dropPresentation();
      report("cancel", { serial: current.serial, scope });
    }

    function isTypedCharacter(event) {
      return !event.metaKey && !event.ctrlKey && !event.altKey && Array.from(event.key).length === 1;
    }

    /// Keys that act on what is shown: ⇥ applies a review or takes the completion's next word
    /// (held, all of it), → shows the next alternative, Esc dismisses, ⌫ right after a fix takes it
    /// back. With nothing shown, every key keeps its own meaning.
    function handleKeyDown(event) {
      const key = event.key;
      const plain = !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
      if (key === "Tab" && tab) {
        // A held Tab and its repeats belong to the suggestion it took.
        event.preventDefault();
        return true;
      }
      if (settle) {
        if (key === "Backspace" && plain && settle.revertible && settleMatches()) {
          event.preventDefault();
          const serial = settle.serial;
          const caret = settle.caret;
          clearSettle();
          revertRequest = { serial, v: version, anchor: caret, head: caret };
          report("revert", { serial });
          return true;
        }
        if (!MODIFIER_KEYS.has(key)) clearSettle();
      }
      if (!review && !ghost) return false;
      if (key === "ArrowRight" && plain && review && review.variants.length > 1) {
        event.preventDefault();
        cycleReview();
        return true;
      }
      if (key === "Tab" && plain) {
        if (review) {
          if (reviewAcceptable()) {
            event.preventDefault();
            tab = { serial: review.serial, armed: false, timer: 0 };
            report("accept", { kind: "repair", serial: review.serial, variant: review.index });
            return true;
          }
          // Not drawn yet: Tab does what it would have done.
          cancel("repair");
          return false;
        }
        if (event.repeat) {
          event.preventDefault();
          return true;
        }
        if (ghostAcceptable()) {
          event.preventDefault();
          armTab(ghost);
          return true;
        }
        cancel("completion");
        return false;
      }
      if (key === "Escape" && plain) {
        event.preventDefault();
        const serial = (review || ghost).serial;
        dropPresentation();
        report("dismiss", { serial });
        return true;
      }
      if (MODIFIER_KEYS.has(key)) return false;
      // A space right after the reviewed sentence keeps it; typing what the completion shows
      // keeps the rest of it. Both are settled once the edit is made.
      if (key === " " && plain && review) return false;
      if (ghost && !review && isTypedCharacter(event) && ghost.text.startsWith(key)) return false;
      cancel("focus");
      return false;
    }

    function handleKeyUp(event) {
      if (event.key !== "Tab" || !tab) return false;
      event.preventDefault();
      const current = tab;
      tab = null;
      window.clearTimeout(current.timer);
      if (current.armed && ghost && ghost.serial === current.serial) {
        report("accept", { kind: "completion", serial: current.serial, text: ghost.text, nextWordOnly: true });
      }
      return true;
    }

    /// Called just before a typed insertion is applied.
    function prepareCarry(selection, text, op) {
      carry = null;
      if (!op || selection.from !== selection.to || op.from !== selection.head || op.to !== selection.head || op.insert !== text) return;
      if (ghost && ghost.v === version && ghost.at === selection.head
        && ghost.text.length > text.length && ghost.text.startsWith(text)) {
        carry = { kind: "ghost", serial: ghost.serial, at: selection.head, text, remainder: ghost.text.slice(text.length) };
      } else if (review && text === " " && review.v === version
        && review.caret === selection.head && review.sentence[1] === selection.head) {
        carry = { kind: "review", serial: review.serial, at: selection.head };
      }
    }

    /// After every edit: the page re-rendered the blocks it touched, so what was drawn there is
    /// gone. A carried completion or review is drawn again for the new text; anything else goes.
    function afterEdit(op) {
      const pending = carry;
      carry = null;
      revertRequest = null;
      clearSettle();
      if (pending && pending.kind === "ghost" && ghost && ghost.serial === pending.serial
        && op.from === pending.at && op.to === pending.at && op.insert === pending.text) {
        const target = ghost;
        undecorate([target.element]);
        target.element = null;
        target.at = pending.at + pending.text.length;
        target.v = version;
        target.text = pending.remainder;
        target.rendered = false;
        presented(target, drawGhost(target));
        return;
      }
      if (pending && pending.kind === "review" && review && review.serial === pending.serial
        && op.from === pending.at && op.to === pending.at && op.insert === " ") {
        const target = review;
        undecorate(target.decorations);
        target.decorations = [];
        target.v = version;
        target.caret = pending.at + 1;
        target.rendered = false;
        presented(target, drawReview(target));
        return;
      }
      dropPresentation();
    }

    /// A caret that moved away takes what was shown for the old one with it; the app hears of the
    /// move from the selection report.
    function selectionChanged(selection) {
      if (!selection) return;
      const collapsed = selection.from === selection.to;
      if (settle && (!collapsed || selection.head !== settle.caret || version !== settle.v)) clearSettle();
      if (review && (!collapsed || selection.head !== review.caret || version !== review.v)) dropPresentation();
      if (ghost && (!collapsed || selection.head !== ghost.at || version !== ghost.v)) dropPresentation();
    }

    function pointerDown() {
      clearSettle();
      cancel("focus");
    }

    /// Called as a composition starts, before its marked text is in: everything drawn around the
    /// caret comes out now, while that is still safe.
    function compositionStarted() {
      clearFlash();
      clearSettle();
      cancel("focus");
    }

    /// Called once a composition has ended and its text is in the model.
    function compositionEnded() {
      if (composing || !deferred.length) return;
      const pending = deferred;
      deferred = [];
      undecorate(pending);
    }

    function blur() {
      if (tab) {
        window.clearTimeout(tab.timer);
        tab = null;
      }
      clearSettle();
      dropPresentation();
    }

    /// A review whose sentence scrolls away, or a completion no longer wholly on screen, goes, as
    /// in Source.
    function onScroll() {
      if ((!review && !ghost) || scrollFrame) return;
      scrollFrame = window.setTimeout(() => {
        scrollFrame = 0;
        if (review && !caretInView()) {
          cancel("repair");
        } else if (ghost && ghost.element) {
          const text = ghost.element.querySelector(".mk-flow-ghost-text");
          if (!text || !rectInView(text.getBoundingClientRect())) cancel("completion");
        }
      }, 16);
    }

    /// A new width re-wraps what is shown; Tab waits until it has been drawn again.
    function onResize() {
      for (const target of [review, ghost]) {
        if (!target) continue;
        target.rendered = false;
        afterPaint(() => {
          if (target === review || target === ghost) target.rendered = true;
        });
      }
    }

    /// The page stops editing: its contents are replaced, so drop everything without drawing.
    function forget() {
      if (tab) window.clearTimeout(tab.timer);
      if (flashing) window.clearTimeout(flashing.timer);
      flashing = null;
      deferred = [];
      tab = null;
      review = null;
      ghost = null;
      settle = null;
      carry = null;
      revertRequest = null;
    }

    function state() {
      return {
        spellcheck,
        review: review ? { serial: review.serial, index: review.index, variants: review.variants.length, rendered: review.rendered } : null,
        ghost: ghost ? { serial: ghost.serial, at: ghost.at, text: ghost.text, rendered: ghost.rendered } : null,
        settle: settle ? { serial: settle.serial, caret: settle.caret, revertible: settle.revertible } : null
      };
    }

    return {
      receive,
      handleKeyDown,
      handleKeyUp,
      prepareCarry,
      afterEdit,
      selectionChanged,
      pointerDown,
      compositionStarted,
      compositionEnded,
      blur,
      onScroll,
      onResize,
      forget,
      state,
      get spellcheck() { return spellcheck; }
    };
  })();

  window.MonknotEditor = {
    activate,
    deactivate,
    isActive,
    focus,
    command,
    applyRemote,
    reset,
    insertMarkdown: insertMarkdownAt,
    wikilinkSuggestions: (payload) => UI.showWikilinks(payload),
    flow: (message) => Flow.receive(message),
    flowState: () => Flow.state(),
    setIcons,
    sourceLineElements,
    selection: currentSelectionForApp,
    setSelection: (anchor, head) => {
      if (!active || !model) return false;
      UI.hostWillSelect();
      root.focus({ preventScroll: true });
      setSelection(anchor, head ?? anchor);
      return true;
    },
    source: () => (model ? model.source : null),
    version: () => version
  };
})();
