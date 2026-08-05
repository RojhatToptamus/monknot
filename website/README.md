# Monknot product site

A dependency-free, single-page product site for Monknot. The page uses verified product behavior,
screenshots captured from a local demo workspace, and a live palette explorer generated from
`MonknotThemeCatalog` during the production build.

```sh
cd website
npm run check
npm run build
npm run preview
```

The production output is written to `website/dist` and can be served by any static host. SwiftPM
is used only at build time to export the canonical 20 light and 31 dark theme presets.
