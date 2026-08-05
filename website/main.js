const skipLink = document.querySelector(".skip-link");
const mainContent = document.querySelector("#main-content");
const siteThemeColor = document.querySelector("#site-theme-color");
const siteAppearance = document.querySelector(".site-appearance");
const siteAppearanceInputs = Array.from(
  document.querySelectorAll('input[name="site-appearance"]'),
);
const featureTabs = Array.from(document.querySelectorAll('[role="tab"][data-feature]'));
const productShotPanel = document.querySelector("#product-shot-panel");
const productSource = document.querySelector("#product-source");
const productImage = document.querySelector("#product-image");
const productCaption = document.querySelector("#product-caption");
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
const themeDetails = document.querySelector("#theme-details");
const themeAnnouncement = document.querySelector("#theme-announcement");
const palettePreview = document.querySelector("#palette-preview");
const terminalPalette = document.querySelector("#terminal-palette");
const previewThemeNames = Array.from(document.querySelectorAll("[data-preview-theme-name]"));

const productFeatures = {
  default: {
    image: "monknot-default",
    alt: "Monknot with the Project Borealis workspace open in its Markdown source editor.",
    caption: "Project Borealis · Browse and edit workspace files.",
  },
  split: {
    image: "monknot-split",
    alt: "Monknot showing Project Borealis Markdown source and its rendered preview side by side.",
    caption: "Project Borealis · Markdown source and live preview.",
  },
  terminal: {
    image: "monknot-terminal",
    alt: "Monknot with a shell session open beside the Project Borealis Markdown editor.",
    caption: "Project Borealis · Run a shell beside the active document.",
  },
  pdf: {
    image: "monknot-pdf",
    alt: "Monknot displaying the exported Project Borealis PDF with its annotation toolbar.",
    caption: "Project Borealis · Read and annotate PDFs.",
  },
};

const featuredNames = ["Absolutely", "Codex", "Catppuccin", "Everforest", "Rose Pine"];
const selectedThemeIDs = {
  light: "absolutely-light",
  dark: "absolutely-dark",
};

let catalog;
let activeVariant = "dark";
let activeProductFeature = "default";
let productFeatureRequest = 0;
const productFeaturePreloads = new Map();

function featureSrcset(feature) {
  return [
    `assets/${feature.image}-1200.webp 1200w`,
    `assets/${feature.image}-2400.webp 2400w`,
    `assets/${feature.image}.webp 3600w`,
  ].join(", ");
}

function preloadProductFeature(id) {
  if (productFeaturePreloads.has(id)) return productFeaturePreloads.get(id);

  const feature = productFeatures[id];
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
    image.srcset = featureSrcset(feature);
    image.src = `assets/${feature.image}.jpg`;
    if (image.complete) finish(image.naturalWidth > 0);
  });

  productFeaturePreloads.set(id, preload);
  preload.then((success) => {
    if (!success && productFeaturePreloads.get(id) === preload) {
      productFeaturePreloads.delete(id);
    }
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

async function selectProductFeature(id, moveFocus = false) {
  const feature = productFeatures[id];
  if (!feature || !productSource || !productImage || !productCaption || !productShotPanel) return;
  if (id === activeProductFeature && !productShotPanel.hasAttribute("aria-busy")) {
    setSelectedProductTab(id, moveFocus);
    return;
  }

  const activeTab = setSelectedProductTab(id, moveFocus);

  const request = ++productFeatureRequest;
  productShotPanel.classList.add("is-changing");
  productShotPanel.setAttribute("aria-busy", "true");
  const loaded = await preloadProductFeature(id);
  if (request !== productFeatureRequest) return;
  if (!loaded) {
    const restoreFocus = moveFocus || document.activeElement === activeTab;
    setSelectedProductTab(activeProductFeature, restoreFocus);
    productShotPanel.removeAttribute("aria-busy");
    productShotPanel.classList.remove("is-changing");
    return;
  }

  activeProductFeature = id;

  productSource.srcset = featureSrcset(feature);
  productImage.src = `assets/${feature.image}.jpg`;
  productImage.alt = feature.alt;
  productCaption.textContent = feature.caption;
  productShotPanel.removeAttribute("aria-busy");
  productShotPanel.classList.remove("is-changing");
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

function applySiteAppearance(preference, persist = true) {
  document.documentElement.dataset.siteTheme = preference;
  siteThemeColor?.setAttribute("content", preference === "dark" ? "#12110f" : "#f9f9f7");

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

function rgba(hex, alpha) {
  const color = parseHex(hex);
  return `rgba(${color.red}, ${color.green}, ${color.blue}, ${alpha})`;
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
  const colorPattern = /^#[0-9a-f]{6}$/i;
  if (value?.sourceVersion !== "monknot-theme-v1") return false;
  if (value.light?.length !== 20 || value.dark?.length !== 31) return false;
  if (!value.light.every((theme) => theme.variant === "light")) return false;
  if (!value.dark.every((theme) => theme.variant === "dark")) return false;

  const themes = [...value.light, ...value.dark];
  const ids = new Set(themes.map((theme) => theme.id));
  if (ids.size !== themes.length) return false;

  return themes.every(
    (theme) =>
      [theme.surface, theme.ink, theme.accent, theme.selection, theme.added, theme.removed, theme.skill].every(
        (color) => colorPattern.test(color),
      ) &&
      Array.isArray(theme.palette) &&
      theme.palette.length === 16,
  );
}

function currentThemes() {
  return catalog[activeVariant];
}

function selectedTheme() {
  const themes = currentThemes();
  return themes.find((theme) => theme.id === selectedThemeIDs[activeVariant]) ?? themes[0];
}

function createFeaturedButton(theme) {
  const button = document.createElement("button");
  const label = document.createElement("span");
  const colors = document.createElement("span");

  button.type = "button";
  button.className = "featured-theme";
  button.dataset.themeId = theme.id;
  button.setAttribute("aria-pressed", "false");
  label.textContent = theme.name;
  colors.className = "featured-theme__colors";
  colors.setAttribute("aria-hidden", "true");

  for (const color of [theme.surface, theme.ink, theme.accent]) {
    const swatch = document.createElement("i");
    swatch.style.backgroundColor = color;
    colors.append(swatch);
  }

  button.append(label, colors);
  button.addEventListener("click", () => selectTheme(theme.id));
  return button;
}

function renderVariantOptions() {
  const themes = currentThemes();
  const fragment = document.createDocumentFragment();

  themeSelect.textContent = "";
  for (const theme of themes) {
    const option = document.createElement("option");
    option.value = theme.id;
    option.textContent = theme.name;
    fragment.append(option);
  }
  themeSelect.append(fragment);

  featuredThemes.textContent = "";
  for (const name of featuredNames) {
    const theme = themes.find((candidate) => candidate.name === name);
    if (theme) featuredThemes.append(createFeaturedButton(theme));
  }

  themeSelectLabel.textContent = `All ${activeVariant} presets`;
  selectTheme(selectedThemeIDs[activeVariant]);
}

function applyPreview(theme) {
  const dark = relativeLuminance(theme.surface) < 0.45;
  const previewTokens = {
    "--preview-surface": theme.surface,
    "--preview-ink": theme.ink,
    "--preview-surface-2": mix(theme.surface, theme.ink, dark ? 0.11 : 0.05),
    "--preview-surface-3": mix(theme.surface, theme.ink, dark ? 0.17 : 0.09),
    "--preview-line": rgba(theme.ink, dark ? 0.09 : 0.12),
    "--preview-accent": theme.accent,
    "--preview-selection": theme.selection,
    "--preview-added": theme.added,
    "--preview-removed": theme.removed,
    "--preview-skill": theme.skill,
  };

  for (const [property, value] of Object.entries(previewTokens)) {
    palettePreview.style.setProperty(property, value);
  }

  if (terminalPalette.children.length !== theme.palette.length) {
    const fragment = document.createDocumentFragment();
    for (const color of theme.palette) {
      const swatch = document.createElement("i");
      swatch.style.backgroundColor = color;
      fragment.append(swatch);
    }
    terminalPalette.replaceChildren(fragment);
  } else {
    Array.from(terminalPalette.children).forEach((swatch, index) => {
      swatch.style.backgroundColor = theme.palette[index];
    });
  }
}

function selectTheme(id) {
  const themes = currentThemes();
  const theme = themes.find((candidate) => candidate.id === id) ?? themes[0];
  const index = themes.indexOf(theme);
  selectedThemeIDs[activeVariant] = theme.id;

  themeSelect.value = theme.id;
  themeName.textContent = theme.name;
  themeCaption.textContent = `${theme.name} · ${activeVariant === "light" ? "Light" : "Dark"} palette`;
  themePosition.textContent = `${index + 1} / ${themes.length}`;
  themeDetails.textContent = `Colors 1 through 16: ${theme.palette.join(", ")}.`;
  themeAnnouncement.textContent = `${theme.name}, ${activeVariant} theme, ${index + 1} of ${themes.length}.`;
  previewThemeNames.forEach((element) => {
    element.textContent = theme.name;
  });

  for (const button of featuredThemes.querySelectorAll("button[data-theme-id]")) {
    button.setAttribute("aria-pressed", String(button.dataset.themeId === theme.id));
  }

  for (const element of document.querySelectorAll("[data-token-swatch]")) {
    const token = element.dataset.tokenSwatch;
    element.style.backgroundColor = theme[token];
  }

  for (const element of document.querySelectorAll("[data-token-value]")) {
    const token = element.dataset.tokenValue;
    element.textContent = theme[token].toUpperCase();
  }

  applyPreview(theme);
}

function stepTheme(direction) {
  const themes = currentThemes();
  const currentIndex = themes.findIndex((theme) => theme.id === selectedThemeIDs[activeVariant]);
  const nextIndex = (currentIndex + direction + themes.length) % themes.length;
  selectTheme(themes[nextIndex].id);
}

async function setupThemeExplorer() {
  if (!themeExplorer) return;

  try {
    const response = await fetch("assets/theme-catalog.json");
    if (!response.ok) return;

    const value = await response.json();
    if (!validateCatalog(value)) return;
    catalog = value;

    variantInputs.forEach((input) => {
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

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const revealItems = Array.from(document.querySelectorAll(".reveal"));

if (reduceMotion || !("IntersectionObserver" in window)) {
  revealItems.forEach((item) => item.classList.add("is-visible"));
} else {
  document.documentElement.classList.add("motion-ready");
  const revealObserver = new IntersectionObserver(
    (entries, observer) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    },
    { rootMargin: "0px 0px -8%", threshold: 0.08 },
  );
  revealItems.forEach((item) => revealObserver.observe(item));
}

const year = document.querySelector("#current-year");
if (year) year.textContent = String(new Date().getFullYear());

setupThemeExplorer();
setupProductShowcase();
