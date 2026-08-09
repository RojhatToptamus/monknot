#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"
APPCAST_PATH="${1:-$ROOT_DIR/dist/appcast.xml}"
RELEASE_VERSION="$(tr -d '\r\n' <"$VERSION_FILE")"
BUILD_NUMBER="$(tr -d '\r\n' <"$BUILD_NUMBER_FILE")"
DMG_PATH="$ROOT_DIR/dist/Monknot-$RELEASE_VERSION-arm64.dmg"
EXPECTED_URL="https://github.com/RojhatToptamus/monknot/releases/download/v$RELEASE_VERSION/Monknot-$RELEASE_VERSION-arm64.dmg"

if [[ $# -gt 1 ]]; then
  echo "Usage: script/verify_appcast.sh [APPCAST]" >&2
  exit 64
fi
if [[ ! -s "$APPCAST_PATH" ]]; then
  echo "appcast is missing or empty: $APPCAST_PATH" >&2
  exit 66
fi
if [[ ! -s "$DMG_PATH" ]]; then
  echo "matching update DMG is missing or empty: $DMG_PATH" >&2
  exit 66
fi
if ! command -v xmllint >/dev/null 2>&1; then
  echo "xmllint is required to verify the appcast" >&2
  exit 69
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required to verify Sparkle signatures" >&2
  exit 69
fi

xmllint --noout "$APPCAST_PATH"

xpath_string() {
  xmllint --xpath "string($1)" "$APPCAST_PATH"
}

ITEM_XPATH='/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"]'
ITEM_COUNT="$(xmllint --xpath "count($ITEM_XPATH)" "$APPCAST_PATH")"
ENCLOSURE_COUNT="$(xmllint --xpath "count($ITEM_XPATH/*[local-name()=\"enclosure\"])" "$APPCAST_PATH")"
DELTA_COUNT="$(xmllint --xpath "count(//*[local-name()=\"deltas\"])" "$APPCAST_PATH")"
CHANNEL_COUNT="$(xmllint --xpath "count(//*[local-name()=\"channel\" and namespace-uri()=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"])" "$APPCAST_PATH")"

if [[ "$ITEM_COUNT" != "1" || "$ENCLOSURE_COUNT" != "1" ]]; then
  echo "appcast must contain exactly one update item and one enclosure" >&2
  exit 1
fi
if [[ "$DELTA_COUNT" != "0" || "$CHANNEL_COUNT" != "0" ]]; then
  echo "appcast must not contain delta updates or Sparkle channels" >&2
  exit 1
fi

ACTUAL_BUILD="$(xpath_string "$ITEM_XPATH/*[local-name()=\"version\"]")"
ACTUAL_VERSION="$(xpath_string "$ITEM_XPATH/*[local-name()=\"shortVersionString\"]")"
ACTUAL_MINIMUM_SYSTEM="$(xpath_string "$ITEM_XPATH/*[local-name()=\"minimumSystemVersion\"]")"
ACTUAL_DESCRIPTION="$(xpath_string "$ITEM_XPATH/*[local-name()=\"description\"]")"
ACTUAL_URL="$(xpath_string "$ITEM_XPATH/*[local-name()=\"enclosure\"]/@url")"
ACTUAL_LENGTH="$(xpath_string "$ITEM_XPATH/*[local-name()=\"enclosure\"]/@length")"
ACTUAL_SIGNATURE="$(xpath_string "$ITEM_XPATH/*[local-name()=\"enclosure\"]/@*[local-name()=\"edSignature\"]")"

if [[ "$ACTUAL_BUILD" != "$BUILD_NUMBER" || "$ACTUAL_VERSION" != "$RELEASE_VERSION" ]]; then
  echo "appcast version mismatch: $ACTUAL_VERSION ($ACTUAL_BUILD)" >&2
  exit 1
fi
if [[ "$ACTUAL_MINIMUM_SYSTEM" != "14.0" ]]; then
  echo "appcast minimum system version is $ACTUAL_MINIMUM_SYSTEM; expected 14.0" >&2
  exit 1
fi
if [[ "$ACTUAL_URL" != "$EXPECTED_URL" ]]; then
  echo "appcast enclosure URL is unexpected: $ACTUAL_URL" >&2
  exit 1
fi
if [[ ! "$ACTUAL_LENGTH" =~ ^[1-9][0-9]*$ ]]; then
  echo "appcast enclosure length is missing or invalid" >&2
  exit 1
fi
if [[ "$ACTUAL_LENGTH" != "$(stat -f '%z' "$DMG_PATH")" ]]; then
  echo "appcast enclosure length does not match the final DMG" >&2
  exit 1
fi
if [[ ! "$ACTUAL_SIGNATURE" =~ ^[A-Za-z0-9+/]{86}==$ ]]; then
  echo "appcast enclosure Ed25519 signature is missing or invalid" >&2
  exit 1
fi
if [[ -z "$ACTUAL_DESCRIPTION" ]]; then
  echo "appcast must embed release notes" >&2
  exit 1
fi
if ! grep -q '<!-- sparkle-signatures:' "$APPCAST_PATH" || \
   ! grep -Eq '^edSignature: [A-Za-z0-9+/]{86}==$' "$APPCAST_PATH" || \
   ! grep -Eq '^length: [1-9][0-9]*$' "$APPCAST_PATH"; then
  echo "appcast signed-feed block is missing or malformed" >&2
  exit 1
fi

xcrun swift "$ROOT_DIR/script/verify_appcast_signatures.swift" \
  "$APPCAST_PATH" \
  "$DMG_PATH" \
  "$ROOT_DIR/SPARKLE_PUBLIC_ED_KEY"

echo "Verified signed Sparkle appcast: $APPCAST_PATH"
echo "Update: $ACTUAL_VERSION ($ACTUAL_BUILD)"
echo "DMG: $ACTUAL_URL"
