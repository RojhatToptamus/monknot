# Monknot Release Guide

Monknot is distributed directly through GitHub Releases as an Apple-silicon
DMG. Production builds are signed with Developer ID Application, use Hardened
Runtime and secure timestamps, and are notarized by Apple. Monknot is not a Mac
App Store app and does not use App Sandbox, an App Store provisioning profile,
Transporter, TestFlight, or a Store `.pkg`.

Apple documents Developer ID as the certificate for software distributed
outside the Mac App Store in [Developer ID certificates][developer-id]. Apple’s
[notarization requirements][notarization] require Developer ID signing,
Hardened Runtime, and a secure timestamp. The app currently needs no Hardened
Runtime exception entitlement, so production signing intentionally supplies no
entitlements file.

[developer-id]: https://developer.apple.com/help/account/certificates/create-developer-id-certificates/
[notarization]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

## Release contract

`VERSION` is the authoritative release version. It must contain a stable
semantic version with three numeric components. The first public release is:

```text
VERSION                         0.1.0
Git tag                         v0.1.0
CFBundleShortVersionString      0.1.0
CFBundleVersion                 1
Artifact                        Monknot-0.1.0-arm64.dmg
Bundle identifier               com.monknot.app
Minimum macOS                   14.0
Architecture                    arm64
Signing identity                Developer ID Application: rojhat toptamus (ZD35XP4V7D)
Team identifier                 ZD35XP4V7D
```

The release workflow rejects prerelease/build metadata, a tag that does not
exactly match `v$(cat VERSION)`, or a tagged commit that is not reachable from
`main`. The fixed build value is sufficient for the current direct-distribution
flow; there is no App Store build-number lifecycle.

## GitHub release environment

The signing/notarization job uses the protected GitHub Environment named
`release`. Configure these environment secrets by name only:

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `APPLE_API_KEY_P8`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`

`MACOS_CERTIFICATE_P12` is the base64-encoded Developer ID Application `.p12`.
The workflow imports it into a randomly passworded temporary keychain, limits
private-key access to `codesign`, verifies the exact identity, restores the
runner’s keychain list, deletes the certificate file, and deletes the temporary
keychain even when packaging fails.

The Apple API key is written with owner-only permissions only during the
notarization step. `notarytool` submits the DMG with `--wait`; the workflow
independently requires the returned status to be `Accepted`, then deletes the
temporary key, staples and validates the ticket, and runs Gatekeeper checks.
Never print, commit, cache, or upload any secret value or decoded credential.

## Automated flow

Pushing a matching tag runs `.github/workflows/release.yml`:

1. Validate the stable version, exact tag, and `main` ancestry.
2. Use an arm64 GitHub-hosted macOS runner with Xcode 26.3 and macOS 26 SDK.
3. Build shipping SwiftPM products and run XCTest plus executable smoke suites.
4. Build `Monknot.app` for arm64 with macOS 14 as its deployment target.
5. Import the Developer ID certificate into a temporary keychain.
6. Discover every nested Mach-O file, sign nested code first, then sign the app
   with `--options runtime --timestamp` and no entitlements.
7. Create `Monknot-<version>-arm64.dmg` containing `Monknot.app` and an
   Applications shortcut.
8. Submit that DMG to Apple with `notarytool --wait` and require `Accepted`.
9. Staple and validate the ticket, then assess the DMG and mounted app with
   Gatekeeper.
10. Verify bundle metadata, arm64 architecture, macOS 14 deployment target,
    exact authority/team, Hardened Runtime, every nested signature, absence of
    entitlements/provisioning profiles, legal payload, third-party hashes, and
    runtime launch.
11. Create the non-draft GitHub Release and attach only the final notarized,
    stapled DMG.

There is no unsigned or ad-hoc fallback in the workflow. A failed test, build,
signature, notarization, staple, Gatekeeper assessment, verification, or
missing artifact stops publication.

## Mandatory pre-release dry-run

Before creating `v0.1.0`, manually dispatch the Release workflow on `main` from
GitHub Actions or run:

```sh
gh workflow run release.yml --ref main
gh run watch
```

The workflow refuses a manual dispatch from any ref other than the current
`origin/main` tip. It uses the same protected `release` environment, temporary
Keychain import, Developer ID signing, DMG creation, Apple notarization,
stapling, Gatekeeper assessment, and final artifact verifier as a tagged
release. The run summary records the notarization submission ID.

The GitHub Release publishing step runs only for a tag-push event. A manual
dispatch does not create or push a tag, publish a GitHub Release, change
`VERSION`, or retain/upload the dry-run DMG. Review every workflow step and the
submission ID before approving the release tag.

## Before tagging

Run the complete local suite when the toolchain is available:

```sh
swift test
swift run MonknotSmokeTests
swift run MonknotStoreSmokeTests
swift run MonknotRecentWorkspaceSmokeTests
swift run MonknotShortcutSmokeTests
swift run MonknotWorkspaceExport
npm --prefix website run build
```

Then confirm:

- `VERSION` and release notes are committed on `main`.
- `git status` is clean.
- No `.p12`, `.p8`, provisioning profile, private key, `.env`, or build output
  is tracked.
- The named `release` environment and five secrets exist.
- The Developer ID certificate has not expired or been revoked.
- The mandatory manual Release workflow dry-run completed successfully on the
  same `main` commit that will be tagged.

Create and push the release tag only after those checks:

```sh
git tag v0.1.0
git show --no-patch --oneline v0.1.0
git push origin v0.1.0
```

Pushing the tag publishes the release, so do not push it as a dry run.

## Local packaging

Normal development builds remain unsandboxed and ad-hoc signed:

```sh
script/build_and_run.sh --verify
```

For local Developer ID packaging, the exact certificate and its private key
must be installed in Keychain. Store notarization credentials in a local
`notarytool` keychain profile and run:

```sh
MONKNOT_NOTARYTOOL_PROFILE="monknot-notary" \
script/release_package.sh --build-number 1

script/release_preflight.sh
script/verify_release_artifact.sh \
  --expected-version "$(tr -d '\r\n' < VERSION)" \
  --expected-build 1 \
  --expected-arch arm64 \
  "dist/Monknot-$(tr -d '\r\n' < VERSION)-arm64.dmg"
```

`--skip-notarize` and `--adhoc` exist only for local packaging diagnostics.
Their output is not a production release and must never be uploaded as a
fallback artifact.

## Terminal verification

The app is intentionally unsandboxed. `TerminalPTYSession` launches
`/bin/zsh -il`, so terminal sessions use normal login/interactive zsh startup,
inherit the user environment, and can resolve tools installed through shell
configuration and standard paths. Release verification must cover:

```text
pwd
echo
ls
git --version
which git
which claude; claude --version     # when installed
which codex; codex --version       # when installed
which node; node --version         # when installed
which brew                         # when installed
echo $PATH
```

Also verify the workspace working directory, login and interactive shell modes,
Ctrl+C, PTY resize, multiple sessions, `/opt/homebrew/bin`, and
`/usr/local/bin` when those directories/tools exist. XCTest exercises the PTY
contract on every release run. Before a public release, repeat the matrix from
the final installed DMG on a representative clean Mac; signing without App
Sandbox must not change shell behavior.

## Packaged legal payload

Monknot’s first-party source and assets are MIT-licensed. Every app includes the
root `LICENSE`, `THIRD_PARTY_NOTICES.md`, and the complete verified license
texts under `Contents/Resources/Legal`. Third-party software and palettes keep
their original licenses; the release verifier compares the packaged copies and
vendored xterm hashes with the audited repository files.

`LICENSE_AUDIT.md` is the source inventory. Gruvbox is not distributed. The
historical `app-store/` screenshot folder is not consumed by any product or
release build and does not represent a supported Store distribution path.
