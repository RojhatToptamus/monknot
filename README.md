<p align="center">
  <img src="docs/images/monknot-readme-icon.png" width="104" height="104" alt="Monknot app icon">
</p>

<h1 align="center">Monknot</h1>

<p align="center">
  <strong>Markdown, PDFs, and a terminal. One window.</strong>
</p>

<p align="center">
  Write in Editor. Keep source and output together in Split. Read in Preview.<br>
  Search and annotate PDFs. Run Terminal sessions beside the active document.
</p>

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

<p align="center">
  <sub>Split · Markdown source and rendered output, scrolling in sync</sub>
</p>

## Features

**Editor:** Write Markdown and plain text with syntax highlighting, document
tabs, search, and a formatting bar when you want one.

**Writing assistance:** Fix spelling and grammar inline in Markdown, `.txt`,
and `.text` files. On supported Macs with macOS 26, private AI suggestions and
completions run on-device. They need no internet connection or AI subscription.
Press Tab for the next word, or hold Tab for the full completion. Apple Writing
Tools are also available on macOS 15.2 or later.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="website/shots/writing-assistance-light.gif">
    <source media="(prefers-color-scheme: dark)" srcset="website/shots/writing-assistance.gif">
    <img src="website/shots/writing-assistance.gif" width="800" height="520" alt="Monknot writing assistance in Field-brief.txt: automatic typo fixes, a reviewed grammar correction, full autocomplete acceptance, and the Apple Writing Tools menu">
  </picture>
</p>

<p align="center">
  <sub>Inline fixes · Reviewed grammar · On-device autocomplete · Apple Writing Tools</sub>
</p>

**Split:** Keep source and rendered output side by side, scrolling in sync.

**Preview:** Read the rendered document full width, including tables, task
lists, code blocks, links, and images.

**PDF:** Search documents and add highlights, underlines, strike-throughs, and
freehand marks. Markdown exports to PDF.

**Terminal:** Run several shell sessions beside the active document, switch
between them, and search bounded scrollback without leaving Monknot.

<p align="center">
  <img src="app-store/screenshots/macos/en-US/03-pdf-dark.png" width="49%" alt="Monknot PDF reader with annotation tools">
  <img src="app-store/screenshots/macos/en-US/04-terminal-dark.png" width="49%" alt="Monknot with terminal sessions beside the active document">
</p>

<p align="center">
  <sub>PDF · Terminal</sub>
</p>

## Install

1. Download the latest Apple-silicon DMG from [GitHub Releases](https://github.com/RojhatToptamus/monknot/releases).
2. Open the DMG and drag **Monknot** into **Applications**.
3. Open Monknot.

Release downloads are signed with a Developer ID certificate and notarized by Apple.

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
remain subject to their respective license terms in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
