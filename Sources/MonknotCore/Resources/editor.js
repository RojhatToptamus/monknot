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

  function renderBlocks(model, blocks) {
    const render = MD.newRender(model.doc, { editing: true, unitSequence: model.unitSequence });
    for (const block of blocks) {
      block.shift = 0;
      block.lineShift = 0;
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

  const bStart = (block) => block.start + block.shift;
  const bEnd = (block) => block.end + block.shift;
  const bLine = (block) => block.line + block.lineShift;
  const S = (unit, offset) => offset + unit.top.shift;

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
  /// can affect. Returns what changed so the page can replace just those blocks.
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

    model.doc.source = source;
    const reader = MD.streamReader(source, parseStart, parseLine, hasCR);
    const context = { definitions: true, top: true, editing: true, anchor: 0 };
    const parsed = MD.parseBlockList(reader, context, true, stop);
    let added = parsed.blocks;
    let replaceTo = resyncIndex >= 0 ? resyncIndex : blocks.length;
    if (parseStart === 0 && restart < 0 && resyncIndex < 0 && added.length === 0) {
      added = [];
    }

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

    const removed = blocks.slice(replaceFrom + keepFront, replaceTo - keepBack);
    const inserted = added.slice(keepFront, added.length - keepBack);
    const definitionsChanged = removed.some((block) => block.type === "definition")
      || inserted.some((block) => block.type === "definition");

    model.source = source;
    model.hasCR = hasCR;
    if (definitionsChanged) {
      const rebuilt = createModel(source);
      Object.assign(model, rebuilt);
      return { full: true };
    }

    for (const block of removed) {
      for (const unit of block.units || []) model.units.delete(unit.id);
    }
    carryToggleState(model, removed, inserted, from, to, delta);
    renderBlocks(model, inserted);
    const index = replaceFrom + keepFront;
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
    const collect = (block, shift) => {
      if (block.type === "toggle" && block.viewOpen !== undefined) {
        const start = block.start + shift;
        if (start < from) states.set(start, block.viewOpen);
        else if (start >= to) states.set(start + delta, block.viewOpen);
      }
      for (const child of block.children || []) if (child.type === "toggle" || child.type === "quote") collect(child, shift);
    };
    for (const block of removed) collect(block, block.shift);
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

  // ---------------------------------------------------------------------
  // Units and the visible text
  // ---------------------------------------------------------------------

  function regionMap(unit) {
    return MD.regionMap(unit.region);
  }

  function rawOf(unit, j) {
    const map = regionMap(unit);
    return map[Math.max(0, Math.min(j, map.length - 1))] + unit.top.shift;
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
    const target = raw - unit.top.shift;
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
    let before = null;
    let after = null;
    let inside = [];
    for (const unit of units) {
      const start = unitStart(unit);
      const end = unitEnd(unit);
      if (start <= raw && raw <= end) inside.push(unit);
      else if (end < raw) before = unit;
      else if (!after && start > raw) after = unit;
    }
    if (inside.length === 1) return inside[0];
    if (inside.length > 1) return side === "left" ? inside[0] : inside[inside.length - 1];
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
    const blank = prefix.replace(/[ \t]+$/, "");
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
    const blank = prefix.replace(/[ \t]+$/, "");
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

  function compose(source, parts, text = "", caretOffset = null) {
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
      select: caretAt(from + (caretOffset ?? text.length))
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
    const units = allUnits(model);
    if (units.length && from <= unitStart(units[0]) && to >= unitEnd(units[units.length - 1]) && to > from) {
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
    const blank = prefix.replace(/[ \t]+$/, "");
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
        const gap = blankLinesAfter(model.source, lineEnd, prefix);
        const blank = prefix.replace(/[ \t]+$/, "");
        const count = prefix ? (gap.count >= 1 ? 1 : 2) : gap.trailing ? (gap.hasTerminator ? 1 : 2) : (gap.count >= 1 ? 1 : 2);
        const insert = "---" + (eol + blank).repeat(count);
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
    const blank = prefix.replace(/[ \t]+$/, "");
    const gap = blankLinesAfter(source, at, prefix);
    let count;
    if (prefix) count = gap.count >= 1 ? 1 : 2;
    else if (gap.trailing) count = gap.hasTerminator ? 1 : 2;
    else count = gap.count >= 1 ? 1 : 2;
    const insert = (eol + blank).repeat(count);
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
    const blank = prefix.replace(/[ \t]+$/, "");
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
    const blank = prefix.replace(/[ \t]+$/, "");

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
    if (unit.role === "cell") return { kind: "move", select: null, cellMove: "down", unit };

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
        const end = S(unit, container.end);
        let firstBlank = lineStart;
        for (let previous = previousLineEnd(source, lineStart); previous >= 0;) {
          const start = lineStartOf(source, previous);
          if (!isBlankLineIn(source, start, prefix)) break;
          firstBlank = start;
          previous = previousLineEnd(source, start);
        }
        const cut = previousLineEnd(source, firstBlank);
        const gap = blankLinesAfter(source, end, "");
        const count = gap.trailing ? (gap.hasTerminator ? 1 : 2) : gap.count >= 1 ? 1 : 2;
        const insert = eol.repeat(count);
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
    const blank = prefix.replace(/[ \t]+$/, "");
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
    const blank = prefix.replace(/[ \t]+$/, "");
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
    const end = S(unit, toggle.end);
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
        const remove = Math.min(indent.length, indent.startsWith("\t") ? 1 : 2);
        return { from: lineStart, to: lineStart + remove, insert: "", select: caretAt(position - remove), kind: "enter", label: "Outdent" };
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

  function planLineBreak(model, selection) {
    const position = selection.head;
    const unit = unitAt(model, position, "left");
    if (!unit) return null;
    if (unit.kind === "code" || unit.kind === "raw") return planEnter(model, selection);
    if (unit.role === "paragraph") {
      const prefix = quotePrefixOfLine(model.source, position);
      const insert = "\\" + model.eol + prefix;
      return { from: position, to: position, insert, select: caretAt(position + insert.length), kind: "typing" };
    }
    return planEnter(model, selection);
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
      const lineStart = S(unit, block.start);
      const removePrefix = { s: lineStart, e: S(unit, block.prefixEnd), keep: "" };
      const lineEnd = S(unit, block.view.end);
      const closing = S(unit, block.contentEnd) < lineEnd ? { s: S(unit, block.contentEnd), e: lineEnd, keep: "" } : null;
      const op = compose(source, [removePrefix, closing]);
      op.select = caretAt(lineStart);
      op.kind = "format";
      op.label = "Paragraph";
      return op;
    }
    if (unit.role === "item") {
      const item = unit.item;
      // A nested item steps out a level first, as ⇧⇥ does: without its marker it would read as
      // more of its parent's text.
      if (item.indent >= 2) {
        const outdent = planIndent(model, { from: position, to: position, anchor: position, head: position }, -1);
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
      const op = compose(source, parts);
      op.select = caretAt(parts[0].s);
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
    if (next.top !== unit.top && isAtomBlock(nextTop)) {
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
    const lineStart = lineStartOf(source, S(unit, marker.start));
    const hasChildren = callout.inner.length > 1;
    if (!hasChildren) {
      const from = S(unit, marker.start);
      return { from, to: S(unit, marker.end), insert: "", select: (next) => caretAt(closestUnitPosition(next, from)), kind: "format", label: "Quote" };
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
    const lines = toggle.body.filter((view) => !MD.isBlank(view.text));
    let insert = title;
    if (lines.length) {
      const bodyStart = S(unit, lines[0].prefixStart ?? lines[0].start);
      const bodyEnd = S(unit, lines[lines.length - 1].end);
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

  function serializeItems(items) {
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
    // marker, so emphasis alternates between * and _.
    const markerFor = (style, stack, out) => {
      const starOpen = stack.some((entry) => entry.open === "*" || entry.open === "**");
      const underscoreOpen = stack.some((entry) => entry.open === "_" || entry.open === "__");
      const last = out[out.length - 1];
      const useUnderscore = starOpen || (last === "*" && !underscoreOpen);
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
        entry.open = markerFor(entry.style, stack, out);
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

    if (removing && selectedItems.some((item) => item.styles[`outer_${style}`])) {
      // The style comes from a construct around the region; rewrite all of it.
      const constructs = map.constructs.filter((construct) => (construct.type === style
        || (style === "link" && construct.type === "link")
        || (style === "strong" && construct.type === "strong"))
        && construct.s <= js && construct.e >= je);
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
    const insert = serializeItems(items);
    const from = rawOf(unit, js);
    const to = rawOf(unit, je);
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

  const BLOCK_TYPES = ["paragraph", "heading1", "heading2", "heading3", "heading4", "heading5", "heading6", "bullet", "numbered", "todo", "quote", "code"];

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

  /// The raw content of a text-like unit, without its block markers.
  function unitContent(model, unit) {
    const source = model.source;
    if (unit.kind === "empty") return "";
    if (unit.role === "heading") return source.slice(S(unit, unit.block.contentStart), S(unit, unit.block.contentEnd));
    if (unit.role === "item") {
      return unit.item.lines.map((view, index) => index === 0
        ? source.slice(S(unit, unit.item.contentStart), S(unit, view.end))
        : source.slice(S(unit, view.start), S(unit, view.end)).replace(/^\s+/, "")).join(" ");
    }
    if (unit.role === "paragraph") {
      return unit.block.lines.map((view) => source.slice(S(unit, view.start), S(unit, view.end))).join(model.eol);
    }
    return source.slice(unitStart(unit), unitEnd(unit));
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
    if (unit.role === "heading") return [S(unit, unit.block.start), S(unit, unit.block.view.end)];
    if (unit.role === "item") return [lineStartOf(source, S(unit, unit.item.view.start)), S(unit, unit.item.end)];
    if (unit.role === "paragraph") {
      const lines = unit.block.lines;
      return [lineStartOf(source, S(unit, lines[0].start)), S(unit, lines[lines.length - 1].end)];
    }
    return [lineStartOf(source, unitStart(unit)), lineEndOf(source, unitEnd(unit))];
  }

  function prefixForType(type, index, unit) {
    switch (type) {
      case "heading1": case "heading2": case "heading3": case "heading4": case "heading5": case "heading6":
        return "#".repeat(Number(type.slice(-1))) + " ";
      case "bullet": return "- ";
      case "numbered": return `${index + 1}. `;
      case "todo": return unit && unit.role === "item" && unit.item.task && unit.item.task.checked ? "- [x] " : "- [ ] ";
      default: return "";
    }
  }

  /// Turns the selected blocks into `type`. Converting blocks that already
  /// all have the type turns them back into paragraphs when `toggle` is set.
  function planBlockType(model, selection, type, options = {}) {
    const units = unitsBetween(model, selection.from, selection.to).filter((unit) => isTextLike(unit) || unit.kind === "code");
    if (units.length === 0) return null;
    let target = type;
    if (options.toggle && units.every((unit) => blockTypeOf(unit) === type)) target = "paragraph";
    if (units.length === 1 && units[0].kind === "code") {
      if (target === "code") return null;
      return codeToText(model, units[0], target);
    }
    const textUnits = units.filter(isTextLike).filter((unit) => unit.kind !== "raw");
    if (textUnits.length === 0) return null;
    if (target === "code") return textToCode(model, textUnits, selection);

    const source = model.source;
    const eol = model.eol;
    const listLike = target === "bullet" || target === "numbered" || target === "todo";
    const caret = describeSelection(model, selection, textUnits);
    const parts = [];
    let previousEnd = null;
    let replacement = "";
    let rangeStart = null;
    textUnits.forEach((unit, index) => {
      const [lineStart, lineEnd] = unitLineRange(model, unit);
      const prefix = target === "quote" ? "" : quotePrefixOfLine(source, lineStart);
      const blank = prefix.replace(/[ \t]+$/, "");
      const inQuote = Boolean(prefix);
      const content = unitContent(model, unit);
      let lineText;
      if (target === "quote") {
        const body = content.split(eol);
        const existing = quotePrefixOfLine(source, lineStart);
        lineText = body.map((line) => `${existing}> ${line}`.replace(/> $/, ">")).join(eol);
      } else if (unit.kind === "empty" && target === "paragraph") {
        lineText = prefix;
      } else {
        const marker = prefixForType(target, index, unit);
        const indent = unit.role === "item" && listLike ? source.slice(lineStartOf(source, S(unit, unit.item.view.start)) + prefix.length, S(unit, unit.item.markerStart)) : "";
        const body = target.startsWith("heading") ? content.split(eol).join(" ") : prefixFollowingLines(content, prefix, eol);
        lineText = prefix + indent + marker + body;
      }
      if (rangeStart === null) rangeStart = lineStart;
      if (previousEnd !== null) {
        const between = source.slice(previousEnd, lineStart);
        const bothList = listLike;
        const blockSeparator = eol + (inQuote ? blank : "") + eol;
        replacement += bothList ? eol : (/^\s*$/.test(between.replace(/>/g, "")) && countLineBreaks(between) >= 2 ? between : (target === "paragraph" || target === "quote" ? blockSeparator : between));
      }
      replacement += lineText;
      previousEnd = lineEnd;
    });
    // An item or heading made into text gets blank lines around it, so it does not join its neighbours.
    let gap = { before: "", after: "" };
    if (target === "paragraph" && rangeStart === lineStartOf(source, rangeStart)
      && textUnits.some((unit) => unit.role === "item" || unit.role === "heading")) {
      gap = paragraphSeparation(source, rangeStart, lineEndOf(source, previousEnd), quotePrefixOfLine(source, rangeStart), eol);
    }
    parts.push({ s: rangeStart, e: previousEnd, keep: gap.before + replacement + gap.after });
    const op = compose(source, parts);
    op.kind = "format";
    op.label = BLOCK_LABELS[target] || "Format";
    const restoreFrom = rangeStart + gap.before.length;
    op.select = (next) => restoreDescribedSelection(next, caret, restoreFrom);
    if (textUnits.length === 1 && textUnits[0].kind === "empty") {
      const unit = textUnits[0];
      const marker = target === "quote" ? "> " : prefixForType(target, 0, unit);
      if (!marker) return null;
      const materialized = materializeEmpty(model, unit, marker);
      materialized.kind = "format";
      materialized.label = BLOCK_LABELS[target];
      return materialized;
    }
    return op;
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

  function restoreDescribedSelection(model, described, rangeStart) {
    const units = [];
    for (const unit of allUnits(model)) {
      if (unitStart(unit) >= rangeStart || unitEnd(unit) >= rangeStart) units.push(unit);
    }
    const resolve = (point) => {
      if (!point) return null;
      const unit = units[point.index] || units[units.length - 1];
      if (!unit) return null;
      return visibleToRaw(model, unit, Math.min(point.v, visibleText(model, unit).length), "left");
    };
    const anchor = resolve(described.anchor);
    const head = resolve(described.head);
    if (anchor === null && head === null) return caretAt(rangeStart);
    return { anchor: anchor ?? head, head: head ?? anchor };
  }

  function textToCode(model, units, selection) {
    const source = model.source;
    const eol = model.eol;
    const [start] = unitLineRange(model, units[0]);
    const [, end] = unitLineRange(model, units[units.length - 1]);
    const prefix = quotePrefixOfLine(source, start);
    const contents = units.map((unit) => unitContent(model, unit));
    const body = contents.join(eol).split(eol).map((line, index) => (index === 0 ? "" : "") + line).join(eol + prefix);
    const insert = `${prefix}\`\`\`${eol}${prefix}${body}${eol}${prefix}\`\`\``;
    const caret = start + prefix.length + 3 + eol.length + prefix.length + body.length;
    return { from: start, to: end, insert, select: caretAt(caret), kind: "format", label: "Code Block" };
  }

  function codeToText(model, unit, target) {
    const block = unit.block;
    const source = model.source;
    const eol = model.eol;
    const start = S(unit, block.start);
    const end = S(unit, block.end);
    const prefix = quotePrefixOfLine(source, start);
    const lines = block.body.map((view) => source.slice(S(unit, view.start), S(unit, view.end)));
    const marker = prefixForType(target, 0, null);
    const text = lines.length ? lines.map((line, index) => (index === 0 ? marker : "") + line).join(eol + prefix) : marker;
    return { from: start, to: end, insert: text, select: caretAt(start + marker.length), kind: "format", label: BLOCK_LABELS[target] || "Paragraph" };
  }

  // Lists: indent and outdent -----------------------------------------

  function itemSubtreeEnd(list, item) {
    let end = item.end;
    const visit = (child) => {
      for (const nested of child.items) {
        end = Math.max(end, nested.end);
        nested.children.forEach(visit);
      }
    };
    item.children.forEach(visit);
    return end;
  }

  function planIndent(model, selection, direction) {
    const units = unitsBetween(model, selection.from, selection.to).filter((unit) => unit.role === "item");
    if (units.length === 0) return null;
    const source = model.source;
    const eol = model.eol;
    const first = units[0];
    const last = units[units.length - 1];
    const start = lineStartOf(source, S(first, first.item.view.start));
    const end = S(last, itemSubtreeEnd(last.list, last.item));
    if (direction > 0) {
      const siblings = first.list.items;
      if (siblings.indexOf(first.item) === 0 && first.item.indent === first.list.items[0].indent) return null;
    }
    const prefix = quotePrefixOfLine(source, start);
    const width = Math.max(2, first.item.contentStart - first.item.markerStart - (first.item.task ? 4 : 0));
    const lines = source.slice(start, end).split(/\r\n|\r|\n/);
    // How far the anchor and the head each move: by what changes on their line and the lines above.
    let anchorShift = 0;
    let headShift = 0;
    let lineOffset = start;
    const changed = lines.map((line) => {
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
      lineOffset += line.length + eol.length;
      return result;
    });
    // A numbered item indented under a sibling with no sub-list starts one, numbered from 1.
    let renumbered = 0;
    if (direction > 0 && first.list.ordered) {
      const siblings = first.list.items;
      const previous = siblings[siblings.indexOf(first.item) - 1];
      if (previous && previous.children.length === 0) {
        changed[0] = changed[0].replace(/^((?:[ \t>]*?)[ \t]*)(\d+)([.)])/, (match, lead, number, delimiter) => {
          renumbered = number.length - 1;
          return `${lead}1${delimiter}`;
        });
      }
    }
    const insert = changed.join(eol);
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

  function emptyRow(table) {
    return "|" + "  |".repeat(table.header.cells.length);
  }

  function planTable(model, unit, action) {
    if (!unit || unit.role !== "cell") return null;
    const table = unit.table;
    const source = model.source;
    const eol = model.eol;
    const shift = unit.top.shift;
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
          const cells = allUnits(next).filter((candidate) => candidate.role === "cell" && candidate.rowIndex === unit.rowIndex && bStart(candidate.top) === bStart(unit.top));
          const targetColumn = action === "columnLeft" ? column : column + 1;
          const cell = cells.find((candidate) => candidate.column === targetColumn);
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
    const cells = tableCells(model, unit.table);
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
    const blank = prefix.replace(/[ \t]+$/, "");
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

  function adjustCaretForPrefix(text, caretIn, prefix, eol) {
    if (!prefix) return caretIn;
    const lineBreaks = countLineBreaks(text.slice(0, caretIn));
    return caretIn + lineBreaks * prefix.length;
  }

  /// Replaces the `/query` typed in `unit` with the chosen block.
  function planSlashCommand(model, unit, slashFrom, slashTo, command) {
    const source = model.source;
    const eol = model.eol;
    if (!unit || unit.kind !== "inline") return null;
    const content = visibleText(model, unit);
    const slashV0 = rawToVisible(model, unit, slashFrom, "right");
    const slashV1 = rawToVisible(model, unit, slashTo, "left");
    const remaining = content.slice(0, slashV0) + content.slice(slashV1);
    const removeSlash = { s: slashFrom, e: slashTo, keep: "" };
    const lineStart = unitLineRange(model, unit)[0];
    const prefix = quotePrefixOfLine(source, lineStart);
    const isEmpty = remaining.trim() === "";
    const typeCommands = {
      text: "paragraph", h1: "heading1", h2: "heading2", h3: "heading3",
      bullet: "bullet", numbered: "numbered", todo: "todo", quote: "quote"
    };

    if (typeCommands[command]) {
      const target = typeCommands[command];
      if (unit.role === "cell") return compose(source, [removeSlash]);
      const [start, end] = unitLineRange(model, unit);
      const contentWithoutSlash = source.slice(unitStart(unit), slashFrom) + source.slice(slashTo, unitEnd(unit));
      const existingPrefix = source.slice(start, unitStart(unit));
      let marker;
      if (target === "quote") marker = "> ";
      else marker = prefixForType(target, 0, unit);
      const containerPrefix = target === "quote" ? existingPrefix.match(QUOTE_PREFIX)?.[0] || "" : prefix;
      const line = containerPrefix + marker + (unit.role === "heading" || unit.role === "item" || target !== "paragraph" ? contentWithoutSlash.replace(/^\s+/, "") : contentWithoutSlash);
      const caretOffset = slashFrom - unitStart(unit);
      const lineTailEnd = unit.role === "paragraph" ? end : unitEnd(unit);
      const restAfterUnit = source.slice(unitEnd(unit), lineTailEnd);
      const insert = line + restAfterUnit;
      return {
        from: start,
        to: lineTailEnd,
        insert,
        select: caretAt(start + containerPrefix.length + marker.length + Math.max(0, caretOffset - (contentWithoutSlash.length - contentWithoutSlash.replace(/^\s+/, "").length))),
        kind: "format",
        label: BLOCK_LABELS[target]
      };
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

    if (isEmpty && unit.role === "paragraph") {
      const [start, end] = unitLineRange(model, unit);
      const gapAfter = blankLinesAfter(source, end, prefix);
      const gapBefore = blankLinesBefore(source, start, prefix);
      const blank = prefix.replace(/[ \t]+$/, "");
      const body = prefixFollowingLines(block, prefix, eol);
      let trailing = "";
      if (atomic) {
        const count = gapAfter.trailing ? (gapAfter.hasTerminator ? 1 : 2) : gapAfter.count >= 1 ? 1 : 2;
        trailing = (eol + blank).repeat(count);
      } else if (!gapAfter.trailing && gapAfter.count === 0) {
        trailing = eol + blank;
      }
      const leading = !gapBefore.leading && gapBefore.count === 0 ? blank + eol : "";
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

  /// Text that puts `chunk` in the gap before block `index` (after the last block when `index` is
  /// the block count), with one blank line on each side.
  function topInsertion(model, gap, chunk) {
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
    const shift = target.top.shift;
    return [lineStartOf(model.source, target.item.view.start + shift), itemSubtreeEnd(target.list, target.item) + shift];
  }

  /// Rewrites a list with its items in `order` (indexes into its items). Markers keep their
  /// places, so an ordered list still counts from its first number.
  function rebuildList(model, top, list, order, selection, label, moved) {
    const source = model.source;
    const shift = top.shift;
    const items = list.items;
    const ranges = items.map((item) => [lineStartOf(source, item.view.start + shift), itemSubtreeEnd(list, item) + shift]);
    const gaps = ranges.slice(1).map((range, index) => source.slice(ranges[index][1], range[0]));
    const from = ranges[0][0];
    const to = ranges[ranges.length - 1][1];
    const starts = new Map();
    let insert = "";
    order.forEach((original, position) => {
      if (position > 0) insert += gaps[position - 1];
      let chunk = source.slice(ranges[original][0], ranges[original][1]);
      let markerDelta = 0;
      const markerOffset = items[original].markerStart + shift - ranges[original][0];
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
    const place = topInsertion(model, gap, chunk);
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

  /// ⌘⇧↑ / ⌘⇧↓: the block holding the caret swaps with its neighbour.
  function planMoveByStep(model, selection, direction) {
    const unit = unitAt(model, selection.head, "left");
    const target = handleTargetOf(model, unit);
    if (!target) return null;
    if (target.kind === "item") {
      const from = target.list.items.indexOf(target.item);
      return planMoveBlock(model, target, direction < 0 ? from - 1 : from + 2, selection);
    }
    return planMoveBlock(model, target, direction < 0 ? target.index - 1 : target.index + 2, selection);
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
    return withOrderCore(unitStart(units[0]), unitEnd(units[units.length - 1]));
  }

  function withOrderCore(anchor, head) {
    return { anchor, head, from: Math.min(anchor, head), to: Math.max(anchor, head) };
  }

  /// Lines `[start, end)` replaced by `text`, with a blank line kept on each side.
  function replaceIsolated(model, start, end, text, prefix) {
    const source = model.source;
    const eol = model.eol;
    const blank = prefix.replace(/[ \t]+$/, "");
    const before = start > 0 && !isBlankLineIn(source, lineStartOf(source, previousLineEnd(source, start)), prefix) ? eol + blank : "";
    const next = nextLineStart(source, end);
    const after = next > end && next < source.length && !isBlankLineIn(source, next, prefix) ? eol + blank : "";
    return { from: start, to: end, insert: before + text + after, offset: before.length };
  }

  /// Turns the text block holding the caret into a toggle titled with its text, opened.
  function planWrapToggle(model, selection) {
    const unit = unitAt(model, selection.head, "left");
    if (!unit || !(isTextLike(unit) || unit.role === "summary") || unit.kind === "raw" || unit.role === "cell") return null;
    if (unit.role === "summary") return null;
    const source = model.source;
    const eol = model.eol;
    const [start, end] = unitLineRange(model, unit);
    const prefix = quotePrefixOfLine(source, start);
    const title = unitContent(model, unit).split(eol).join(" ").replace(/^\s+/, "");
    const blank = prefix.replace(/[ \t]+$/, "");
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
    if (!unit || !isTextLike(unit) || unit.kind === "raw") return null;
    const source = model.source;
    const eol = model.eol;
    const marker = `[!${kind}]`;
    if (calloutOf(unit)) return null;
    if (unit.container && unit.container.type === "quote" && !unit.container.callout) {
      const quote = unit.container;
      const lineStart = lineStartOf(source, S(unit, quote.lines[0].start));
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
    const from = S(unit, quote.lines[0].start);
    const to = S(unit, quote.lines[quote.lines.length - 1].end);
    const first = quote.callout ? 1 : 0;
    const lines = [];
    for (let index = first; index < quote.inner.length; index += 1) {
      const view = quote.inner[index];
      let text = source.slice(S(unit, view.start), S(unit, view.end));
      if (lines.length > 0) {
        const lineStart = S(unit, quote.lines[index].start);
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
    const shift = target.top.shift;
    const contentLineStart = item.view.start + shift;
    const prefix = quotePrefixOfLine(source, contentLineStart);
    const indent = source.slice(contentLineStart, item.markerStart + shift);
    if (above) {
      const at = lineStartOf(source, contentLineStart);
      const insert = prefix + indent + item.marker + " " + (item.task ? "[ ] " : "") + eol;
      return { from: at, to: at, insert, select: caretAt(at + insert.length - eol.length) };
    }
    const at = itemSubtreeEnd(target.list, item) + shift;
    const insert = eol + prefix + indent + nextMarker(item);
    return { from: at, to: at, insert, select: caretAt(at + insert.length) };
  }

  /// Sets a callout's kind: `[!NOTE]` becomes `[!TIP]` and so on.
  function planCalloutKind(model, unit, kind) {
    const callout = unit && calloutOf(unit);
    if (!callout) return null;
    const marker = callout.callout.marker;
    const from = S(unit, marker.start);
    const to = S(unit, marker.end);
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
    const blocks = convertBlocks(body, 0);
    return blocks.join("\n\n").replace(/\n{3,}/g, "\n\n").trim();
  }

  const BLOCK_TAGS = new Set(["P", "DIV", "H1", "H2", "H3", "H4", "H5", "H6", "UL", "OL", "LI", "BLOCKQUOTE", "PRE", "TABLE", "HR", "SECTION", "ARTICLE", "HEADER", "FOOTER", "MAIN", "FIGURE"]);

  function convertBlocks(element, depth) {
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
        const converted = convertBlock(node, depth);
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

  function convertBlock(element, depth) {
    const tag = element.tagName;
    switch (tag) {
      case "H1": case "H2": case "H3": case "H4": case "H5": case "H6":
        return "#".repeat(Number(tag[1])) + " " + inlineOf(element).replace(/\s+/g, " ").trim();
      case "UL":
      case "OL":
        return convertList(element, depth);
      case "BLOCKQUOTE":
        return convertBlocks(element, depth).join("\n\n").split("\n").map((line) => (line ? `> ${line}` : ">")).join("\n");
      case "PRE": {
        const code = element.textContent.replace(/\n$/, "");
        const language = ((element.querySelector("code") || element).className.match(/language-([\w.+-]+)/) || [])[1] || "";
        return "```" + language + "\n" + code + "\n```";
      }
      case "TABLE":
        return convertTable(element);
      case "HR":
        return "---";
      default:
        return convertBlocks(element, depth).join("\n\n");
    }
  }

  function convertList(element, depth) {
    const ordered = element.tagName === "OL";
    const lines = [];
    let number = Number(element.getAttribute("start")) || 1;
    for (const item of Array.from(element.children)) {
      if (item.tagName !== "LI") continue;
      const checkbox = item.querySelector(":scope > input[type=checkbox]");
      let text = "";
      const nested = [];
      for (const child of Array.from(item.childNodes)) {
        if (child.nodeType === 1 && (child.tagName === "UL" || child.tagName === "OL")) nested.push(convertList(child, depth + 1));
        else if (child.nodeType === 1 && child.tagName === "INPUT") continue;
        else if (child.nodeType === 1 && BLOCK_TAGS.has(child.tagName)) text += " " + convertBlocks(child, depth + 1).join(" ");
        else text += convertInline(child);
      }
      const marker = ordered ? `${number}. ` : "- ";
      number += 1;
      const task = checkbox ? (checkbox.checked ? "[x] " : "[ ] ") : "";
      lines.push("  ".repeat(depth) + marker + task + text.replace(/\s+/g, " ").trim());
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
      case "CODE": case "KBD": case "SAMP":
        return "`" + node.textContent.replace(/`/g, "") + "`";
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
  let footnotesElement = null;
  let icons = {};
  let layer = null;
  const listeners = [];

  function post(message) {
    if (!documentID) return;
    window.webkit?.messageHandlers?.monknotEditor?.postMessage({ documentID, renderID, ...message });
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
    document.documentElement.classList.add("mk-editing");
    root.setAttribute("contenteditable", "true");
    root.setAttribute("spellcheck", "true");
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
    listen(root, "focus", () => scheduleSelectionReport());
    listen(root, "blur", onBlur);
    listen(document, "selectionchange", scheduleSelectionReport);
    listen(document, "keydown", onDocumentKeyDown, true);
    listen(document, "keyup", onDocumentKeyUp, true);
    listen(window, "resize", () => UI.reposition());
    listen(window, "scroll", () => {
      UI.reposition();
      Handles.update();
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
      setSelection(payload.selection.anchor, payload.selection.head, { reveal: false });
    }
    if (payload.focus) focus();
    post({ type: "ready", v: version });
  }

  function deactivate() {
    if (!active) return;
    Handles.cancelDrag();
    Handles.hide();
    UI.closeAll();
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
    root.innerHTML = model.blocks.map((block) => block.html).join("");
    const children = Array.from(root.children);
    model.blocks.forEach((block, index) => {
      block.el = children[index];
      bindUnits(block);
    });
    footnotesElement = null;
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

  function applyUpdate(update) {
    if (update.full) {
      fullRender();
      return;
    }
    const { index, removed, inserted } = update;
    for (const block of removed) block.el?.remove();
    if (inserted.length) {
      const template = document.createElement("template");
      template.innerHTML = inserted.map((block) => block.html).join("");
      const elements = Array.from(template.content.children);
      inserted.forEach((block, position) => {
        block.el = elements[position];
      });
      const next = model.blocks[index + inserted.length];
      root.insertBefore(template.content, next?.el || footnotesElement || null);
      inserted.forEach(bindUnits);
    }
    if (removed.some(changesContents) || inserted.some(changesContents)) refreshTablesOfContents();
    Handles.hide();
    refreshFootnotes();
    markEmptyDocument();
  }

  function changesContents(block) {
    return block.type === "heading" || block.type === "toc";
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
    if (footnotesElement && !footnotesElement.isConnected) footnotesElement = null;
    if (!doc.footnotes || doc.footnotes.size === 0) {
      footnotesElement?.remove();
      footnotesElement = null;
      return;
    }
    const numbers = new Map();
    root.querySelectorAll("sup.footnote-ref").forEach((element) => {
      const key = keyFromFootnoteElement(element);
      if (!numbers.has(key)) numbers.set(key, numbers.size + 1);
      const anchor = element.querySelector("a");
      if (anchor) anchor.textContent = String(numbers.get(key));
    });
    const html = MD.renderFootnotes(doc, { ...MD.newRender(doc, { editing: true }), refNumbers: numbers });
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

  function keyFromFootnoteElement(element) {
    const id = element.id || "";
    for (const key of model.doc.footnoteOrder) {
      if (`fnref-${MD.slug(key)}` === id) return key;
    }
    return id;
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
    // Outside any unit (a margin, a list marker, between blocks): the nearest unit.
    const elements = Array.from(root.querySelectorAll("[data-mk-u]"));
    const point = document.createRange();
    try {
      point.setStart(node, offset);
    } catch {
      return null;
    }
    let before = null;
    let after = null;
    for (const element of elements) {
      const elementRange = document.createRange();
      elementRange.selectNodeContents(element);
      if (point.compareBoundaryPoints(Range.START_TO_START, elementRange) >= 0) before = element;
      else if (!after) after = element;
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

  function withOrder(anchor, head) {
    return { anchor, head, from: Math.min(anchor, head), to: Math.max(anchor, head) };
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
      label: op.label || meta.label || ""
    });
    UI.afterEdit(op);
    scheduleSelectionReport();
    return true;
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
    apply(op);
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
      reconcile();
      const queued = pendingRemote;
      pendingRemote = [];
      queued.forEach((payload) => applyRemote(payload));
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
      reconcileUnit(changed, changed.el, null);
      return;
    }
    reconcileUnit(unit, element, selection);
  }

  function reconcileUnit(unit, element, selection) {
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
    if (UI.handleKeyDown(event)) return;
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

  /// Runs a formatting command on the current selection: from the docked
  /// toolbar, the floating toolbar, the slash menu or a shortcut.
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
    if (pendingMarks && lastSelection && (selection.head !== lastSelection.head || selection.from !== selection.to)) pendingMarks = null;
    lastSelection = selection;
    markCurrentUnit(selection);
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
      selectedMarkdown: selection.from === selection.to ? "" : model.source.slice(selection.from, Math.min(selection.to, selection.from + 4000))
    };
    UI.selectionChanged(selection, unit, state, report);
    const key = JSON.stringify(report);
    if (key === lastReportedSelection) return;
    lastReportedSelection = key;
    post({ type: "selection", ...report });
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
    currentUnitElement?.classList.remove("mk-current");
    currentUnitElement = null;
    window.setTimeout(() => {
      if (!layer || !layer.contains(document.activeElement)) UI.closeTransient();
    }, 0);
  }

  // Mouse ---------------------------------------------------------------

  function onMouseDown(event) {
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
      // A click below the last block puts the caret on a new line there.
      const last = model.blocks[model.blocks.length - 1];
      if (last && last.el) {
        const rect = last.el.getBoundingClientRect();
        if (event.clientY > rect.bottom && last.type !== "empty") {
          event.preventDefault();
          root.focus({ preventScroll: true });
          apply({ ...insertEmptyAfterBlock(model, last), kind: "enter" });
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
    const text = data.getData("application/x-monknot-markdown") || data.getData("text/plain");
    if (!text || (data.files && data.files.length)) return;
    const caret = document.caretRangeFromPoint ? document.caretRangeFromPoint(event.clientX, event.clientY) : null;
    if (!caret) return;
    const raw = domToRaw(caret.startContainer, caret.startOffset, "left");
    if (raw === null) return;
    apply(planInsertText(model, withOrder(raw, raw), text, { kind: "paste" }), { coalesce: false, label: "Drop" });
  }

  // Messages from the app ----------------------------------------------

  /// Applies a change the app asks for (undo, redo, a file inserted, the
  /// file changed on disk). `base` is the last version the app has seen;
  /// local edits it has not seen yet are transformed through first.
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
    for (const entry of unacknowledged) {
      if (!entry.local) continue;
      const entryDelta = entry.length - (entry.to - entry.from);
      if (entry.to <= from) {
        from += entryDelta;
        to += entryDelta;
        if (selection) selection = { anchor: selection.anchor + entryDelta, head: selection.head + entryDelta };
      } else if (entry.from >= to) {
        continue;
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
      remote: true,
      reason: payload.reason || "remote",
      kind: payload.reason || "remote",
      coalesce: false,
      group: ++groupSequence,
      selectionBefore: keepSelection || undefined,
      selection: payload.reason === "external" ? (document.activeElement === root) : true
    });
    return { applied };
  }

  function reset(payload) {
    if (!active) return;
    const keep = readSelection();
    model = createModel(typeof payload.text === "string" ? payload.text : "");
    fullRender();
    version += 1;
    unacknowledged = [];
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

  function setIcons(map) {
    icons = map && typeof map === "object" ? map : {};
    document.querySelectorAll(".mk-icon[data-mk-icon]").forEach(applyIcon);
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
    const gap = 6;
    const margin = 8;
    const viewportWidth = document.documentElement.clientWidth;
    const viewportHeight = window.innerHeight;
    let left;
    let top;
    let origin;
    if (preference === "right") {
      left = rect.right + 4;
      if (left + width > viewportWidth - margin) left = rect.left - width - 4;
      left = Math.max(margin, left);
      top = Math.max(margin, Math.min(rect.top - 6, viewportHeight - height - margin));
      origin = `${left < rect.left ? "100%" : "0"} ${Math.round(Math.max(0, Math.min(height, rect.top - top + rect.height / 2)))}px`;
    } else {
      const above = rect.top - height - gap;
      const below = rect.bottom + gap;
      if (preference === "above") top = above >= margin ? above : below;
      else top = below + height <= viewportHeight - margin || above < margin ? below : above;
      if (align === "start") left = rect.left;
      else if (align === "center") left = rect.left + (rect.width || 0) / 2 - width / 2;
      else left = rect.left - 10;
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
    const state = { items: [], visible: [], index: 0, open: false, query: "", preference: "below", align: "caret", owner: null };
    let hoverTimer = 0;

    const selectable = (item) => Boolean(item) && !item.separator;
    const rows = () => list.querySelectorAll(".mk-menu-row");

    const render = () => {
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
          if (item.submenu) {
            if (!row.classList.contains("mk-open-submenu")) hoverTimer = window.setTimeout(() => choose(index), 120);
          } else {
            options.onHoverRow?.();
          }
        });
        row.addEventListener("click", (event) => {
          event.preventDefault();
          choose(index);
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

    const rowRect = (index) => {
      const row = list.querySelector(`.mk-menu-row[data-index="${index}"]`);
      return row ? row.getBoundingClientRect() : element.getBoundingClientRect();
    };

    const choose = (index) => {
      const at = index ?? state.index;
      const item = state.visible[at];
      if (!selectable(item)) return;
      if (item.submenu) {
        rows().forEach((row) => row.classList.toggle("mk-open-submenu", Number(row.dataset.index) === at));
        options.onSubmenu?.(item, rowRect(at));
        return;
      }
      close("choose");
      options.onChoose(item);
    };

    const open = (items, rect, settings = {}) => {
      state.items = items;
      state.query = settings.query || "";
      const checked = items.findIndex((item) => item.checked);
      state.index = checked >= 0 ? checked : 0;
      state.preference = settings.preference || "below";
      state.align = settings.align || "caret";
      state.anchor = rect ? { rect, scrollX: window.scrollX, scrollY: window.scrollY } : null;
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
      hide(element);
      options.onClose?.(reason);
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
      reposition(rect) {
        if (!state.open || !rect) return;
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

  function targetElement(target) {
    if (!target) return null;
    if (target.kind === "item") {
      const unit = unitsOf(target.top).find((candidate) => candidate.role === "item" && candidate.item === target.item);
      return unit && unit.el ? unit.el.closest("li") : null;
    }
    return target.block.el || null;
  }

  function targetCaret(target) {
    const selection = targetSelection(model, target);
    return selection ? caretAt(selection.from) : null;
  }

  /// A short highlight on a block that just moved or was duplicated, so the eye finds it.
  function flashBlockAt(position) {
    const unit = unitAt(model, position, "right");
    if (!unit) return;
    const element = unit.role === "item" && unit.el ? unit.el.closest("li") : unit.top.el;
    if (!element) return;
    element.classList.remove("mk-block-moved");
    void element.offsetWidth;
    element.classList.add("mk-block-moved");
    window.setTimeout(() => element.classList.remove("mk-block-moved"), 950);
  }

  function moveTarget(target, direction) {
    const selection = readSelection();
    const gap = target.kind === "item"
      ? target.list.items.indexOf(target.item) + (direction < 0 ? -1 : 2)
      : target.index + (direction < 0 ? -1 : 2);
    const keep = selection && handleTargetMatches(target, selection) ? selection : null;
    const op = planMoveBlock(model, target, gap, keep);
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
      addButton.appendChild(icon("plus"));
      grip = document.createElement("button");
      grip.type = "button";
      grip.className = "mk-handle mk-handle-drag";
      grip.tabIndex = -1;
      grip.setAttribute("aria-label", "Drag to move, or click for the block menu");
      const dots = document.createElement("span");
      dots.className = "mk-grip";
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
        const left = Math.max(8, rect.left + rect.width / 2 - width / 2);
        tooltip.style.left = `${Math.round(left + window.scrollX)}px`;
        tooltip.style.top = `${Math.round(rect.bottom + 6 + window.scrollY)}px`;
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
      if (frame) return;
      // A timer, unlike an animation frame, also runs while the window is in the background.
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
      if (found.item) {
        const list = found.el.parentElement;
        const marker = list ? parseFloat(window.getComputedStyle(list).paddingLeft) || 24 : 24;
        right = found.el.getBoundingClientRect().left - marker - 2;
      } else {
        right = found.el.getBoundingClientRect().left - 6;
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
        const elements = target.list.items.map((item) => {
          const unit = unitsOf(target.top).find((candidate) => candidate.role === "item" && candidate.item === item);
          return unit && unit.el ? unit.el.closest("li") : null;
        });
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
      update,
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
    let calloutMenu = null;
    let calloutUnit = null;
    let languageMenu = null;
    let languageTarget = null;
    let tableMenu = null;
    let formatBar = null;
    let formatButtons = {};
    let turnIntoButton = null;
    let linkCard = null;
    let linkEditor = null;
    let linkField = null;
    let linkGlyph = null;
    let linkEditing = null;
    let tableBar = null;
    let tableUnit = null;
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
        onChoose: (item) => runSlash(item.id),
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
        onSubmenu: (item, rect) => openTurnIntoForBlock(rect),
        onHoverRow: () => {
          if (turnIntoMenu.isOpen) turnIntoMenu.close("back");
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
          blockMenu?.closeSubmenuMark();
          if (reason === "back" || reason === "parent") return;
          if (reason !== "choose") turnContext = null;
        }
      });
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
          root.focus({ preventScroll: true });
          if (tableUnit) apply(planTable(model, tableUnit, item.id), { coalesce: false });
        }
      });
      buildFormatBar();
      buildLinkCard();
      buildLinkEditor();
      buildTableBar();
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
      formatButtons.link = button("link", "Link", "⌘K", () => command("link"));
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
        if (selection) openLinkEditor(selection);
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
      const submit = document.createElement("button");
      submit.type = "submit";
      submit.className = "mk-push mk-primary";
      submit.textContent = "Apply";
      linkEditor.append(linkGlyph, linkField, submit);
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
      const open = (items) => (element) => tableMenu.open(items(), element.getBoundingClientRect(), { preference: "below", align: "start", animate: true, owner: element });
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

    function runSlash(id) {
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
          if (selection) openLinkEditor(selection, id);
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
      else wikilinkMenu.open(items, caretRect() || ZERO_RECT, { preference: "below" });
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
      blockMenu.open(items, rect, { preference: "below", align: "start", animate });
    }

    function openTurnIntoForBlock(rect) {
      const target = blockTarget(blockMenuTarget);
      if (!target) return;
      turnContext = { kind: "block", target };
      const caret = targetCaret(target);
      const unit = caret ? unitAt(model, caret.head, "right") : null;
      const current = blockTypeOf(unit);
      turnIntoMenu.open(TURN_INTO.map((item) => ({ ...item, checked: item.id === current })), rect, { preference: "right", animate: true });
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
        hide(tableBar);
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
        if (formatBar.classList.contains("mk-visible")) refreshFormatBar(report, unit);
        else if (!mouseSelecting) showFormatBarIfNeeded(false);
      }
    }

    let mouseSelecting = false;
    document.addEventListener("mousedown", (event) => {
      if (layer && layer.contains(event.target)) return;
      mouseSelecting = true;
      hideFormatBar();
      if (blockMenu && blockMenu.isOpen) blockMenu.close("outside");
      if (calloutMenu && calloutMenu.isOpen) calloutMenu.close("outside");
    }, true);
    document.addEventListener("mouseup", () => {
      mouseSelecting = false;
    }, true);

    function showFormatBarIfNeeded(immediate) {
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
      refreshFormatBar(lastState, first);
      place(formatBar, rect, "above", "center");
      show(formatBar, immediate === true);
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
      const anchor = linkAnchorElement() || element;
      place(linkCard, anchor.getBoundingClientRect(), "below");
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
    /// new page, which the app creates as a Markdown file next to this one and links here.
    function openLinkEditor(selection, mode = "link") {
      build();
      const settings = EDITOR_MODES[mode] || EDITOR_MODES.link;
      const state = inlineState(model, selection);
      linkEditing = { selection, state, mode };
      linkField.value = mode === "link" && state.link && state.link.kind === "link" ? state.link.href : "";
      linkField.placeholder = settings.placeholder;
      linkField.type = settings.type;
      linkField.setAttribute("aria-label", settings.label);
      linkEditor.setAttribute("aria-label", settings.label);
      linkGlyph.textContent = "";
      linkGlyph.appendChild(icon(settings.glyph));
      hideFormatBar();
      hide(linkCard);
      const rect = selection.from === selection.to ? caretRect() : selectionRect();
      place(linkEditor, rect || ZERO_RECT, "below");
      show(linkEditor, mode === "link" && selection.from !== selection.to);
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
      setSelection(editing.selection.anchor, editing.selection.head, { reveal: false });
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
      const editing = linkEditing;
      linkEditing = null;
      if (restoreFocus) {
        root.focus({ preventScroll: true });
        if (editing) setSelection(editing.selection.anchor, editing.selection.head, { reveal: false });
      }
    }

    // Tables ----------------------------------------------------------------

    function updateTableBar(unit) {
      if (!unit || unit.role !== "cell" || !unit.top.el) {
        tableUnit = null;
        hide(tableBar);
        return;
      }
      tableUnit = unit;
      const rect = unit.top.el.getBoundingClientRect();
      place(tableBar, { left: rect.left, right: rect.right, top: rect.top, bottom: rect.top, width: rect.width, height: 0 }, "above", "start");
      show(tableBar);
    }

    // Code language ---------------------------------------------------------

    function openLanguageMenu(buttonElement) {
      build();
      const block = buttonElement.closest(".mk-code-block");
      const unitElement = block && block.querySelector("[data-mk-u]");
      const unit = unitForElement(unitElement);
      if (!unit) return;
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
      hide(tableBar);
    }

    function reposition() {
      if (!slashMenu) return;
      if (slashMenu.isOpen) slashMenu.reposition(caretRect());
      if (wikilinkMenu.isOpen) wikilinkMenu.reposition(caretRect());
      if (formatBar.classList.contains("mk-visible")) {
        const rect = selectionRect();
        if (rect) place(formatBar, rect, "above", "center");
      }
      if (tableUnit && tableBar.classList.contains("mk-visible")) updateTableBar(tableUnit);
    }

    return {
      afterTyping,
      afterEdit,
      selectionChanged,
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
      get blockMenuOpen() { return Boolean(blockMenu && blockMenu.isOpen); }
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
    setIcons,
    sourceLineElements,
    selection: currentSelectionForApp,
    setSelection: (anchor, head) => {
      if (!active || !model) return false;
      root.focus({ preventScroll: true });
      setSelection(anchor, head ?? anchor);
      return true;
    },
    source: () => (model ? model.source : null),
    version: () => version
  };
})();
