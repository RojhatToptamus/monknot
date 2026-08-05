import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { cp, mkdir, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { validateThemeCatalog } from "./theme-catalog.mjs";

const root = resolve(import.meta.dirname, "..");
const repository = resolve(root, "..");
const output = resolve(root, "dist");
const scratch = resolve(repository, ".build", "website-theme-export");
const moduleCache = resolve(scratch, "module-cache");
const run = promisify(execFile);

await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });

for (const entry of ["index.html", "styles.css", "main.js", "assets"]) {
  await cp(resolve(root, entry), resolve(output, entry), { recursive: true });
}

const { stdout } = await run(
  "swift",
  [
    "run",
    "--package-path",
    repository,
    "--scratch-path",
    scratch,
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

const themeCatalog = JSON.parse(stdout);
validateThemeCatalog(themeCatalog);
await writeFile(
  resolve(output, "assets", "theme-catalog.json"),
  `${JSON.stringify(themeCatalog, null, 2)}\n`,
);

console.log(`Built static site in ${output}`);
