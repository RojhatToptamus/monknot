# Third-Party Notices

Monknot bundles the third-party software listed below. The complete license
texts are distributed in `ThirdPartyLicenses/` in the source repository and in
`Monknot.app/Contents/Resources/Legal/ThirdParty/` in release builds. The source
copies of theme licenses reproduce the complete upstream text without changes.

The bundled files were compared byte-for-byte with the named official npm
package tarballs. Their SHA-256 hashes are recorded below so the notice can be
checked deterministically against a release bundle.

## xterm.js

- `@xterm/xterm` 5.5.0
- Official package: <https://www.npmjs.com/package/@xterm/xterm/v/5.5.0>
- Source repository: <https://github.com/xtermjs/xterm.js>
- Package source revision: `9ba6c00a195c95fcf8292a2b9084d91450e5daae`
- License: MIT
- Complete license: `ThirdPartyLicenses/xterm-MIT.txt`
- Bundled files:
  - `xterm.js` — SHA-256 `1f991ac3b4b283ebf96e60ae23a00a52765dd3a2e46fa6fdda9f1aab032f7495`
  - `xterm.css` — SHA-256 `ba8e6985669488981ccf40c0cefe3aba80722cb6c92de7ad628b0bd717faf2b6`

Copyright (c) 2017-2019, The xterm.js authors.

Copyright (c) 2014-2016, SourceLair Private Company.

Copyright (c) 2012-2013, Christopher Jeffrey.

The historical Fabrice Bellard attribution embedded in `xterm.css` is retained
in the bundled file.

## xterm.js fit addon

- `@xterm/addon-fit` 0.10.0
- Official package: <https://www.npmjs.com/package/@xterm/addon-fit/v/0.10.0>
- Source repository: <https://github.com/xtermjs/xterm.js>
- Package source revision: `9ba6c00a195c95fcf8292a2b9084d91450e5daae`
- License: MIT
- Complete license: `ThirdPartyLicenses/xterm-addon-fit-MIT.txt`
- Bundled file:
  - `xterm-addon-fit.js` — SHA-256 `bdaefa370b1bfc42ee88d46fe6072400902a4d4b2d45cd93438dda9b23c97089`

Copyright (c) 2019, The xterm.js authors.

## Theme palettes

Each entry below identifies the canonical palette source used by Monknot. Monknot
maps selected upstream colors to its own accent, surface, ink, diff-added,
diff-removed, and skill UI roles; it does not bundle the upstream theme package.

| Theme | Canonical source and revision | Palette source | License and copyright | Complete license |
| --- | --- | --- | --- | --- |
| Ayu Dark | <https://github.com/ayu-theme/ayu-colors> at `e3f44fdf2a1c83e3f183d4e8acd40c6a452dcb1c` | `themes/dark.yaml`; Monknot maps the upstream accent, editor foreground/background, VCS added/removed, and purple palette colors to its UI roles | MIT; Copyright (c) Konstantin Pschera `<me@kons.ch>` (kons.ch) | `ThirdPartyLicenses/theme-ayu-MIT.txt` |
| Catppuccin Latte and Catppuccin Mocha | <https://github.com/catppuccin/catppuccin> at `d09787dd98ca6fba08af5ef2ae94a7e09f17daca` | `README.md` palette tables; Monknot maps mauve, text, base, green, red, and mauve to its UI roles | MIT; Copyright (c) 2021 Catppuccin | `ThirdPartyLicenses/theme-catppuccin-MIT.txt` |
| Dracula | <https://github.com/dracula/dracula-theme> at `769cfc706b2d0fb582e7c1947328aeb97c0fea94` | `README.md` color palette; Monknot maps pink, foreground, background, green, red, and pink to its UI roles | MIT; Copyright (c) 2023 Dracula Theme | `ThirdPartyLicenses/theme-dracula-MIT.txt` |
| Everforest Light / Dark | <https://github.com/sainnhe/everforest> at `85a86eb62409e3ec88713bff3d1b9d7374e112e4` | `palette.md`; Monknot maps the documented medium light/dark backgrounds, foregrounds, green/red diff colors, and purple to its UI roles | MIT; Copyright (c) 2019 sainnhe | `ThirdPartyLicenses/theme-everforest-MIT.txt` |
| Night Owl | <https://github.com/sdras/night-owl-vscode-theme> at `cc291eba7976b20d7c66bde6883c27b902196b07` | `themes/Night Owl-color-theme.json`; Monknot maps its editor background/foreground and blue-gray, green, red, and purple colors to its UI roles | MIT; Copyright (c) 2018 Sarah Drasner | `ThirdPartyLicenses/theme-night-owl-MIT.txt` |
| Nord | <https://github.com/nordtheme/nord> at `1cef71605416a222e57225b544540ce0fcec18d4` | `src/nord.scss`; Monknot maps Nord 8, 4, 0, 14, 11, and 15 to its UI roles | MIT; Copyright (c) 2016-present Sven Greb `<development@svengreb.de>` (<https://www.svengreb.de>) | `ThirdPartyLicenses/theme-nord-MIT.txt` |
| One Dark | <https://github.com/atom/one-dark-syntax> at `9c96f4454362267ac45322063e193ccf9d2debb1` | `styles/colors.less`; Monknot maps hue 2, syntax foreground/background, hue 4, hue 5, and hue 3 to its UI roles | MIT; Copyright (c) 2016 GitHub Inc. | `ThirdPartyLicenses/theme-one-dark-MIT.txt` |
| One Light | <https://github.com/atom/one-light-syntax> at `d84579027410c576086dfca14d934c4bd74b0438` | `styles/colors.less`; Monknot maps hue 2, syntax foreground/background, hue 4, hue 5, and hue 3 to its UI roles | MIT; Copyright (c) 2016 GitHub Inc. | `ThirdPartyLicenses/theme-one-light-MIT.txt` |
| Oscura | <https://github.com/narative/oscura> at `f8e450b4b1f2d0bacfec5119601f62bc982a6533` | `themes/oscura-midnight.json`; Monknot maps the numeric peach, editor foreground/background, attribute teal, deleted red, and link blue to its UI roles | MIT; Copyright (c) 2025 Narative | `ThirdPartyLicenses/theme-oscura-MIT.txt` |
| Rosé Pine Dawn and Rosé Pine Moon | <https://github.com/rose-pine/rose-pine-palette> at `92af52b465ab6e47437aca223c9b8d3009a2023b` | `palette.json`; Monknot maps rose, text, base, foam, love, and iris to its UI roles | MIT; Copyright (c) mvllow | `ThirdPartyLicenses/theme-rose-pine-MIT.txt` |
| Solarized Light and Solarized Dark | <https://github.com/altercation/solarized> at `62f656a02f93c5190a8753159e34b385588d5ff3` | `vim-colors-solarized/colors/solarized.vim`; Monknot maps blue, base00/base0, base3/base03, green, red, and magenta to its UI roles | MIT; Copyright (c) 2011 Ethan Schoonover | `ThirdPartyLicenses/theme-solarized-MIT.txt` |
| Tokyo Night | <https://github.com/tokyo-night/tokyo-night-vscode-theme> at `7c0f11eaef322f293621ca7befe462214b7ea468` | `themes/tokyo-night-color-theme.json`; Monknot maps the upstream blue accent, editor foreground/background, Git added/deleted, and purple colors to its UI roles | MIT; Copyright (c) 2018-present Enkia | `ThirdPartyLicenses/theme-tokyo-night-MIT.txt` |

The MIT licenses require their copyright and permission notices to accompany
copies or substantial portions of the software. The complete texts are
therefore shipped with Monknot. MIT imposes no source-disclosure or relinking
requirement.
