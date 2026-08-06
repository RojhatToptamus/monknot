import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { access, mkdir, readFile, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);
const root = resolve(import.meta.dirname, "..");
const repository = resolve(root, "..");
const productDirectory = resolve(root, "assets", "product");
const appStoreDirectory = resolve(root, "app-store-screenshots");
const verificationDirectory = resolve(repository, ".build", "website-campaign-verify");
const geometryPath = resolve(productDirectory, "campaign-geometry.json");
const geometry = JSON.parse(await readFile(geometryPath, "utf8"));

const acceptedSizes = new Set(["1280x800", "1440x900", "2560x1600", "2880x1800"]);
const expectedFrame = {
  x: 96,
  y: 128,
  width: 2688,
  height: 1576,
  radius: 36,
  titlebarHeight: 104,
  sidebarWidth: 448,
  toolbarHeight: 96,
  contentX: 544,
  contentY: 328,
  contentWidth: 2240,
  contentHeight: 1376,
};

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(geometry.schemaVersion === 1, "Unexpected campaign geometry schema.");
assert(geometry.canvas.width === 2880 && geometry.canvas.height === 1800, "Campaign canvas must be 2880 × 1800.");
for (const [key, value] of Object.entries(expectedFrame)) {
  assert(geometry.frame[key] === value, `Master frame ${key} must be ${value}; received ${geometry.frame[key]}.`);
}
assert(geometry.files.length === 10, `Expected 10 campaign masters; received ${geometry.files.length}.`);

for (const region of geometry.sharedRegions) {
  for (const key of ["x", "y", "width", "height"]) {
    assert(Number.isFinite(region[key]) && region[key] >= 0, `Invalid ${key} for shared region ${region.id}.`);
  }
  assert(region.x + region.width <= geometry.canvas.width, `Shared region ${region.id} exceeds canvas width.`);
  assert(region.y + region.height <= geometry.canvas.height, `Shared region ${region.id} exceeds canvas height.`);
}

for (const [state, slots] of Object.entries(geometry.stateSlots ?? {})) {
  assert(geometry.states.includes(state), `Unknown campaign state slot: ${state}.`);
  for (const slot of slots) {
    assert(slot.x >= geometry.frame.contentX, `${state} slot escapes the content area on the left.`);
    assert(slot.y >= geometry.frame.contentY, `${state} slot escapes the content area at the top.`);
    assert(slot.x + slot.width <= geometry.frame.contentX + geometry.frame.contentWidth, `${state} slot escapes the content area on the right.`);
    assert(slot.y + slot.height <= geometry.frame.contentY + geometry.frame.contentHeight, `${state} slot escapes the content area at the bottom.`);
  }
}

function pngMetadata(bytes) {
  assert(bytes.length >= 26, "PNG is too small.");
  assert(bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])), "Invalid PNG signature.");
  return {
    width: bytes.readUInt32BE(16),
    height: bytes.readUInt32BE(20),
    bitDepth: bytes[24],
    colorType: bytes[25],
  };
}

const filesByVariant = { dark: [], light: [] };
for (const file of geometry.files) {
  const path = resolve(appStoreDirectory, file.appStoreName);
  const bytes = await readFile(path);
  const metadata = pngMetadata(bytes);
  assert(acceptedSizes.has(`${metadata.width}x${metadata.height}`), `${file.appStoreName} is not an accepted App Store size.`);
  assert(metadata.width === 2880 && metadata.height === 1800, `${file.appStoreName} must use the 2880 × 1800 master size.`);
  assert(metadata.bitDepth === 8, `${file.appStoreName} must be 8-bit.`);
  assert(metadata.colorType === 2, `${file.appStoreName} must be RGB without alpha.`);
  const digest = createHash("sha256").update(bytes).digest("hex");
  assert(digest === file.sha256, `${file.appStoreName} no longer matches its generated manifest hash.`);
  filesByVariant[file.variant].push(path);

  for (const width of [960, 1920, 2880]) {
    const webPath = resolve(productDirectory, `${file.state}-${file.variant}-${width}.webp`);
    await access(webPath);
    const derivative = file.web?.find((candidate) => candidate.width === width);
    assert(derivative?.name === `${file.state}-${file.variant}-${width}.webp`, `Missing generated WebP manifest entry for ${webPath}.`);
    const webBytes = await readFile(webPath);
    assert(createHash("sha256").update(webBytes).digest("hex") === derivative.sha256, `${webPath} no longer matches its generated manifest hash.`);
    await run("dwebp", [webPath, "-o", "/dev/null"]);
    const { stdout } = await run("ffprobe", [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=width,height",
      "-of",
      "csv=s=x:p=0",
      webPath,
    ]);
    const expected = `${width}x${(width * 10) / 16}`;
    assert(stdout.trim() === expected, `${webPath} must be ${expected}; received ${stdout.trim()}.`);
  }
}

async function cropHash(path, crop) {
  const { stdout } = await run("ffmpeg", [
    "-v",
    "error",
    "-i",
    path,
    "-vf",
    `crop=${crop.width}:${crop.height}:${crop.x}:${crop.y},format=rgb24`,
    "-f",
    "hash",
    "-hash",
    "sha256",
    "-",
  ]);
  return stdout.trim();
}

const stableCrops = [
  { id: "top-edge", x: 96, y: 128, width: 2688, height: 4 },
  { id: "traffic-and-sidebar-control", x: 112, y: 144, width: 216, height: 72 },
  { id: "left-window-edge", x: 96, y: 128, width: 6, height: 1576 },
  { id: "sidebar-divider", x: 544, y: 232, width: 1, height: 1472 },
  { id: "right-window-edge", x: 2783, y: 164, width: 1, height: 1504 },
  { id: "bottom-window-edge", x: 132, y: 1703, width: 2616, height: 1 },
  { id: "titlebar-boundary", x: 96, y: 231, width: 2688, height: 2 },
  { id: "toolbar-boundary", x: 544, y: 327, width: 2240, height: 2 },
];

for (const [variant, files] of Object.entries(filesByVariant)) {
  assert(files.length === 5, `Expected five ${variant} campaign masters.`);
  for (const crop of stableCrops) {
    const hashes = await Promise.all(files.map((path) => cropHash(path, crop)));
    assert(new Set(hashes).size === 1, `${variant} ${crop.id} pixels shift or differ across campaign states.`);
  }
}

async function frameHash(path) {
  const { stdout } = await run("ffmpeg", [
    "-v",
    "error",
    "-i",
    path,
    "-vf",
    "format=rgb24",
    "-f",
    "hash",
    "-hash",
    "sha256",
    "-",
  ]);
  return stdout.trim();
}

await rm(verificationDirectory, { recursive: true, force: true });
await mkdir(verificationDirectory, { recursive: true });

for (const file of geometry.files) {
  const pngPath = resolve(appStoreDirectory, file.appStoreName);
  const webPath = resolve(productDirectory, `${file.state}-${file.variant}-2880.webp`);
  const decodedPath = resolve(verificationDirectory, `${file.state}-${file.variant}-decoded.png`);
  await run("dwebp", [webPath, "-o", decodedPath]);
  assert(await frameHash(pngPath) === await frameHash(decodedPath), `${webPath} does not decode pixel-identically to its App Store master.`);
  await rm(decodedPath, { force: true });
}

for (const [variant, files] of Object.entries(filesByVariant)) {
  const inputs = files.flatMap((path) => ["-i", path]);
  const filters = [
    "[0:v][1:v]blend=all_mode=average[a]",
    "[a][2:v]blend=all_mode=average[b]",
    "[b][3:v]blend=all_mode=average[c]",
    "[c][4:v]blend=all_mode=average,format=rgb24[out]",
  ].join(";");
  await run("ffmpeg", [
    "-y",
    "-loglevel",
    "error",
    ...inputs,
    "-filter_complex",
    filters,
    "-map",
    "[out]",
    "-frames:v",
    "1",
    resolve(verificationDirectory, `overlay-${variant}.png`),
  ]);
}

console.log(`Verified ${geometry.files.length} masters, ${geometry.files.length * 3} fully decoded/hash-checked vector WebPs, eight stable pixel regions per appearance, bounded state slots, pixel-identical full-size derivatives, and wrote alignment overlays to ${verificationDirectory}.`);
