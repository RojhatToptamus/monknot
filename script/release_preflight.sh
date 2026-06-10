#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="dist/monknot.app"
ALLOW_MISSING_IDENTITY=0
REQUIRED_IDENTITY="${MONKNOT_DEVELOPER_ID_IDENTITY:-Developer ID Application}"

usage() {
  cat <<USAGE
Usage: script/release_preflight.sh [--allow-missing-identity] [APP_BUNDLE]

Checks whether a Monknot .app bundle has the local prerequisites for Developer ID
signing and notarization. This script does not sign, notarize, or mutate the app.

Environment:
  MONKNOT_DEVELOPER_ID_IDENTITY   Identity substring to require in the keychain.
                                  Defaults to "Developer ID Application".
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-missing-identity)
      ALLOW_MISSING_IDENTITY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
    *)
      APP_BUNDLE="$1"
      shift
      ;;
  esac
done

failures=0
warnings=0

pass() {
  printf 'PASS  %s\n' "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf 'WARN  %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL  %s\n' "$1"
}

require_tool() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "$1 is available"
  else
    fail "$1 is not available"
  fi
}

echo "Monknot release preflight"
echo "App bundle: $APP_BUNDLE"
echo

require_tool codesign
require_tool security
require_tool spctl
require_tool hdiutil

if xcrun --find notarytool >/dev/null 2>&1; then
  pass "xcrun notarytool is available"
else
  fail "xcrun notarytool is not available"
fi

if xcrun --find stapler >/dev/null 2>&1; then
  pass "xcrun stapler is available"
else
  fail "xcrun stapler is not available"
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  fail "app bundle does not exist; run script/build_and_run.sh --verify first"
else
  pass "app bundle exists"

  INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
  if [[ -f "$INFO_PLIST" ]]; then
    pass "Info.plist exists"
    EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || true)"
    if [[ -n "$EXECUTABLE_NAME" && -x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" ]]; then
      pass "main executable exists: Contents/MacOS/$EXECUTABLE_NAME"
    else
      fail "main executable from CFBundleExecutable is missing or not executable"
    fi
  else
    fail "Info.plist is missing"
  fi

  if codesign -dvvv --entitlements :- "$APP_BUNDLE" >/tmp/monknot-codesign-preflight.txt 2>&1; then
    pass "bundle has a readable code signature"
    if grep -q "runtime" /tmp/monknot-codesign-preflight.txt; then
      pass "hardened runtime flag is present"
    else
      warn "hardened runtime flag was not detected; notarization requires hardened runtime"
    fi
  else
    warn "bundle is unsigned or ad-hoc only; distribution requires Developer ID signing"
  fi
fi

IDENTITIES="$(security find-identity -p codesigning -v 2>/dev/null || true)"
if printf '%s\n' "$IDENTITIES" | grep -q "$REQUIRED_IDENTITY"; then
  pass "matching signing identity found: $REQUIRED_IDENTITY"
else
  MESSAGE="missing signing identity matching \"$REQUIRED_IDENTITY\""
  if [[ "$ALLOW_MISSING_IDENTITY" == "1" ]]; then
    warn "$MESSAGE"
  else
    fail "$MESSAGE"
  fi
fi

echo
echo "Next distribution commands once prerequisites pass:"
echo "  codesign --force --options runtime --timestamp --sign \"Developer ID Application: ...\" \"$APP_BUNDLE\""
echo "  hdiutil create -volname Monknot -srcfolder \"$APP_BUNDLE\" -ov -format UDZO dist/Monknot.dmg"
echo "  xcrun notarytool submit dist/Monknot.dmg --keychain-profile <profile> --wait"
echo "  xcrun stapler staple dist/Monknot.dmg"

echo
echo "Summary: $failures failure(s), $warnings warning(s)"

if [[ "$failures" -gt 0 ]]; then
  exit 2
fi
