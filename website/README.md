# Monknot product site

A dependency-free, single-page product site for Monknot. The page presents five coordinated
product views and a live theme explorer generated from `MonknotThemeCatalog` during the
production build.

```sh
cd website
npm run campaign
npm run check
npm run verify:campaign
npm run build
npm run preview
```

The production output is written to `website/dist` and can be served by any static host. SwiftPM
is used only at build time to export the canonical catalog of 50+ light and dark theme presets.

`npm run campaign` creates ten opaque RGB App Store masters at 2880 × 1800 and thirty lossless
website WebPs from one fixed SVG geometry. `npm run verify:campaign` checks every master and
derivative, hashes stable frame regions across all modes, and writes dark/light alignment
overlays to `.build/website-campaign-verify` for visual review.
