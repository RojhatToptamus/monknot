const skipLink = document.querySelector(".skip-link");
const mainContent = document.querySelector("#main-content");
const siteThemeColor = document.querySelector("#site-theme-color");
const siteAppearance = document.querySelector(".site-appearance");
const siteAppearanceInputs = Array.from(document.querySelectorAll('input[name="site-appearance"]'));
const featureTabs = Array.from(document.querySelectorAll('[role="tab"][data-feature]'));
const productShotPanel = document.querySelector("#product-shot-panel");
const productSource = document.querySelector("#product-source");
const productImage = document.querySelector("#product-image");
const themeExplorer = document.querySelector("#theme-explorer");
const variantInputs = Array.from(document.querySelectorAll('input[name="theme-variant"]'));
const featuredThemes = document.querySelector("#featured-themes");
const themeSelect = document.querySelector("#theme-select");
const themeSelectLabel = document.querySelector("#theme-select-label");
const previousTheme = document.querySelector("#previous-theme");
const nextTheme = document.querySelector("#next-theme");
const themePosition = document.querySelector("#theme-position");
const themeName = document.querySelector("#theme-name");
const themeCaption = document.querySelector("#theme-caption");
const themeAnnouncement = document.querySelector("#theme-announcement");
const palettePreview = document.querySelector("#palette-preview");

const productFeatures = {
  default: {
    label: "Editor",
    alt: "Monknot with the Atlas workspace open in its Markdown editor.",
  },
  split: {
    label: "Split",
    alt: "Monknot showing Markdown source and its rendered preview side by side in the Atlas workspace.",
  },
  terminal: {
    label: "Terminal",
    alt: "Monknot with a terminal session open beside the Atlas Markdown editor.",
  },
  pdf: {
    label: "PDF",
    alt: "Monknot displaying a sharp field-note PDF with its annotation toolbar.",
  },
  themes: {
    label: "Themes",
    alt: "Monknot showing eight featured theme families and a simplified Monolith editor preview.",
  },
};

const appStoreScreenshotNumbers = {
  dark: { default: "01", split: "02", terminal: "03", pdf: "04", themes: "05" },
  light: { default: "06", split: "07", terminal: "08", pdf: "09", themes: "10" },
};

const featuredThemeIDs = {
  light: [
    "harbor-light",
    "brasspants-light",
    "codechimp-light",
    "greaseball-light",
    "sockpuppet-light",
    "forge-light",
    "parchment-light",
    "monolith-light",
  ],
  dark: [
    "harbor-dark",
    "brasspants-dark",
    "codechimp-dark",
    "greaseball-dark",
    "sockpuppet-dark",
    "forge-dark",
    "parchment-dark",
    "monolith-dark",
  ],
};

const selectedThemeIDs = {
  light: "harbor-light",
  dark: "harbor-dark",
};

let catalog;
let activeVariant = "dark";
let activeProductFeature = "default";
let activeSiteAppearance = "dark";
let productFeatureRequest = 0;
const productFeaturePreloads = new Map();

function featureStem(id, appearance = activeSiteAppearance) {
  return `${id}-${appearance}`;
}

function featureSrcset(id, appearance = activeSiteAppearance) {
  const stem = featureStem(id, appearance);
  return [
    `assets/product/${stem}-960.webp 960w`,
    `assets/product/${stem}-1920.webp 1920w`,
    `assets/product/${stem}-2880.webp 2880w`,
  ].join(", ");
}

function featureFallback(id, appearance = activeSiteAppearance) {
  const number = appStoreScreenshotNumbers[appearance][id];
  return `app-store-screenshots/${number}-${id}-${appearance}.png`;
}

function preloadProductFeature(id, appearance = activeSiteAppearance) {
  const key = `${id}-${appearance}`;
  if (productFeaturePreloads.has(key)) return productFeaturePreloads.get(key);

  const preload = new Promise((resolve) => {
    const image = new Image();
    let settled = false;
    const finish = async (success) => {
      if (settled) return;
      settled = true;
      if (success) {
        try {
          await image.decode();
        } catch {}
      }
      resolve(success);
    };

    image.addEventListener("load", () => finish(true), { once: true });
    image.addEventListener("error", () => finish(false), { once: true });
    image.decoding = "async";
    image.sizes = productSource?.sizes || "100vw";
    image.srcset = featureSrcset(id, appearance);
    image.src = featureFallback(id, appearance);
    if (image.complete) finish(image.naturalWidth > 0);
  });

  productFeaturePreloads.set(key, preload);
  preload.then((success) => {
    if (!success && productFeaturePreloads.get(key) === preload) productFeaturePreloads.delete(key);
  });
  return preload;
}

function setSelectedProductTab(id, moveFocus = false) {
  const activeTab = featureTabs.find((tab) => tab.dataset.feature === id);
  featureTabs.forEach((tab) => {
    const selected = tab === activeTab;
    tab.setAttribute("aria-selected", String(selected));
    tab.tabIndex = selected ? 0 : -1;
  });
  if (activeTab) productShotPanel?.setAttribute("aria-labelledby", activeTab.id);
  if (moveFocus) activeTab?.focus();
  return activeTab;
}

async function showProductImage(id, appearance, request) {
  const feature = productFeatures[id];
  const loaded = await preloadProductFeature(id, appearance);
  if (request !== productFeatureRequest || !loaded) return false;

  productSource.srcset = featureSrcset(id, appearance);
  productImage.src = featureFallback(id, appearance);
  productImage.alt = feature.alt;
  productShotPanel.removeAttribute("aria-busy");
  productShotPanel.classList.remove("is-changing");
  return true;
}

async function selectProductFeature(id, moveFocus = false) {
  if (!productFeatures[id] || !productSource || !productImage || !productShotPanel) return;
  const previous = activeProductFeature;
  activeProductFeature = id;
  const activeTab = setSelectedProductTab(id, moveFocus);
  const request = ++productFeatureRequest;
  productShotPanel.classList.add("is-changing");
  productShotPanel.setAttribute("aria-busy", "true");

  const loaded = await showProductImage(id, activeSiteAppearance, request);
  if (loaded) return;

  if (request === productFeatureRequest) {
    activeProductFeature = previous;
    const restoreFocus = moveFocus || document.activeElement === activeTab;
    setSelectedProductTab(previous, restoreFocus);
    productShotPanel.removeAttribute("aria-busy");
    productShotPanel.classList.remove("is-changing");
  }
}

async function refreshProductAppearance() {
  if (!productShotPanel) return;
  const request = ++productFeatureRequest;
  productShotPanel.classList.add("is-changing");
  productShotPanel.setAttribute("aria-busy", "true");
  const loaded = await showProductImage(activeProductFeature, activeSiteAppearance, request);
  if (!loaded && request === productFeatureRequest) {
    productShotPanel.removeAttribute("aria-busy");
    productShotPanel.classList.remove("is-changing");
  }
}

function setupProductShowcase() {
  featureTabs.forEach((tab, index) => {
    tab.addEventListener("click", () => selectProductFeature(tab.dataset.feature));
    tab.addEventListener("keydown", (event) => {
      let nextIndex;
      if (event.key === "ArrowRight") nextIndex = (index + 1) % featureTabs.length;
      if (event.key === "ArrowLeft") nextIndex = (index - 1 + featureTabs.length) % featureTabs.length;
      if (event.key === "Home") nextIndex = 0;
      if (event.key === "End") nextIndex = featureTabs.length - 1;
      if (nextIndex === undefined) return;
      event.preventDefault();
      selectProductFeature(featureTabs[nextIndex].dataset.feature, true);
    });
  });
}

function savedSiteAppearance() {
  try {
    const value = localStorage.getItem("Monknot.siteAppearance");
    return ["light", "dark"].includes(value) ? value : "dark";
  } catch {
    return "dark";
  }
}

function syncThemeVariant(appearance) {
  if (!catalog || activeVariant === appearance) return;
  activeVariant = appearance;
  variantInputs.forEach((input) => {
    input.checked = input.value === activeVariant;
  });
  renderVariantOptions();
}

function applySiteAppearance(preference, persist = true) {
  activeSiteAppearance = preference;
  document.documentElement.dataset.siteTheme = preference;
  siteThemeColor?.setAttribute("content", preference === "dark" ? "#191415" : "#faf6f0");
  refreshProductAppearance();
  syncThemeVariant(preference);

  if (!persist) return;
  try {
    localStorage.setItem("Monknot.siteAppearance", preference);
  } catch {}
}

const initialSiteAppearance = savedSiteAppearance();
siteAppearanceInputs.forEach((input) => {
  input.checked = input.value === initialSiteAppearance;
  input.addEventListener("change", () => {
    if (input.checked) applySiteAppearance(input.value);
  });
});
applySiteAppearance(initialSiteAppearance, false);
siteAppearance.hidden = false;

function parseHex(hex) {
  const value = hex.replace("#", "");
  return {
    red: Number.parseInt(value.slice(0, 2), 16),
    green: Number.parseInt(value.slice(2, 4), 16),
    blue: Number.parseInt(value.slice(4, 6), 16),
  };
}

function toHex(red, green, blue) {
  return `#${[red, green, blue]
    .map((value) => Math.round(value).toString(16).padStart(2, "0"))
    .join("")}`;
}

function mix(fromHex, targetHex, amount) {
  const from = parseHex(fromHex);
  const to = parseHex(targetHex);
  return toHex(
    from.red + (to.red - from.red) * amount,
    from.green + (to.green - from.green) * amount,
    from.blue + (to.blue - from.blue) * amount,
  );
}

function rgba(hex, opacity) {
  const { red, green, blue } = parseHex(hex);
  return `rgba(${red}, ${green}, ${blue}, ${opacity})`;
}

function relativeLuminance(hex) {
  const { red, green, blue } = parseHex(hex);
  const channels = [red, green, blue].map((value) => {
    const normalized = value / 255;
    return normalized <= 0.04045
      ? normalized / 12.92
      : ((normalized + 0.055) / 1.055) ** 2.4;
  });
  return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
}

function validateCatalog(value) {
  if (value?.sourceVersion !== "monknot-theme-v3") return false;
  const themes = [...(value.light || []), ...(value.dark || [])];
  const colorPattern = /^#[0-9a-f]{6}$/i;
  return themes.length >= 50 && themes.every((theme) =>
    [theme.surface, theme.ink, theme.accent, theme.selection, theme.added, theme.skill].every((color) => colorPattern.test(color)),
  );
}

function currentThemes() {
  return catalog[activeVariant];
}

function createFeaturedButton(theme) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "featured-theme";
  button.dataset.themeId = theme.id;
  button.setAttribute("aria-pressed", "false");
  button.textContent = theme.name;
  button.addEventListener("click", () => selectTheme(theme.id));
  return button;
}

function renderVariantOptions() {
  const themes = currentThemes();
  const options = document.createDocumentFragment();
  themeSelect.textContent = "";
  for (const theme of themes) {
    const option = document.createElement("option");
    option.value = theme.id;
    option.textContent = theme.name;
    options.append(option);
  }
  themeSelect.append(options);

  featuredThemes.textContent = "";
  for (const id of featuredThemeIDs[activeVariant]) {
    const theme = themes.find((candidate) => candidate.id === id);
    if (theme) featuredThemes.append(createFeaturedButton(theme));
  }

  themeSelectLabel.textContent = `All ${activeVariant} presets`;
  selectTheme(selectedThemeIDs[activeVariant]);
}

function applyPreview(theme) {
  const dark = relativeLuminance(theme.surface) < 0.45;
  const tokens = {
    "--preview-surface": theme.surface,
    "--preview-sidebar": mix(theme.surface, theme.ink, dark ? 0.075 : 0.028),
    "--preview-surface-2": mix(theme.surface, theme.ink, dark ? 0.11 : 0.05),
    "--preview-ink": theme.ink,
    "--preview-ink-2": rgba(theme.ink, 0.64),
    "--preview-ink-3": rgba(theme.ink, 0.42),
    "--preview-line": rgba(theme.ink, dark ? 0.11 : 0.13),
    "--preview-accent": theme.accent,
    "--preview-selection": theme.selection,
    "--preview-added": theme.added,
    "--preview-skill": theme.skill,
  };
  for (const [property, value] of Object.entries(tokens)) palettePreview.style.setProperty(property, value);
}

function selectTheme(id) {
  const themes = currentThemes();
  const theme = themes.find((candidate) => candidate.id === id) ?? themes[0];
  const index = themes.indexOf(theme);
  selectedThemeIDs[activeVariant] = theme.id;

  themeSelect.value = theme.id;
  themeName.textContent = theme.name;
  themeCaption.textContent = `${theme.name} · ${activeVariant === "light" ? "Light" : "Dark"}`;
  themePosition.textContent = `${index + 1} / ${themes.length}`;
  themeAnnouncement.textContent = `${theme.name}, ${activeVariant} theme, ${index + 1} of ${themes.length}.`;

  for (const button of featuredThemes.querySelectorAll("button[data-theme-id]")) {
    button.setAttribute("aria-pressed", String(button.dataset.themeId === theme.id));
  }
  applyPreview(theme);
}

function stepTheme(direction) {
  const themes = currentThemes();
  const currentIndex = themes.findIndex((theme) => theme.id === selectedThemeIDs[activeVariant]);
  selectTheme(themes[(currentIndex + direction + themes.length) % themes.length].id);
}

async function setupThemeExplorer() {
  if (!themeExplorer) return;
  try {
    const response = await fetch("assets/theme-catalog.json");
    if (!response.ok) return;
    const value = await response.json();
    if (!validateCatalog(value)) return;
    catalog = value;
    activeVariant = activeSiteAppearance;

    variantInputs.forEach((input) => {
      input.checked = input.value === activeVariant;
      input.addEventListener("change", () => {
        if (!input.checked) return;
        activeVariant = input.value;
        renderVariantOptions();
      });
    });
    themeSelect.addEventListener("change", () => selectTheme(themeSelect.value));
    previousTheme.addEventListener("click", () => stepTheme(-1));
    nextTheme.addEventListener("click", () => stepTheme(1));

    renderVariantOptions();
    themeExplorer.hidden = false;
  } catch {}
}

skipLink?.addEventListener("click", () => {
  window.requestAnimationFrame(() => mainContent?.focus({ preventScroll: true }));
});

const year = document.querySelector("#current-year");
if (year) year.textContent = String(new Date().getFullYear());

setupProductShowcase();
setupThemeExplorer();
