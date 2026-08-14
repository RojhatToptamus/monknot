#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"
SPARKLE_PUBLIC_ED_KEY_FILE="$ROOT_DIR/SPARKLE_PUBLIC_ED_KEY"
BUNDLE_ID="com.monknot.app"
EXPECTED_DEVELOPER_ID="Developer ID Application: rojhat toptamus (ZD35XP4V7D)"
EXPECTED_TEAM_ID="ZD35XP4V7D"
APP_COPYRIGHT="Copyright © 2026 Rojhat Toptamuş"
DMG_PATH=""
EXPECTED_RELEASE_VERSION=""
EXPECTED_BUILD_NUMBER=""
EXPECTED_ARCH="arm64"
MIN_SYSTEM_VERSION="14.0"
SPARKLE_VERSION="2.9.5"
SPARKLE_MIN_SYSTEM_VERSION="11.0"
SPARKLE_FEED_URL="https://monknot.app/updates/appcast.xml"
ADHOC=0
MOUNT_POINT=""
SMOKE_DIRECTORY=""
SMOKE_PID=""
ATTACHED=0
THEME_LICENSE_FILES=(
  theme-ayu-MIT.txt
  theme-catppuccin-MIT.txt
  theme-dracula-MIT.txt
  theme-everforest-MIT.txt
  theme-night-owl-MIT.txt
  theme-nord-MIT.txt
  theme-one-dark-MIT.txt
  theme-one-light-MIT.txt
  theme-oscura-MIT.txt
  theme-rose-pine-MIT.txt
  theme-solarized-MIT.txt
  theme-tokyo-night-MIT.txt
)

usage() {
  cat <<USAGE
Usage: script/verify_release_artifact.sh [options] DMG

Mounts and verifies a packaged Monknot DMG, including its checksum, bundle
metadata, deployment target, architecture, signatures, legal payload, and
runtime launch.

Options:
  --adhoc                    Require local diagnostic ad-hoc signatures.
  --expected-version VERSION Expected semantic release version. Defaults to VERSION.
  --expected-build NUMBER    Expected numeric CFBundleVersion.
  --expected-arch ARCH       Expected architecture. Direct releases require arm64.
  --help, -h                 Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --adhoc)
      ADHOC=1
      shift
      ;;
    --expected-version)
      EXPECTED_RELEASE_VERSION="${2:?missing value for --expected-version}"
      shift 2
      ;;
    --expected-build)
      EXPECTED_BUILD_NUMBER="${2:?missing value for --expected-build}"
      shift 2
      ;;
    --expected-arch)
      EXPECTED_ARCH="${2:?missing value for --expected-arch}"
      shift 2
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
      if [[ -n "$DMG_PATH" ]]; then
        echo "only one DMG path may be provided" >&2
        exit 64
      fi
      DMG_PATH="$1"
      shift
      ;;
  esac
done

if [[ -z "$DMG_PATH" ]]; then
  usage >&2
  exit 64
fi
if [[ ! -f "$VERSION_FILE" ]]; then
  echo "missing release version file: $VERSION_FILE" >&2
  exit 66
fi
if [[ ! -f "$BUILD_NUMBER_FILE" ]]; then
  echo "missing build number file: $BUILD_NUMBER_FILE" >&2
  exit 66
fi
if [[ ! -s "$SPARKLE_PUBLIC_ED_KEY_FILE" ]]; then
  echo "missing tracked Sparkle public key: $SPARKLE_PUBLIC_ED_KEY_FILE" >&2
  exit 66
fi
if [[ -z "$EXPECTED_RELEASE_VERSION" ]]; then
  EXPECTED_RELEASE_VERSION="$(tr -d '\r\n' <"$VERSION_FILE")"
fi
if [[ -z "$EXPECTED_BUILD_NUMBER" ]]; then
  EXPECTED_BUILD_NUMBER="$(tr -d '\r\n' <"$BUILD_NUMBER_FILE")"
fi
if [[ ! "$EXPECTED_RELEASE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "invalid expected release version: $EXPECTED_RELEASE_VERSION" >&2
  exit 64
fi
if [[ -n "$EXPECTED_BUILD_NUMBER" && ! "$EXPECTED_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "invalid expected build number: $EXPECTED_BUILD_NUMBER" >&2
  exit 64
fi
if [[ "$EXPECTED_ARCH" != "arm64" ]]; then
  echo "release artifacts currently support arm64 only: $EXPECTED_ARCH" >&2
  exit 64
fi

EXPECTED_BUNDLE_VERSION="${EXPECTED_RELEASE_VERSION%%[-+]*}"
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"
CHECKSUM_PATH="$DMG_PATH.sha256"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required tool: $1" >&2
    exit 69
  fi
}

for tool in codesign cmp file hdiutil lipo otool shasum xcrun; do
  require_tool "$tool"
done
if [[ "$ADHOC" != "1" ]]; then
  require_tool spctl
fi

cleanup() {
  if [[ -n "$SMOKE_PID" ]] && kill -0 "$SMOKE_PID" >/dev/null 2>&1; then
    kill "$SMOKE_PID" >/dev/null 2>&1 || true
    wait "$SMOKE_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$ATTACHED" == "1" && -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SMOKE_DIRECTORY" && -d "$SMOKE_DIRECTORY" ]]; then
    rm -rf -- "$SMOKE_DIRECTORY"
  fi
}
trap cleanup EXIT

if [[ ! -s "$DMG_PATH" ]]; then
  echo "DMG is missing or empty: $DMG_PATH" >&2
  exit 66
fi
if [[ ! -s "$CHECKSUM_PATH" ]]; then
  echo "checksum is missing or empty: $CHECKSUM_PATH" >&2
  exit 66
fi

(
  cd "$(dirname "$DMG_PATH")"
  shasum -a 256 -c "$(basename "$CHECKSUM_PATH")"
)
hdiutil verify "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

DMG_SIGNATURE="$(codesign -dvvv "$DMG_PATH" 2>&1 || true)"
if [[ "$ADHOC" == "1" ]]; then
  if ! grep -q "Signature=adhoc" <<<"$DMG_SIGNATURE"; then
    echo "DMG does not have the required ad-hoc signature" >&2
    exit 1
  fi
else
  if ! grep -F "Authority=$EXPECTED_DEVELOPER_ID" <<<"$DMG_SIGNATURE" >/dev/null; then
    echo "DMG is not signed with the expected Developer ID identity" >&2
    exit 1
  fi
  if ! grep -F "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$DMG_SIGNATURE" >/dev/null; then
    echo "DMG has an unexpected TeamIdentifier" >&2
    exit 1
  fi
  if ! grep -F "Timestamp=" <<<"$DMG_SIGNATURE" >/dev/null; then
    echo "DMG signature is missing a secure timestamp" >&2
    exit 1
  fi
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
fi

MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/monknot-release-mount.XXXXXX")"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null
ATTACHED=1

APP_BUNDLE="$MOUNT_POINT/Monknot.app"
APPLICATIONS_LINK="$MOUNT_POINT/Applications"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "DMG does not contain Monknot.app" >&2
  exit 1
fi
if [[ ! -L "$APPLICATIONS_LINK" || "$(readlink "$APPLICATIONS_LINK")" != "/Applications" ]]; then
  echo "DMG does not contain the expected Applications symlink" >&2
  exit 1
fi

while IFS= read -r TOP_LEVEL_ITEM; do
  case "$(basename "$TOP_LEVEL_ITEM")" in
    Monknot.app|Applications|.fseventsd|.Trashes|.Spotlight-V100)
      ;;
    *)
      echo "unexpected top-level DMG item: $(basename "$TOP_LEVEL_ITEM")" >&2
      exit 1
      ;;
  esac
done < <(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -print)

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/Monknot"
FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/libMonknotCore.dylib"
SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
SPARKLE_INFO_PLIST="$SPARKLE_FRAMEWORK/Versions/B/Resources/Info.plist"
SPARKLE_AUTOUPDATE="$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
SPARKLE_UPDATER_APP="$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
RESOURCES="$APP_BUNDLE/Contents/Resources"

if [[ ! -f "$INFO_PLIST" || ! -x "$EXECUTABLE" || ! -f "$FRAMEWORK" || ! -f "$SPARKLE_INFO_PLIST" ]]; then
  echo "packaged application structure is incomplete" >&2
  exit 1
fi
if [[ -e "$APP_BUNDLE/Contents/embedded.provisionprofile" ]]; then
  echo "Developer ID app unexpectedly contains an App Store provisioning profile" >&2
  exit 1
fi
if [[ -n "$(codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null || true)" ]]; then
  echo "Developer ID app unexpectedly contains code-signing entitlements" >&2
  exit 1
fi

ACTUAL_BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
ACTUAL_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
ACTUAL_MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"

if [[ "$ACTUAL_BUNDLE_VERSION" != "$EXPECTED_BUNDLE_VERSION" ]]; then
  echo "bundle version mismatch: $ACTUAL_BUNDLE_VERSION (expected $EXPECTED_BUNDLE_VERSION)" >&2
  exit 1
fi
if [[ -n "$EXPECTED_BUILD_NUMBER" && "$ACTUAL_BUILD_NUMBER" != "$EXPECTED_BUILD_NUMBER" ]]; then
  echo "build number mismatch: $ACTUAL_BUILD_NUMBER (expected $EXPECTED_BUILD_NUMBER)" >&2
  exit 1
fi
if [[ ! "$ACTUAL_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "bundle build number is not numeric: $ACTUAL_BUILD_NUMBER" >&2
  exit 1
fi
if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "unexpected bundle identifier: $ACTUAL_BUNDLE_ID" >&2
  exit 1
fi
if [[ "$ACTUAL_MINIMUM_SYSTEM" != "$MIN_SYSTEM_VERSION" ]]; then
  echo "unexpected LSMinimumSystemVersion: $ACTUAL_MINIMUM_SYSTEM" >&2
  exit 1
fi

verify_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "$key is missing or unexpected: ${actual:-<missing>}" >&2
    exit 1
  fi
}
verify_plist_value CFBundleName Monknot
verify_plist_value CFBundleDisplayName Monknot
verify_plist_value CFBundleExecutable Monknot
verify_plist_value CFBundlePackageType APPL
verify_plist_value NSHumanReadableCopyright "$APP_COPYRIGHT"
verify_plist_value SUFeedURL "$SPARKLE_FEED_URL"
verify_plist_value SURequireSignedFeed true
verify_plist_value SUVerifyUpdateBeforeExtraction true

verify_plist_absent() {
  local key="$1"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" >/dev/null 2>&1; then
    echo "$key must not be set" >&2
    exit 1
  fi
}
verify_plist_absent SUEnableSystemProfiling
verify_plist_absent SUSendProfileInfo
verify_plist_absent SUEnableAutomaticChecks

EXPECTED_SPARKLE_PUBLIC_ED_KEY="$(tr -d '\r\n' <"$SPARKLE_PUBLIC_ED_KEY_FILE")"
ACTUAL_SPARKLE_PUBLIC_ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST" 2>/dev/null || true)"
if [[ ! "$EXPECTED_SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ || "$ACTUAL_SPARKLE_PUBLIC_ED_KEY" != "$EXPECTED_SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "SUPublicEDKey is malformed or does not match the tracked public key" >&2
  exit 1
fi

ACTUAL_SPARKLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SPARKLE_INFO_PLIST" 2>/dev/null || true)"
if [[ "$ACTUAL_SPARKLE_VERSION" != "$SPARKLE_VERSION" ]]; then
  echo "Sparkle framework version is ${ACTUAL_SPARKLE_VERSION:-unknown}; expected $SPARKLE_VERSION" >&2
  exit 1
fi
if [[ ! -x "$SPARKLE_AUTOUPDATE" || ! -x "$SPARKLE_UPDATER_APP/Contents/MacOS/Updater" ]]; then
  echo "Sparkle Autoupdate or Updater.app helper is missing" >&2
  exit 1
fi
if [[ -e "$SPARKLE_FRAMEWORK/XPCServices" || -e "$SPARKLE_FRAMEWORK/Versions/B/XPCServices" ]]; then
  echo "unused Sparkle XPC services are present in the unsandboxed app" >&2
  exit 1
fi
if ! otool -L "$EXECUTABLE" | grep -F '@rpath/Sparkle.framework/Versions/B/Sparkle' >/dev/null; then
  echo "main executable does not link Sparkle.framework" >&2
  exit 1
fi

REQUIRED_LEGAL_FILES=(
  "Legal/LICENSE"
  "Legal/THIRD_PARTY_NOTICES.md"
  "Legal/ThirdParty/xterm-MIT.txt"
  "Legal/ThirdParty/xterm-addon-fit-MIT.txt"
  "Legal/ThirdParty/xterm-addon-search-MIT.txt"
  "Legal/ThirdParty/sparkle-MIT.txt"
)
for LICENSE_FILE in "${THEME_LICENSE_FILES[@]}"; do
  REQUIRED_LEGAL_FILES+=("Legal/ThirdParty/$LICENSE_FILE")
done
for RELATIVE_PATH in "${REQUIRED_LEGAL_FILES[@]}"; do
  if [[ ! -s "$RESOURCES/$RELATIVE_PATH" ]]; then
    echo "required packaged legal file is missing or empty: $RELATIVE_PATH" >&2
    exit 1
  fi
done

cmp "$ROOT_DIR/LICENSE" "$RESOURCES/Legal/LICENSE"
cmp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES/Legal/THIRD_PARTY_NOTICES.md"
cmp "$ROOT_DIR/ThirdPartyLicenses/xterm-MIT.txt" "$RESOURCES/Legal/ThirdParty/xterm-MIT.txt"
cmp "$ROOT_DIR/ThirdPartyLicenses/xterm-addon-fit-MIT.txt" "$RESOURCES/Legal/ThirdParty/xterm-addon-fit-MIT.txt"
cmp "$ROOT_DIR/ThirdPartyLicenses/xterm-addon-search-MIT.txt" "$RESOURCES/Legal/ThirdParty/xterm-addon-search-MIT.txt"
cmp "$ROOT_DIR/ThirdPartyLicenses/sparkle-MIT.txt" "$RESOURCES/Legal/ThirdParty/sparkle-MIT.txt"
for LICENSE_FILE in "${THEME_LICENSE_FILES[@]}"; do
  cmp "$ROOT_DIR/ThirdPartyLicenses/$LICENSE_FILE" "$RESOURCES/Legal/ThirdParty/$LICENSE_FILE"
done

verify_resource_hash() {
  local resource_path="$1"
  local expected_hash="$2"
  local actual_hash

  actual_hash="$(shasum -a 256 "$resource_path" | awk '{ print $1 }')"
  if [[ "$actual_hash" != "$expected_hash" ]]; then
    echo "third-party resource hash mismatch: ${resource_path#"$APP_BUNDLE/"}" >&2
    exit 1
  fi
}

verify_resource_hash \
  "$RESOURCES/xterm.js" \
  "1f991ac3b4b283ebf96e60ae23a00a52765dd3a2e46fa6fdda9f1aab032f7495"
verify_resource_hash \
  "$RESOURCES/xterm.css" \
  "ba8e6985669488981ccf40c0cefe3aba80722cb6c92de7ad628b0bd717faf2b6"
verify_resource_hash \
  "$RESOURCES/xterm-addon-fit.js" \
  "bdaefa370b1bfc42ee88d46fe6072400902a4d4b2d45cd93438dda9b23c97089"
verify_resource_hash \
  "$RESOURCES/xterm-addon-search.js" \
  "3cf52d71d9deb4ba60125087434c53e3fb35bb2249db9b13987991fd2db1c7bd"

SENSITIVE_PAYLOAD="$(
  find "$APP_BUNDLE" -type f \
    \( -name '.env' -o -name '.env.*' -o -name '*.key' -o -name '*.p12' \
       -o -name '*.pem' -o -name '*.pfx' -o -name '*.mobileprovision' \
       -o -name '*.provisionprofile' -o -name 'improvement_progress.md' \) \
    -print
)"
if [[ -n "$SENSITIVE_PAYLOAD" ]]; then
  echo "sensitive or development-only files are present in the app bundle:" >&2
  printf '%s\n' "$SENSITIVE_PAYLOAD" >&2
  exit 1
fi

verify_macho() {
  local binary_path="$1"
  local architectures
  local minimum_version
  local expected_minimum_version="$MIN_SYSTEM_VERSION"

  architectures="$(lipo -archs "$binary_path")"
  if [[ "$architectures" != "$EXPECTED_ARCH" ]]; then
    echo "architecture mismatch for ${binary_path#"$APP_BUNDLE/"}: $architectures (expected $EXPECTED_ARCH)" >&2
    exit 1
  fi

  if [[ "$binary_path" == "$SPARKLE_FRAMEWORK"/* ]]; then
    expected_minimum_version="$SPARKLE_MIN_SYSTEM_VERSION"
  fi
  minimum_version="$(xcrun vtool -show-build "$binary_path" | awk '$1 == "minos" { print $2; exit }')"
  if [[ "$minimum_version" != "$expected_minimum_version" ]]; then
    echo "deployment target mismatch for ${binary_path#"$APP_BUNDLE/"}: $minimum_version" >&2
    exit 1
  fi
}

MACHO_COUNT=0
NESTED_MACHO_COUNT=0
while IFS= read -r -d '' CANDIDATE; do
  if file -b "$CANDIDATE" | grep -q '^Mach-O'; then
    MACHO_COUNT=$((MACHO_COUNT + 1))
    [[ "$CANDIDATE" == "$EXECUTABLE" ]] || NESTED_MACHO_COUNT=$((NESTED_MACHO_COUNT + 1))
    verify_macho "$CANDIDATE"
    codesign --verify --strict --verbose=4 "$CANDIDATE"

    if [[ "$ADHOC" != "1" ]]; then
      CANDIDATE_SIGNATURE="$(codesign -dvvv "$CANDIDATE" 2>&1 || true)"
      if ! grep -F "Authority=$EXPECTED_DEVELOPER_ID" <<<"$CANDIDATE_SIGNATURE" >/dev/null; then
        echo "Mach-O file is not signed with the expected Developer ID identity: ${CANDIDATE#"$APP_BUNDLE/"}" >&2
        exit 1
      fi
      if ! grep -F "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$CANDIDATE_SIGNATURE" >/dev/null; then
        echo "Mach-O file has an unexpected TeamIdentifier: ${CANDIDATE#"$APP_BUNDLE/"}" >&2
        exit 1
      fi
      if ! grep -F "runtime" <<<"$CANDIDATE_SIGNATURE" >/dev/null; then
        echo "Mach-O file is missing Hardened Runtime: ${CANDIDATE#"$APP_BUNDLE/"}" >&2
        exit 1
      fi
      if ! grep -F "Timestamp=" <<<"$CANDIDATE_SIGNATURE" >/dev/null; then
        echo "Mach-O file is missing a secure timestamp: ${CANDIDATE#"$APP_BUNDLE/"}" >&2
        exit 1
      fi
      if [[ -n "$(codesign -d --entitlements - "$CANDIDATE" 2>/dev/null || true)" ]]; then
        echo "Mach-O file unexpectedly contains entitlements: ${CANDIDATE#"$APP_BUNDLE/"}" >&2
        exit 1
      fi
    fi
  fi
done < <(find "$APP_BUNDLE/Contents" -type f -print0)

if [[ "$MACHO_COUNT" == "0" || "$NESTED_MACHO_COUNT" == "0" ]]; then
  echo "expected the app executable and at least one nested Mach-O file" >&2
  exit 1
fi
echo "Verified $MACHO_COUNT Mach-O files, including $NESTED_MACHO_COUNT nested file(s)"

for CODE_BUNDLE in "$SPARKLE_UPDATER_APP" "$SPARKLE_FRAMEWORK"; do
  codesign --verify --strict --verbose=4 "$CODE_BUNDLE"
done

codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"

APP_SIGNATURE="$(codesign -dvvv "$APP_BUNDLE" 2>&1 || true)"
if [[ "$ADHOC" == "1" ]]; then
  if ! grep -q "Signature=adhoc" <<<"$APP_SIGNATURE"; then
    echo "application does not have the required ad-hoc signature" >&2
    exit 1
  fi
else
  if ! grep -F "Authority=$EXPECTED_DEVELOPER_ID" <<<"$APP_SIGNATURE" >/dev/null; then
    echo "application is not signed with the expected Developer ID identity" >&2
    exit 1
  fi
  if ! grep -F "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$APP_SIGNATURE" >/dev/null; then
    echo "application has an unexpected TeamIdentifier" >&2
    exit 1
  fi
  if ! grep -q "runtime" <<<"$APP_SIGNATURE"; then
    echo "application signature is missing hardened runtime" >&2
    exit 1
  fi
  if ! grep -F "Timestamp=" <<<"$APP_SIGNATURE" >/dev/null; then
    echo "application signature is missing a secure timestamp" >&2
    exit 1
  fi
  spctl --assess --type execute -vv "$APP_BUNDLE"
fi

SMOKE_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/monknot-release-smoke.XXXXXX")"
SMOKE_LOG="$SMOKE_DIRECTORY/Monknot.log"
CFFIXED_USER_HOME="$SMOKE_DIRECTORY" "$EXECUTABLE" >"$SMOKE_LOG" 2>&1 &
SMOKE_PID=$!

for _ in {1..12}; do
  if ! kill -0 "$SMOKE_PID" >/dev/null 2>&1; then
    echo "packaged application exited during runtime smoke test" >&2
    sed -n '1,160p' "$SMOKE_LOG" >&2
    exit 1
  fi
  sleep 0.25
done

kill "$SMOKE_PID" >/dev/null 2>&1 || true
wait "$SMOKE_PID" >/dev/null 2>&1 || true
SMOKE_PID=""

echo "Verified release artifact: $DMG_PATH"
echo "Release version: $EXPECTED_RELEASE_VERSION"
echo "Bundle version: $ACTUAL_BUNDLE_VERSION ($ACTUAL_BUILD_NUMBER)"
echo "Architecture: $EXPECTED_ARCH"
echo "Deployment target: macOS $MIN_SYSTEM_VERSION"
echo "Signing: $([[ "$ADHOC" == "1" ]] && echo "ad-hoc" || echo "Developer ID and notarized")"
