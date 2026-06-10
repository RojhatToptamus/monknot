<p align="center">
  <img src="Sources/Monknot/Resources/AppIcon.iconset/icon_256x256.png" width="96" height="96" alt="Monknot icon">
</p>

# Monknot

Monknot is a native macOS workspace editor for developers and writers who want one focused window for project files — browse folders, edit Markdown and text, preview in place, search across documents, and run a terminal without leaving the app.

Built with SwiftUI, AppKit, WebKit, PDFKit, FSEvents, and an embedded PTY terminal. Local-first: your files stay on disk; Monknot opens folders with security-scoped bookmarks and watches for external changes.

## Features

- Open folders or individual files from Finder, the Dock icon, or drag and drop.
- Browse a workspace with a native sidebar and lightweight document tabs.
- Edit Markdown, source files, and other text-like documents.
- Preview Markdown with live rendering and source navigation.
- Render PDFs in-app with PDFKit while unsupported binary/media file types stay out of the workspace document list.
- Search inside text and PDF documents across the workspace.
- Export Markdown documents to PDF.
- Use the embedded terminal in the current workspace.
- Copy, paste, drag, rename, move, and manage files without leaving the app.
- Resolve external file-change conflicts when a dirty document changes on disk.

## Development

Run the test suite:

```sh
swift test
```

Run integration smoke executables (also wired into SwiftPM):

```sh
swift run MonknotSmokeTests
swift run MonknotStoreSmokeTests
swift run MonknotRecentWorkspaceSmokeTests
swift run MonknotShortcutSmokeTests
```

Build and launch the macOS app bundle:

```sh
script/build_and_run.sh
```

Build and verify that the app launches:

```sh
script/build_and_run.sh --verify
```

## Agent-Friendly Export

Monknot does not store AI provider API keys or run an in-app AI chat flow. For Codex, Claude, OpenCode, Copilot, and other terminal agents, use the read-only workspace export CLI to provide local context from the terminal:

```sh
swift run monknot-export --workspace /path/to/workspace --json
```

The export surface is intentionally local, explicit, and read-only so external agents can consume workspace metadata and search context without Monknot becoming a weaker chat client.

## Capture Helpers

Monknot can import captured text or URLs into a workspace inbox through its `monknot://capture` URL scheme. For terminal, Shortcuts, or browser bookmarklet workflows, generate or open capture URLs with:

```sh
swift run monknot-capture --workspace /path/to/workspace --url https://example.com/research
swift run monknot-capture --workspace /path/to/workspace --url https://example.com/research --title "Readable page title"
swift run monknot-capture --workspace /path/to/workspace --text "Captured note"
pbpaste | swift run monknot-capture --workspace /path/to/workspace --stdin
swift run monknot-capture --workspace /path/to/workspace --url https://example.com --print-url
```

For a browser bookmarklet, replace `/path/to/workspace` below with your workspace path and save the one-line script as a bookmark:

```js
javascript:(()=>{const workspace="/path/to/workspace";const title=document.title||"";const url=location.href;location.href=`monknot://capture?workspace=${encodeURIComponent(workspace)}&url=${encodeURIComponent(url)}&title=${encodeURIComponent(title)}`;})();
```

## Distribution

Use your Apple Developer ID certificate and `notarytool` profile when preparing builds for distribution outside your machine.

Run the local release preflight before attempting a signed DMG. `--allow-missing-identity` is useful on development machines without the certificate installed:

```sh
script/build_and_run.sh --verify
script/release_preflight.sh --allow-missing-identity
```

Drop `--allow-missing-identity` when you expect the machine to have a `Developer ID Application` certificate installed.

When the certificate and notarytool profile are installed, build the signed DMG and submit it for notarization:

```sh
MONKNOT_DEVELOPER_ID_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
MONKNOT_NOTARYTOOL_PROFILE="monknot-notary" \
script/release_package.sh
```

Use `script/release_package.sh --skip-notarize` to produce a signed DMG without submitting it, or `--dry-run` to inspect the commands.
