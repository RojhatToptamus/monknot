#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
APP_BUNDLE="$ROOT_DIR/dist/Monknot.app"
DMG_PATH=""
EXPECTED_DEVELOPER_ID="Developer ID Application: rojhat toptamus (ZD35XP4V7D)"
EXPECTED_TEAM_ID="ZD35XP4V7D"
IDENTITY_QUERY="${MONKNOT_DEVELOPER_ID_IDENTITY:-$EXPECTED_DEVELOPER_ID}"
KEYCHAIN_PROFILE="${MONKNOT_NOTARYTOOL_PROFILE:-}"
BUILD_NUMBER="${MONKNOT_BUILD_NUMBER:-1}"
TARGET_ARCH="${MONKNOT_TARGET_ARCH:-arm64}"
MIN_SYSTEM_VERSION="14.0"
ADHOC=0
SKIP_NOTARIZE=0
DRY_RUN=0

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "missing release version file: $VERSION_FILE" >&2
  exit 66
fi

RELEASE_VERSION="${MONKNOT_RELEASE_VERSION:-$(tr -d '\r\n' <"$VERSION_FILE")}"
BUNDLE_VERSION="${RELEASE_VERSION%%[-+]*}"

usage() {
  cat <<USAGE
Usage: script/release_package.sh [options]

Builds and packages Monknot for direct distribution.

Options:
  --adhoc                 Ad-hoc sign the app and DMG. This mode cannot be
                          notarized and Gatekeeper will warn users.
  --identity NAME          Developer ID identity substring. Defaults to
                           the Monknot Developer ID Application identity.
  --keychain-profile NAME  notarytool keychain profile. Defaults to
                           MONKNOT_NOTARYTOOL_PROFILE.
  --skip-notarize          Stop after creating a signed DMG.
  --version VERSION        Stable semantic release version. Defaults to VERSION or
                           MONKNOT_RELEASE_VERSION.
  --build-number NUMBER    Bundle build number. Defaults to MONKNOT_BUILD_NUMBER or 1.
  --dry-run                Print the release commands without running them.
  --dmg PATH               DMG output path. Defaults to a versioned, architecture-
                           specific path under dist.
  --help, -h               Show this help.

Prerequisites:
  - Local diagnostic package: no Apple Developer account; use --adhoc.
  - Trusted distribution: Apple Developer Program membership, a Developer ID
    Application certificate, and a notarytool keychain profile.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --adhoc)
      ADHOC=1
      SKIP_NOTARIZE=1
      shift
      ;;
    --identity)
      IDENTITY_QUERY="${2:?missing value for --identity}"
      shift 2
      ;;
    --keychain-profile)
      KEYCHAIN_PROFILE="${2:?missing value for --keychain-profile}"
      shift 2
      ;;
    --skip-notarize)
      SKIP_NOTARIZE=1
      shift
      ;;
    --version)
      RELEASE_VERSION="${2:?missing value for --version}"
      BUNDLE_VERSION="${RELEASE_VERSION%%[-+]*}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:?missing value for --build-number}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --dmg)
      DMG_PATH="${2:?missing value for --dmg}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ ! "$RELEASE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "invalid version (expected a stable semantic version such as 1.2.3): $RELEASE_VERSION" >&2
  exit 64
fi
if [[ ! "$BUNDLE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid bundle version derived from release version: $BUNDLE_VERSION" >&2
  exit 64
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "invalid build number (expected digits): $BUILD_NUMBER" >&2
  exit 64
fi
if [[ "$TARGET_ARCH" != "arm64" ]]; then
  echo "release packaging currently supports arm64 only: $TARGET_ARCH" >&2
  exit 64
fi

if [[ -z "$DMG_PATH" ]]; then
  DMG_PATH="$ROOT_DIR/dist/Monknot-$RELEASE_VERSION-$TARGET_ARCH.dmg"
fi
CHECKSUM_PATH="$DMG_PATH.sha256"

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "$DRY_RUN" != "1" ]]; then
    "$@"
  fi
}

write_checksum() {
  local directory
  local dmg_name
  local checksum_name
  directory="$(dirname "$DMG_PATH")"
  dmg_name="$(basename "$DMG_PATH")"
  checksum_name="$(basename "$CHECKSUM_PATH")"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ cd %q && shasum -a 256 %q > %q\n' "$directory" "$dmg_name" "$checksum_name"
  else
    (
      cd "$directory"
      shasum -a 256 "$dmg_name" >"$checksum_name"
    )
  fi
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required tool: $1" >&2
    exit 69
  fi
}

find_identity() {
  security find-identity -p codesigning -v 2>/dev/null \
    | awk -v query="$IDENTITY_QUERY" '
        index($0, query) {
          if (match($0, /"[^"]+"/)) {
            print substr($0, RSTART + 1, RLENGTH - 2)
            exit
          }
        }
      '
}

require_tool codesign
require_tool file
require_tool hdiutil
require_tool shasum

SIGN_IDENTITY="-"
if [[ "$ADHOC" != "1" ]]; then
  require_tool security
  if [[ "$SKIP_NOTARIZE" != "1" ]]; then
    require_tool xcrun
    require_tool spctl
    xcrun --find notarytool >/dev/null
    xcrun --find stapler >/dev/null
  fi

  if [[ "$SKIP_NOTARIZE" != "1" && -z "$KEYCHAIN_PROFILE" && "$DRY_RUN" != "1" ]]; then
    echo "missing notarytool keychain profile; set MONKNOT_NOTARYTOOL_PROFILE, pass --keychain-profile, or use --skip-notarize" >&2
    exit 64
  fi

  SIGN_IDENTITY="$(find_identity || true)"
  if [[ -z "$SIGN_IDENTITY" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      SIGN_IDENTITY="$IDENTITY_QUERY"
    else
      echo "missing Developer ID signing identity matching: $IDENTITY_QUERY" >&2
      echo "Install a Developer ID Application certificate, use --adhoc, or pass --identity with a matching substring." >&2
      exit 65
    fi
  fi
fi

if [[ "$ADHOC" != "1" && "$SKIP_NOTARIZE" != "1" && -z "$KEYCHAIN_PROFILE" ]]; then
  KEYCHAIN_PROFILE="<notarytool-profile>"
fi

echo "Monknot release package"
echo "App bundle: $APP_BUNDLE"
echo "DMG: $DMG_PATH"
echo "Release version: $RELEASE_VERSION"
echo "Bundle version: $BUNDLE_VERSION ($BUILD_NUMBER)"
echo "Target: $TARGET_ARCH-apple-macosx$MIN_SYSTEM_VERSION"
if [[ "$ADHOC" == "1" ]]; then
  echo "Signing: ad-hoc (no developer identity)"
  echo "Notarization: unavailable for ad-hoc signatures"
else
  echo "Identity: $SIGN_IDENTITY"
fi
if [[ "$ADHOC" != "1" && "$SKIP_NOTARIZE" == "1" ]]; then
  echo "Notarization: skipped"
elif [[ "$ADHOC" != "1" ]]; then
  echo "Notarization profile: $KEYCHAIN_PROFILE"
fi
echo

run env \
  "MONKNOT_SIGNING_MODE=adhoc" \
  "MONKNOT_VERSION=$BUNDLE_VERSION" \
  "MONKNOT_BUILD_NUMBER=$BUILD_NUMBER" \
  "MONKNOT_TARGET_ARCH=$TARGET_ARCH" \
  "MONKNOT_TARGET_TRIPLE=$TARGET_ARCH-apple-macosx$MIN_SYSTEM_VERSION" \
  "$ROOT_DIR/script/build_and_run.sh" --build

if [[ "$DRY_RUN" != "1" && ! -d "$APP_BUNDLE" ]]; then
  echo "app bundle missing after build: $APP_BUNDLE" >&2
  exit 66
fi

APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/Monknot"
sign_nested_macho_code() {
  local nested_count=0
  local candidate

  if [[ "$DRY_RUN" == "1" ]]; then
    candidate="$APP_BUNDLE/Contents/Frameworks/libMonknotCore.dylib"
    if [[ "$ADHOC" == "1" ]]; then
      run codesign --force --sign - "$candidate"
    else
      run codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$candidate"
    fi
    return
  fi

  while IFS= read -r -d '' candidate; do
    [[ "$candidate" == "$APP_EXECUTABLE" ]] && continue
    if file -b "$candidate" | grep -q '^Mach-O'; then
      nested_count=$((nested_count + 1))
      if [[ "$ADHOC" == "1" ]]; then
        run codesign --force --sign - "$candidate"
      else
        run codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$candidate"
      fi
    fi
  done < <(find "$APP_BUNDLE/Contents" -type f -print0)

  if [[ "$nested_count" == "0" ]]; then
    echo "no nested Mach-O code found to sign" >&2
    exit 1
  fi
  echo "Signed $nested_count nested Mach-O file(s) before the app bundle"
}

sign_nested_macho_code
if [[ "$ADHOC" == "1" ]]; then
  run codesign --force --sign - "$APP_BUNDLE"
else
  run codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi

run codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"

if [[ "$DRY_RUN" != "1" ]]; then
  if [[ -e "$APP_BUNDLE/Contents/embedded.provisionprofile" ]]; then
    echo "Developer ID app unexpectedly contains a provisioning profile" >&2
    exit 1
  fi
  if [[ -n "$(codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null || true)" ]]; then
    echo "Developer ID app unexpectedly contains entitlements" >&2
    exit 1
  fi

  if [[ "$ADHOC" != "1" ]]; then
    SIGNATURE_DETAILS="$(codesign -dvvv "$APP_BUNDLE" 2>&1)"
    if ! grep -F "Authority=$EXPECTED_DEVELOPER_ID" <<<"$SIGNATURE_DETAILS" >/dev/null; then
      echo "application was not signed with the expected Developer ID identity" >&2
      exit 1
    fi
    if ! grep -F "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$SIGNATURE_DETAILS" >/dev/null; then
      echo "application signature has an unexpected TeamIdentifier" >&2
      exit 1
    fi
    if ! grep -F "runtime" <<<"$SIGNATURE_DETAILS" >/dev/null; then
      echo "application signature is missing Hardened Runtime" >&2
      exit 1
    fi
    if ! grep -F "Timestamp=" <<<"$SIGNATURE_DETAILS" >/dev/null; then
      echo "application signature is missing a secure timestamp" >&2
      exit 1
    fi
  fi
fi

DMG_DIRECTORY="$(dirname "$DMG_PATH")"
run mkdir -p "$DMG_DIRECTORY"

STAGING_DIR="$DMG_DIRECTORY/.monknot-release.DRYRUN"
if [[ "$DRY_RUN" != "1" ]]; then
  STAGING_DIR="$(mktemp -d "$DMG_DIRECTORY/.monknot-release.XXXXXX")"
  cleanup() {
    if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then
      rm -rf "$STAGING_DIR"
    fi
  }
  trap cleanup EXIT
fi

run cp -R "$APP_BUNDLE" "$STAGING_DIR/Monknot.app"
run ln -s /Applications "$STAGING_DIR/Applications"
run rm -f "$DMG_PATH" "$CHECKSUM_PATH"
run hdiutil create -volname Monknot -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
if [[ "$ADHOC" == "1" ]]; then
  run codesign --force --sign - "$DMG_PATH"
else
  run codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi
run codesign --verify --verbose=2 "$DMG_PATH"

if [[ "$ADHOC" != "1" && "$SKIP_NOTARIZE" != "1" ]]; then
  run xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
  run xcrun stapler staple "$DMG_PATH"
  run xcrun stapler validate "$DMG_PATH"
  run spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
  run spctl --assess --type execute --verbose "$APP_BUNDLE"
fi

write_checksum

echo
echo "Release artifact ready: $DMG_PATH"
echo "SHA-256 checksum: $CHECKSUM_PATH"
