# Monknot Release Checklist

Monknot's automated GitHub release path is configured for ad-hoc-signed alpha
artifacts, but production packaging is intentionally blocked while the theme
and asset items in `LICENSE_AUDIT.md` remain unresolved. Apple does not treat an
ad-hoc signature as a developer identity, and an ad-hoc build cannot be
notarized. The repository also has separate Developer ID and Mac App Store
packaging paths; signing credentials and provisioning profiles are never stored
in the repository.

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

## Local development signing

Normal local builds remain ad-hoc signed by default. To test stable developer
identity behavior, sign with one Apple Development certificate already installed
with its private key in the login Keychain:

```sh
script/build_and_run.sh --verify --development-sign
```

The script queries `security find-identity -v -p codesigning` and requires
exactly one match for `Apple Development`. If more than one development identity
is installed, select one with a full certificate name or SHA-1 identity hash:

```sh
MONKNOT_DEVELOPMENT_IDENTITY="Apple Development: YOUR NAME (TEAMID)" \
script/build_and_run.sh --verify --development-sign
```

The certificate name and SHA-1 identity are selectors, not credentials. They may
be supplied as temporary environment variables or shell-local configuration;
the certificate and private key stay in Keychain. Do not export a private key,
commit a `.p12`, provisioning profile, `.env` file, or Apple account credential.
The repository ignores those file types. Apple Development signing applies no
Store entitlements and embeds no Store provisioning profile, so it preserves the
normal unsandboxed development behavior. The resulting signature must report
TeamIdentifier `ZD35XP4V7D`; the script rejects a certificate from another team.

If `codesign` cannot build the certificate chain, install the matching current
WWDR intermediate from [Apple PKI](https://www.apple.com/certificateauthority/)
and leave the Apple Development leaf certificate on the system-default trust
setting. Do not mark a development leaf certificate as a trusted root.

Apple Development is not a distribution identity. Direct downloads still use
the Developer ID/notarization path, while App Store uploads still use the
application-distribution identity, installer-distribution identity, Store
profile, and sandbox entitlements described below.

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

## Packaged legal payload

Monknot is proprietary software. The root `LICENSE` contains Monknot's
proprietary notice; it is separate from the third-party license texts. Every app
bundle must contain:

```text
Contents/Resources/Legal/LICENSE
Contents/Resources/Legal/THIRD_PARTY_NOTICES.md
Contents/Resources/Legal/ThirdParty/xterm-MIT.txt
Contents/Resources/Legal/ThirdParty/xterm-addon-fit-MIT.txt
Contents/Resources/Legal/ThirdParty/theme-ayu-MIT.txt
Contents/Resources/Legal/ThirdParty/theme-catppuccin-MIT.txt
Contents/Resources/Legal/ThirdParty/theme-dracula-MIT.txt
Contents/Resources/Legal/ThirdParty/theme-everforest-MIT.txt
Contents/Resources/Legal/ThirdParty/theme-night-owl-MIT.txt
Contents/Resources/Legal/ThirdParty/theme-nord-MIT.txt
Contents/Resources/Legal/ThirdParty/theme-one-dark-MIT.txt
Contents/Resources/Legal/ThirdParty/theme-one-light-MIT.txt
Contents/Resources/Legal/ThirdParty/theme-oscura-MIT.txt
Contents/Resources/Legal/ThirdParty/theme-rose-pine-MIT.txt
Contents/Resources/Legal/ThirdParty/theme-solarized-MIT.txt
Contents/Resources/Legal/ThirdParty/theme-tokyo-night-MIT.txt
```

The release verifier compares these files with the source copies and validates
the hashes of the vendored xterm.js assets. It also validates
`NSHumanReadableCopyright` as
`Copyright © 2026 Rojhat Toptamuş. All rights reserved.` Do not add an Electron,
Chromium, React, or OpenAI Codex license unless the corresponding third-party
code is actually distributed in Monknot.

`LICENSE_AUDIT.md` is the repository compliance inventory. The owner-provided
house-theme replacement palettes are recorded as resolved. Release scripts fail
with `RELEASE_COMPLIANCE_BLOCKER` until custom-theme authorship is confirmed,
complete authoritative Gruvbox license evidence is obtained (or that preset is
replaced/removed), and the app icon review is resolved. The twelve verified MIT
theme projects are not a claim that the remaining catalog is cleared.

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

## Mac App Store candidate packaging

The permanent bundle identifier is `com.monknot.app`. The signing application
identifier is `ZD35XP4V7D.com.monknot.app`; the Team ID is not part of
`CFBundleIdentifier`.

The Mac App Store path is intentionally separate from direct-download
distribution. It uses `config/MonknotAppStore.entitlements`, a Mac App Store
Connect provisioning profile, an application distribution identity, and a Mac
Installer Distribution identity. It produces a signed `.pkg`, not a notarized
Developer ID DMG:

```sh
MONKNOT_APP_STORE_APP_IDENTITY="Mac App Distribution: YOUR NAME (ZD35XP4V7D)" \
MONKNOT_APP_STORE_INSTALLER_IDENTITY="Mac Installer Distribution: YOUR NAME (ZD35XP4V7D)" \
MONKNOT_APP_STORE_PROVISIONING_PROFILE="$PWD/private/Monknot_App_Store.provisionprofile" \
script/app_store_package.sh --build-number 1
```

An `Apple Distribution` application identity can be supplied instead when that
is the certificate issued for the team. The script does not hardcode certificate
names. It validates the profile's Team ID and explicit application identifier,
builds using `VERSION`, embeds the profile, signs `libMonknotCore.dylib` before
the main app, applies the App Store entitlements to the app, verifies both
signatures and the signed entitlements, then checks the package signature and
payload with `pkgutil`. Upload the package with
Transporter or another method supported by App Store Connect; Mac App Store
packages are not submitted to `notarytool`.

The App Store entitlement set is deliberately narrow:

- `com.apple.security.app-sandbox`: required for Mac App Store apps.
- `com.apple.security.files.user-selected.read-write`: the editor reads and
  modifies folders chosen in `NSOpenPanel`.
- `com.apple.security.files.bookmarks.app-scope`: Monknot persists the selected
  workspace and restores its security-scoped bookmark after restart.
- `com.apple.application-identifier` and
  `com.apple.developer.team-identifier`: bind the distribution signature to the
  registered explicit App ID and Team ID.

There is no network entitlement because Monknot contains no outgoing or incoming
network implementation. There is no entitlement for all files, Downloads,
user-selected executables, automation, or temporary sandbox exceptions.

Apple requires App Sandbox for Mac App Store distribution and documents folder
selection and persistent security-scoped bookmark access in
[App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
and [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).
Apple documents the distinct Mac App Distribution and Mac Installer Distribution
certificates in [Certificates overview](https://developer.apple.com/help/account/certificates/certificates-overview/),
and the required explicit App ID profile in
[Create an App Store provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile).

### Known sandbox blockers

Do not submit the current candidate without resolving and manually retesting
these behaviors:

- The embedded terminal launches `/bin/zsh` and lets the user run external
  commands. Its process behavior and access boundaries need a signed Store-build
  review with representative shell profiles and commands. Broad or temporary
  exception entitlements were not added.
- Recent-workspace and `monknot://capture` entries store or receive plain paths.
  Only the last workspace has a persisted security-scoped bookmark today.
  Reopening another recent path or accepting an arbitrary workspace path from a
  capture URL does not itself grant sandbox access. Store submission requires a
  bookmark per reopened workspace or a new user selection prompt.

These limitations are not present in the normal local or Developer ID builds,
which remain unsandboxed. No existing feature is silently disabled by the build
scripts.

`WorkspaceGitStatusService` still contains a `/usr/bin/git` launcher, but the
production store currently never calls it: `WorkspaceStore.refreshGitStatus()`
only clears any supplied status map. It therefore creates no current entitlement
or Store-runtime requirement. Re-enabling Git badges later requires a fresh
sandbox compatibility review.

### Apple portal and App Store Connect steps

1. Register the explicit App ID `com.monknot.app` with description
   `Monknot macOS App` for Team `ZD35XP4V7D`.
2. Create or select a Mac App Distribution/Apple Distribution certificate and a
   Mac Installer Distribution certificate, and install their private keys in
   the release keychain.
3. Create and download a Mac App Store Connect distribution provisioning profile
   for that explicit App ID and application distribution certificate.
4. Create the macOS app record in App Store Connect with the same bundle ID,
   complete agreements, tax/banking as applicable, privacy answers, category,
   age rating, screenshots, description, support URL, and review information.
   Do not provide a custom EULA; use Apple's standard App Store EULA. Apple
   documents that default in [Provide a custom license agreement](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/).
5. Resolve the sandbox blockers above, run the signed sandbox smoke matrix, build
   the package, and validate/upload it with Transporter.
6. Wait for processing, test the processed build through TestFlight if used,
   complete review notes, and submit the selected build for App Review.

Apple associates uploads with the app using the bundle ID and version values;
see [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).

### Local data after the identifier change

Changing the bundle identifier changes the standard preferences domain. Existing
development preferences under `io.github.rojhattoptamus.monknot` remain on disk
but are not automatically imported into `com.monknot.app`. That includes the last
workspace bookmark and UI preferences, so the first build with the new identifier
asks the user to choose a workspace again. The old data is not deleted.

For sandboxed builds, Application Support and preferences live inside
`~/Library/Containers/com.monknot.app`; direct-development data under the normal
user Library also remains untouched. Monknot has no Keychain service/access
group, updater configuration, login item, extension, XPC service, or embedded
helper bundle to migrate.

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

- Normal local and Developer ID builds are unsandboxed so the embedded terminal
  and system Git invocation retain their existing behavior. Mac App Store
  candidates use the dedicated sandbox entitlement file described above.
- No network entitlement is required and Monknot stores no AI-provider keys.
- Markdown preview escapes raw HTML and blocks active URL schemes.
- HTML preview disables page-authored JavaScript while retaining Monknot’s
  injected search and scroll-sync helpers.
- `monknot://capture` asks before writing a new inbox note.
- xterm.js license texts and provenance are included in every release bundle.
