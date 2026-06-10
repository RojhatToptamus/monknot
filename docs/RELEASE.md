# Monknot Release Checklist

Use this checklist when preparing a build for distribution outside your machine. The repository includes release preflight and packaging scripts, but notarized public distribution still requires a local Developer ID Application identity and a configured `notarytool` profile.

## Prerequisites

- macOS 14 or later on the build machine
- Xcode or Swift toolchain matching `Package.swift`
- Apple Developer ID Application certificate (for signed distribution)
- `notarytool` credentials saved as a keychain profile, or Apple notary API credentials
- Optional environment overrides:
  - `MONKNOT_DEVELOPER_ID_IDENTITY`
  - `MONKNOT_NOTARYTOOL_PROFILE`

## Build And Preflight

```sh
script/build_and_run.sh --verify
script/release_preflight.sh --allow-missing-identity
```

On a signing machine, rerun preflight without `--allow-missing-identity` before packaging. Confirm the app launches, opens a workspace, edits a file, and saves without errors.

## Entitlements

Monknot is built as a local file workspace editor. Typical entitlements:

- **App Sandbox**: off for the current manual bundle (full folder access via open panel + security-scoped bookmarks)
- **Hardened Runtime**: enable when signing for distribution
- **Outgoing network**: not required for local core features. Monknot does not store AI provider API keys or run an in-app AI chat flow; external terminal agents consume explicitly exported local context when the user runs the export CLI.

If you enable App Sandbox later, document these user-selected capabilities:

- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.files.bookmarks.app-scope`

## Package

```sh
script/release_package.sh --dry-run --skip-notarize
script/release_package.sh --skip-notarize
```

For a signed and notarized distribution DMG:

```sh
MONKNOT_DEVELOPER_ID_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
MONKNOT_NOTARYTOOL_PROFILE="AC_PROFILE" \
script/release_package.sh
```

The package script builds the app bundle, signs it with hardened runtime, creates a DMG, signs the DMG, submits notarization when enabled, staples the result, and runs `spctl` assessment.

## Smoke before ship

```sh
swift test
swift run MonknotSmokeTests
swift run MonknotStoreSmokeTests
swift run MonknotRecentWorkspaceSmokeTests
swift run MonknotShortcutSmokeTests
```

## Post-release

- Tag the release commit
- Archive the signed DMG and checksums
- Note known limitations, including no iCloud sync and no built-in AI provider integration
