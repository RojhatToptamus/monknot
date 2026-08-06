import { access, readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const productViews = ["default", "split", "terminal", "pdf", "themes"];
const variants = ["dark", "light"];
const geometry = JSON.parse(await readFile(resolve(root, "assets/product/campaign-geometry.json"), "utf8"));
const appStoreScreenshots = geometry.files.map((file) => `app-store-screenshots/${file.appStoreName}`);
const requiredFiles = [
  "index.html",
  "styles.css",
  "main.js",
  "assets/monknot-icon.png",
  "assets/product/campaign-geometry.json",
  ...productViews.flatMap((view) =>
    variants.flatMap((variant) =>
      [960, 1920, 2880].map((width) => `assets/product/${view}-${variant}-${width}.webp`),
    ),
  ),
  ...appStoreScreenshots,
];

await Promise.all(requiredFiles.map((file) => access(resolve(root, file))));

if (geometry.canvas.width !== 2880 || geometry.canvas.height !== 1800) {
  throw new Error("Campaign master canvas must be 2880 × 1800.");
}

const expectedFrame = {
  x: 96,
  y: 128,
  width: 2688,
  height: 1576,
  titlebarHeight: 104,
  sidebarWidth: 448,
  toolbarHeight: 96,
  contentX: 544,
  contentY: 328,
  contentWidth: 2240,
  contentHeight: 1376,
};
for (const [key, value] of Object.entries(expectedFrame)) {
  if (geometry.frame[key] !== value) {
    throw new Error(`Campaign frame ${key} must remain ${value}; received ${geometry.frame[key]}.`);
  }
}

if (geometry.files.length !== 10) throw new Error("Expected ten generated App Store masters.");

for (const file of appStoreScreenshots) {
  const png = await readFile(resolve(root, file));
  const isPNG =
    png.length >= 26 &&
    png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  if (!isPNG) throw new Error(`App Store screenshot is not a PNG: ${file}`);
  const width = png.readUInt32BE(16);
  const height = png.readUInt32BE(20);
  const bitDepth = png[24];
  const colorType = png[25];
  if (width !== 2880 || height !== 1800) {
    throw new Error(`App Store screenshot must be 2880 × 1800: ${file} is ${width} × ${height}`);
  }
  if (bitDepth !== 8 || colorType !== 2) {
    throw new Error(`App Store screenshot must be an opaque 8-bit RGB PNG: ${file}`);
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
  ...productViews.map((view) => `id="feature-tab-${view}"`),
  'id="product-shot-panel"',
  'id="product-image"',
  'role="tabpanel"',
  'tabindex="0"',
  'name="theme-variant"',
  'class="preview-titlebar"',
  'class="preview-workspace"',
  'class="preview-sidebar"',
  'class="preview-editor"',
  'class="preview-window-controls"',
  "50+ themes",
  'width="2880"',
  'height="1800"',
  "Brasspants",
  "Codechimp",
  "Greaseball",
  "Sockpuppet",
  "Forge",
  "Parchment",
  "Monolith",
];

for (const marker of requiredMarkup) {
  if (!html.includes(marker)) throw new Error(`Missing required markup: ${marker}`);
}

for (const value of variants) {
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
  'class="product-stage__bar"',
  'class="media-bar"',
  'class="traffic-light',
  "20 light presets. 31 dark.",
  "Absolutely",
  "codex-dark",
  "Real app",
  "working tree clean",
  "Project-Borealis",
  'class="theme-tokens"',
]) {
  if (html.includes(forbidden)) throw new Error(`Removed website content remains: ${forbidden}`);
}

if ((html.match(/<h1\b/g) ?? []).length !== 1) throw new Error("Expected exactly one h1.");

const mainJavaScript = await readFile(resolve(root, "main.js"), "utf8");
for (const marker of [
  'fetch("assets/theme-catalog.json")',
  'document.querySelectorAll(\'[role="tab"][data-feature]\')',
  'productShotPanel?.setAttribute("aria-labelledby"',
  'productShotPanel.setAttribute("aria-busy", "true")',
  "await preloadProductFeature(id, appearance)",
  "image.naturalWidth > 0",
  'value?.sourceVersion !== "monknot-theme-v3"',
  'default: "01"',
  'default: "06"',
  '"brasspants-dark"',
  '"codechimp-dark"',
  '"greaseball-dark"',
  '"sockpuppet-dark"',
  '"forge-dark"',
  '"parchment-dark"',
  '"monolith-dark"',
  '"--preview-sidebar"',
  '"--preview-selection"',
  "setupProductShowcase()",
  "setupThemeExplorer()",
]) {
  if (!mainJavaScript.includes(marker)) {
    throw new Error(`Website interactions are missing required behavior: ${marker}`);
  }
}

const styles = await readFile(resolve(root, "styles.css"), "utf8");
for (const marker of [
  ".feature-tabs",
  ".product-shot",
  "aspect-ratio: 16 / 10",
  ".preview-titlebar",
  ".preview-workspace",
  ".preview-sidebar",
  ".preview-editor",
  ".preview-window-controls",
]) {
  if (!styles.includes(marker)) throw new Error(`Missing required interface styling: ${marker}`);
}

for (const forbidden of [
  "aspect-ratio: 3600 / 2209",
  "translateY(-1.822222%)",
  "height: 101.856044%",
  ".product-stage__bar",
]) {
  if (styles.includes(forbidden)) throw new Error(`Legacy screenshot patch remains: ${forbidden}`);
}

console.log(`Checked ${requiredFiles.length} files, ${appStoreScreenshots.length} App Store masters, ${productViews.length} product tabs, and ${localAnchors.length} local links.`);
