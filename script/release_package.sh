#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/monknot.app"
DMG_PATH="$ROOT_DIR/dist/Monknot.dmg"
IDENTITY_QUERY="${MONKNOT_DEVELOPER_ID_IDENTITY:-Developer ID Application}"
KEYCHAIN_PROFILE="${MONKNOT_NOTARYTOOL_PROFILE:-}"
SKIP_NOTARIZE=0
DRY_RUN=0

usage() {
  cat <<USAGE
Usage: script/release_package.sh [options]

Builds, Developer ID signs, packages, and optionally notarizes Monknot.

Options:
  --identity NAME          Developer ID identity substring. Defaults to
                           MONKNOT_DEVELOPER_ID_IDENTITY or "Developer ID Application".
  --keychain-profile NAME  notarytool keychain profile. Defaults to
                           MONKNOT_NOTARYTOOL_PROFILE.
  --skip-notarize          Stop after creating a signed DMG.
  --dry-run                Print the release commands without running them.
  --app PATH               App bundle path. Defaults to dist/monknot.app.
  --dmg PATH               DMG output path. Defaults to dist/Monknot.dmg.
  --help, -h               Show this help.

Prerequisites:
  - Apple Developer Program membership with a Developer ID Application certificate.
  - A notarytool keychain profile unless --skip-notarize is used.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --app)
      APP_BUNDLE="${2:?missing value for --app}"
      shift 2
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

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "$DRY_RUN" != "1" ]]; then
    "$@"
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
          sub(/.*"/, "")
          sub(/".*/, "")
          print
          exit
        }
      '
}

require_tool codesign
require_tool security
require_tool hdiutil
require_tool xcrun
if [[ "$SKIP_NOTARIZE" != "1" ]]; then
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
    echo "Install a Developer ID Application certificate or pass --identity with a matching substring." >&2
    exit 65
  fi
fi

if [[ "$SKIP_NOTARIZE" != "1" && -z "$KEYCHAIN_PROFILE" ]]; then
  KEYCHAIN_PROFILE="<notarytool-profile>"
fi

echo "Monknot release package"
echo "App bundle: $APP_BUNDLE"
echo "DMG: $DMG_PATH"
echo "Identity: $SIGN_IDENTITY"
if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  echo "Notarization: skipped"
else
  echo "Notarization profile: $KEYCHAIN_PROFILE"
fi
echo

run "$ROOT_DIR/script/build_and_run.sh" --build

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "app bundle missing after build: $APP_BUNDLE" >&2
  exit 66
fi

FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/libMonknotCore.dylib"
if [[ -f "$FRAMEWORK" ]]; then
  run codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$FRAMEWORK"
fi

run codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
run codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

run rm -f "$DMG_PATH"
run hdiutil create -volname Monknot -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_PATH"
run codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
run codesign --verify --verbose=2 "$DMG_PATH"

if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  run xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
  run xcrun stapler staple "$DMG_PATH"
  run xcrun stapler validate "$DMG_PATH"
  run spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
fi

echo
echo "Release artifact ready: $DMG_PATH"
