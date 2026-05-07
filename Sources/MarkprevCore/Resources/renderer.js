(() => {
  "use strict";

  let markdown = "";

  const target = document.getElementById("content");
  if (!target) return;

  window.markprevRender = render;
  render(window.markprev || {});
  target.addEventListener("dblclick", handleSourceJump);

  function render(nextState) {
    markdown = typeof nextState.markdown === "string" ? nextState.markdown : "";
    document.documentElement.dataset.theme = nextState.theme === "dark" ? "dark" : "light";
    target.innerHTML = renderMarkdown(markdown);
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
      blocks.push(markSource(`<p>${inline(paragraph.join(" "), footnotes, footnoteOrder, refNumbers)}</p>`, startLine));
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
    window.webkit?.messageHandlers?.markprevSourceJump?.postMessage({ line, offset: 0 });
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

    return { html: `<table>${thead}${tbody}</table>`, nextIndex: index };
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

  function inline(text, footnotes, footnoteOrder, refNumbers) {
    const codeTokens = [];
    let value = text.replace(/`([^`]+)`/g, (_, code) => {
      const token = `\u0000CODE${codeTokens.length}\u0000`;
      codeTokens.push(`<code>${escapeHTML(code)}</code>`);
      return token;
    });

    value = escapeHTML(value);

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

    value = value.replace(/(\*\*|__)(.+?)\1/g, "<strong>$2</strong>");
    value = value.replace(/~~(.+?)~~/g, "<del>$1</del>");
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
