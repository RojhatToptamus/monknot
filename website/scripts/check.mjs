import { access, readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const requiredFiles = [
  "index.html",
  "styles.css",
  "main.js",
  "assets/monknot-icon.png",
  "assets/monknot-light.jpg",
  "assets/monknot-light-1200.webp",
  "assets/monknot-light-2400.webp",
  "assets/monknot-light.webp",
  "assets/monknot-dark.jpg",
  "assets/monknot-dark-1200.webp",
  "assets/monknot-dark-2400.webp",
  "assets/monknot-dark.webp",
];

await Promise.all(requiredFiles.map((file) => access(resolve(root, file))));

const html = await readFile(resolve(root, "index.html"), "utf8");
const requiredMarkup = [
  '<html lang="en"',
  '<main id="main-content" tabindex="-1">',
  'class="skip-link"',
  'id="theme-explorer" hidden',
  'id="appearance-proof"',
  'class="site-appearance" hidden',
  'name="site-appearance" value="system"',
  'name="site-appearance" value="light"',
  'name="site-appearance" value="dark"',
  'name="theme-variant"',
  'id="terminal-palette"',
  'id="theme-details"',
  'aria-labelledby="terminal-palette-label"',
  '20 light presets.',
  '31 dark.',
  'width="3600"',
  'height="2250"',
];

for (const marker of requiredMarkup) {
  if (!html.includes(marker)) throw new Error(`Missing required markup: ${marker}`);
}

const ids = new Set(Array.from(html.matchAll(/\sid="([^"]+)"/g), (match) => match[1]));
const localAnchors = Array.from(html.matchAll(/href="#([^"]+)"/g), (match) => match[1]);

for (const anchor of localAnchors) {
  if (!ids.has(anchor)) throw new Error(`Link points to missing section: #${anchor}`);
}

if (/\b(lorem ipsum|placeholder|coming soon)\b/i.test(html)) {
  throw new Error("Placeholder copy remains in index.html");
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
  'document.querySelector("#terminal-palette")',
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
if (/\.(?:preview-titlebar|preview-tools|preview-workspace|preview-sidebar|preview-editor|preview-document|preview-source|preview-terminal)\b/.test(styles)) {
  throw new Error("Removed simulated product UI selectors remain in styles.css.");
}

console.log(`Checked ${requiredFiles.length} files and ${localAnchors.length} local links.`);
