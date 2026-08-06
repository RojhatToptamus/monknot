import { access, readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const productViews = ["default", "split", "terminal", "pdf"];
const appStoreScreenshots = [
  "01-markdown-editor-dark.png",
  "02-markdown-split-dark.png",
  "03-terminal-dark.png",
  "04-pdf-dark.png",
  "05-markdown-split-light.png",
  "06-markdown-editor-light.png",
].map((file) => `app-store-screenshots/${file}`);
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
  ...appStoreScreenshots,
];

await Promise.all(requiredFiles.map((file) => access(resolve(root, file))));

for (const file of appStoreScreenshots) {
  const png = await readFile(resolve(root, file));
  const isPNG =
    png.length >= 24 &&
    png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  if (!isPNG) throw new Error(`App Store screenshot is not a PNG: ${file}`);
  const width = png.readUInt32BE(16);
  const height = png.readUInt32BE(20);
  if (width !== 2560 || height !== 1600) {
    throw new Error(`App Store screenshot must be 2560 × 1600: ${file} is ${width} × ${height}`);
  }
  const colorType = png[25];
  if (colorType !== 2) {
    throw new Error(
      `App Store screenshot must be an RGB PNG without alpha: ${file} uses PNG color type ${colorType}`,
    );
  }
}

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
  'class="product-stage"',
  'id="product-stage-view"',
  'role="tabpanel"',
  'tabindex="0"',
  'name="theme-variant"',
  'class="preview-titlebar"',
  'class="preview-workspace"',
  'class="preview-sidebar"',
  'class="preview-editor"',
  'class="preview-source"',
  'class="preview-document"',
  'class="preview-window-controls"',
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
  "Absolutely",
  "codex-dark",
  "Real app",
  "working tree clean",
  'class="theme-tokens"',
  'id="terminal-palette"',
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
  'value?.sourceVersion !== "monknot-theme-v3"',
  'dark: "harbor-dark"',
  "productFeatureRequest",
  "setSelectedProductTab",
  "setupProductShowcase()",
  '"--preview-sidebar"',
  '"--preview-ink-2"',
  '"--preview-ink-3"',
  "theme.palette.length",
  'document.querySelectorAll(\'input[name="site-appearance"]\')',
  "siteAppearance.hidden = false",
]) {
  if (!mainJavaScript.includes(marker)) {
    throw new Error(`Theme interactions are missing required behavior: ${marker}`);
  }
}

const styles = await readFile(resolve(root, "styles.css"), "utf8");
if (/\.(?:preview-tools|preview-terminal|traffic-light|media-bar|window-chrome)\b/.test(styles)) {
  throw new Error("Removed simulated product UI selectors remain in styles.css.");
}

for (const marker of [
  ".feature-tabs",
  ".preview-titlebar",
  ".preview-workspace",
  ".preview-sidebar",
  ".preview-editor",
  ".preview-source",
  ".preview-document",
  ".preview-window-controls",
]) {
  if (!styles.includes(marker)) throw new Error(`Missing required interface styling: ${marker}`);
}

if (styles.includes("transform: scale(0.998)")) {
  throw new Error("Product switching must not animate position or scale.");
}

console.log(`Checked ${requiredFiles.length} files and ${localAnchors.length} local links.`);
