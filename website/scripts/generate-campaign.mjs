import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);
const root = resolve(import.meta.dirname, "..");
const repository = resolve(root, "..");
const scratch = resolve(repository, ".build", "website-campaign");
const svgDirectory = resolve(scratch, "svg");
const rasterDirectory = resolve(scratch, "raster");
const productDirectory = resolve(root, "assets", "product");
const appStoreDirectory = resolve(root, "app-store-screenshots");

const canvas = { width: 2880, height: 1800 };
const frame = {
  x: 96,
  y: 128,
  width: 2688,
  height: 1576,
  radius: 36,
  titlebarHeight: 104,
  sidebarWidth: 448,
  toolbarHeight: 96,
};
frame.contentX = frame.x + frame.sidebarWidth;
frame.contentY = frame.y + frame.titlebarHeight + frame.toolbarHeight;
frame.contentWidth = frame.width - frame.sidebarWidth;
frame.contentHeight = frame.height - frame.titlebarHeight - frame.toolbarHeight;

const states = [
  { id: "default", label: "Markdown editor", tab: "README.md" },
  { id: "split", label: "Editor + preview", tab: "README.md" },
  { id: "terminal", label: "Terminal", tab: "README.md" },
  { id: "pdf", label: "PDF reader", tab: "Field-note.pdf" },
  { id: "themes", label: "Theme explorer", tab: "Themes" },
];

const campaignFamilies = [
  "harbor",
  "brasspants",
  "codechimp",
  "greaseball",
  "sockpuppet",
  "forge",
  "parchment",
  "monolith",
];

const geometry = {
  schemaVersion: 1,
  canvas,
  frame,
  states: states.map(({ id }) => id),
  variants: ["dark", "light"],
  sharedRegions: [
    { id: "window-edge", x: frame.x, y: frame.y, width: frame.width, height: frame.height },
    { id: "traffic-lights", x: frame.x + 24, y: frame.y + 20, width: 128, height: 64 },
    { id: "sidebar-shell", x: frame.x, y: frame.y + frame.titlebarHeight, width: frame.sidebarWidth, height: frame.height - frame.titlebarHeight },
    { id: "content-boundary", x: frame.contentX - 2, y: frame.y + frame.titlebarHeight, width: 4, height: frame.height - frame.titlebarHeight },
    { id: "toolbar-boundary", x: frame.contentX, y: frame.contentY - 2, width: frame.contentWidth, height: 4 },
  ],
  stateSlots: {
    default: [{ x: frame.contentX, y: frame.contentY, width: frame.contentWidth, height: frame.contentHeight }],
    split: [
      { x: frame.contentX, y: frame.contentY, width: 1098, height: frame.contentHeight },
      { x: frame.contentX + 1108, y: frame.contentY, width: 1132, height: frame.contentHeight },
    ],
    terminal: [
      { x: frame.contentX, y: frame.contentY, width: 1320, height: frame.contentHeight },
      { x: frame.contentX + 1330, y: frame.contentY, width: 910, height: frame.contentHeight },
    ],
    pdf: [{ x: frame.contentX, y: frame.contentY, width: frame.contentWidth, height: frame.contentHeight }],
    themes: [{ x: frame.contentX, y: frame.contentY, width: frame.contentWidth, height: frame.contentHeight }],
  },
};

function escapeXML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function hexToRGB(hex) {
  const value = hex.replace("#", "");
  return {
    red: Number.parseInt(value.slice(0, 2), 16),
    green: Number.parseInt(value.slice(2, 4), 16),
    blue: Number.parseInt(value.slice(4, 6), 16),
  };
}

function mix(first, second, amount) {
  const from = hexToRGB(first);
  const to = hexToRGB(second);
  const channel = (key) => Math.round(from[key] + (to[key] - from[key]) * amount);
  return `#${[channel("red"), channel("green"), channel("blue")]
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("")}`;
}

function alpha(hex, opacity) {
  const { red, green, blue } = hexToRGB(hex);
  return `rgba(${red},${green},${blue},${opacity})`;
}

function palette(theme) {
  const dark = theme.variant === "dark";
  return {
    ...theme,
    canvas: dark ? "#0d0f12" : "#f3f0e9",
    window: dark ? mix(theme.surface, "#ffffff", 0.035) : mix(theme.surface, "#000000", 0.018),
    sidebar: mix(theme.surface, theme.ink, dark ? 0.075 : 0.028),
    titlebar: mix(theme.surface, theme.ink, dark ? 0.105 : 0.045),
    toolbar: mix(theme.surface, theme.ink, dark ? 0.055 : 0.018),
    raised: mix(theme.surface, theme.ink, dark ? 0.13 : 0.065),
    boundary: mix(theme.surface, theme.ink, dark ? 0.12 : 0.14),
    line: alpha(theme.ink, dark ? 0.12 : 0.14),
    lineSoft: alpha(theme.ink, dark ? 0.075 : 0.09),
    muted: alpha(theme.ink, 0.64),
    faint: alpha(theme.ink, 0.42),
  };
}

function rect(x, y, width, height, fill, options = "") {
  return `<rect x="${x}" y="${y}" width="${width}" height="${height}" fill="${fill}" ${options}/>`;
}

function line(x1, y1, x2, y2, stroke, width = 2, options = "") {
  return `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="${stroke}" stroke-width="${width}" ${options}/>`;
}

function circle(cx, cy, radius, fill, options = "") {
  return `<circle cx="${cx}" cy="${cy}" r="${radius}" fill="${fill}" ${options}/>`;
}

function text(x, y, value, fill, size, options = "") {
  return `<text x="${x}" y="${y}" fill="${fill}" font-size="${size}" ${options}>${escapeXML(value)}</text>`;
}

function folderIcon(x, y, color) {
  return `<path d="M${x} ${y + 6}h20l8 8h34v40h-62z" fill="none" stroke="${color}" stroke-width="4" stroke-linejoin="round"/>`;
}

function fileIcon(x, y, color) {
  return `<path d="M${x} ${y}h30l16 16v48h-46z M${x + 30} ${y}v16h16" fill="none" stroke="${color}" stroke-width="4" stroke-linejoin="round"/>`;
}

function sidebar(palette, selectedLabel) {
  const x = frame.x;
  const y = frame.y + frame.titlebarHeight;
  const rowX = x + 26;
  const labelX = x + 116;
  const rows = [
    { label: "notes", kind: "folder" },
    { label: "research", kind: "folder" },
    { label: "drafts", kind: "folder" },
    { label: selectedLabel, kind: "file", selected: true },
  ];
  let markup = rect(x, y, frame.sidebarWidth, frame.height - frame.titlebarHeight, palette.sidebar);
  markup += line(x + frame.sidebarWidth, y, x + frame.sidebarWidth, frame.y + frame.height, palette.line, 2);
  markup += text(x + 34, y + 72, "Atlas", palette.ink, 34, 'font-weight="650"');
  markup += text(x + 34, y + 112, "WORKSPACE", palette.faint, 20, 'letter-spacing="3"');
  markup += circle(x + frame.sidebarWidth - 76, y + 69, 4, palette.muted);
  markup += circle(x + frame.sidebarWidth - 48, y + 69, 4, palette.muted);

  rows.forEach((row, index) => {
    const rowY = y + 158 + index * 86;
    if (row.selected) {
      markup += rect(rowX, rowY, frame.sidebarWidth - 52, 66, palette.selection, 'rx="14"');
    }
    markup += row.kind === "folder"
      ? folderIcon(x + 48, rowY + 10, row.selected ? palette.ink : palette.muted)
      : fileIcon(x + 56, rowY + 3, row.selected ? palette.accent : palette.muted);
    markup += text(labelX, rowY + 44, row.label, row.selected ? palette.ink : palette.muted, 30, 'font-weight="520"');
  });

  const footerY = frame.y + frame.height - 82;
  markup += line(x + 26, footerY - 26, x + frame.sidebarWidth - 26, footerY - 26, palette.lineSoft, 2);
  markup += circle(x + 54, footerY + 4, 15, "none", `stroke="${palette.muted}" stroke-width="4"`);
  markup += line(x + 54, footerY - 19, x + 54, footerY + 27, palette.muted, 4, 'stroke-linecap="round"');
  markup += text(x + 90, footerY + 15, "Settings", palette.muted, 28);
  return markup;
}

function titlebar(palette, state) {
  const { x, y, width, titlebarHeight } = frame;
  const centerY = y + titlebarHeight / 2;
  let markup = rect(x, y, width, titlebarHeight, palette.titlebar);
  markup += line(x, y + titlebarHeight, x + width, y + titlebarHeight, palette.line, 2);

  [["#ff5f57", x + 40], ["#febc2e", x + 72], ["#28c840", x + 104]].forEach(([color, cx]) => {
    markup += circle(cx, centerY, 10, color, `stroke="${alpha("#000000", 0.18)}" stroke-width="2"`);
  });

  markup += rect(x + 152, y + 20, 68, 64, palette.raised, `rx="14" stroke="${palette.line}" stroke-width="2"`);
  markup += `<rect x="${x + 171}" y="${y + 35}" width="31" height="34" rx="5" fill="none" stroke="${palette.muted}" stroke-width="4"/><line x1="${x + 182}" y1="${y + 36}" x2="${x + 182}" y2="${y + 68}" stroke="${palette.muted}" stroke-width="4"/>`;
  markup += rect(x + 238, y + 20, 130, 64, palette.toolbar, `rx="14" stroke="${palette.lineSoft}" stroke-width="2"`);
  markup += `<path d="M${x + 286} ${centerY - 14}l-14 14 14 14M${x + 316} ${centerY - 14}l14 14-14 14" fill="none" stroke="${palette.faint}" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>`;

  const tabX = x + 408;
  markup += rect(tabX, y + 18, 390, 68, palette.raised, `rx="16" stroke="${palette.lineSoft}" stroke-width="2"`);
  markup += fileIcon(tabX + 24, y + 20, palette.accent);
  markup += text(tabX + 92, y + 64, state.tab, palette.ink, 30, 'font-weight="570"');
  markup += `<path d="M${tabX + 348} ${centerY - 10}l20 20m0-20-20 20" stroke="${palette.faint}" stroke-width="3" stroke-linecap="round"/>`;

  markup += text(x + width - 424, y + 68, state.label, palette.muted, 26, 'text-anchor="end"');
  markup += rect(x + width - 380, y + 20, 142, 64, palette.toolbar, `rx="14" stroke="${palette.lineSoft}" stroke-width="2"`);
  markup += `<path d="M${x + width - 349} ${centerY - 13}h41m-41 13h31m-31 13h22" stroke="${palette.accent}" stroke-width="5" stroke-linecap="round"/>`;
  markup += `<path d="M${x + width - 281} ${centerY}c18-22 40-22 58 0-18 22-40 22-58 0z" fill="none" stroke="${palette.muted}" stroke-width="4"/><circle cx="${x + width - 252}" cy="${centerY}" r="8" fill="${palette.muted}"/>`;
  markup += rect(x + width - 208, y + 20, 68, 64, palette.toolbar, `rx="14" stroke="${palette.line}" stroke-width="2"`);
  markup += `<rect x="${x + width - 189}" y="${y + 35}" width="31" height="34" rx="5" fill="none" stroke="${palette.muted}" stroke-width="4"/><line x1="${x + width - 169}" y1="${y + 36}" x2="${x + width - 169}" y2="${y + 68}" stroke="${palette.muted}" stroke-width="4"/>`;
  return markup;
}

function toolbar(palette, mode) {
  const x = frame.contentX;
  const y = frame.y + frame.titlebarHeight;
  let markup = rect(x, y, frame.contentWidth, frame.toolbarHeight, palette.toolbar);
  markup += line(x, y + frame.toolbarHeight, x + frame.contentWidth, y + frame.toolbarHeight, palette.line, 2);
  if (mode === "pdf") {
    markup += text(x + 30, y + 54, "1 / 1", palette.muted, 27, 'font-family="monospace"');
    const labels = ["↶", "↷", "↖", "✎", "U", "S", "◯", "◇"];
    labels.forEach((label, index) => {
      const active = index === 2;
      const bx = x + 150 + index * 72;
      if (active) markup += rect(bx - 12, y + 13, 58, 58, palette.selection, 'rx="13"');
      markup += text(bx + 16, y + 55, label, active ? palette.accent : palette.muted, 31, 'text-anchor="middle" font-weight="600"');
    });
    ["#ffd644", "#6bd67d", "#55b8ff", "#f57ab1", "#ef5d5d"].forEach((color, index) => {
      markup += circle(x + 810 + index * 62, y + 43, 16, color);
    });
    markup += text(x + frame.contentWidth - 178, y + 54, "140%", palette.ink, 27, 'font-family="monospace"');
  } else if (mode === "themes") {
    markup += text(x + 30, y + 55, "Themes", palette.ink, 30, 'font-weight="650"');
    markup += text(x + frame.contentWidth - 30, y + 55, "Light and dark presets", palette.muted, 25, 'text-anchor="end"');
  } else {
    markup += text(x + 30, y + 55, "Paragraph", palette.ink, 28, 'font-weight="560"');
    const tools = ["B", "I", "“", "{}", "↗", "☷", "☑", "▧", "—"];
    tools.forEach((label, index) => {
      markup += text(x + 208 + index * 76, y + 57, label, index === 0 ? palette.ink : palette.muted, 31, `text-anchor="middle" font-weight="${index === 0 ? 700 : 500}"`);
    });
    markup += text(x + frame.contentWidth - 30, y + 54, "31/120", palette.faint, 25, 'text-anchor="end" font-family="monospace"');
  }
  return markup;
}

function sourceEditor(palette, x, y, width, height, compact = false) {
  const pad = compact ? 48 : 64;
  const size = compact ? 30 : 34;
  const lineHeight = compact ? 62 : 69;
  const startX = x + pad;
  const startY = y + 82;
  const rows = [
    ["# Field notes", palette.accent, 650],
    ["An offline route brief for a small team.", palette.muted, 480],
    ["> Focus: confirm the weather window.", palette.faint, 480],
    ["## This week", palette.accent, 650],
    ["- [x] Compare the north and harbor routes", palette.added, 520],
    ["- [ ] Review the weather window", palette.muted, 480],
    ["- [ ] Export the field brief as PDF", palette.muted, 480],
    ["[[route-plan]]", palette.skill, 560],
    ["", palette.ink, 400],
    ["let route = notes.filter { !$0.isResolved }", palette.skill, 500],
  ];
  let markup = rect(x, y, width, height, palette.surface);
  rows.forEach(([value, fill, weight], index) => {
    if (!value) return;
    markup += text(startX, startY + index * lineHeight, value, fill, size, `font-family="monospace" font-weight="${weight}"`);
  });
  markup += `<rect x="${x + width - 22}" y="${y + 34}" width="6" height="${Math.max(120, height * 0.27)}" rx="3" fill="${palette.faint}"/>`;
  markup += line(x + width - 8, y, x + width - 8, y + height, palette.lineSoft, 2);
  return markup;
}

function documentPreview(palette, x, y, width, height) {
  const px = x + Math.max(70, width * 0.1);
  const max = width - Math.max(140, width * 0.2);
  let markup = rect(x, y, width, height, palette.surface);
  markup += text(px, y + 104, "Field notes", palette.ink, 52, 'font-weight="700" letter-spacing="-1.5"');
  markup += text(px, y + 166, "An offline route brief for a small team.", palette.muted, 29);
  markup += rect(px, y + 214, max, 126, palette.selection, 'rx="16"');
  markup += rect(px, y + 214, 6, 126, palette.accent, 'rx="3"');
  markup += text(px + 30, y + 265, "Focus", palette.ink, 28, 'font-weight="700"');
  markup += text(px + 30, y + 310, "Confirm the weather window before departure.", palette.muted, 27);
  markup += text(px, y + 415, "This week", palette.ink, 35, 'font-weight="700"');
  [
    ["Compare the north and harbor routes", true],
    ["Review the weather window", false],
    ["Export the field brief as PDF", false],
  ].forEach(([label, done], index) => {
    const rowY = y + 476 + index * 58;
    markup += rect(px + 5, rowY - 23, 20, 20, done ? palette.added : "none", `rx="4" stroke="${done ? palette.added : palette.faint}" stroke-width="3"`);
    if (done) markup += `<path d="M${px + 9} ${rowY - 13}l5 5 9-12" fill="none" stroke="${palette.surface}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>`;
    markup += text(px + 45, rowY - 5, label, done ? palette.faint : palette.muted, 27, done ? 'text-decoration="line-through"' : "");
  });
  markup += text(px, y + 690, "Route snapshot", palette.ink, 35, 'font-weight="700"');
  const tableY = y + 730;
  markup += rect(px, tableY, max, 184, palette.toolbar, `rx="12" stroke="${palette.line}" stroke-width="2"`);
  [0, 1, 2].forEach((index) => {
    if (index) markup += line(px, tableY + index * 61, px + max, tableY + index * 61, palette.line, 2);
    markup += text(px + 22, tableY + 41 + index * 61, ["Day", "1", "2"][index], index ? palette.muted : palette.ink, 25, index ? "" : 'font-weight="700"');
    markup += text(px + 132, tableY + 41 + index * 61, ["Base", "Alder Bay", "North Ridge"][index], index ? palette.muted : palette.ink, 25, index ? "" : 'font-weight="700"');
    markup += text(px + 370, tableY + 41 + index * 61, ["Plan", "Map shoreline", "Check wind"][index], index ? palette.muted : palette.ink, 25, index ? "" : 'font-weight="700"');
  });
  markup += line(px + 106, tableY, px + 106, tableY + 184, palette.line, 2);
  markup += line(px + 340, tableY, px + 340, tableY + 184, palette.line, 2);
  return markup;
}

function editorState(palette, mode) {
  const { contentX: x, contentY: y, contentWidth: width, contentHeight: height } = frame;
  if (mode === "default") return sourceEditor(palette, x, y, width, height);
  if (mode === "split") {
    const sourceWidth = Math.round(width * 0.49);
    return sourceEditor(palette, x, y, sourceWidth, height, true)
      + rect(x + sourceWidth, y, 10, height, palette.raised)
      + documentPreview(palette, x + sourceWidth + 10, y, width - sourceWidth - 10, height);
  }
  const sourceWidth = 1320;
  const terminalX = x + sourceWidth + 10;
  const terminalWidth = width - sourceWidth - 10;
  let markup = sourceEditor(palette, x, y, sourceWidth, height, true);
  markup += rect(x + sourceWidth, y, 10, height, palette.raised);
  markup += rect(terminalX, y, terminalWidth, height, palette.sidebar);
  markup += rect(terminalX, y, terminalWidth, 78, palette.titlebar);
  markup += line(terminalX, y + 78, terminalX + terminalWidth, y + 78, palette.line, 2);
  markup += rect(terminalX + 28, y + 16, 132, 50, palette.raised, 'rx="12"');
  markup += text(terminalX + 50, y + 51, "⌁  1", palette.added, 25, 'font-family="monospace"');
  markup += text(terminalX + terminalWidth - 42, y + 52, "+", palette.muted, 38, 'text-anchor="middle"');
  markup += text(terminalX + 48, y + 158, 'atlas % rg "weather" notes', palette.ink, 31, 'font-family="monospace"');
  markup += text(terminalX + 48, y + 224, "notes/field-log.md:12  weather window", palette.muted, 27, 'font-family="monospace"');
  markup += text(terminalX + 48, y + 290, "notes/route.md:8       weather station", palette.muted, 27, 'font-family="monospace"');
  markup += text(terminalX + 48, y + 356, "atlas %", palette.ink, 31, 'font-family="monospace"');
  markup += rect(terminalX + 203, y + 325, 18, 42, palette.accent, 'rx="2"');
  return markup;
}

function pdfState(palette) {
  const { contentX: x, contentY: y, contentWidth: width, contentHeight: height } = frame;
  const paperWidth = 920;
  const paperHeight = 1264;
  const paperX = x + (width - paperWidth) / 2;
  const paperY = y + 56;
  let markup = rect(x, y, width, height, mix(palette.surface, palette.ink, palette.variant === "dark" ? 0.075 : 0.05));
  markup += rect(paperX, paperY, paperWidth, paperHeight, "#fffdfa", 'rx="5" filter="url(#paper-shadow)"');
  markup += text(paperX + 110, paperY + 124, "ATLAS  /  FIELD NOTE 04", "#b85d35", 24, 'font-weight="750" letter-spacing="2"');
  markup += text(paperX + 110, paperY + 220, "Winter route brief", "#201f1d", 58, 'font-weight="760" letter-spacing="-2"');
  markup += text(paperX + 110, paperY + 278, "A three-day research route for the north shore team.", "#73706b", 27);
  markup += rect(paperX + 110, paperY + 344, paperWidth - 220, 150, "#f8eee8", 'rx="16"');
  markup += rect(paperX + 110, paperY + 344, 7, 150, "#c5683e", 'rx="3"');
  markup += text(paperX + 145, paperY + 397, "CURRENT FOCUS", "#b85d35", 22, 'font-weight="760"');
  markup += text(paperX + 145, paperY + 451, "Confirm the weather window and equipment brief.", "#3c3935", 28, 'font-weight="560"');
  markup += text(paperX + 110, paperY + 590, "This week", "#282623", 38, 'font-weight="740"');
  markup += line(paperX + 110, paperY + 615, paperX + paperWidth - 110, paperY + 615, "#dedbd6", 3);
  [
    ["Compare the north and harbor routes", true],
    ["Collect the equipment notes", true],
    ["Review the weather window", false],
    ["Export the final field brief", false],
  ].forEach(([label, done], index) => {
    const rowY = paperY + 678 + index * 61;
    markup += rect(paperX + 114, rowY - 27, 22, 22, done ? "#c5683e" : "none", `rx="4" stroke="${done ? "#c5683e" : "#d6d2cc"}" stroke-width="3"`);
    if (done) markup += `<path d="M${paperX + 119} ${rowY - 16}l5 5 9-12" fill="none" stroke="#fffdfa" stroke-width="3" stroke-linecap="round"/>`;
    markup += text(paperX + 158, rowY - 7, label, "#514e49", 28);
  });
  markup += text(paperX + 110, paperY + 1000, "Route snapshot", "#282623", 38, 'font-weight="740"');
  markup += line(paperX + 110, paperY + 1025, paperX + paperWidth - 110, paperY + 1025, "#dedbd6", 3);
  markup += rect(paperX + 110, paperY + 1070, paperWidth - 220, 196, "#f7f5f1", 'rx="12"');
  return markup;
}

function simplifiedThemePreview(theme, x, y, width, height) {
  const p = palette(theme);
  const titleHeight = 104;
  const sideWidth = 340;
  let markup = rect(x, y, width, height, p.surface, `rx="28" stroke="${p.line}" stroke-width="5"`);
  markup += `<path d="M${x + 28} ${y}h${width - 56}a28 28 0 0 1 28 28v${titleHeight - 28}h-${width}v-${titleHeight - 28}a28 28 0 0 1 28-28z" fill="${p.titlebar}"/>`;
  markup += line(x, y + titleHeight, x + width, y + titleHeight, p.line, 5);
  [x + 54, x + 96, x + 138].forEach((cx) => { markup += circle(cx, y + titleHeight / 2, 15, p.faint); });
  markup += rect(x + 192, y + 18, 330, 68, p.raised, 'rx="16"');
  markup += rect(x + 224, y + 40, 24, 24, p.accent, 'rx="6"');
  markup += text(x + 270, y + 65, "README.md", p.ink, 31, 'font-family="monospace"');
  markup += rect(x, y + titleHeight, sideWidth, height - titleHeight, p.sidebar, 'rx="0 0 0 28"');
  markup += line(x + sideWidth, y + titleHeight, x + sideWidth, y + height, p.line, 5);
  ["notes", "research", "README.md"].forEach((label, index) => {
    const rowY = y + titleHeight + 82 + index * 76;
    if (index === 2) markup += rect(x + 30, rowY - 48, sideWidth - 60, 64, p.selection, 'rx="14"');
    markup += text(x + 48, rowY, label, index === 2 ? p.ink : p.muted, 31, 'font-family="monospace"');
  });
  const codeX = x + sideWidth + 64;
  const codeY = y + titleHeight + 92;
  const codeSize = 35;
  const gap = 74;
  [
    ["# Atlas field notes", p.accent],
    ["An offline field guide.", p.ink],
    ["│ Focus: map the route", p.faint],
    ["## This week", p.accent],
    ["- [x] Compare routes", p.added],
    ["- [ ] Review weather", p.muted],
    ["[[route-plan]]", p.skill],
  ].forEach(([value, fill], index) => {
    markup += text(codeX, codeY + index * gap, value, fill, codeSize, 'font-family="monospace" font-weight="520"');
  });
  return markup;
}

function themeState(basePalette, catalog, variant) {
  const { contentX: x, contentY: y, contentWidth: width, contentHeight: height } = frame;
  const themes = catalog[variant];
  const families = campaignFamilies.map((family) => themes.find((theme) => theme.id === `${family}-${variant}`));
  const selected = themes.find((theme) => theme.id === `monolith-${variant}`);
  const railWidth = 500;
  let markup = rect(x, y, width, height, basePalette.surface);
  markup += rect(x, y, railWidth, height, basePalette.toolbar);
  markup += line(x + railWidth, y, x + railWidth, y + height, basePalette.line, 2);
  markup += text(x + 42, y + 72, "Featured families", basePalette.faint, 23, 'font-weight="700" letter-spacing="2"');
  families.forEach((theme, index) => {
    const rowY = y + 112 + index * 105;
    const active = theme.id === selected.id;
    if (active) markup += rect(x + 26, rowY, railWidth - 52, 82, basePalette.selection, 'rx="16"');
    markup += circle(x + 66, rowY + 41, 15, theme.accent);
    markup += text(x + 102, rowY + 52, theme.name, active ? basePalette.ink : basePalette.muted, 29, `font-weight="${active ? 650 : 520}"`);
    markup += text(x + railWidth - 38, rowY + 50, variant === "dark" ? "Dark" : "Light", basePalette.faint, 22, 'text-anchor="end"');
  });
  markup += text(x + railWidth + 54, y + 74, "Monolith", basePalette.ink, 39, 'font-weight="700" letter-spacing="-1"');
  markup += text(x + width - 54, y + 72, `${variant === "dark" ? "Dark" : "Light"} preset`, basePalette.muted, 24, 'text-anchor="end"');
  markup += simplifiedThemePreview(selected, x + railWidth + 54, y + 118, width - railWidth - 108, height - 180);
  return markup;
}

function masterSVG(state, variant, catalog) {
  const baseTheme = catalog[variant].find((theme) => theme.id === `harbor-${variant}`);
  const p = palette(baseTheme);
  const selectedLabel = state.id === "pdf" ? "Field-note.pdf" : "README.md";
  let content;
  if (["default", "split", "terminal"].includes(state.id)) content = editorState(p, state.id);
  if (state.id === "pdf") content = pdfState(p);
  if (state.id === "themes") content = themeState(p, catalog, variant);

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${canvas.width}" height="${canvas.height}" viewBox="0 0 ${canvas.width} ${canvas.height}">
  <defs>
    <filter id="window-shadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="34" stdDeviation="44" flood-color="#000000" flood-opacity="${variant === "dark" ? 0.5 : 0.2}"/></filter>
    <filter id="paper-shadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="20" stdDeviation="28" flood-color="#000000" flood-opacity="0.26"/></filter>
    <clipPath id="window-clip"><rect x="${frame.x}" y="${frame.y}" width="${frame.width}" height="${frame.height}" rx="${frame.radius}"/></clipPath>
    <clipPath id="content-clip"><rect x="${frame.contentX}" y="${frame.contentY}" width="${frame.contentWidth}" height="${frame.contentHeight}"/></clipPath>
  </defs>
  <style>
    text { font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif; }
    text[font-family="monospace"] { font-family: "SFMono-Regular", Menlo, Consolas, monospace; }
  </style>
  ${rect(0, 0, canvas.width, canvas.height, p.canvas)}
  ${rect(frame.x, frame.y, frame.width, frame.height, p.window, `rx="${frame.radius}" filter="url(#window-shadow)"`)}
  <g clip-path="url(#window-clip)">
    ${titlebar(p, state)}
    ${sidebar(p, selectedLabel)}
    ${toolbar(p, state.id)}
    <g clip-path="url(#content-clip)">${content}</g>
    ${line(frame.contentX, frame.y + frame.titlebarHeight, frame.contentX, frame.y + frame.height, p.boundary, 2)}
    ${line(frame.contentX, frame.contentY, frame.x + frame.width, frame.contentY, p.boundary, 2)}
  </g>
  ${rect(frame.x, frame.y, frame.width, frame.height, "none", `rx="${frame.radius}" stroke="${p.boundary}" stroke-width="3"`)}
</svg>`;
}

async function exportThemeCatalog() {
  const moduleCache = resolve(scratch, "module-cache");
  await mkdir(moduleCache, { recursive: true });
  const { stdout } = await run(
    "swift",
    [
      "run",
      "--package-path",
      repository,
      "--scratch-path",
      resolve(scratch, "swift"),
      "--disable-sandbox",
      "--quiet",
      "MonknotThemeCatalogExport",
    ],
    {
      cwd: repository,
      env: {
        ...process.env,
        CLANG_MODULE_CACHE_PATH: moduleCache,
        SWIFTPM_MODULECACHE_OVERRIDE: moduleCache,
      },
      maxBuffer: 5 * 1024 * 1024,
    },
  );
  return JSON.parse(stdout);
}

async function rasterize(svgPath, outputPath, background) {
  const rgbaPath = resolve(rasterDirectory, `${outputPath.split("/").pop()}.rgba.png`);
  await run("rsvg-convert", ["--width", String(canvas.width), "--height", String(canvas.height), "--background-color", background, "--output", rgbaPath, svgPath]);
  await run("ffmpeg", ["-y", "-loglevel", "error", "-i", rgbaPath, "-vf", "format=rgb24", "-frames:v", "1", outputPath]);
}

async function webDerivatives(svgPath, masterPath, state, variant, background) {
  const stem = `${state.id}-${variant}`;
  const derivatives = [];
  for (const width of [960, 1920, 2880]) {
    const source = width === canvas.width
      ? masterPath
      : resolve(rasterDirectory, `${stem}-${width}.png`);
    if (width !== canvas.width) {
      await run("rsvg-convert", [
        "--width",
        String(width),
        "--height",
        String((width * canvas.height) / canvas.width),
        "--background-color",
        background,
        "--output",
        source,
        svgPath,
      ]);
    }
    const name = `${stem}-${width}.webp`;
    const output = resolve(productDirectory, name);
    await run("cwebp", ["-quiet", "-lossless", "-q", "100", "-m", "6", "-exact", source, "-o", output]);
    const bytes = await readFile(output);
    derivatives.push({ width, name, sha256: createHash("sha256").update(bytes).digest("hex") });
  }
  return derivatives;
}

await rm(svgDirectory, { recursive: true, force: true });
await rm(rasterDirectory, { recursive: true, force: true });
await rm(productDirectory, { recursive: true, force: true });
await rm(appStoreDirectory, { recursive: true, force: true });
await Promise.all([
  mkdir(svgDirectory, { recursive: true }),
  mkdir(rasterDirectory, { recursive: true }),
  mkdir(productDirectory, { recursive: true }),
  mkdir(appStoreDirectory, { recursive: true }),
]);

const catalog = await exportThemeCatalog();
const manifest = { ...geometry, files: [] };
let screenshotNumber = 1;

for (const variant of ["dark", "light"]) {
  for (const state of states) {
    const stem = `${state.id}-${variant}`;
    const svgPath = resolve(svgDirectory, `${stem}.svg`);
    const appStoreName = `${String(screenshotNumber).padStart(2, "0")}-${stem}.png`;
    const appStorePath = resolve(appStoreDirectory, appStoreName);
    const svg = masterSVG(state, variant, catalog);
    await writeFile(svgPath, svg);
    const background = variant === "dark" ? "#0d0f12" : "#f3f0e9";
    await rasterize(svgPath, appStorePath, background);
    const web = await webDerivatives(svgPath, appStorePath, state, variant, background);
    const bytes = await readFile(appStorePath);
    manifest.files.push({ state: state.id, variant, appStoreName, sha256: createHash("sha256").update(bytes).digest("hex"), web });
    screenshotNumber += 1;
  }
}

await writeFile(resolve(productDirectory, "campaign-geometry.json"), `${JSON.stringify(manifest, null, 2)}\n`);
await writeFile(
  resolve(appStoreDirectory, "README.md"),
  `# Mac App Store screenshots\n\nGenerated by \`npm run campaign\` from one fixed 2880 × 1800 SVG composition.\n\n- 01–05: dark appearance (Editor, Split, Terminal, PDF, Themes)\n- 06–10: light appearance (Editor, Split, Terminal, PDF, Themes)\n- Every file is an opaque RGB PNG.\n- Shared window, titlebar, traffic-light, sidebar, toolbar, and content-boundary geometry comes from \`website/scripts/generate-campaign.mjs\`.\n`,
);

console.log(`Generated ${manifest.files.length} aligned 2880 × 1800 campaign masters and website derivatives.`);
