const THEMES = [
  { name: "Harbor", dark: { surface: "#121212", ink: "#ebebeb", accent: "#5399ea", ok: "#65c387", skill: "#c092e7" }, light: { surface: "#fdfdfe", ink: "#1c1e22", accent: "#0a52a3", ok: "#277c4c", skill: "#7436ab" } },
  { name: "Parchment", dark: { surface: "#14120f", ink: "#ede9e3", accent: "#cbb072", ok: "#65c387", skill: "#dc92e7" }, light: { surface: "#f7f4ed", ink: "#241b12", accent: "#876a26", ok: "#277c4c", skill: "#9b36ab" } },
  { name: "Forge", dark: { surface: "#0c1118", ink: "#e6ebef", accent: "#5c91e0", ok: "#65c387", skill: "#bd92e7" }, light: { surface: "#f9fafb", ink: "#191f29", accent: "#13499a", ok: "#277c4c", skill: "#7036ab" } },
  { name: "Axis", dark: { surface: "#111013", ink: "#e4e3e8", accent: "#7e6dd0", ok: "#65c387", skill: "#d692e7" }, light: { surface: "#f6f6f9", ink: "#1d1c26", accent: "#321f8e", ok: "#277c4c", skill: "#9336ab" } },
  { name: "Paper", dark: { surface: "#171717", ink: "#e9e9e7", accent: "#7da0bf", ok: "#65c387", skill: "#b792e7" }, light: { surface: "#fdfdfc", ink: "#22201d", accent: "#2f597f", ok: "#277c4c", skill: "#6836ab" } },
  { name: "Signal", dark: { surface: "#141010", ink: "#ebe6e5", accent: "#e86354", ok: "#65c387", skill: "#cb92e7" }, light: { surface: "#fcf9f8", ink: "#271d1b", accent: "#a11b0c", ok: "#277c4c", skill: "#8436ab" } },
  { name: "Monolith", dark: { surface: "#0a0a0a", ink: "#ededed", accent: "#c7c7c7", ok: "#65c387", skill: "#c292e7" }, light: { surface: "#fdfdfd", ink: "#1a1a1a", accent: "#424242", ok: "#277c4c", skill: "#7836ab" } },
  { name: "Workbench", dark: { surface: "#12171c", ink: "#e1e6ea", accent: "#6aacd2", ok: "#65c387", skill: "#b792e7" }, light: { surface: "#f6f7f9", ink: "#181e25", accent: "#1d6690", ok: "#277c4c", skill: "#6836ab" } },
  { name: "Blueprint", dark: { surface: "#0b101d", ink: "#dee3ed", accent: "#5678e6", ok: "#65c387", skill: "#d192e7" }, light: { surface: "#e9edf7", ink: "#111a30", accent: "#0c2fa1", ok: "#277c4c", skill: "#8b36ab" } },
  { name: "Lagoon", dark: { surface: "#0d191c", ink: "#e0e9eb", accent: "#62dace", ok: "#65c387", skill: "#a392e7" } },
  { name: "Phosphor", dark: { surface: "#0b0f0c", ink: "#dbe6de", accent: "#62da86", ok: "#65c387", skill: "#ba92e7" } },
  { name: "Citrus", dark: { surface: "#161612", ink: "#efefe7", accent: "#e4db58", ok: "#65c387", skill: "#e792d1" } },
  { name: "Watchtower", dark: { surface: "#141019", ink: "#e3dfe7", accent: "#a966d6", ok: "#65c387", skill: "#c592e7" } },
];

const VIEWS = [
  { id: "editor", caption: "Markdown source, with a formatting bar when you want one." },
  { id: "split", caption: "Source and rendered preview, scrolled together." },
  { id: "preview", caption: "The rendered document, with the outline rail at the right edge." },
  { id: "pdf", caption: "Read, search, and mark up: highlight, underline, strike through, draw." },
  { id: "terminal", caption: "Real shell sessions in the workspace folder, beside the document." },
];

const root = document.documentElement;
const body = document.body;
const siteFrame = document.querySelector("#site-frame");
const themeColor = document.querySelector("#theme-color");
const siteModeButtons = Array.from(document.querySelectorAll("[data-site-mode]"));
const previewModeButtons = Array.from(document.querySelectorAll("[data-preview-mode]"));
const productTabs = Array.from(document.querySelectorAll(".product-tabs [role='tab']"));
const productShots = Array.from(document.querySelectorAll(".product-shot"));
const productPanel = document.querySelector("#product-panel");
const productCaption = document.querySelector(".product-caption");
const themeList = document.querySelector("#theme-list");
const previewThemeName = document.querySelector("#preview-theme-name");
const previewThemeMeta = document.querySelector("#preview-theme-meta");
const themePreviewWindow = document.querySelector("#theme-preview-window");
const themeAnnouncement = document.querySelector("#theme-announcement");

let activeView = 0;
let siteMode = "dark";
let activeTheme = 3;
let previewMode = "light";

function rgbOf(hex) {
  let value = hex.replace("#", "");
  if (value.length === 3) value = value.split("").map((character) => character + character).join("");
  const number = Number.parseInt(value, 16);
  return [(number >> 16) & 255, (number >> 8) & 255, number & 255];
}

function toHex(values) {
  return `#${values.map((value) => Math.round(value).toString(16).padStart(2, "0")).join("")}`;
}

function mix(first, second, amount) {
  const from = rgbOf(first);
  const to = rgbOf(second);
  return toHex([0, 1, 2].map((index) => from[index] + (to[index] - from[index]) * amount));
}

function rgba(hex, alpha) {
  const [red, green, blue] = rgbOf(hex);
  return `rgba(${red},${green},${blue},${alpha})`;
}

function over(ink, surface, alpha) {
  const foreground = rgbOf(ink);
  const background = rgbOf(surface);
  return toHex([0, 1, 2].map((index) => foreground[index] * alpha + background[index] * (1 - alpha)));
}

function luminance(hex) {
  const values = rgbOf(hex).map((value) => {
    const channel = value / 255;
    return channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2];
}

function contrast(first, second) {
  const firstLuminance = luminance(first);
  const secondLuminance = luminance(second);
  return (Math.max(firstLuminance, secondLuminance) + 0.05) / (Math.min(firstLuminance, secondLuminance) + 0.05);
}

function readable(color, grounds, ink, target) {
  for (let amount = 0; amount <= 0.9001; amount += 0.02) {
    const candidate = mix(color, ink, amount);
    if (grounds.every((ground) => contrast(candidate, ground) >= target)) return candidate;
  }
  return ink;
}

function siteTokens(palette) {
  const dark = luminance(palette.surface) < 0.45;
  const sidebar = mix(palette.surface, palette.ink, dark ? 0.075 : 0.028);
  const surfaceRaised = mix(palette.surface, palette.ink, dark ? 0.11 : 0.05);
  const grounds = [palette.surface, sidebar, surfaceRaised];
  return {
    "--bg": palette.surface,
    "--sidebar": sidebar,
    "--surf2": surfaceRaised,
    "--bar": rgba(palette.surface, 0.82),
    "--ink": palette.ink,
    "--ink2": readable(over(palette.ink, palette.surface, 0.62), grounds, palette.ink, 4.5),
    "--ink3": readable(over(palette.ink, palette.surface, 0.4), grounds, palette.ink, 3),
    "--line": rgba(palette.ink, dark ? 0.09 : 0.12),
    "--line2": rgba(palette.ink, dark ? 0.06 : 0.08),
    "--hover": rgba(palette.ink, dark ? 0.06 : 0.055),
    "--accent": palette.accent,
    "--onaccent": contrast("#ffffff", palette.accent) >= contrast("#101010", palette.accent) ? "#ffffff" : "#101010",
    "--accsoft": rgba(palette.accent, dark ? 0.18 : 0.14),
    "--sel": mix(palette.surface, palette.accent, dark ? 0.28 : 0.2),
    "--link": readable(palette.accent, grounds, palette.ink, 4.5),
    "--win": dark
      ? "0 30px 70px rgba(0,0,0,.55),0 8px 20px rgba(0,0,0,.35)"
      : `0 24px 56px ${rgba(mix(palette.ink, palette.accent, 0.1), 0.16)},0 6px 14px ${rgba(mix(palette.ink, palette.accent, 0.1), 0.07)}`,
  };
}

function previewTokens(palette) {
  const dark = luminance(palette.surface) < 0.45;
  const sidebar = mix(palette.surface, palette.ink, dark ? 0.075 : 0.028);
  const surfaceRaised = mix(palette.surface, palette.ink, dark ? 0.11 : 0.05);
  const grounds = [palette.surface, sidebar, surfaceRaised];
  return {
    "--tp-bg": palette.surface,
    "--tp-sidebar": sidebar,
    "--tp-surf2": surfaceRaised,
    "--tp-ink": palette.ink,
    "--tp-ink2": readable(over(palette.ink, palette.surface, 0.62), grounds, palette.ink, 4.5),
    "--tp-ink3": readable(over(palette.ink, palette.surface, 0.4), grounds, palette.ink, 3),
    "--tp-line": rgba(palette.ink, dark ? 0.09 : 0.12),
    "--tp-accent": readable(palette.accent, grounds, palette.ink, 4.5),
    "--tp-sel": mix(palette.surface, palette.accent, dark ? 0.28 : 0.2),
    "--tp-ok": readable(palette.ok, grounds, palette.ink, 4.5),
    "--tp-skill": readable(palette.skill, grounds, palette.ink, 4.5),
    "--tp-ui": '-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif',
    "--tp-mono": 'ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace',
  };
}

function setProperties(element, properties) {
  Object.entries(properties).forEach(([name, value]) => element.style.setProperty(name, value));
}

function renderProductView() {
  const view = VIEWS[activeView];
  productTabs.forEach((tab, index) => {
    const selected = index === activeView;
    tab.setAttribute("aria-selected", String(selected));
    tab.tabIndex = selected ? 0 : -1;
  });

  productShots.forEach((shot) => {
    const selected = shot.dataset.view === view.id && shot.dataset.mode === siteMode;
    shot.classList.toggle("is-visible", selected);
    shot.setAttribute("aria-hidden", String(!selected));
  });

  productPanel.setAttribute("aria-labelledby", `tab-${view.id}`);
  productCaption.textContent = view.caption;
}

function setSiteMode(mode) {
  siteMode = mode;
  const palette = THEMES[0][mode];
  setProperties(siteFrame, siteTokens(palette));
  root.dataset.siteTheme = mode;
  root.style.background = palette.surface;
  root.style.colorScheme = mode;
  body.style.background = palette.surface;
  body.style.color = palette.ink;
  themeColor.setAttribute("content", palette.surface);
  siteModeButtons.forEach((button) => button.setAttribute("aria-pressed", String(button.dataset.siteMode === mode)));
  renderProductView();
  renderThemeList();
}

function effectivePreviewMode() {
  return THEMES[activeTheme].light ? previewMode : "dark";
}

function renderThemeList() {
  themeList.replaceChildren();
  THEMES.forEach((theme, index) => {
    const mode = theme.light ? previewMode : "dark";
    const swatch = theme[mode];
    const item = document.createElement("li");
    const button = document.createElement("button");
    const dot = document.createElement("span");
    const label = document.createElement("span");
    const tag = document.createElement("span");

    button.type = "button";
    button.setAttribute("aria-pressed", String(index === activeTheme));
    button.addEventListener("click", () => {
      activeTheme = index;
      renderThemeExplorer();
    });

    dot.className = "theme-dot";
    dot.style.background = swatch.accent;
    dot.style.boxShadow = `0 0 0 1px ${rgba(swatch.ink, 0.25)}`;
    label.className = "theme-label";
    label.textContent = theme.name;
    tag.className = "theme-tag";
    tag.textContent = theme.light ? "" : "Dark only";
    button.append(dot, label, tag);
    item.append(button);
    themeList.append(item);
  });
}

function renderThemeExplorer() {
  const theme = THEMES[activeTheme];
  const mode = effectivePreviewMode();
  const palette = theme[mode];
  setProperties(themePreviewWindow, previewTokens(palette));
  previewThemeName.textContent = theme.name;
  previewThemeMeta.textContent = `${theme.name} · ${mode === "dark" ? "Dark" : "Light"}`;
  themeAnnouncement.textContent = `${theme.name}, ${mode} variant, shown in the preview.`;

  previewModeButtons.forEach((button) => {
    const isLight = button.dataset.previewMode === "light";
    const disabled = isLight && !theme.light;
    button.setAttribute("aria-disabled", String(disabled));
    button.setAttribute("aria-pressed", String(button.dataset.previewMode === mode));
    button.title = disabled ? `${theme.name} is dark only` : isLight ? "Light" : "Dark";
  });

  renderThemeList();
}

siteModeButtons.forEach((button) => {
  button.addEventListener("click", () => setSiteMode(button.dataset.siteMode));
});

previewModeButtons.forEach((button) => {
  button.addEventListener("click", () => {
    if (button.getAttribute("aria-disabled") === "true") return;
    previewMode = button.dataset.previewMode;
    renderThemeExplorer();
  });
});

productTabs.forEach((tab, index) => {
  tab.addEventListener("click", () => {
    activeView = index;
    renderProductView();
  });
});

document.querySelector(".product-tabs").addEventListener("keydown", (event) => {
  const direction = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
  if (!direction) return;
  event.preventDefault();
  activeView = (activeView + direction + VIEWS.length) % VIEWS.length;
  renderProductView();
  productTabs[activeView].focus();
});

setSiteMode("dark");
renderThemeExplorer();
