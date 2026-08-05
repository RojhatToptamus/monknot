# License Audit

Audit date: 2026-08-05

This file records the repository and release-bundle license inventory. It is a
technical compliance record, not legal advice and not a representation that an
uncleared item is suitable for commercial distribution.

## Release status

**Not cleared for production or Mac App Store release.** The vendored terminal
libraries and twelve canonical theme projects have verified MIT licenses and
complete notices. The thirteen neutral house themes now use independently
generated replacement palettes supplied by the project owner. Production
packaging remains blocked by seven custom palettes awaiting authorship
confirmation, Gruvbox's missing complete upstream license text, and the app
icon ownership review. The generated design-spec runtime also needs
provenance confirmation if it will remain in the proprietary repository or be
distributed outside the team.

## Distributed application contents

| Component | Version or location | License/provenance | Distribution action | Status |
| --- | --- | --- | --- | --- |
| Monknot source and documentation | Repository root | Proprietary; `LICENSE` | Ship the proprietary notice in `Contents/Resources/Legal/LICENSE` | Cleared by repository policy |
| `@xterm/xterm` | 5.5.0; `xterm.js`, `xterm.css` | MIT; official npm tarball and source revision recorded in `THIRD_PARTY_NOTICES.md` | Retain notices and ship `ThirdPartyLicenses/xterm-MIT.txt` | Verified |
| `@xterm/addon-fit` | 0.10.0; `xterm-addon-fit.js` | MIT; official npm tarball and source revision recorded in `THIRD_PARTY_NOTICES.md` | Retain notices and ship `ThirdPartyLicenses/xterm-addon-fit-MIT.txt` | Verified |
| App icon PNG set | `Sources/Monknot/Resources/Assets.xcassets` | Added in project history, but no source file, license, commission record, or ownership attestation is stored in the repository | Confirm original creation or obtain the applicable assignment/license and retain the evidence outside the public bundle | **Manual review required** |
| Verified theme-palette data | `Sources/MonknotCore/Models/MonknotThemeCatalog.swift` | Twelve canonical projects independently verified as MIT at the revisions below | Ship every corresponding complete license and notice | Verified only for the rows marked cleared below |
| Owner-provided house-theme palettes | Same catalog | Twenty-two independently generated variants supplied for Parchment, Harbor, Forge, Axis, Lagoon, Phosphor, Citrus, Paper, Signal, Watchtower, Monolith, Workbench, and Blueprint | Retain exact-value regression coverage | Cleared by project-owner representation |
| Remaining theme-palette data | Same catalog | Seven custom palettes and Gruvbox require further evidence or replacement | Keep development-only and block production/App Store packaging | **Release blocker** |

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
| Gruvbox Light / Dark | <https://github.com/morhetz/gruvbox> `5d15b2765f59754d7ac263c88a0f6e3e58124951` | `colors/gruvbox.vim` | Blue; foreground/background; green; red; purple | The README says MIT/X11, but this pinned tree contains no complete license text and no license file to reproduce | **Blocked: obtain complete authoritative license evidence or replace/remove** |
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

### Custom palettes awaiting evidence

Brasspants, Codechimp, Greaseball, Lobster, Proof, Sockpuppet, and Temple retain
their current names and colors. **Original authorship confirmation pending —
not cleared for release.** The former `*-monkey-*` internal IDs were replaced
with neutral current IDs and retained only as private migration aliases.

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
| GitHub-maintained workflow actions | SHA-pinned [`actions/checkout`](https://github.com/actions/checkout), [`actions/upload-artifact`](https://github.com/actions/upload-artifact), [`actions/download-artifact`](https://github.com/actions/download-artifact), and [`actions/attest`](https://github.com/actions/attest) | MIT in the official action repositories | Build-service dependencies only; not app-bundle notices |
| README icon and workspace screenshot | `docs/images` | Added in project history; repository contains no separate source/ownership record | Confirm original creation or retained publication rights before public reuse |

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
- Unknown provenance is not a permissive license. The app icon and theme
  palettes remain release blockers for legal/ownership review; the generated
  spec runtime remains a repository/distribution review item.
- No custom end-user license agreement is stored in this repository. The release
  plan uses Apple's standard App Store EULA rather than adding an in-app EULA or
  custom legal screen.

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
