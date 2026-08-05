const hexColor = /^#[0-9a-f]{6}$/i;
const colorKeys = ["surface", "ink", "accent", "selection", "added", "removed", "skill"];

export function validateThemeCatalog(catalog) {
  if (catalog?.sourceVersion !== "monknot-theme-v1") {
    throw new Error("Unexpected Monknot theme catalog version.");
  }

  if (catalog.light?.length !== 20 || catalog.dark?.length !== 31) {
    throw new Error("Expected 20 light presets and 31 dark presets.");
  }

  for (const variant of ["light", "dark"]) {
    if (!catalog[variant].every((theme) => theme.variant === variant)) {
      throw new Error(`Theme catalog contains a misplaced ${variant} preset.`);
    }
  }

  const themes = [...catalog.light, ...catalog.dark];
  const ids = new Set();

  for (const theme of themes) {
    if (ids.has(theme.id)) throw new Error(`Duplicate theme id: ${theme.id}`);
    ids.add(theme.id);

    if (!theme.name || !["light", "dark"].includes(theme.variant)) {
      throw new Error(`Invalid theme metadata: ${theme.id ?? "unknown"}`);
    }

    for (const key of colorKeys) {
      if (!hexColor.test(theme[key])) throw new Error(`Invalid ${key} color for ${theme.id}`);
    }

    if (!Array.isArray(theme.palette) || theme.palette.length !== 16) {
      throw new Error(`Expected 16 palette colors for ${theme.id}`);
    }

    if (!theme.palette.every((color) => hexColor.test(color))) {
      throw new Error(`Invalid terminal palette for ${theme.id}`);
    }
  }
}
