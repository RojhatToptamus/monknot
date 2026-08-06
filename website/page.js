const root = document.documentElement;
const themeColor = document.querySelector("#theme-color");
const siteModeButtons = Array.from(document.querySelectorAll("[data-site-mode]"));

const surfaces = {
  light: "#fdfdfe",
  dark: "#121212",
};

function setSiteMode(mode) {
  root.dataset.siteTheme = mode;
  root.style.colorScheme = mode;
  themeColor.setAttribute("content", surfaces[mode]);
  siteModeButtons.forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.siteMode === mode));
  });
}

siteModeButtons.forEach((button) => {
  button.addEventListener("click", () => setSiteMode(button.dataset.siteMode));
});

setSiteMode(root.dataset.siteTheme === "light" ? "light" : "dark");
