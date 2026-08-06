import { createHash } from "node:crypto";
import { access, readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const expectedAssets = new Map([
  ["shots/icon-graphite.png", "5782830cc7547778000122cf9b46bf2218e0576eb06bfc9419f963aacebd49c0"],
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

await Promise.all(["index.html", "styles.css", "main.js", "vercel.json", ...expectedAssets.keys()].map((file) => access(resolve(root, file))));

for (const [file, expectedHash] of expectedAssets) {
  const data = await readFile(resolve(root, file));
  const actualHash = createHash("sha256").update(data).digest("hex");
  if (actualHash !== expectedHash) throw new Error(`Supplied asset changed: ${file}`);
}

const html = await readFile(resolve(root, "index.html"), "utf8");
const styles = await readFile(resolve(root, "styles.css"), "utf8");
const script = await readFile(resolve(root, "main.js"), "utf8");
const vercel = JSON.parse(await readFile(resolve(root, "vercel.json"), "utf8"));

if (vercel.buildCommand !== "npm run build" || vercel.outputDirectory !== "dist") {
  throw new Error("Website-level Vercel configuration must build and serve this directory.");
}

const requiredMarkup = [
  "Markdown, PDFs, and a terminal. One window.",
  "Thirteen themes, 22 variants.",
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
if ((script.match(/name: "/g) ?? []).length !== 13) throw new Error("Expected the supplied thirteen-theme catalog.");
if (!script.includes('let activeTheme = 3;') || !script.includes('let previewMode = "light";')) {
  throw new Error("The supplied Axis Light preview state changed.");
}

const localReferences = Array.from(html.matchAll(/(?:src|href)="((?!https?:|#)[^"]+)"/g), (match) => match[1]);
await Promise.all(localReferences.map((file) => access(resolve(root, file))));

console.log(`Checked ${expectedAssets.size} untouched source assets, 10 product views, 13 themes, and deployment files.`);
