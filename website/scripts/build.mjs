import { cp, mkdir, rm } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const output = resolve(root, "dist");

await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });

for (const entry of ["index.html", "support.html", "privacy.html", "styles.css", "main.js", "page.js", "theme-catalog.json", "shots"]) {
  await cp(resolve(root, entry), resolve(output, entry), { recursive: true });
}

console.log(`Built deployable site in ${output}`);
