<p align="center">
  <img src="Sources/Monknot/Resources/AppIcon.iconset/icon_256x256.png" width="96" height="96" alt="Monknot icon">
</p>

# Monknot

Monknot is a native macOS workspace editor for reading, editing, previewing, and searching project files from one focused window.

It is built with SwiftUI, AppKit, WebKit, PDFKit, Quick Look, FSEvents, and an embedded PTY terminal.

## Features

- Open folders or individual files from Finder, the Dock icon, or drag and drop.
- Browse a workspace with a native sidebar and lightweight document tabs.
- Edit Markdown, source files, and other text-like documents.
- Preview Markdown with live rendering and source navigation.
- View PDFs, Quick Look supported files, and unsupported files safely.
- Search inside text and PDF documents across the workspace.
- Export Markdown documents to PDF.
- Use the embedded terminal in the current workspace.
- Copy, paste, drag, rename, move, and manage files without leaving the app.

## Development

Run the test suite:

```sh
swift test
```

Build and launch the macOS app bundle:

```sh
script/build_and_run.sh
```

Build and verify that the app launches:

```sh
script/build_and_run.sh --verify
```
