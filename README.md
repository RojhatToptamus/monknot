<p align="center">
  <img src="docs/images/monknot-readme-icon.png" width="104" height="104" alt="Monknot app icon">
</p>

<h1 align="center">Monknot</h1>

Monknot is a native macOS Markdown editor with PDF tools, an integrated
terminal, workspace-wide search and replace, and offline writing assistance.

Edit and preview Markdown side by side, search across files and searchable PDFs,
annotate PDFs, export Markdown to PDF, and keep a terminal beside your documents.

<p align="center">
  <a href="https://github.com/RojhatToptamus/monknot/releases">
    <img src="docs/images/download-for-macos.svg" width="224" alt="Download Monknot for macOS">
  </a>
</p>

<p align="center">
  <sub>macOS 14 or later · Apple silicon</sub>
</p>

<p align="center">
  <a href="https://monknot.app">Website</a>
  ·
  <a href="https://github.com/RojhatToptamus/monknot/releases">Releases</a>
  ·
  <a href="https://monknot.app/support">Support</a>
</p>

<br>

<p align="center">
  <img src="docs/images/monknot-workspace.png" alt="Monknot showing Markdown source and its rendered preview side by side">
</p>

## Capabilities

- **Markdown:** Edit Markdown with live preview, synchronized scrolling, daily
  notes, wikilinks, and document navigation.
- **Search and replace:** Search across text files and searchable PDFs. Preview
  scoped multi-file replacements before applying them and undo the last batch.
- **PDF:** Search and read PDFs, add highlights, underlines, strikeouts, drawings,
  and text boxes, then export annotations to Markdown or save an annotated copy.
- **Terminal:** Run terminal sessions beside your documents without leaving
  Monknot.
- **Export:** Export Markdown to PDF with page and layout controls.

### Writing assistance

Monknot provides inline spelling and grammar corrections for Markdown and text
files.

On supported Macs with macOS 26, optional on-device writing assistance can
propose sentence corrections and short completions using Apple's on-device
models. Suggestions remain optional and can be reviewed before they are applied.

Apple Writing Tools are also available on supported systems when enabled by
macOS.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="website/shots/writing-assistance-light.gif">
    <source media="(prefers-color-scheme: dark)" srcset="website/shots/writing-assistance.gif">
    <img src="website/shots/writing-assistance.gif" width="800" height="520" alt="Monknot editing Field-brief.txt. The demo corrects a typo, presents a grammar repair for review, accepts a full on-device completion, and opens Apple Writing Tools.">
  </picture>
</p>

<p align="center">
  <img src="docs/images/monknot-pdf-dark.png" width="49%" alt="Monknot PDF reader with annotation tools">
  <img src="docs/images/monknot-terminal-dark.png" width="49%" alt="Monknot with terminal sessions beside the active document">
</p>

## Install

1. Download the latest Apple-silicon DMG from [GitHub Releases](https://github.com/RojhatToptamus/monknot/releases).
2. Open the DMG and drag **Monknot** into **Applications**.
3. Open Monknot.

Releases are signed with a Developer ID certificate and notarized by Apple.

## Useful shortcuts

| Action | Shortcut |
| --- | --- |
| Quick Open | <kbd>⌘ P</kbd> |
| Go to Heading | <kbd>⇧ ⌘ O</kbd> |
| Show Writing Tools | <kbd>⌃ ⌘ R</kbd> |
| Toggle split editor | <kbd>⌘ \</kbd> |
| Toggle terminal | <kbd>⌥ ⌘ J</kbd> |

## License

Monknot is available under the [MIT License](LICENSE). Third-party components
remain subject to their [respective license terms](THIRD_PARTY_NOTICES.md).
