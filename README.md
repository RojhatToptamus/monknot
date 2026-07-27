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

## macOS Guide

Monknot is currently an unsigned alpha release. The app bundle is ad-hoc signed
so macOS can detect accidental changes after packaging, but it is not signed
with an Apple Developer ID and it is not notarized. Gatekeeper may block the
first launch.

Download the DMG and its matching `.sha256` file from the same release. Before
opening the DMG, verify the download from Terminal:

```sh
cd ~/Downloads
shasum -a 256 -c Monknot-0.2.0-alpha.1-macos-arm64.dmg.sha256
```

Use the actual downloaded filename if the version or architecture differs.
Then open the DMG and drag **Monknot** to **Applications**.

If macOS blocks the first launch:

1. Try opening **Monknot** once.
2. Open **System Settings → Privacy & Security**.
3. Scroll down to **Security**.
4. Click **Open Anyway** next to Monknot. Apple makes this button available for
   about an hour after a blocked launch attempt.
5. Confirm with your password or Touch ID, then click **Open**.

This is Apple’s supported override for an app from an unidentified developer.
Only use it when you trust the release source and the checksum passed. See
[Apple’s safety guidance](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unidentified-developer-mh40616/mac).

If **Open Anyway** does not appear, or the app opens without showing a window,
quit Monknot. As an advanced last resort, and only after verifying the
checksum, remove the download quarantine flag and launch it again:

```sh
xattr -dr com.apple.quarantine "/Applications/Monknot.app"
open "/Applications/Monknot.app"
```

Removing quarantine bypasses this Gatekeeper check; it does not sign, notarize,
or independently verify the app.

## Development

Building the full app requires Xcode 26 or newer because Monknot conditionally
uses macOS 26 AppKit APIs. The resulting app still targets macOS 14 or later;
the build SDK and deployment target are separate.

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

## Releasing

Releases are tag-driven. `VERSION` is the authoritative release version, and
the tag must match it exactly with a `v` prefix:

```sh
# Update VERSION, release notes, and other release inputs, then commit them.
git tag v0.2.0-alpha.1
git push origin v0.2.0-alpha.1
```

GitHub Actions then tests, packages, mounts, signature-checks, launch-smokes,
and checksum-verifies separate Apple-silicon and Intel DMGs. If both builds
pass, it creates one draft GitHub Release containing:

- `Monknot-<version>-macos-arm64.dmg`
- `Monknot-<version>-macos-x86_64.dmg`
- each DMG’s matching `.sha256` file
- `SHA256SUMS-macOS.txt`

Pull requests and pushes to `main` run the XCTest suite, release-mode builds of
the shipping SwiftPM CLI products, executable smoke suites, and CLI entry-point
checks on both architectures before a release tag is created. Public releases
also receive GitHub artifact provenance attestations.

The workflow never publishes automatically. Download and test the assets,
mark alpha, beta, and release-candidate drafts as pre-releases, then publish
the verified draft manually.

The current alpha path requires no Apple Developer account. To reproduce the
same release locally on the current architecture:

```sh
script/release_package.sh --adhoc --build-number 1
script/release_preflight.sh --adhoc
script/verify_release_artifact.sh \
  --adhoc \
  --expected-build 1 \
  "dist/Monknot-$(tr -d '\r\n' < VERSION)-macos-$(uname -m).dmg"
```

Ad-hoc signing is not a substitute for Developer ID signing. It provides no
publisher identity, cannot be notarized, and does not prevent someone from
replacing and re-signing a modified download. Publish the generated checksum
over the trusted release channel.

## License

Monknot is available under the [MIT License](LICENSE). Bundled third-party
software retains its original license; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
[ThirdPartyLicenses](ThirdPartyLicenses).

### Future Developer ID release

Use your Apple Developer ID certificate and `notarytool` profile when preparing builds for distribution outside your machine.

Run the Developer ID preflight before attempting a notarized DMG.
`--allow-missing-identity` is useful only when inspecting prerequisites on a
machine without the certificate installed:

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

See [docs/RELEASE.md](docs/RELEASE.md) for the complete checklist.
