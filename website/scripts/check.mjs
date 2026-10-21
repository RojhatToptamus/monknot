import { createHash } from "node:crypto";
import { access, readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const canonicalURL = "https://monknot.app/";
const releasesURL = "https://github.com/RojhatToptamus/monknot/releases";
const expectedAssets = new Map([
  ["icons/apple-touch-icon.png", "1e95f8ecd2186e67e1c33dd37dee8ad8ebab2f480c8091c775bfa9f9b89bc55e"],
  ["icons/brand-icon.png", "8a63a843862321a96613f0a619ae2687153e968daa467af432e6b0d47f69336d"],
  ["icons/favicon-64.png", "8a63a843862321a96613f0a619ae2687153e968daa467af432e6b0d47f69336d"],
  ["social/monknot-social.jpg", "0bffeee4fd414f06c522caec55244d8e740c15030dbe43f4728a16cc208c74bc"],
  ["shots/icon-graphite.png", "caeea8d148e460babb768f9b99597cee91294b703c7e0c7bcdd567ac4b7c334a"],
  ["shots/macbook-pro.png", "42ab04218d7e3312a25dcc977fcdaa0787a91597c54337490ad5029b0aa8c129"],
  ["shots/editor-dark.jpg", "9f7753a40fdd7d7bfa4ce6fd960a7e24eabc8a3e07573b364f44b6a4117c5fe9"],
  ["shots/split-dark.jpg", "aea19ab16046af89f19c2ecec3cfa1c98de369fd5dfd4fb1e9b2298419b1f42a"],
  ["shots/preview-dark.jpg", "c90b7e8d345effb7de678c91b5af5765ac4c0217a2770507a87fafc646dd607c"],
  ["shots/pdf-dark.jpg", "5eb184ea9be32484ff0482e8650b7179db5a86f65b54f30251a0cdb0a4160647"],
  ["shots/terminal-dark.jpg", "68f80fa59123682eecefaae151070cc94198e457f5d074d159a4f178173f204a"],
  ["shots/editor-light.jpg", "8bd2f02456aa1d80c5ca1a82795e669610780f7b5964ec42826f3ba1453847ee"],
  ["shots/split-light.jpg", "c89f9a48b0abb8b0936ed1c7ebc858cbadfbcbcbecadedd2c4f8e7c24fd6831d"],
  ["shots/preview-light.jpg", "19fec5fc032cf48620949ca7743bbe4090a7d10d8c7780f00dfb1c56154f8d0f"],
  ["shots/pdf-light.jpg", "75fac9790f228089f29beb51748ebc0f51719981a6b723a8f45f10e71c91cc95"],
  ["shots/terminal-light.jpg", "8e6cdfb518aec6bcad336e9c1b566003555d15e92a74b470d80fd45fe0cd943f"],
  ["shots/writing-assistance.gif", "7e69e0bd9dc893ab6185ef0c55b07d36c58b0f9891fdd4f7c9b17710e41f07dc"],
  ["shots/writing-assistance-poster.png", "72cb0c81bf82980fd7f65f882c55738e7009673c6429b7f6c8588db2256d313a"],
  ["shots/writing-assistance-light.gif", "e96667d07e75f64850f32a33349b9854edb67d661290cae313fb3bc9fb9b50f9"],
  ["shots/writing-assistance-light-poster.png", "8c2fcf300772d1b8b4bcbf9006f7ef362ff0ab3250d45f95b61adb14c3bbfe25"],
]);

await Promise.all(["index.html", "support.html", "privacy.html", "styles.css", "main.js", "page.js", "theme-catalog.json", "robots.txt", "sitemap.xml", "vercel.json", ...expectedAssets.keys()].map((file) => access(resolve(root, file))));

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
const robots = await readFile(resolve(root, "robots.txt"), "utf8");
const sitemap = await readFile(resolve(root, "sitemap.xml"), "utf8");
const vercel = JSON.parse(await readFile(resolve(root, "vercel.json"), "utf8"));

if (vercel.buildCommand !== "npm run build" || vercel.outputDirectory !== "dist") {
  throw new Error("Website-level Vercel configuration must build and serve this directory.");
}
if (vercel.cleanUrls !== true || vercel.trailingSlash !== false) {
  throw new Error("Vercel must expose support.html and privacy.html as /support and /privacy.");
}
const expectedAppcastRedirect = {
  source: "/updates/appcast.xml",
  destination: "https://github.com/RojhatToptamus/monknot/releases/latest/download/appcast.xml",
  permanent: false,
};
if (vercel.redirects?.length !== 1 || Object.entries(expectedAppcastRedirect).some(([key, value]) => vercel.redirects[0][key] !== value)) {
  throw new Error("Vercel must redirect the stable Sparkle feed to the latest GitHub Release appcast.");
}

const requiredMarkup = [
  "Edit Markdown, annotate PDFs, and run terminal sessions.",
  "19 light presets. 30 dark.",
  "<title>Monknot: Markdown Editor, PDF Tools, and Terminal</title>",
  'name="application-name" content="Monknot"',
  'name="description"',
  'content="Edit local Markdown and text files, preview and export Markdown, annotate PDFs, and run terminal sessions with optional on-device writing assistance."',
  'property="og:title" content="Monknot: Markdown Editor, PDF Tools, and Terminal"',
  'property="og:description" content="Edit local Markdown and text files, preview and export Markdown, annotate PDFs, and run terminal sessions with optional on-device writing assistance."',
  'name="robots" content="index, follow, max-image-preview:large"',
  `rel="canonical" href="${canonicalURL}"`,
  'property="og:type" content="website"',
  'property="og:site_name" content="Monknot"',
  'property="og:locale" content="en_US"',
  `property="og:url" content="${canonicalURL}"`,
  'property="og:image" content="https://monknot.app/social/monknot-social.jpg"',
  'property="og:image:type" content="image/jpeg"',
  'property="og:image:width" content="1200"',
  'property="og:image:height" content="630"',
  'property="og:image:alt" content="Monknot editing README.md in Preview in dark mode, with the block menu open below a to-do list."',
  'name="twitter:card" content="summary_large_image"',
  'name="twitter:title" content="Monknot: Markdown Editor, PDF Tools, and Terminal"',
  'name="twitter:description" content="Edit local Markdown and text files, preview and export Markdown, annotate PDFs, and run terminal sessions with optional on-device writing assistance."',
  'name="twitter:image" content="https://monknot.app/social/monknot-social.jpg"',
  'name="twitter:image:alt" content="Monknot editing README.md in Preview in dark mode, with the block menu open below a to-do list."',
  'rel="icon" type="image/png" sizes="64x64" href="icons/favicon-64.png"',
  'rel="apple-touch-icon" sizes="180x180" href="icons/apple-touch-icon.png"',
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
  'data-view="writing" data-mode="dark"',
  'data-view="writing" data-mode="light"',
  'data-static-src="shots/writing-assistance-poster.png"',
  'data-animated-src="shots/writing-assistance.gif"',
  'data-static-src="shots/writing-assistance-light-poster.png"',
  'data-animated-src="shots/writing-assistance-light.gif"',
  'id="tab-writing"',
  'class="writing-demo-toggle"',
];

for (const marker of requiredMarkup) {
  if (!html.includes(marker)) throw new Error(`Missing supplied design element: ${marker}`);
}

if ((html.match(/rel="canonical"/g) ?? []).length !== 1) throw new Error("Expected one canonical URL.");
if (/name=["']keywords["']/i.test(html)) throw new Error("Do not add obsolete keyword metadata.");

const structuredDataMatch = html.match(/<script type="application\/ld\+json">\s*([\s\S]*?)\s*<\/script>/);
if (!structuredDataMatch) throw new Error("Missing WebSite structured data.");
const structuredData = JSON.parse(structuredDataMatch[1]);
if (structuredData["@context"] !== "https://schema.org" || structuredData["@type"] !== "WebSite" || structuredData.name !== "Monknot" || structuredData.url !== canonicalURL) {
  throw new Error("WebSite structured data must match the canonical Monknot identity.");
}
if ("aggregateRating" in structuredData || "review" in structuredData) throw new Error("Do not publish unverified ratings or reviews.");

if (robots.trim() !== `User-agent: *\nAllow: /\n\nSitemap: ${canonicalURL}sitemap.xml`) {
  throw new Error("robots.txt must allow crawling and reference the canonical sitemap.");
}
const sitemapLocations = Array.from(sitemap.matchAll(/<loc>([^<]+)<\/loc>/g), (match) => match[1]);
const expectedSitemapLocations = [canonicalURL, `${canonicalURL}support`, `${canonicalURL}privacy`];
if (sitemapLocations.length !== expectedSitemapLocations.length || expectedSitemapLocations.some((location) => !sitemapLocations.includes(location))) {
  throw new Error("sitemap.xml must contain the canonical homepage, support, and privacy URLs.");
}

for (const marker of [
  'href="/support">Support</a>',
  'href="/privacy">Privacy</a>',
  '© 2026 <a href="https://rojhat.com">Rojhat Toptamuş</a>',
]) {
  if (!html.includes(marker)) throw new Error(`Missing homepage footer element: ${marker}`);
}

for (const marker of [
  'class="download-meta"',
  'class="download-version" hidden',
  'class="download-started" hidden',
  'class="closing-download"',
  'class="closing-version"',
  '<a href="https://github.com/RojhatToptamus/monknot/releases">Releases</a>',
]) {
  if (!html.includes(marker)) throw new Error(`Missing direct-download element: ${marker}`);
}

if ((html.match(/class="primary-download"/g) ?? []).length !== 2) throw new Error("Expected a download button in the hero and at the end of the page.");

const downloadControls = Array.from(html.matchAll(/<a\b[^>]*class="(?:header-download|primary-download)"[^>]*>/g), (match) => match[0]);
if (downloadControls.length !== 3 || downloadControls.some((control) => !control.includes(`href="${releasesURL}"`))) {
  throw new Error("Each download control must ship pointing at the releases page until the latest build resolves.");
}

for (const marker of [
  "https://api.github.com/repos/RojhatToptamus/monknot/releases/latest",
  "browser_download_url",
  "dataset.directDownload",
]) {
  if (!script.includes(marker)) throw new Error(`Missing direct-download behavior: ${marker}`);
}

const requiredPages = [
  {
    name: "support",
    html: supportHTML,
    markers: [
      "<title>Monknot Support: Files, PDFs, and Terminal</title>",
      'name="application-name" content="Monknot"',
      'content="Get help with file access, PDF search, terminal errors, feedback, and bug reports in Monknot."',
      'property="og:title" content="Monknot Support: Files, PDFs, and Terminal"',
      'property="og:description" content="Get help with file access, PDF search, terminal errors, feedback, and bug reports in Monknot."',
      'name="twitter:title" content="Monknot Support: Files, PDFs, and Terminal"',
      'name="twitter:description" content="Get help with file access, PDF search, terminal errors, feedback, and bug reports in Monknot."',
      'property="og:image:type" content="image/jpeg"',
      'property="og:image:alt" content="Monknot editing README.md in Preview in dark mode, with the block menu open below a to-do list."',
      'name="twitter:image:alt" content="Monknot editing README.md in Preview in dark mode, with the block menu open below a to-do list."',
      'name="robots" content="index, follow, max-image-preview:large"',
      'rel="canonical" href="https://monknot.app/support"',
      'property="og:url" content="https://monknot.app/support"',
      'name="twitter:card" content="summary_large_image"',
      "Monknot Support",
      'href="mailto:support@monknot.app"',
      "Steps that reproduce the problem",
      "Common problems",
      "Monknot Privacy Policy",
      'href="/privacy"',
    ],
  },
  {
    name: "privacy",
    html: privacyHTML,
    markers: [
      "<title>Monknot Privacy Policy: Local Files and App Data</title>",
      'name="application-name" content="Monknot"',
      "Read how Monknot handles local files, writing assistance, terminal data, software updates, website analytics, and support email.",
      'property="og:title" content="Monknot Privacy Policy: Local Files and App Data"',
      'property="og:description" content="Read how Monknot handles local files, writing assistance, terminal data, software updates, website analytics, and support email."',
      'name="twitter:title" content="Monknot Privacy Policy: Local Files and App Data"',
      'name="twitter:description" content="Read how Monknot handles local files, writing assistance, terminal data, software updates, website analytics, and support email."',
      'property="og:image:type" content="image/jpeg"',
      'property="og:image:alt" content="Monknot editing README.md in Preview in dark mode, with the block menu open below a to-do list."',
      'name="twitter:image:alt" content="Monknot editing README.md in Preview in dark mode, with the block menu open below a to-do list."',
      'name="robots" content="index, follow, max-image-preview:large"',
      'rel="canonical" href="https://monknot.app/privacy"',
      'property="og:url" content="https://monknot.app/privacy"',
      'name="twitter:card" content="summary_large_image"',
      "Last updated: August 26, 2026",
      "Files and Documents",
      "Local Application Data",
      "Writing Assistance",
      "Terminal Sessions",
      "Network Connections",
      "Software Updates",
      "Analytics and Crash Reporting",
      "Data Sharing",
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

if ((html.match(/class="product-shot/g) ?? []).length !== 12) throw new Error("Expected ten screenshots and two writing-assistance demos.");
if ((html.match(/role="tab"/g) ?? []).length !== 6) throw new Error("Expected six product tabs.");
const writingMedia = [...html.matchAll(/<img class="product-shot" data-view="writing"[^>]+>/g)].map((match) => match[0]);
if (writingMedia.length !== 2 || writingMedia.some((media) => !media.includes('width="1600" height="1039"'))) {
  throw new Error("Writing-assistance media must keep its fixed 1600 by 1039 dimensions.");
}

if (themeCatalog.sourceVersion !== "monknot-theme-v4" || themeCatalog.light?.length !== 19 || themeCatalog.dark?.length !== 30) {
  throw new Error("Expected the complete canonical catalog of 19 light and 30 dark presets.");
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

for (const marker of ['window.matchMedia("(prefers-reduced-motion: reduce)")', "shot.dataset.animatedSrc", 'reducedMotion.addEventListener("change", renderProductView)', 'writingDemoToggle.addEventListener("click"']) {
  if (!script.includes(marker)) throw new Error(`Missing writing-demo behavior: ${marker}`);
}


for (const marker of ["dataset.siteTheme", 'aria-pressed', 'theme-color']) {
  if (!pageScript.includes(marker)) throw new Error(`Missing legal-page appearance behavior: ${marker}`);
}

const localReferences = [html, supportHTML, privacyHTML].flatMap((pageHTML) =>
  Array.from(pageHTML.matchAll(/(?:src|href)="((?!https?:|mailto:|#)[^"]+)"/g), (match) => match[1])
);
await Promise.all(
  localReferences
    .filter((file) => file !== "/" && file !== "/support" && file !== "/privacy" && !file.startsWith("/_vercel/"))
    .map((file) => access(resolve(root, file.replace(/^\//, ""))))
);

console.log(`Checked ${expectedAssets.size} assets, complete SEO metadata, six product views backed by 12 media elements, 49 theme presets, the direct-download flow and its releases-page fallback, support and privacy routes, and deployment files.`);
