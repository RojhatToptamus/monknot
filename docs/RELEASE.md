# Monknot Release Guide

Monknot is an arm64 macOS app distributed directly through GitHub Releases in
a DMG. It does not use App Sandbox and is not a Mac App Store app. Production releases
use Developer ID signing, Hardened Runtime, secure timestamps, Apple
notarization, stapling, and Gatekeeper verification.

Updates use Sparkle 2.9.5. The stable feed is
`https://monknot.app/updates/appcast.xml`, which redirects to the
`appcast.xml` asset on the latest GitHub Release. Each update release contains
exactly these immutable assets:

- `Monknot-<version>-arm64.dmg`
- `Monknot-<version>-arm64.dmg.sha256`
- `appcast.xml`

Apple documents Developer ID for software distributed outside the Mac App
Store in [Developer ID certificates][developer-id]. Apple’s
[notarization guidance][notarization] requires Developer ID signing, Hardened
Runtime, and a secure timestamp. The app needs no exception entitlements.

[developer-id]: https://developer.apple.com/help/account/certificates/create-developer-id-certificates/
[notarization]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

## Release metadata

`VERSION` owns `CFBundleShortVersionString`. `BUILD_NUMBER` owns
`CFBundleVersion`. Both files must be committed, and the build number must
increase by exactly one for every release. Never reuse a build number or
replace an uploaded DMG.

The first Sparkle-enabled release is:

```text
VERSION                         0.1.1
BUILD_NUMBER                    2
Git tag                         v0.1.1
CFBundleShortVersionString      0.1.1
CFBundleVersion                 2
Artifact                        Monknot-0.1.1-arm64.dmg
Bundle identifier               com.monknot.app
Minimum macOS                   14.0
Architecture                    arm64
```

Users of 0.1.0 must install 0.1.1 manually. The first automatic-update test is
0.1.1 build 2 to 0.1.2 build 3.

Update `RELEASE_NOTES.md` for every release. The release workflow embeds this
file in the signed appcast and uses it as the GitHub Release notes.

## Sparkle key setup

The repository contains only the Ed25519 public key in
`SPARKLE_PUBLIC_ED_KEY`. Never commit or upload the private key. Perform all
private-key operations yourself on a trusted Mac.

After `swift package resolve`, use Sparkle’s official tool:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account monknot
```

Copy only the printed base64 public key into `SPARKLE_PUBLIC_ED_KEY` as one
line. Do not copy the private key into the repository, a shell argument, a
prompt, or a log.

Export the private key yourself to a protected location, then add it to the
GitHub Environment named `release`:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account monknot \
  -x /secure/path/to/private-key

gh secret set SPARKLE_ED25519_PRIVATE_KEY \
  --env release \
  --repo RojhatToptamus/monknot \
  < /secure/path/to/private-key
```

Delete the temporary export from its protected location and retain an
encrypted offline recovery copy. Do not list, retrieve, echo, decode, or test
the stored GitHub secret. The workflow exposes it only to the appcast-signing
step and passes it directly to `generate_appcast --ed-key-file -` on standard
input. It is not written to disk, passed as an argument, or uploaded.

The existing `release` environment also needs these secrets:

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `APPLE_API_KEY_P8`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `SPARKLE_ED25519_PRIVATE_KEY`

## Automated release flow

Pushing `v$(cat VERSION)` runs `.github/workflows/release.yml`:

1. Validate the version, sequential build number, exact tag, and `main`
   ancestry.
2. Build the SwiftPM products and run XCTest and executable smoke tests.
3. Build `Monknot.app` and embed the arm64 Sparkle framework.
4. Remove Sparkle’s unused XPC services because Monknot is unsandboxed.
5. Sign `Autoupdate`, `Updater.app`, `Sparkle.framework`,
   `libMonknotCore.dylib`, and `Monknot.app` in that order.
6. Create and Developer ID sign the DMG.
7. Submit the DMG to Apple, require `Accepted`, staple it, and run Gatekeeper.
8. Verify metadata, linkage, Sparkle 2.9.5 layout, arm64 slices, deployment
   targets, signatures, timestamps, lack of entitlements, and legal files.
9. Generate a one-item signed appcast from the final DMG. No delta, channel,
   phased, profiling, or analytics data is added.
10. Upload the DMG, checksum, and appcast to a draft GitHub Release.
11. Download and compare all three draft assets, then publish the release as
    latest. Until this final step, the stable feed cannot expose the update.

A failure before step 11 leaves no public stable update. If publication fails
after the draft is created, inspect and delete that draft before rerunning.
Never overwrite its assets.

## Protected dry-run

Before tagging, dispatch the Release workflow from the current `main` tip with
`publish_prerelease` disabled:

```sh
gh workflow run release.yml --ref main -f publish_prerelease=false
gh run watch
```

The dry-run performs signing, notarization, final artifact verification, and
signed appcast generation. It does not upload artifacts or create a release.

## Publish 0.1.1

Confirm the complete local suite and protected dry-run pass. Then tag the
exact `main` commit:

```sh
git tag v0.1.1
git show --no-patch --oneline v0.1.1
git push origin v0.1.1
```

After publication, verify all three assets and both URLs:

```text
https://github.com/RojhatToptamus/monknot/releases/download/v0.1.1/Monknot-0.1.1-arm64.dmg
https://monknot.app/updates/appcast.xml
```

Install 0.1.1 manually in `/Applications`. Launch it twice so Sparkle can show
its standard permission prompt. Confirm **Check for Updates…** reports no newer
stable version.

## Test 0.1.1 to 0.1.2

Set `VERSION` to `0.1.2`, `BUILD_NUMBER` to `3`, and update
`RELEASE_NOTES.md`. Dispatch the protected workflow with
`publish_prerelease=true`. It publishes the fully verified, immutable assets
as a GitHub prerelease without changing GitHub’s latest stable release.

On a test Mac with the public 0.1.1 app in `/Applications`, point Sparkle’s
user-default feed override to the prerelease appcast asset:

```sh
defaults write com.monknot.app SUFeedURL \
  'https://github.com/RojhatToptamus/monknot/releases/download/v0.1.2/appcast.xml'
```

Test manual and scheduled checks, automatic download/install on quit, relaunch,
offline failure, and an active terminal. Test multiple dirty windows and verify
Save, Discard, and Cancel. Cancel must leave 0.1.1 running and installed. Also
confirm a modified appcast or DMG is rejected.

Remove the test override afterward:

```sh
defaults delete com.monknot.app SUFeedURL
```

When the exact prerelease assets pass, promote the unchanged release:

```sh
gh release edit v0.1.2 --prerelease=false --latest \
  --repo RojhatToptamus/monknot
```

Do not upload or replace any asset during promotion. Repeat the update once
from an untouched public 0.1.1 installation using the stable feed.

## Local verification

The public key file is required for bundle builds. Normal local builds remain
unsandboxed and ad-hoc signed:

```sh
swift test
swift run MonknotSmokeTests
swift run MonknotStoreSmokeTests
swift run monknot-export --help
swift run monknot-capture --help
npm --prefix website run build
script/build_and_run.sh --verify
```

For local packaging diagnostics:

```sh
script/release_package.sh --adhoc
script/verify_release_artifact.sh \
  --adhoc \
  --expected-version "$(tr -d '\r\n' < VERSION)" \
  --expected-build "$(tr -d '\r\n' < BUILD_NUMBER)" \
  --expected-arch arm64 \
  "dist/Monknot-$(tr -d '\r\n' < VERSION)-arm64.dmg"
```

Ad-hoc or `--skip-notarize` output must never be published. Appcast generation
is intentionally limited to a final notarized and stapled DMG.

## Packaged legal payload

Every app includes the root `LICENSE`, `THIRD_PARTY_NOTICES.md`, Sparkle’s
complete license and external notices, the terminal licenses, and the verified
theme licenses under `Contents/Resources/Legal`. `LICENSE_AUDIT.md` is the
source inventory. The release verifier compares the packaged copies with the
repository.
