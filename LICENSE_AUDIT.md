# License Audit

Audit date: 2026-08-07

This file records the repository and release-bundle license inventory. It is a
technical compliance record, not legal advice and not a representation that an
uncleared item is suitable for commercial distribution.

## Release status

**Cleared for the direct-distribution application bundle described here.** The
project owner confirmed authorship of the current Monknot icon/logo and the
Brasspants, Codechimp, Greaseball, Lobster, Proof, Sockpuppet, and Temple
palettes. Those first-party assets are covered by Monknot's MIT License.
Gruvbox has been removed. The vendored terminal libraries and twelve remaining
canonical third-party theme projects retain their verified MIT licenses and
complete notices.

This inventory does not replace the release controls: the public DMG must still
be Developer ID signed, notarized, stapled, and verified. Repository-only
design/spec material remains outside the application bundle and is called out
separately below where provenance is incomplete.

## Distributed application contents

| Component | Version or location | License/provenance | Distribution action | Status |
| --- | --- | --- | --- | --- |
| Monknot first-party source, documentation, and assets | Repository root | MIT; root `LICENSE` | Ship `LICENSE` in `Contents/Resources/Legal/LICENSE` | Cleared by project-owner representation |
| `@xterm/xterm` | 5.5.0; `xterm.js`, `xterm.css` | MIT; official npm tarball and source revision recorded in `THIRD_PARTY_NOTICES.md` | Retain notices and ship `ThirdPartyLicenses/xterm-MIT.txt` | Verified |
| `@xterm/addon-fit` | 0.10.0; `xterm-addon-fit.js` | MIT; official npm tarball and source revision recorded in `THIRD_PARTY_NOTICES.md` | Retain notices and ship `ThirdPartyLicenses/xterm-addon-fit-MIT.txt` | Verified |
| App icon/logo PNG set | `Sources/Monknot/Resources/Assets.xcassets` and current first-party logo derivatives | Original work by Rojhat Toptamuş; MIT | Treat as first-party Monknot assets | Cleared by project-owner representation |
| Verified theme-palette data | `Sources/MonknotCore/Models/MonknotThemeCatalog.swift` | Twelve canonical projects independently verified as MIT at the revisions below | Ship every corresponding complete license and notice | Verified only for the rows marked cleared below |
| Owner-provided house-theme palettes | Same catalog | Twenty-two independently generated variants supplied for Parchment, Harbor, Forge, Axis, Lagoon, Phosphor, Citrus, Paper, Signal, Watchtower, Monolith, Workbench, and Blueprint | Retain exact-value regression coverage | Cleared by project-owner representation |
| Owner-authored custom palettes | Same catalog | Brasspants, Codechimp, Greaseball, Lobster, Proof, Sockpuppet, and Temple were confirmed as original work by Rojhat Toptamuş | Treat as first-party Monknot assets under MIT | Cleared by project-owner representation |

## Theme palette audit

Monknot derives its compact application themes by selecting colors from each
canonical palette and mapping them to accent, surface, ink, diff-added,
diff-removed, and skill roles. Selection backgrounds and the repeated editor
palette array are Monknot-generated semantic adaptations. No upstream theme
runtime or source package is bundled.

| Catalog theme | Canonical repository and exact revision | Upstream palette file | Monknot semantic mapping | License evidence | Status |
| --- | --- | --- | --- | --- | --- |
| Ayu Dark | <https://github.com/ayu-theme/ayu-colors> `e3f44fdf2a1c83e3f183d4e8acd40c6a452dcb1c` | `themes/dark.yaml` | Accent; editor foreground/background; VCS added/removed; purple | MIT, Copyright (c) Konstantin Pschera; `ThirdPartyLicenses/theme-ayu-MIT.txt` | Cleared |
| Catppuccin Latte and Catppuccin Mocha | <https://github.com/catppuccin/catppuccin> `d09787dd98ca6fba08af5ef2ae94a7e09f17daca` | `README.md` palette tables | Mauve; text/base; green/red; mauve | MIT, Copyright (c) 2021 Catppuccin; `ThirdPartyLicenses/theme-catppuccin-MIT.txt` | Cleared |
| Dracula | <https://github.com/dracula/dracula-theme> `769cfc706b2d0fb582e7c1947328aeb97c0fea94` | `README.md` color palette | Pink; foreground/background; green/red; pink | MIT, Copyright (c) 2023 Dracula Theme; `ThirdPartyLicenses/theme-dracula-MIT.txt` | Cleared |
| Everforest Light / Dark | <https://github.com/sainnhe/everforest> `85a86eb62409e3ec88713bff3d1b9d7374e112e4` | `palette.md` | Medium light/dark accents, foregrounds/backgrounds, green/red, and purple | MIT, Copyright (c) 2019 sainnhe; `ThirdPartyLicenses/theme-everforest-MIT.txt` | Cleared |
| Night Owl | <https://github.com/sdras/night-owl-vscode-theme> `cc291eba7976b20d7c66bde6883c27b902196b07` | `themes/Night Owl-color-theme.json` | Editor foreground/background and blue-gray, green, red, and purple | MIT, Copyright (c) 2018 Sarah Drasner; `ThirdPartyLicenses/theme-night-owl-MIT.txt` | Cleared |
| Nord | <https://github.com/nordtheme/nord> `1cef71605416a222e57225b544540ce0fcec18d4` | `src/nord.scss` | Nord 8, 4, 0, 14, 11, and 15 | MIT, Copyright (c) 2016-present Sven Greb; `ThirdPartyLicenses/theme-nord-MIT.txt` | Cleared |
| One Dark | <https://github.com/atom/one-dark-syntax> `9c96f4454362267ac45322063e193ccf9d2debb1` | `styles/colors.less` | Hue 2; syntax foreground/background; hue 4; hue 5; hue 3 | MIT, Copyright (c) 2016 GitHub Inc.; `ThirdPartyLicenses/theme-one-dark-MIT.txt` | Cleared |
| One Light | <https://github.com/atom/one-light-syntax> `d84579027410c576086dfca14d934c4bd74b0438` | `styles/colors.less` | Hue 2; syntax foreground/background; hue 4; hue 5; hue 3 | MIT, Copyright (c) 2016 GitHub Inc.; `ThirdPartyLicenses/theme-one-light-MIT.txt` | Cleared |
| Oscura | <https://github.com/narative/oscura> `f8e450b4b1f2d0bacfec5119601f62bc982a6533` | `themes/oscura-midnight.json` | Numeric peach; editor foreground/background; attribute teal; deleted red; link blue | MIT, Copyright (c) 2025 Narative; `ThirdPartyLicenses/theme-oscura-MIT.txt` | Cleared |
| Rosé Pine Dawn and Rosé Pine Moon | <https://github.com/rose-pine/rose-pine-palette> `92af52b465ab6e47437aca223c9b8d3009a2023b` | `palette.json` | Rose; text/base; foam/love/iris | MIT, Copyright (c) mvllow; `ThirdPartyLicenses/theme-rose-pine-MIT.txt` | Cleared |
| Solarized Light and Solarized Dark | <https://github.com/altercation/solarized> `62f656a02f93c5190a8753159e34b385588d5ff3` | `vim-colors-solarized/colors/solarized.vim` | Blue; base00/base0; base3/base03; green/red/magenta | MIT, Copyright (c) 2011 Ethan Schoonover; `ThirdPartyLicenses/theme-solarized-MIT.txt` | Cleared |
| Tokyo Night | <https://github.com/tokyo-night/tokyo-night-vscode-theme> `7c0f11eaef322f293621ca7befe462214b7ea468` | `themes/tokyo-night-color-theme.json` | Blue accent; editor foreground/background; Git added/deleted; purple | MIT, Copyright (c) 2018-present Enkia; `ThirdPartyLicenses/theme-tokyo-night-MIT.txt` | Cleared |

### Owner-provided replacement palettes

Parchment, Harbor, Forge, Axis, Lagoon, Phosphor, Citrus, Paper, Signal,
Watchtower, Monolith, Workbench, and Blueprint now use twenty-two replacement
variants supplied by the project owner on 2026-08-05. The supplied catalog
states that every value was generated independently from hue, saturation, and
lightness specifications rather than sampled from or adjusted out of another
palette. Exact-value tests protect the approved inputs. Superseded preference
IDs exist only as private, idempotent migration aliases in
`ThemeSettingsStore`; they are not user-visible catalog names.

### Owner-authored custom palettes

Brasspants, Codechimp, Greaseball, Lobster, Proof, Sockpuppet, and Temple retain
their current names and colors. The project owner confirmed on 2026-08-07 that
these palettes were created by Rojhat Toptamuş. They are first-party assets
under Monknot's MIT License. The former `*-monkey-*` internal IDs were replaced
with neutral current IDs and retained only as private migration aliases.

Gruvbox Light and Gruvbox Dark were removed from the application and website
catalog because complete authoritative license evidence was not retained. They
are not present in the distributed application or third-party notice list.

Monknot also links only against Apple system frameworks and renders system fonts
and SF Symbols by name. Those platform-provided resources are not vendored into
the repository or copied into the app as third-party packages. `Package.swift`
declares no external SwiftPM package dependencies, and the repository has no
`Package.resolved` file or bundled third-party frameworks.

## Repository-only and development dependencies

These items are not copied by `script/build_and_run.sh` into `Monknot.app`:

| Component | Location/use | License/provenance | Status |
| --- | --- | --- | --- |
| `dc-runtime` generated output | `spec/support.js` | Header identifies generation from absent `dc-runtime/src/*.ts`; no source URL or license notice is present | **Manual review required** |
| React and ReactDOM | 18.3.1, loaded from unpkg only by `spec/support.js` | MIT, [official React repository](https://github.com/facebook/react) | Verified as development/spec runtime; not an app-bundle notice |
| `@babel/standalone` | 7.29.0, loaded from unpkg only by `spec/support.js` when needed | MIT, [official Babel repository](https://github.com/babel/babel) | Verified as development/spec runtime; not an app-bundle notice |
| GitHub-maintained workflow action | SHA-pinned [`actions/checkout`](https://github.com/actions/checkout) | MIT in the official action repository | Build-service dependency only; not an app-bundle notice |
| Historical Store-marketing compositions | `app-store/` | Designer-delivered captures retained as repository-only marketing source material | Not copied into the app, DMG, or website; review publication rights before reuse |
| README workspace screenshot and non-logo website captures | `docs/images`, `website/shots` | Repository contains no separate source/ownership record for every image | Not copied into the app bundle; review publication rights before reuse outside their current project context |

The design specimen references system font-family names but bundles no font
files. GitHub-hosted runners, Xcode, Swift, macOS command-line tools, and App
Store services are build/platform tooling rather than components distributed in
the app.

## License obligations and risk summary

- Verified distributed third-party code is MIT-licensed. Keep each complete MIT
  text and its copyright notice with every distributed app bundle.
- No GPL, AGPL, LGPL, SSPL, Business Source License, Commons Clause, or other
  source-disclosure/relinking restriction was found in the verified distributed
  dependencies.
- No source-code offer or relinking mechanism is required by the verified MIT
  dependencies.
- The current app icon/logo and named first-party theme palettes are covered by
  the owner’s authorship confirmation and Monknot's MIT License.
- Unknown provenance is not a permissive license. The generated spec runtime
  and repository-only screenshots remain review items if their distribution
  scope changes, but they are not application-bundle release blockers.
- No custom end-user license agreement is stored in this repository. The MIT
  License governs Monknot's first-party code and assets.

## Maintenance procedure

Before accepting a new vendored library, asset, font, theme, package, or
generated file:

1. Record its exact name, version, canonical source, source revision, license,
   copyright holder, and whether it ships in the app.
2. Preserve all required notices and the complete license text without altering
   the third party's terms.
3. Hash vendored release files and make the release verifier compare the bundle
   with the audited source copies.
4. Escalate unknown, restrictive, reciprocal, trademark-sensitive, or
   source-unavailable material for manual legal review before distribution.
5. Update this audit, `THIRD_PARTY_NOTICES.md`, bundle-copy rules, verification
   scripts, and tests in the same change.
