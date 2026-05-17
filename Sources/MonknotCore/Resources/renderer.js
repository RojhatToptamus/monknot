(() => {
  "use strict";

  let markdown = "";
  let searchQuery = "";
  let searchNavigationSerial = -1;
  let searchMatches = [];
  let searchCurrentIndex = 0;
  let hasRendered = false;

  const target = document.getElementById("content");
  if (!target) return;

  window.monknotRender = render;
  window.monknotApplyAppearance = applyAppearance;
  window.monknotSearch = searchDocument;
  window.monknotRevealSourceLine = revealSourceLine;
  render(window.monknot || {});
  target.addEventListener("dblclick", handleSourceJump);

  function render(nextState) {
    const nextMarkdown = typeof nextState.markdown === "string" ? nextState.markdown : "";
    const nextTheme = nextState.theme === "dark" ? "dark" : "light";
    if (hasRendered && nextMarkdown === markdown && document.documentElement.dataset.theme === nextTheme) {
      return;
    }

    markdown = nextMarkdown;
    document.documentElement.dataset.theme = nextTheme;
    target.innerHTML = renderMarkdown(markdown);
    hasRendered = true;
    if (searchQuery) {
      searchDocument({
        query: searchQuery,
        navigationSerial: searchNavigationSerial,
        direction: "current",
        isPresented: true
      });
    }
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
    const queryChanged = requestedQuery !== searchQuery;
    const navigationChanged = navigationSerial !== searchNavigationSerial;

    searchQuery = requestedQuery;
    removeSearchHighlights();

    if (!searchQuery) {
      searchMatches = [];
      searchCurrentIndex = 0;
      searchNavigationSerial = navigationSerial;
      return searchResult();
    }

    searchMatches = highlightSearchMatches(searchQuery);

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

  function highlightSearchMatches(query) {
    const matches = [];
    const queryLower = query.toLocaleLowerCase();
    const nodes = textNodesForSearch();

    for (const node of nodes) {
      const value = node.nodeValue || "";
      const valueLower = value.toLocaleLowerCase();
      let cursor = 0;
      let matchIndex = valueLower.indexOf(queryLower);
      if (matchIndex < 0) continue;

      const fragment = document.createDocumentFragment();
      while (matchIndex >= 0) {
        if (matchIndex > cursor) {
          fragment.appendChild(document.createTextNode(value.slice(cursor, matchIndex)));
        }

        const mark = document.createElement("mark");
        mark.className = "monknot-search-match";
        mark.textContent = value.slice(matchIndex, matchIndex + query.length);
        fragment.appendChild(mark);
        matches.push(mark);

        cursor = matchIndex + query.length;
        matchIndex = valueLower.indexOf(queryLower, cursor);
      }

      if (cursor < value.length) {
        fragment.appendChild(document.createTextNode(value.slice(cursor)));
      }

      node.parentNode?.replaceChild(fragment, node);
    }

    return matches;
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

    target.querySelectorAll(".monknot-source-reveal").forEach((element) => {
      element.classList.remove("monknot-source-reveal");
    });
    targetElement.classList.add("monknot-source-reveal");
    targetElement.scrollIntoView({ block: "start", inline: "nearest", behavior: "smooth" });

    window.setTimeout(() => {
      targetElement.classList.remove("monknot-source-reveal");
    }, 1400);

    return true;
  }

  function captureScrollAnchor() {
    const scroller = document.scrollingElement || document.documentElement;
    const maxBefore = Math.max(1, scroller.scrollHeight - window.innerHeight);
    const ratio = scroller.scrollTop / maxBefore;
    const pointX = Math.max(1, Math.floor(window.innerWidth / 2));
    const pointY = Math.max(1, Math.min(window.innerHeight - 1, Math.floor(window.innerHeight / 2)));
    const anchor = document.elementFromPoint(pointX, pointY);
    const anchorTop = anchor?.getBoundingClientRect().top;

    return () => {
      requestAnimationFrame(() => {
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
    const lines = source.replace(/\r\n?/g, "\n").split("\n");
    const bodyLines = [];

    for (const line of lines) {
      const match = line.match(/^\[\^([^\]]+)\]:\s*(.*)$/);
      if (match) {
        const key = match[1].trim();
        if (!footnotes.has(key)) footnoteOrder.push(key);
        footnotes.set(key, match[2]);
      } else {
        bodyLines.push(line);
      }
    }

    const refNumbers = new Map();
    const html = parseBlocks(bodyLines, footnotes, footnoteOrder, refNumbers);

    if (refNumbers.size === 0) return html;

    const notes = footnoteOrder
      .filter((key) => refNumbers.has(key))
      .sort((a, b) => refNumbers.get(a) - refNumbers.get(b))
      .map((key) => {
        const number = refNumbers.get(key);
        return `<li id="fn-${escapeAttr(slug(key))}">${inline(footnotes.get(key) || "", footnotes, footnoteOrder, refNumbers)} <a class="footnote-backref" href="#fnref-${escapeAttr(slug(key))}">↩</a></li>`;
      })
      .join("");

    return `${html}<section class="footnotes"><ol>${notes}</ol></section>`;
  }

  function parseBlocks(lines, footnotes, footnoteOrder, refNumbers) {
    const blocks = [];
    let index = 0;

    while (index < lines.length) {
      const line = lines[index];

      if (isBlank(line)) {
        index += 1;
        continue;
      }

      const fence = line.match(/^ {0,3}(```+|~~~+)\s*([\w.+-]*)\s*$/);
      if (fence) {
        const startLine = index;
        const marker = fence[1][0];
        const lang = fence[2] || "";
        const codeLines = [];
        index += 1;
        while (index < lines.length && !new RegExp(`^ {0,3}${escapeRegExp(marker.repeat(3))}`).test(lines[index])) {
          codeLines.push(lines[index]);
          index += 1;
        }
        if (index < lines.length) index += 1;
        blocks.push(markSource(`<pre><code class="language-${escapeAttr(lang)}">${highlightCode(codeLines.join("\n"), lang)}</code></pre>`, startLine));
        continue;
      }

      const heading = line.match(/^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$/);
      if (heading) {
        const startLine = index;
        const level = heading[1].length;
        const text = heading[2].trim();
        blocks.push(markSource(`<h${level} id="${escapeAttr(slug(stripInline(text)))}">${inline(text, footnotes, footnoteOrder, refNumbers)}</h${level}>`, startLine));
        index += 1;
        continue;
      }

      if (/^ {0,3}([-*_])(?:\s*\1){2,}\s*$/.test(line)) {
        blocks.push(markSource("<hr>", index));
        index += 1;
        continue;
      }

      if (isTableStart(lines, index)) {
        const startLine = index;
        const parsed = parseTable(lines, index, footnotes, footnoteOrder, refNumbers);
        blocks.push(markSource(parsed.html, startLine));
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
        blocks.push(markSource(`<blockquote>${parseBlocks(quoteLines, footnotes, footnoteOrder, refNumbers)}</blockquote>`, startLine));
        continue;
      }

      if (isListLine(line)) {
        const startLine = index;
        const parsed = parseList(lines, index, footnotes, footnoteOrder, refNumbers);
        blocks.push(markSource(parsed.html, startLine));
        index = parsed.nextIndex;
        continue;
      }

      const startLine = index;
      const paragraph = [];
      while (index < lines.length && !isBlank(lines[index]) && !isBlockStart(lines, index)) {
        paragraph.push(lines[index]);
        index += 1;
      }
      blocks.push(markSource(`<p>${inline(paragraphText(paragraph), footnotes, footnoteOrder, refNumbers)}</p>`, startLine));
    }

    return blocks.join("\n");
  }

  function handleSourceJump(event) {
    const targetElement = event.target instanceof Element ? event.target : event.target?.parentElement;
    const quoteElement = targetElement?.closest("blockquote[data-source-line]");
    const sourceElement = quoteElement || targetElement?.closest("[data-source-line]");

    const line = sourceElement ? Number(sourceElement.dataset.sourceLine || "0") : estimateSourceLine(event);
    if (!Number.isFinite(line) || line < 1) return;

    event.preventDefault();
    window.webkit?.messageHandlers?.monknotSourceJump?.postMessage({ line, offset: 0 });
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

  function parseList(lines, start, footnotes, footnoteOrder, refNumbers) {
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
      let content = inline(match[4], footnotes, footnoteOrder, refNumbers);
      let className = "";
      if (task) {
        hasTasks = true;
        const checked = /\[[xX]\]/.test(task) ? " checked" : "";
        className = " class=\"task-list-item\"";
        content = `<input type="checkbox" disabled${checked}> <span>${content}</span>`;
      }

      items.push(markSource(`<li${className}>${content}</li>`, index));
      index += 1;
    }

    const listClass = hasTasks ? " class=\"contains-task-list\"" : "";
    return { html: `<${tag}${listClass}>${items.join("")}</${tag}>`, nextIndex: index };
  }

  function parseTable(lines, start, footnotes, footnoteOrder, refNumbers) {
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
    const thead = `<thead><tr>${headers.map((cell, idx) => `<th${alignAttr(idx)}>${inline(cell.trim(), footnotes, footnoteOrder, refNumbers)}</th>`).join("")}</tr></thead>`;
    const tbody = `<tbody>${rows.map((row) => `<tr>${headers.map((_, idx) => `<td${alignAttr(idx)}>${inline((row[idx] || "").trim(), footnotes, footnoteOrder, refNumbers)}</td>`).join("")}</tr>`).join("")}</tbody>`;

    return { html: `<div class="table-wrapper"><table>${thead}${tbody}</table></div>`, nextIndex: index };
  }

  function isTableStart(lines, index) {
    if (index + 1 >= lines.length) return false;
    if (!/\|/.test(lines[index])) return false;
    return splitTableRow(lines[index + 1]).every((cell) => /^:?-{3,}:?$/.test(cell.trim()));
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

  function inline(text, footnotes, footnoteOrder, refNumbers) {
    const codeTokens = [];
    let value = text.replace(/`([\s\S]+?)`/g, (_, code) => {
      const token = `\u0000CODE${codeTokens.length}\u0000`;
      codeTokens.push(`<code>${escapeHTML(code)}</code>`);
      return token;
    });

    value = escapeHTML(value);
    value = value.replace(/(?: {2,}|\\)\n/g, "<br>");

    value = value.replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]+)")?\)/g, (_, alt, url, title) => {
      const safe = sanitizeURL(url, true);
      if (!safe) return "";
      const titleAttr = title ? ` title="${escapeAttr(title)}"` : "";
      return `<img src="${escapeAttr(safe)}" alt="${escapeAttr(alt)}"${titleAttr}>`;
    });

    value = value.replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]+)")?\)/g, (_, label, url, title) => {
      const safe = sanitizeURL(url, false);
      if (!safe) return label;
      const titleAttr = title ? ` title="${escapeAttr(title)}"` : "";
      return `<a href="${escapeAttr(safe)}"${titleAttr}>${label}</a>`;
    });

    value = value.replace(/&lt;(https?:\/\/[^&\s]+)&gt;/g, (_, url) => `<a href="${escapeAttr(url)}">${escapeHTML(url)}</a>`);
    value = value.replace(/(^|[\s(])(https?:\/\/[^\s<]+)/g, (_, prefix, url) => `${prefix}<a href="${escapeAttr(url)}">${escapeHTML(url)}</a>`);

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
