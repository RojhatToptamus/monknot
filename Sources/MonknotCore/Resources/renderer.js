(() => {
  "use strict";

  let markdown = "";
  let searchQuery = "";
  let searchOptions = { isCaseSensitive: false, isWholeWord: false };
  let searchNavigationSerial = -1;
  let searchMatches = [];
  let searchCurrentIndex = 0;
  let hasRendered = false;
  let documentID = "";
  let renderID = 0;

  const target = document.getElementById("content");
  if (!target) return;

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

  function render(nextState) {
    const nextMarkdown = typeof nextState.markdown === "string" ? nextState.markdown : "";
    const nextTheme = nextState.theme === "dark" ? "dark" : "light";
    const nextDocumentID = typeof nextState.documentID === "string" ? nextState.documentID : "";
    const parsedRenderID = Number(nextState.renderID);
    const nextRenderID = Number.isSafeInteger(parsedRenderID) && parsedRenderID >= 0 ? parsedRenderID : 0;
    if (hasRendered
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
    target.innerHTML = renderMarkdown(markdown);
    hasRendered = true;
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

  function handleInteraction(event) {
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

  function tearDown() {
    target.removeEventListener("dblclick", handleSourceJump);
    target.removeEventListener("click", handleInteraction);
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

  function searchResult() {
    return {
      currentIndex: searchMatches.length > 0 ? searchCurrentIndex + 1 : 0,
      totalCount: searchMatches.length
    };
  }

  function removeSearchHighlights() {
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

    for (const node of nodes) {
      const value = node.nodeValue || "";
      const ranges = matchingSearchRanges(value, query, options);
      if (ranges.length === 0) continue;
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
          if (parent.closest("script, style, mark.monknot-search-match")) {
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

  function scrollToSourceLine(nextState = {}, options = {}) {
    const line = Number(nextState.line || 0);
    if (!Number.isFinite(line) || line < 1) return false;

    const sourceElements = Array.from(target.querySelectorAll("[data-source-line]"));
    if (sourceElements.length === 0) return false;

    let bestElement = null;
    let bestLine = 0;
    let nextElement = null;
    let nextLine = Number.MAX_SAFE_INTEGER;

    for (const element of sourceElements) {
      const sourceLine = Number(element.dataset.sourceLine || "0");
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
    const elements = Array.from(target.querySelectorAll("[data-source-line]"));
    let bestLine = 1;

    for (const element of elements) {
      const sourceLine = Number(element.dataset.sourceLine || "0");
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

  function renderMarkdown(source) {
    const footnotes = new Map();
    const footnoteOrder = [];
    const references = new Map();
    const lines = source.replace(/\r\n?/g, "\n").split("\n");
    const bodyLines = [];
    let definitionFence = null;

    for (const line of lines) {
      if (definitionFence) {
        if (isFenceCloser(line, definitionFence)) definitionFence = null;
        bodyLines.push(line);
        continue;
      }
      const fence = openingFence(line);
      if (fence) {
        definitionFence = fence;
        bodyLines.push(line);
        continue;
      }

      const footnote = line.match(/^\[\^([^\]]+)\]:\s*(.*)$/);
      if (footnote) {
        const key = footnote[1].trim();
        if (!footnotes.has(key)) footnoteOrder.push(key);
        footnotes.set(key, footnote[2]);
        // Keep a blank slot so every later data-source-line still refers to
        // the original Markdown line rather than the filtered body index.
        bodyLines.push("");
        continue;
      }

      const reference = line.match(/^ {0,3}\[([^\]\r\n]+)\]:[ \t]*(<[^>\r\n]+>|[^\s\r\n]+)(?:[ \t]+(?:"([^"\r\n]*)"|'([^'\r\n]*)'|\(([^)\r\n]*)\)))?[ \t]*$/);
      if (reference && !reference[1].startsWith("^")) {
        const key = normalizeReferenceLabel(reference[1]);
        let destination = reference[2];
        if (destination.startsWith("<") && destination.endsWith(">")) {
          destination = destination.slice(1, -1);
        }
        if (key && destination && !references.has(key)) {
          references.set(key, {
            destination,
            title: reference[3] ?? reference[4] ?? reference[5] ?? ""
          });
        }
        bodyLines.push("");
        continue;
      }

      bodyLines.push(line);
    }

    const refNumbers = new Map();
    const html = parseBlocks(bodyLines, footnotes, footnoteOrder, refNumbers, references);

    if (refNumbers.size === 0) return html;

    const notes = footnoteOrder
      .filter((key) => refNumbers.has(key))
      .sort((a, b) => refNumbers.get(a) - refNumbers.get(b))
      .map((key) => {
        const number = refNumbers.get(key);
        return `<li id="fn-${escapeAttr(slug(key))}">${inline(footnotes.get(key) || "", footnotes, footnoteOrder, refNumbers, references)} <a class="footnote-backref" href="#fnref-${escapeAttr(slug(key))}">↩</a></li>`;
      })
      .join("");

    return `${html}<section class="footnotes"><ol>${notes}</ol></section>`;
  }

  function parseBlocks(lines, footnotes, footnoteOrder, refNumbers, references, sourceLineBase = 0) {
    const blocks = [];
    let index = 0;

    while (index < lines.length) {
      const line = lines[index];

      if (isBlank(line)) {
        index += 1;
        continue;
      }

      const fence = openingFence(line);
      if (fence) {
        const startLine = index;
        const lang = fence.language;
        const codeLines = [];
        index += 1;
        while (index < lines.length && !isFenceCloser(lines[index], fence)) {
          codeLines.push(lines[index]);
          index += 1;
        }
        if (index < lines.length) index += 1;
        const code = markSource(`<pre><code class="language-${escapeAttr(lang)}">${highlightCode(codeLines.join("\n"), lang)}</code></pre>`, sourceLineBase + startLine);
        blocks.push(code);
        continue;
      }

      const heading = line.match(/^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$/);
      if (heading) {
        const startLine = index;
        const level = heading[1].length;
        const text = heading[2].trim();
        blocks.push(markSource(`<h${level} id="${escapeAttr(slug(stripInline(text)))}">${inline(text, footnotes, footnoteOrder, refNumbers, references)}</h${level}>`, sourceLineBase + startLine));
        index += 1;
        continue;
      }

      if (/^ {0,3}([-*_])(?:\s*\1){2,}\s*$/.test(line)) {
        // Thematic breaks (---, ***, ___) are ignored; content uses heading spacing only.
        index += 1;
        continue;
      }

      if (isTableStart(lines, index)) {
        const startLine = index;
        const parsed = parseTable(lines, index, footnotes, footnoteOrder, refNumbers, references);
        blocks.push(markSource(parsed.html, sourceLineBase + startLine));
        index = parsed.nextIndex;
        continue;
      }

      if (/^ {0,3}>\s?/.test(line)) {
        const startLine = index;
        const quoteLines = [];
        while (index < lines.length && (/^ {0,3}>\s?/.test(lines[index]) || isBlank(lines[index]))) {
          quoteLines.push(lines[index].replace(/^ {0,3}>\s?/, ""));
          index += 1;
        }
        blocks.push(markSource(
          `<blockquote>${parseBlocks(quoteLines, footnotes, footnoteOrder, refNumbers, references, sourceLineBase + startLine)}</blockquote>`,
          sourceLineBase + startLine
        ));
        continue;
      }

      if (isListLine(line)) {
        const startLine = index;
        const parsed = parseList(lines, index, footnotes, footnoteOrder, refNumbers, references, sourceLineBase);
        blocks.push(markSource(parsed.html, sourceLineBase + startLine));
        index = parsed.nextIndex;
        continue;
      }

      const startLine = index;
      const paragraph = [];
      while (index < lines.length && !isBlank(lines[index]) && !isBlockStart(lines, index)) {
        paragraph.push(lines[index]);
        index += 1;
      }
      blocks.push(markSource(`<p>${inline(paragraphText(paragraph), footnotes, footnoteOrder, refNumbers, references)}</p>`, sourceLineBase + startLine));
    }

    return blocks.join("\n");
  }

  function handleSourceJump(event) {
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

  function markSource(html, zeroBasedLine) {
    const sourceLine = Math.max(1, zeroBasedLine + 1);
    return html.replace(/^<([a-z0-9]+)(\s|>)/i, `<$1 data-source-line="${sourceLine}"$2`);
  }

  function isBlockStart(lines, index) {
    const line = lines[index] || "";
    return /^ {0,3}(```+|~~~+)/.test(line)
      || /^ {0,3}#{1,6}\s+/.test(line)
      || /^ {0,3}([-*_])(?:\s*\1){2,}\s*$/.test(line)
      || /^ {0,3}>\s?/.test(line)
      || isListLine(line)
      || isTableStart(lines, index);
  }

  function parseList(lines, start, footnotes, footnoteOrder, refNumbers, references, sourceLineBase) {
    const first = lines[start].match(/^(\s*)([-+*]|\d+[.)])\s+(\[[ xX]\]\s+)?(.*)$/);
    const ordered = /\d/.test(first[2]);
    const tag = ordered ? "ol" : "ul";
    const items = [];
    let hasTasks = false;
    let index = start;

    while (index < lines.length) {
      const match = lines[index].match(/^(\s*)([-+*]|\d+[.)])\s+(\[[ xX]\]\s+)?(.*)$/);
      if (!match || /\d/.test(match[2]) !== ordered) break;

      const task = match[3];
      let content = inline(match[4], footnotes, footnoteOrder, refNumbers, references);
      let className = "";
      if (task) {
        hasTasks = true;
        const isChecked = /\[[xX]\]/.test(task);
        const checked = isChecked ? " checked" : "";
        className = " class=\"task-list-item\"";
        content = `<input type="checkbox" data-monknot-task data-source-line="${sourceLineBase + index + 1}" data-task-checked="${isChecked}" aria-label="Toggle task"${checked}> <span>${content}</span>`;
      }

      items.push(markSource(`<li${className}>${content}</li>`, sourceLineBase + index));
      index += 1;
    }

    const listClass = hasTasks ? " class=\"contains-task-list\"" : "";
    return { html: `<${tag}${listClass}>${items.join("")}</${tag}>`, nextIndex: index };
  }

  function parseTable(lines, start, footnotes, footnoteOrder, refNumbers, references) {
    const headers = splitTableRow(lines[start]);
    const alignment = splitTableRow(lines[start + 1]).map((cell) => {
      const trimmed = cell.trim();
      if (/^:-+:$/.test(trimmed)) return "center";
      if (/^-+:$/.test(trimmed)) return "right";
      if (/^:-+$/.test(trimmed)) return "left";
      return "";
    });
    let index = start + 2;
    const rows = [];

    while (index < lines.length && /\|/.test(lines[index]) && !isBlank(lines[index])) {
      rows.push(splitTableRow(lines[index]));
      index += 1;
    }

    const alignAttr = (idx) => alignment[idx] ? ` align="${alignment[idx]}"` : "";
    const thead = `<thead><tr>${headers.map((cell, idx) => `<th${alignAttr(idx)}>${inline(cell.trim(), footnotes, footnoteOrder, refNumbers, references)}</th>`).join("")}</tr></thead>`;
    const tbody = `<tbody>${rows.map((row) => `<tr>${headers.map((_, idx) => `<td${alignAttr(idx)}>${inline((row[idx] || "").trim(), footnotes, footnoteOrder, refNumbers, references)}</td>`).join("")}</tr>`).join("")}</tbody>`;

    return { html: `<div class="table-wrapper"><table>${thead}${tbody}</table></div>`, nextIndex: index };
  }

  function isTableStart(lines, index) {
    if (index + 1 >= lines.length) return false;
    if (!/\|/.test(lines[index])) return false;
    return splitTableRow(lines[index + 1]).every((cell) => /^:?-{3,}:?$/.test(cell.trim()));
  }

  function openingFence(line) {
    const match = line.match(/^ {0,3}(```+|~~~+)\s*([\w.+-]*)\s*$/);
    if (!match) return null;
    return { marker: match[1][0], length: match[1].length, language: match[2] || "" };
  }

  function isFenceCloser(line, opening) {
    const match = line.match(/^ {0,3}(`+|~+)/);
    return Boolean(
      match
      && match[1][0] === opening.marker
      && match[1].length >= opening.length
    );
  }

  function splitTableRow(line) {
    let row = line.trim();
    if (row.startsWith("|")) row = row.slice(1);
    if (row.endsWith("|")) row = row.slice(0, -1);
    return row.split(/(?<!\\)\|/).map((cell) => cell.replace(/\\\|/g, "|"));
  }

  function paragraphText(lines) {
    if (lines.length === 0) return "";

    let text = lines[0];
    for (let index = 1; index < lines.length; index += 1) {
      const separator = /(?: {2,}|\\)$/.test(text) ? "\n" : " ";
      text += separator + lines[index];
    }
    return text;
  }

  function inline(text, footnotes, footnoteOrder, refNumbers, references) {
    const codeTokens = [];
    const wikilinkTokens = [];
    const generatedHTMLTokens = [];
    let value = text.replace(/`([\s\S]+?)`/g, (_, code) => {
      const token = `\u0000CODE${codeTokens.length}\u0000`;
      codeTokens.push(`<code>${escapeHTML(code)}</code>`);
      return token;
    });
    value = value.replace(/\[\[([^\]\n]+)\]\]/g, (_, content) => {
      const token = `\u0000WIKILINK${wikilinkTokens.length}\u0000`;
      const separator = content.indexOf("|");
      const destination = (separator >= 0 ? content.slice(0, separator) : content).trim();
      const alias = separator >= 0 ? content.slice(separator + 1).trim() : "";
      const label = alias || destination;
      wikilinkTokens.push(destination
        ? `<a href="#" class="wikilink" data-monknot-link-kind="wikilink" data-monknot-destination="${escapeAttr(destination)}">${escapeHTML(label)}</a>`
        : escapeHTML(label));
      return token;
    });
    value = value.replace(/(?<!!)\[([^\]\n]+)\]\[([^\]\n]*)\]/g, (match, label, identifier) => {
      const reference = references.get(normalizeReferenceLabel(identifier || label));
      if (!reference) return match;
      const safe = sanitizeURL(reference.destination, false);
      if (!safe) return label;
      const titleAttr = reference.title ? ` title="${escapeAttr(reference.title)}"` : "";
      const token = `\u0000GENERATED${generatedHTMLTokens.length}\u0000`;
      generatedHTMLTokens.push(`<a href="${escapeAttr(safe)}" data-monknot-link-kind="markdown" data-monknot-destination="${escapeAttr(safe)}"${titleAttr}>${inline(label, footnotes, footnoteOrder, refNumbers, references)}</a>`);
      return token;
    });

    value = escapeHTML(value);
    value = value.replace(/(?: {2,}|\\)\n/g, "<br>");

    value = value.replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]+)")?\)/g, (_, alt, url, title) => {
      const safe = sanitizeURL(url, true);
      if (!safe) return "";
      const titleAttr = title ? ` title="${escapeAttr(title)}"` : "";
      const token = `\u0000GENERATED${generatedHTMLTokens.length}\u0000`;
      generatedHTMLTokens.push(`<img src="${escapeAttr(safe)}" alt="${escapeAttr(alt)}"${titleAttr}>`);
      return token;
    });

    value = value.replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]+)")?\)/g, (_, label, url, title) => {
      const safe = sanitizeURL(url, false);
      if (!safe) return label;
      const titleAttr = title ? ` title="${escapeAttr(title)}"` : "";
      const token = `\u0000GENERATED${generatedHTMLTokens.length}\u0000`;
      generatedHTMLTokens.push(`<a href="${escapeAttr(safe)}" data-monknot-link-kind="markdown" data-monknot-destination="${escapeAttr(safe)}"${titleAttr}>${inline(label, footnotes, footnoteOrder, refNumbers, references)}</a>`);
      return token;
    });

    value = value.replace(/(^|[\s(])(https?:\/\/[^\s<]+)/g, (_, prefix, url) => `${prefix}<a href="${escapeAttr(url)}" data-monknot-link-kind="markdown" data-monknot-destination="${escapeAttr(url)}">${escapeHTML(url)}</a>`);
    value = value.replace(/&lt;(https?:\/\/[^&\s]+)&gt;/g, (_, url) => `<a href="${escapeAttr(url)}" data-monknot-link-kind="markdown" data-monknot-destination="${escapeAttr(url)}">${escapeHTML(url)}</a>`);

    value = value.replace(/\[\^([^\]]+)\]/g, (_, key) => {
      const normalized = key.trim();
      if (!footnotes.has(normalized)) return `[^${escapeHTML(key)}]`;
      if (!refNumbers.has(normalized)) refNumbers.set(normalized, refNumbers.size + 1);
      const number = refNumbers.get(normalized);
      return `<sup class="footnote-ref" id="fnref-${escapeAttr(slug(normalized))}"><a href="#fn-${escapeAttr(slug(normalized))}">${number}</a></sup>`;
    });

    value = value.replace(/(\*\*|__)([\s\S]+?)\1/g, "<strong>$2</strong>");
    value = value.replace(/~~([\s\S]+?)~~/g, "<del>$1</del>");
    value = value.replace(/(^|[^*])\*([^*\s][^*]*?)\*/g, "$1<em>$2</em>");
    value = value.replace(/(^|[^_])_([^_\s][^_]*?)_/g, "$1<em>$2</em>");

    codeTokens.forEach((html, index) => {
      value = value.replace(`\u0000CODE${index}\u0000`, html);
    });
    wikilinkTokens.forEach((html, index) => {
      value = value.replace(`\u0000WIKILINK${index}\u0000`, html);
    });
    generatedHTMLTokens.forEach((html, index) => {
      value = value.replace(`\u0000GENERATED${index}\u0000`, html);
    });

    return value;
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

  function isListLine(line) {
    return /^(\s*)([-+*]|\d+[.)])\s+/.test(line);
  }

  function isBlank(line) {
    return /^\s*$/.test(line);
  }

  function estimateSourceLine(event) {
    const rect = target.getBoundingClientRect();
    const lineCount = Math.max(1, markdown.replace(/\r\n?/g, "\n").split("\n").length);
    const ratio = rect.height > 0 ? Math.min(1, Math.max(0, (event.clientY - rect.top) / rect.height)) : 0;
    return Math.max(1, Math.round(ratio * lineCount));
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

  function escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }
})();
