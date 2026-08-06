# Monknot product site

A dependency-free, single-page product site for Monknot. The page uses verified product behavior,
four real app captures from the compact Borealis workspace, and a live theme explorer generated
from `MonknotThemeCatalog` during the production build.

```sh
cd website
npm run check
npm run build
npm run preview
```

The production output is written to `website/dist` and can be served by any static host. SwiftPM
is used only at build time to export the canonical catalog of 50+ light and dark theme presets.

App Store-ready 2560 × 1600 PNGs are kept separately in `app-store-screenshots`; they are not
copied into the deployable site bundle.
