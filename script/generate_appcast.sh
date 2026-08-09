#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"
SPARKLE_VERSION="2.9.5"
SPARKLE_TOOL="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
DOWNLOAD_ROOT="https://github.com/RojhatToptamus/monknot/releases/download"

usage() {
  echo "Usage: script/generate_appcast.sh FINAL_DMG RELEASE_NOTES OUTPUT_APPCAST" >&2
}

if [[ $# -ne 3 ]]; then
  usage
  exit 64
fi

DMG_PATH="$1"
RELEASE_NOTES_PATH="$2"
OUTPUT_PATH="$3"
RELEASE_VERSION="$(tr -d '\r\n' <"$VERSION_FILE")"
BUILD_NUMBER="$(tr -d '\r\n' <"$BUILD_NUMBER_FILE")"
EXPECTED_DMG_NAME="Monknot-$RELEASE_VERSION-arm64.dmg"

if [[ ! "$RELEASE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "invalid release version: $RELEASE_VERSION" >&2
  exit 64
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "invalid build number: $BUILD_NUMBER" >&2
  exit 64
fi
if [[ "$(basename "$DMG_PATH")" != "$EXPECTED_DMG_NAME" ]]; then
  echo "update artifact must be named $EXPECTED_DMG_NAME" >&2
  exit 64
fi
if [[ ! -s "$DMG_PATH" || ! -s "$DMG_PATH.sha256" || ! -s "$RELEASE_NOTES_PATH" ]]; then
  echo "final DMG, checksum, and release notes must exist before generating the appcast" >&2
  exit 66
fi
if [[ ! -x "$SPARKLE_TOOL" ]]; then
  echo "missing Sparkle $SPARKLE_VERSION generate_appcast tool; run swift package resolve" >&2
  exit 66
fi

(
  cd "$(dirname "$DMG_PATH")"
  shasum -a 256 -c "$(basename "$DMG_PATH").sha256"
)
codesign --verify --verbose=2 "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/monknot-appcast.XXXXXX")"
cleanup() {
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

ditto "$DMG_PATH" "$WORK_DIR/$EXPECTED_DMG_NAME"
ditto "$RELEASE_NOTES_PATH" "$WORK_DIR/${EXPECTED_DMG_NAME%.dmg}.md"

# The private Ed25519 key is supplied only on standard input. This script never
# stores it, accepts it as an argument, or includes it in generated artifacts.
"$SPARKLE_TOOL" \
  --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_ROOT/v$RELEASE_VERSION/" \
  --embed-release-notes \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  --link "https://monknot.app/" \
  -o "$WORK_DIR/appcast.xml" \
  "$WORK_DIR"

if [[ ! -s "$WORK_DIR/appcast.xml" ]]; then
  echo "Sparkle did not generate appcast.xml" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
ditto "$WORK_DIR/appcast.xml" "$OUTPUT_PATH"
echo "Generated signed appcast: $OUTPUT_PATH"
