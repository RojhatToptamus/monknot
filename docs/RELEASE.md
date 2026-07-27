# Monknot Release Checklist

Monknot currently ships as an ad-hoc-signed alpha because the project does not
yet have an Apple Developer Program account. Apple does not treat an ad-hoc
signature as a developer identity, and an ad-hoc build cannot be notarized.
Gatekeeper warnings are therefore expected.

## Release contract

`VERSION` is the single release-version source. It may contain a semantic
prerelease such as `0.2.0-alpha.1`. Release automation derives:

- Git tag and artifact version: `v0.2.0-alpha.1`
- `CFBundleShortVersionString`: `0.2.0`
- `CFBundleVersion`: the numeric GitHub Actions run number

The tag must point to a commit reachable from `main` and must exactly match
`v$(cat VERSION)`. GitHub Actions builds separate `arm64` and `x86_64`
artifacts, and it creates a draft release only after both pass.

Pull requests and pushes to `main` run the same XCTest, smoke, shipping-product
release builds, and CLI-entry-point checks on both architectures through
`.github/workflows/ci.yml`. Keep the `CI / Test macOS (arm64)` and
`CI / Test macOS (x86_64)` checks passing before tagging.

Both workflows select Xcode 26.3 and require a macOS 26 SDK because the app
conditionally uses `NSGlassEffectView`. This does not raise the deployment
target: the package, manual compiler target, bundle metadata, and artifact
verifier continue to require macOS 14.0.

## Before tagging

- Update `VERSION` and release notes, then commit them.
- Confirm `git status` is clean and the commit is on `main`.
- Confirm no certificate, provisioning profile, `.env`, private key, build
  output, local progress log, or user data is tracked.
- Run the full local verification set when possible:

```sh
swift test
swift run MonknotSmokeTests
swift run MonknotStoreSmokeTests
swift run MonknotRecentWorkspaceSmokeTests
swift run MonknotShortcutSmokeTests
swift run MonknotWorkspaceExport
```

The release workflow repeats these checks independently on Apple-silicon and
Intel GitHub-hosted runners.

## Creating the automated draft

For `VERSION` containing `0.2.0-alpha.1`:

```sh
git tag v0.2.0-alpha.1
git show --no-patch --oneline v0.2.0-alpha.1
git push origin v0.2.0-alpha.1
```

`.github/workflows/release.yml` then:

1. Validates the version, tag, and `main` ancestry.
2. Runs XCTest and all release smoke executables on both architectures.
3. Builds optimized binaries with an explicit macOS 14 deployment target.
4. Ad-hoc signs the embedded library, app bundle, and DMG.
5. Creates architecture-specific DMGs.
6. Verifies each checksum and disk image.
7. Mounts each DMG and checks bundle metadata, architecture, deployment target,
   signatures, required legal files, third-party asset hashes, and runtime
   launch.
8. Downloads the job artifacts and verifies their checksums again.
9. For public repositories, creates GitHub artifact provenance attestations
   for both DMGs and the aggregate checksum file.
10. Uploads both DMGs, their `.sha256` files, and
   `SHA256SUMS-macOS.txt` to one draft GitHub Release.

The workflow does not publish the release and does not automatically label it
as a pre-release.

## Local package verification

Build the current machine’s architecture using the version in `VERSION`:

```sh
script/release_package.sh --adhoc --build-number 1
script/release_preflight.sh --adhoc
script/verify_release_artifact.sh \
  --adhoc \
  --expected-build 1 \
  "dist/Monknot-$(tr -d '\r\n' < VERSION)-macos-$(uname -m).dmg"
```

The verifier launches the executable from the mounted DMG with isolated user
defaults, confirms that it remains running, terminates it, and detaches the
image. Ad-hoc Gatekeeper rejection is expected and is not treated as a failed
runtime smoke test.

## Draft release review

Before publishing:

- Confirm both architecture DMGs and all checksum files are attached.
- Download at least the artifact matching the test Mac and verify its checksum.
- For a public release, verify its GitHub provenance with:

```sh
gh attestation verify Monknot-0.2.0-alpha.1-macos-arm64.dmg \
  --repo RojhatToptamus/monknot
```

- Install it through the DMG and exercise the first-launch instructions in
  `README.md`.
- Manually confirm workspace open, edit/save, Markdown and HTML preview, PDF
  viewing, terminal start/kill, and clean application quit.
- State that the alpha is ad-hoc signed, not Developer ID signed, and not
  notarized.
- Mark alpha, beta, and release-candidate builds as pre-releases.
- State that macOS 14 or later is required and identify the two architectures.
- Note known limitations, including no notarization, automatic updates, or
  iCloud sync.
- Confirm Flow is disabled by default, uses only its documented loopback
  endpoint, and leaves editor text unchanged when Ollama is absent or times
  out.
- Confirm Flow diagnostics remain disabled by default and that enabled records contain
  no note text, suggestion text, file path, or document identifier.

## Packaged legal payload

Monknot’s source is MIT licensed. Every app bundle must contain:

```text
Contents/Resources/Legal/LICENSE
Contents/Resources/Legal/THIRD_PARTY_NOTICES.md
Contents/Resources/Legal/ThirdParty/xterm-MIT.txt
Contents/Resources/Legal/ThirdParty/xterm-addon-fit-MIT.txt
```

The release verifier compares these files with the source copies and validates
the hashes of the vendored xterm.js assets. Do not add an Electron, Chromium,
React, or OpenAI Codex license unless the corresponding third-party code is
actually distributed in Monknot.

## Developer ID release later

Trusted distribution outside the Mac App Store requires:

- Apple Developer Program membership
- a Developer ID Application certificate
- hardened runtime and secure timestamps
- `notarytool` credentials stored as a keychain profile

Preflight and package:

```sh
script/release_preflight.sh

MONKNOT_DEVELOPER_ID_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
MONKNOT_NOTARYTOOL_PROFILE="AC_PROFILE" \
script/release_package.sh --build-number 1
```

The Developer ID path signs nested code and the app with hardened runtime,
creates and signs the DMG, submits it with `notarytool`, staples the ticket, and
runs Gatekeeper assessment. `--skip-notarize` exists for diagnostic packaging;
do not present that output as the normal trusted release.

Do not add dormant signing-secret branches to the ad-hoc GitHub workflow. When
the account exists, update the workflow deliberately, store credentials as
GitHub environment secrets, and protect the release environment with required
reviewers.

## GitHub repository settings

- Require both `CI / Test macOS (arm64)` and `CI / Test macOS (x86_64)` before
  merging to `main`.
- Prevent force pushes and branch deletion on `main`.
- Keep the default `GITHUB_TOKEN` permission read-only. The release job alone
  elevates `contents`, `id-token`, and `attestations` permissions.
- Protect `v*` tags against deletion or modification after release.
- Enable private-vulnerability reporting, Dependabot alerts, and secret
  scanning before making the repository public.
- `.github/dependabot.yml` opens weekly pull requests when pinned GitHub Actions
  have supported updates.

## Current security posture

- App Sandbox is off. Monknot is a local workspace editor with an embedded
  interactive shell and intentionally needs broad access to folders the user
  opens.
- Monknot stores no AI-provider keys. Optional Flow writing assistance makes
  HTTP requests only to the loopback Ollama endpoint documented in
  `docs/TYPING_ASSISTANCE.md`; it does not call a cloud inference API.
- Markdown preview escapes raw HTML and blocks active URL schemes.
- HTML preview disables page-authored JavaScript while retaining Monknot’s
  injected search and scroll-sync helpers.
- `monknot://capture` asks before writing a new inbox note.
- xterm.js license texts and provenance are included in every release bundle.

Flow is experimental and must not be advertised as production-ready until the
model-quality, independent-review, and real-user trace gates in the companion
research repository pass.
