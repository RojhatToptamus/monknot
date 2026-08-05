#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
APP_BUNDLE="$ROOT_DIR/dist/Monknot.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_EXECUTABLE="$APP_CONTENTS/MacOS/Monknot"
FRAMEWORK="$APP_CONTENTS/Frameworks/libMonknotCore.dylib"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ENTITLEMENTS="$ROOT_DIR/config/MonknotAppStore.entitlements"
BUNDLE_ID="com.monknot.app"
TEAM_ID="ZD35XP4V7D"
APPLICATION_IDENTIFIER="$TEAM_ID.$BUNDLE_ID"
APP_IDENTITY="${MONKNOT_APP_STORE_APP_IDENTITY:-}"
INSTALLER_IDENTITY="${MONKNOT_APP_STORE_INSTALLER_IDENTITY:-}"
PROVISIONING_PROFILE="${MONKNOT_APP_STORE_PROVISIONING_PROFILE:-}"
BUILD_NUMBER="${MONKNOT_BUILD_NUMBER:-1}"
TARGET_ARCH="${MONKNOT_TARGET_ARCH:-$(uname -m)}"
MIN_SYSTEM_VERSION="14.0"
PKG_PATH=""

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "missing release version file: $VERSION_FILE" >&2
  exit 66
fi

RELEASE_VERSION="${MONKNOT_RELEASE_VERSION:-$(tr -d '\r\n' <"$VERSION_FILE")}"
BUNDLE_VERSION="${RELEASE_VERSION%%[-+]*}"

usage() {
  cat <<USAGE
Usage: script/app_store_package.sh [options]

Builds, signs, verifies, and packages Monknot for Mac App Store upload.
This is separate from the Developer ID DMG flow in release_package.sh.

Required environment:
  MONKNOT_APP_STORE_APP_IDENTITY        Mac App Distribution or Apple
                                         Distribution identity name or hash.
  MONKNOT_APP_STORE_INSTALLER_IDENTITY  Mac Installer Distribution identity
                                         name or hash.
  MONKNOT_APP_STORE_PROVISIONING_PROFILE
                                         Mac App Store Connect provisioning
                                         profile for com.monknot.app.

Options:
  --version VERSION       Semantic release version. Defaults to VERSION or
                          MONKNOT_RELEASE_VERSION.
  --build-number NUMBER   Numeric CFBundleVersion. Defaults to
                          MONKNOT_BUILD_NUMBER or 1.
  --package PATH          Output package. Defaults to a versioned path in dist.
  --help, -h              Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      RELEASE_VERSION="${2:?missing value for --version}"
      BUNDLE_VERSION="${RELEASE_VERSION%%[-+]*}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:?missing value for --build-number}"
      shift 2
      ;;
    --package)
      PKG_PATH="${2:?missing value for --package}"
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

if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  echo "invalid version: $RELEASE_VERSION" >&2
  exit 64
fi
if [[ ! "$BUNDLE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid bundle version derived from release version: $BUNDLE_VERSION" >&2
  exit 64
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "invalid build number: $BUILD_NUMBER" >&2
  exit 64
fi
if [[ ! "$TARGET_ARCH" =~ ^(arm64|x86_64)$ ]]; then
  echo "unsupported target architecture: $TARGET_ARCH" >&2
  exit 64
fi

echo "RELEASE_COMPLIANCE_BLOCKER: custom-theme authorship confirmation, complete Gruvbox license evidence, and app icon ownership review are still pending" >&2
exit 78

if [[ -z "$APP_IDENTITY" || -z "$INSTALLER_IDENTITY" || -z "$PROVISIONING_PROFILE" ]]; then
  echo "Mac App Store application identity, installer identity, and provisioning profile are required" >&2
  usage >&2
  exit 64
fi
if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
  echo "provisioning profile does not exist: $PROVISIONING_PROFILE" >&2
  exit 66
fi
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "App Store entitlements do not exist: $ENTITLEMENTS" >&2
  exit 66
fi
if [[ -z "$PKG_PATH" ]]; then
  PKG_PATH="$ROOT_DIR/dist/Monknot-$RELEASE_VERSION-mac-app-store.pkg"
fi

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required tool: $1" >&2
    exit 69
  fi
}

for tool in codesign pkgutil plutil productbuild security; do
  require_tool "$tool"
done

if ! security find-identity -v | grep -F "$APP_IDENTITY" >/dev/null; then
  echo "application signing identity was not found: $APP_IDENTITY" >&2
  exit 65
fi
if ! security find-identity -v | grep -F "$INSTALLER_IDENTITY" >/dev/null; then
  echo "installer signing identity was not found: $INSTALLER_IDENTITY" >&2
  exit 65
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/monknot-app-store.XXXXXX")"
cleanup() {
  if [[ -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

PROFILE_PLIST="$WORK_DIR/profile.plist"
SIGNED_ENTITLEMENTS="$WORK_DIR/signed-entitlements.plist"
security cms -D -i "$PROVISIONING_PROFILE" >"$PROFILE_PLIST"
plutil -lint "$PROFILE_PLIST" "$ENTITLEMENTS" >/dev/null

PROFILE_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST" 2>/dev/null || true)"
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
if [[ "$PROFILE_TEAM_ID" != "$TEAM_ID" ]]; then
  echo "provisioning profile Team ID is $PROFILE_TEAM_ID; expected $TEAM_ID" >&2
  exit 1
fi
if [[ "$PROFILE_APP_ID" != "$APPLICATION_IDENTIFIER" ]]; then
  echo "provisioning profile application identifier is $PROFILE_APP_ID; expected $APPLICATION_IDENTIFIER" >&2
  exit 1
fi

echo "Building Monknot $RELEASE_VERSION ($BUILD_NUMBER) for Mac App Store"
env \
  "MONKNOT_SIGNING_MODE=adhoc" \
  "MONKNOT_BUNDLE_ID=$BUNDLE_ID" \
  "MONKNOT_VERSION=$BUNDLE_VERSION" \
  "MONKNOT_BUILD_NUMBER=$BUILD_NUMBER" \
  "MONKNOT_TARGET_ARCH=$TARGET_ARCH" \
  "MONKNOT_TARGET_TRIPLE=$TARGET_ARCH-apple-macosx$MIN_SYSTEM_VERSION" \
  "$ROOT_DIR/script/build_and_run.sh" --build

if [[ ! -x "$APP_EXECUTABLE" || ! -f "$FRAMEWORK" || ! -f "$INFO_PLIST" ]]; then
  echo "built application structure is incomplete" >&2
  exit 1
fi
if find "$APP_CONTENTS" -type d \( -name '*.app' -o -name '*.appex' -o -name '*.xpc' \) -print -quit | grep -q .; then
  echo "unexpected embedded bundle found; assign it a com.monknot.app.* identifier and sign it before the main app" >&2
  exit 1
fi

cp "$PROVISIONING_PROFILE" "$APP_CONTENTS/embedded.provisionprofile"

# The only nested code today is MonknotCore. Sign nested code before the app.
codesign --force --sign "$APP_IDENTITY" "$FRAMEWORK"
codesign \
  --force \
  --sign "$APP_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$APP_BUNDLE"

codesign --verify --strict --verbose=2 "$FRAMEWORK"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign -dvvv "$APP_BUNDLE"
codesign -d --entitlements :- "$APP_BUNDLE" >"$SIGNED_ENTITLEMENTS"
plutil -lint "$SIGNED_ENTITLEMENTS" >/dev/null

verify_signed_entitlement() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$SIGNED_ENTITLEMENTS" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "signed entitlement $key is ${actual:-<missing>}; expected $expected" >&2
    exit 1
  fi
}
verify_signed_entitlement com.apple.application-identifier "$APPLICATION_IDENTIFIER"
verify_signed_entitlement com.apple.developer.team-identifier "$TEAM_ID"
verify_signed_entitlement com.apple.security.app-sandbox true
verify_signed_entitlement com.apple.security.files.user-selected.read-write true
verify_signed_entitlement com.apple.security.files.bookmarks.app-scope true
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$SIGNED_ENTITLEMENTS" >/dev/null 2>&1; then
  echo "unexpected network client entitlement in App Store signature" >&2
  exit 1
fi

mkdir -p "$(dirname "$PKG_PATH")"
rm -f "$PKG_PATH"
productbuild \
  --component "$APP_BUNDLE" /Applications \
  --sign "$INSTALLER_IDENTITY" \
  "$PKG_PATH"

pkgutil --check-signature "$PKG_PATH"
if ! pkgutil --payload-files "$PKG_PATH" | grep 'Monknot.app/Contents/MacOS/Monknot' >/dev/null; then
  echo "installer package does not contain the Monknot executable" >&2
  exit 1
fi

echo
echo "Mac App Store package ready: $PKG_PATH"
echo "Bundle identifier: $BUNDLE_ID"
echo "Application identifier: $APPLICATION_IDENTIFIER"
echo "Upload with Transporter or another App Store Connect-supported upload method."
