import { access, readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const productViews = ["default", "split", "terminal", "pdf"];
const requiredFiles = [
  "index.html",
  "styles.css",
  "main.js",
  "assets/monknot-icon.png",
  ...productViews.flatMap((view) => [
    `assets/monknot-${view}.jpg`,
    `assets/monknot-${view}-1200.webp`,
    `assets/monknot-${view}-2400.webp`,
    `assets/monknot-${view}.webp`,
  ]),
];

await Promise.all(requiredFiles.map((file) => access(resolve(root, file))));

const html = await readFile(resolve(root, "index.html"), "utf8");
const requiredMarkup = [
  '<html lang="en"',
  '<main id="main-content" tabindex="-1">',
  'class="skip-link"',
  'id="theme-explorer" hidden',
  'class="site-appearance" hidden',
  'class="header-download"',
  'href="https://github.com/RojhatToptamus/monknot/releases"',
  'class="feature-tabs" role="tablist"',
  'id="feature-tab-default"',
  'id="feature-tab-split"',
  'id="feature-tab-terminal"',
  'id="feature-tab-pdf"',
  'id="product-shot-panel"',
  'id="product-image"',
  'role="tabpanel"',
  'tabindex="0"',
  'name="theme-variant"',
  'class="preview-editor"',
  'class="preview-source"',
  'class="preview-document"',
  'data-preview-theme-name',
  'id="terminal-palette"',
  'id="theme-details"',
  'aria-labelledby="terminal-palette-label"',
  '50+ themes.',
  'width="3600"',
  'height="2250"',
];

for (const marker of requiredMarkup) {
  if (!html.includes(marker)) throw new Error(`Missing required markup: ${marker}`);
}

for (const value of ["light", "dark"]) {
  const appearanceInput = new RegExp(
    `<input[^>]*name="site-appearance"[^>]*value="${value}"|<input[^>]*value="${value}"[^>]*name="site-appearance"`,
    "s",
  );
  if (!appearanceInput.test(html)) throw new Error(`Missing ${value} appearance control.`);
}

const ids = new Set(Array.from(html.matchAll(/\sid="([^"]+)"/g), (match) => match[1]));
const localAnchors = Array.from(html.matchAll(/href="#([^"]+)"/g), (match) => match[1]);
const productTabTags = Array.from(html.matchAll(/<button\b[^>]*\brole="tab"[^>]*>/g), (match) => match[0]);

if (productTabTags.length !== productViews.length) {
  throw new Error(`Expected ${productViews.length} product tabs, found ${productTabTags.length}.`);
}

productViews.forEach((view, index) => {
  const tag = productTabTags[index];
  for (const marker of [
    `id="feature-tab-${view}"`,
    `data-feature="${view}"`,
    'aria-controls="product-shot-panel"',
    `aria-selected="${index === 0}"`,
  ]) {
    if (!tag.includes(marker)) throw new Error(`Product tab ${view} is missing ${marker}.`);
  }

  if (index > 0 && !tag.includes('tabindex="-1"')) {
    throw new Error(`Inactive product tab ${view} must use roving tabindex.`);
  }
});

for (const anchor of localAnchors) {
  if (!ids.has(anchor)) throw new Error(`Link points to missing section: #${anchor}`);
}

if (/\b(lorem ipsum|placeholder|coming soon)\b/i.test(html)) {
  throw new Error("Placeholder copy remains in index.html");
}

for (const forbidden of [
  'id="appearance-proof"',
  'class="media-bar"',
  'class="traffic-light',
  "20 light presets. 31 dark.",
  "Real app",
  "working tree clean",
]) {
  if (html.includes(forbidden)) throw new Error(`Removed website content remains: ${forbidden}`);
}

const systemAppearanceInput =
  /<input[^>]*name="site-appearance"[^>]*value="system"|<input[^>]*value="system"[^>]*name="site-appearance"/s;
if (systemAppearanceInput.test(html)) {
  throw new Error("System appearance control remains in index.html");
}

if ((html.match(/<h1\b/g) ?? []).length !== 1) {
  throw new Error("Expected exactly one h1.");
}

if (html.includes('aria-describedby="theme-caption theme-details"')) {
  throw new Error("Theme select should not announce the full terminal palette on focus.");
}

const mainJavaScript = await readFile(resolve(root, "main.js"), "utf8");
if (!mainJavaScript.includes('fetch("assets/theme-catalog.json")')) {
  throw new Error("Theme explorer is not connected to the generated catalog.");
}

for (const marker of [
  'document.querySelectorAll(\'[role="tab"][data-feature]\')',
  'productShotPanel?.setAttribute("aria-labelledby"',
  'productShotPanel.setAttribute("aria-busy", "true")',
  "await preloadProductFeature(id)",
  "image.naturalWidth > 0",
  "productFeatureRequest",
  "setSelectedProductTab",
  "setupProductShowcase()",
  'document.querySelector("#terminal-palette")',
  'document.querySelectorAll("[data-preview-theme-name]")',
  "theme.palette.length",
  "terminalPalette.replaceChildren(fragment)",
  'document.querySelectorAll(\'input[name="site-appearance"]\')',
  "siteAppearance.hidden = false",
]) {
  if (!mainJavaScript.includes(marker)) {
    throw new Error(`Theme interactions are missing required behavior: ${marker}`);
  }
}

const styles = await readFile(resolve(root, "styles.css"), "utf8");
if (/\.(?:preview-titlebar|preview-tools|preview-workspace|preview-sidebar|preview-terminal|traffic-light|media-bar|window-chrome)\b/.test(styles)) {
  throw new Error("Removed simulated product UI selectors remain in styles.css.");
}

for (const marker of [".feature-tabs", ".preview-editor", ".preview-source", ".preview-document"]) {
  if (!styles.includes(marker)) throw new Error(`Missing required interface styling: ${marker}`);
}

if (styles.includes("transform: scale(0.998)")) {
  throw new Error("Product switching must not animate position or scale.");
}

console.log(`Checked ${requiredFiles.length} files and ${localAnchors.length} local links.`);
