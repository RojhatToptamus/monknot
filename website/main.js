const themeCatalogResponse = await fetch("theme-catalog.json");
if (!themeCatalogResponse.ok) throw new Error("Unable to load the Monknot theme catalog.");

const themeCatalog = await themeCatalogResponse.json();
if (themeCatalog.sourceVersion !== "monknot-theme-v4") {
  throw new Error("Unsupported Monknot theme catalog.");
}

function websiteTheme(theme) {
  return {
    id: theme.id,
    name: theme.name,
    surface: theme.surface,
    ink: theme.ink,
    accent: theme.accent,
    ok: theme.added,
    skill: theme.skill,
  };
}

const THEMES = {
  light: themeCatalog.light.map(websiteTheme),
  dark: themeCatalog.dark.map(websiteTheme),
};

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
let previewMode = "light";
const activeThemeIDs = {
  light: THEMES.light.find((theme) => theme.id === "axis-light")?.id ?? THEMES.light[0].id,
  dark: THEMES.dark.find((theme) => theme.id === "axis-dark")?.id ?? THEMES.dark[0].id,
};

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
  const palette = THEMES[mode].find((theme) => theme.id === `harbor-${mode}`) ?? THEMES[mode][0];
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

function currentThemes() {
  return THEMES[previewMode];
}

function activeThemeIndex() {
  const themes = currentThemes();
  const index = themes.findIndex((theme) => theme.id === activeThemeIDs[previewMode]);
  return index >= 0 ? index : 0;
}

function revealActiveTheme(moveFocus) {
  const button = themeList.querySelector('[aria-pressed="true"]');
  if (!button) return;
  if (moveFocus) button.focus({ preventScroll: true });

  const listBounds = themeList.getBoundingClientRect();
  const buttonBounds = button.getBoundingClientRect();
  if (buttonBounds.top < listBounds.top) themeList.scrollTop -= listBounds.top - buttonBounds.top;
  if (buttonBounds.bottom > listBounds.bottom) themeList.scrollTop += buttonBounds.bottom - listBounds.bottom;
}

function renderThemeList(moveFocus = false) {
  const themes = currentThemes();
  const selectedIndex = activeThemeIndex();
  let buttons = Array.from(themeList.querySelectorAll("button"));
  const catalogChanged = buttons.length !== themes.length || buttons.some((button, index) => button.dataset.themeId !== themes[index].id);

  if (catalogChanged) {
    themeList.replaceChildren();
    themes.forEach((theme) => {
      const item = document.createElement("li");
      const button = document.createElement("button");
      const dot = document.createElement("span");
      const label = document.createElement("span");

      button.type = "button";
      button.dataset.themeId = theme.id;
      button.addEventListener("click", () => {
        activeThemeIDs[previewMode] = theme.id;
        renderThemeExplorer(true);
      });

      dot.className = "theme-dot";
      dot.style.background = theme.accent;
      dot.style.boxShadow = `0 0 0 1px ${rgba(theme.ink, 0.25)}`;
      label.className = "theme-label";
      label.textContent = theme.name;
      button.append(dot, label);
      item.append(button);
      themeList.append(item);
    });
    buttons = Array.from(themeList.querySelectorAll("button"));
  }

  buttons.forEach((button, index) => {
    button.setAttribute("aria-pressed", String(index === selectedIndex));
    button.tabIndex = index === selectedIndex ? 0 : -1;
  });
  revealActiveTheme(moveFocus);
}

function renderThemeExplorer(moveFocus = false) {
  const themes = currentThemes();
  const index = activeThemeIndex();
  const theme = themes[index];
  activeThemeIDs[previewMode] = theme.id;
  setProperties(themePreviewWindow, previewTokens(theme));
  previewThemeName.textContent = theme.name;
  previewThemeMeta.textContent = `${theme.name} · ${previewMode === "dark" ? "Dark" : "Light"}`;
  themeAnnouncement.textContent = `${theme.name}, ${previewMode} preset, ${index + 1} of ${themes.length}, shown in the preview.`;

  previewModeButtons.forEach((button) => {
    const selected = button.dataset.previewMode === previewMode;
    button.setAttribute("aria-pressed", String(selected));
    button.title = button.dataset.previewMode === "light" ? "Light" : "Dark";
  });

  renderThemeList(moveFocus);
}

siteModeButtons.forEach((button) => {
  button.addEventListener("click", () => setSiteMode(button.dataset.siteMode));
});

previewModeButtons.forEach((button) => {
  button.addEventListener("click", () => {
    previewMode = button.dataset.previewMode;
    renderThemeExplorer();
  });
});

themeList.addEventListener("keydown", (event) => {
  const themes = currentThemes();
  const currentIndex = activeThemeIndex();
  let nextIndex;
  if (event.key === "ArrowDown") nextIndex = (currentIndex + 1) % themes.length;
  if (event.key === "ArrowUp") nextIndex = (currentIndex - 1 + themes.length) % themes.length;
  if (event.key === "Home") nextIndex = 0;
  if (event.key === "End") nextIndex = themes.length - 1;
  if (nextIndex === undefined) return;

  event.preventDefault();
  activeThemeIDs[previewMode] = themes[nextIndex].id;
  renderThemeExplorer(true);
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
