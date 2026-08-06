import { createHash } from "node:crypto";
import { access, readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const expectedAssets = new Map([
  ["shots/icon-graphite.png", "caeea8d148e460babb768f9b99597cee91294b703c7e0c7bcdd567ac4b7c334a"],
  ["shots/macbook-pro.png", "42ab04218d7e3312a25dcc977fcdaa0787a91597c54337490ad5029b0aa8c129"],
  ["shots/editor-dark.jpg", "1aff6cf96c868f166cff17d2df4996087e146224953879d68af78b0227bc0319"],
  ["shots/split-dark.jpg", "67e104f82bca2df2b337f01b94c16ee8ddad348f3af1eae3fbd73a5e0fae2e1f"],
  ["shots/preview-dark.jpg", "09f7c9276e355c55d208b2d4c505f5f3cfeaebef17590f1fa5e0f1cb7d99baba"],
  ["shots/pdf-dark.jpg", "a083dcae5657283dace725e56e0ce9cdea7e35d9e9f83e6ca51fb036a1017b02"],
  ["shots/terminal-dark.jpg", "5eb6966a14d01c9efe98c2007d6e2e7017d692e34e2dfecfb5a34a74714ee864"],
  ["shots/editor-light.jpg", "ed301173e1314055a51be04229615f348227f7156675c33511d5ca1c1c8423e0"],
  ["shots/split-light.jpg", "442c94e679913c40ec3cd883bad93eb50e5a4555bd8458c98ce8df5660675872"],
  ["shots/preview-light.jpg", "362b4da1d50e300bee2620e7a5c6cdacf4f8ebc741aa4ef3c9c24ed42c1e3183"],
  ["shots/pdf-light.jpg", "275ea7146cda16cf336290fc25a9830921d9d3c9eb4d6a4d144991e5f86813d6"],
  ["shots/terminal-light.jpg", "285be266ac7f12a9c2f0b345b0b0047df5e2d5763be1687cca43c5b47823503a"],
]);

await Promise.all(["index.html", "support.html", "privacy.html", "styles.css", "main.js", "page.js", "theme-catalog.json", "vercel.json", ...expectedAssets.keys()].map((file) => access(resolve(root, file))));

for (const [file, expectedHash] of expectedAssets) {
  const data = await readFile(resolve(root, file));
  const actualHash = createHash("sha256").update(data).digest("hex");
  if (actualHash !== expectedHash) throw new Error(`Supplied asset changed: ${file}`);
}

const html = await readFile(resolve(root, "index.html"), "utf8");
const supportHTML = await readFile(resolve(root, "support.html"), "utf8");
const privacyHTML = await readFile(resolve(root, "privacy.html"), "utf8");
const styles = await readFile(resolve(root, "styles.css"), "utf8");
const script = await readFile(resolve(root, "main.js"), "utf8");
const pageScript = await readFile(resolve(root, "page.js"), "utf8");
const themeCatalog = JSON.parse(await readFile(resolve(root, "theme-catalog.json"), "utf8"));
const vercel = JSON.parse(await readFile(resolve(root, "vercel.json"), "utf8"));

if (vercel.buildCommand !== "npm run build" || vercel.outputDirectory !== "dist") {
  throw new Error("Website-level Vercel configuration must build and serve this directory.");
}
if (vercel.cleanUrls !== true || vercel.trailingSlash !== false) {
  throw new Error("Vercel must expose support.html and privacy.html as /support and /privacy.");
}

const requiredMarkup = [
  "Markdown, PDFs, and a terminal. One window.",
  "20 light presets. 31 dark.",
  'class="laptop-stage"',
  'class="laptop-screen"',
  'src="shots/macbook-pro.png"',
  'id="theme-list"',
  'id="theme-preview-window"',
  ...["editor", "split", "preview", "pdf", "terminal"].flatMap((view) => [
    `data-view="${view}" data-mode="dark"`,
    `data-view="${view}" data-mode="light"`,
    `id="tab-${view}"`,
  ]),
];

for (const marker of requiredMarkup) {
  if (!html.includes(marker)) throw new Error(`Missing supplied design element: ${marker}`);
}

for (const marker of ['href="/support">Support</a>', 'href="/privacy">Privacy</a>', "© 2026 Rojhat Toptamuş"]) {
  if (!html.includes(marker)) throw new Error(`Missing homepage footer element: ${marker}`);
}

const requiredPages = [
  {
    name: "support",
    html: supportHTML,
    markers: [
      "<title>Monknot Support</title>",
      'content="Get help with Monknot, report problems, or send feedback."',
      'rel="canonical" href="https://monknot.app/support"',
      "Monknot Support",
      'href="mailto:support@monknot.app"',
      "Common Issues",
      'href="/privacy"',
    ],
  },
  {
    name: "privacy",
    html: privacyHTML,
    markers: [
      "<title>Monknot Privacy Policy</title>",
      "Learn how Monknot handles files, local data, network requests, and support communications.",
      'rel="canonical" href="https://monknot.app/privacy"',
      "Last updated: August 6, 2026",
      "Data Monknot Processes",
      "Network Requests and Third-Party Services",
      "Analytics and Crash Reports",
      "Children’s Privacy",
      'href="mailto:support@monknot.app"',
    ],
  },
];

for (const page of requiredPages) {
  for (const marker of page.markers) {
    if (!page.html.includes(marker)) throw new Error(`Missing ${page.name} page element: ${marker}`);
  }
  if (!page.html.includes('href="/" aria-label="Monknot home"')) throw new Error(`${page.name} page must link back to the homepage.`);
  if (!page.html.includes('src="page.js"')) throw new Error(`${page.name} page must load appearance behavior.`);
}

for (const marker of [
  "aspect-ratio: 3860 / 2540",
  "left: 10.829%",
  "top: 11.339%",
  "width: 78.342%",
  "height: 77.323%",
  "max-width: 1120px",
  "height: 56px",
]) {
  if (!styles.includes(marker)) throw new Error(`Supplied geometry changed: ${marker}`);
}

if ((html.match(/class="product-shot/g) ?? []).length !== 10) throw new Error("Expected ten supplied product screenshots.");
if ((html.match(/role="tab"/g) ?? []).length !== 5) throw new Error("Expected five product tabs.");

if (themeCatalog.sourceVersion !== "monknot-theme-v3" || themeCatalog.light?.length !== 20 || themeCatalog.dark?.length !== 31) {
  throw new Error("Expected the complete canonical catalog of 20 light and 31 dark presets.");
}

const themeIDs = new Set();
for (const theme of [...themeCatalog.light, ...themeCatalog.dark]) {
  if (themeIDs.has(theme.id)) throw new Error(`Duplicate theme preset: ${theme.id}`);
  themeIDs.add(theme.id);
  for (const key of ["surface", "ink", "accent", "added", "skill"]) {
    if (!/^#[0-9a-f]{6}$/i.test(theme[key])) throw new Error(`Invalid ${key} color for ${theme.id}`);
  }
}

for (const marker of ['let previewMode = "light";', 'event.key === "ArrowDown"', 'event.key === "ArrowUp"', "event.preventDefault();", "preventScroll: true"]) {
  if (!script.includes(marker)) throw new Error(`Missing theme keyboard behavior: ${marker}`);
}


for (const marker of ["dataset.siteTheme", 'aria-pressed', 'theme-color']) {
  if (!pageScript.includes(marker)) throw new Error(`Missing legal-page appearance behavior: ${marker}`);
}

const localReferences = [html, supportHTML, privacyHTML].flatMap((pageHTML) =>
  Array.from(pageHTML.matchAll(/(?:src|href)="((?!https?:|mailto:|#)[^"]+)"/g), (match) => match[1])
);
await Promise.all(
  localReferences
    .filter((file) => file !== "/" && file !== "/support" && file !== "/privacy")
    .map((file) => access(resolve(root, file.replace(/^\//, ""))))
);

console.log(`Checked ${expectedAssets.size} untouched source assets, 10 product views, 51 theme presets, support and privacy routes, and deployment files.`);
