#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="dist/Monknot.app"
ADHOC=0
ALLOW_MISSING_IDENTITY=0
REQUIRED_IDENTITY="${MONKNOT_DEVELOPER_ID_IDENTITY:-Developer ID Application}"
MIN_SYSTEM_VERSION="14.0"
VERSION_FILE="VERSION"

usage() {
  cat <<USAGE
Usage: script/release_preflight.sh [--adhoc] [--allow-missing-identity] [APP_BUNDLE]

Checks repository hygiene, bundle metadata, signatures, and local packaging
prerequisites. This script does not sign, notarize, or mutate the app.

Options:
  --adhoc                    Validate the unsigned-alpha/ad-hoc release path.
  --allow-missing-identity   Warn instead of failing when Developer ID is absent.

Environment:
  MONKNOT_DEVELOPER_ID_IDENTITY   Identity substring to require in the keychain.
                                  Defaults to "Developer ID Application".
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --adhoc)
      ADHOC=1
      shift
      ;;
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
if [[ "$ADHOC" == "1" ]]; then
  echo "Release mode: ad-hoc alpha"
else
  echo "Release mode: Developer ID"
fi
echo

require_tool codesign
require_tool hdiutil
require_tool lipo
require_tool shasum
require_tool xcrun

if [[ "$ADHOC" != "1" ]]; then
  require_tool security
  require_tool spctl

  if command -v xcrun >/dev/null 2>&1; then
    pass "xcrun is available"
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
  else
    fail "xcrun is not available"
  fi
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git diff --quiet && git diff --cached --quiet; then
    pass "tracked worktree files are clean"
  else
    warn "tracked worktree files have uncommitted changes"
  fi

  if [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    pass "no untracked release inputs are present"
  else
    warn "untracked files are present; review git status before release"
  fi

  SENSITIVE_TRACKED_FILES="$(
    git ls-files \
      | grep -Ei '(^|/)(\.env($|\.)|id_rsa($|\.)|id_ed25519($|\.)|credentials?($|\.)|secrets?($|\.))|(\.p12|\.pfx|\.pem|\.key|\.mobileprovision|\.provisionprofile)$' \
      || true
  )"
  if [[ -z "$SENSITIVE_TRACKED_FILES" ]]; then
    pass "no sensitive credential filenames are tracked"
  else
    fail "sensitive credential-like files are tracked"
  fi

  SECRET_PATTERN='BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-(proj-)?[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}'
  UNTRACKED_SECRET=0
  while IFS= read -r -d '' UNTRACKED_FILE; do
    if grep -I -q -E "$SECRET_PATTERN" "$UNTRACKED_FILE"; then
      UNTRACKED_SECRET=1
      break
    fi
  done < <(git ls-files --others --exclude-standard -z)

  if git grep -I -q -E "$SECRET_PATTERN" -- . || [[ "$UNTRACKED_SECRET" == "1" ]]; then
    fail "a tracked or untracked file matches a high-confidence secret pattern"
  else
    pass "tracked and untracked files do not match high-confidence secret patterns"
  fi

  HISTORY_SECRET_MATCH=0
  while IFS= read -r COMMIT; do
    if git grep -I -q -E "$SECRET_PATTERN" "$COMMIT" -- . 2>/dev/null; then
      HISTORY_SECRET_MATCH=1
      break
    fi
  done < <(git rev-list --all)

  if [[ "$HISTORY_SECRET_MATCH" == "1" ]]; then
    fail "a reachable Git-history revision matches a high-confidence secret pattern"
  else
    pass "reachable Git history does not match high-confidence secret patterns"
  fi

  SENSITIVE_HISTORY_FILENAMES="$(
    git log --all --name-only --pretty=format: \
      | sort -u \
      | grep -Ei '(^|/)(\.env($|\.)|id_rsa($|\.)|id_ed25519($|\.)|credentials?($|\.)|secrets?($|\.))|(\.p12|\.pfx|\.pem|\.key|\.mobileprovision|\.provisionprofile)$' \
      || true
  )"
  if [[ -z "$SENSITIVE_HISTORY_FILENAMES" ]]; then
    pass "no sensitive credential filenames appear in reachable Git history"
  else
    fail "sensitive credential-like filenames appear in reachable Git history"
  fi
else
  warn "not running in a Git worktree; repository hygiene checks skipped"
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  fail "app bundle does not exist; run script/build_and_run.sh --build first"
else
  pass "app bundle exists"

  INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
  APP_RESOURCES="$APP_BUNDLE/Contents/Resources"
  FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/libMonknotCore.dylib"
  if [[ -f "$INFO_PLIST" ]]; then
    pass "Info.plist exists"
    EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || true)"
    if [[ -n "$EXECUTABLE_NAME" && -x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" ]]; then
      pass "main executable exists: Contents/MacOS/$EXECUTABLE_NAME"
    else
      fail "main executable from CFBundleExecutable is missing or not executable"
    fi

    BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
    if [[ "$BUNDLE_IDENTIFIER" == "io.github.rojhattoptamus.monknot" ]]; then
      pass "public bundle identifier is set: $BUNDLE_IDENTIFIER"
    elif [[ -n "$BUNDLE_IDENTIFIER" && "$BUNDLE_IDENTIFIER" != "com.local.monknot" ]]; then
      warn "non-default bundle identifier is set: $BUNDLE_IDENTIFIER"
    else
      fail "public bundle identifier is missing or still local-only"
    fi

    SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
    BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || true)"
    if [[ "$SHORT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_VERSION" =~ ^[0-9]+$ ]]; then
      pass "bundle version is set: $SHORT_VERSION ($BUILD_VERSION)"
    else
      fail "bundle version metadata is missing or malformed"
    fi

    if [[ -f "$VERSION_FILE" ]]; then
      RELEASE_VERSION="$(tr -d '\r\n' <"$VERSION_FILE")"
      EXPECTED_SHORT_VERSION="${RELEASE_VERSION%%[-+]*}"
      if [[ "$SHORT_VERSION" == "$EXPECTED_SHORT_VERSION" ]]; then
        pass "bundle version matches VERSION: $RELEASE_VERSION"
      else
        fail "bundle version $SHORT_VERSION does not match VERSION $RELEASE_VERSION"
      fi
    else
      fail "VERSION is missing"
    fi
  else
    fail "Info.plist is missing"
  fi

  REQUIRED_LEGAL_FILES=(
    "$APP_RESOURCES/Legal/LICENSE"
    "$APP_RESOURCES/Legal/THIRD_PARTY_NOTICES.md"
    "$APP_RESOURCES/Legal/ThirdParty/xterm-MIT.txt"
    "$APP_RESOURCES/Legal/ThirdParty/xterm-addon-fit-MIT.txt"
  )
  for LEGAL_FILE in "${REQUIRED_LEGAL_FILES[@]}"; do
    if [[ -s "$LEGAL_FILE" ]]; then
      pass "packaged legal file exists: ${LEGAL_FILE#"$APP_BUNDLE/"}"
    else
      fail "packaged legal file is missing or empty: ${LEGAL_FILE#"$APP_BUNDLE/"}"
    fi
  done

  verify_bundled_resource_hash() {
    local resource_path="$1"
    local expected_hash="$2"
    local actual_hash

    if [[ ! -f "$resource_path" ]]; then
      fail "bundled third-party resource is missing: ${resource_path#"$APP_BUNDLE/"}"
      return
    fi
    actual_hash="$(shasum -a 256 "$resource_path" | awk '{ print $1 }')"
    if [[ "$actual_hash" == "$expected_hash" ]]; then
      pass "bundled third-party resource hash matches: ${resource_path#"$APP_BUNDLE/"}"
    else
      fail "bundled third-party resource hash mismatch: ${resource_path#"$APP_BUNDLE/"}"
    fi
  }

  verify_bundled_resource_hash \
    "$APP_RESOURCES/xterm.js" \
    "1f991ac3b4b283ebf96e60ae23a00a52765dd3a2e46fa6fdda9f1aab032f7495"
  verify_bundled_resource_hash \
    "$APP_RESOURCES/xterm.css" \
    "ba8e6985669488981ccf40c0cefe3aba80722cb6c92de7ad628b0bd717faf2b6"
  verify_bundled_resource_hash \
    "$APP_RESOURCES/xterm-addon-fit.js" \
    "bdaefa370b1bfc42ee88d46fe6072400902a4d4b2d45cd93438dda9b23c97089"

  if codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >/dev/null 2>&1; then
    pass "bundle code signature verifies"
    SIGNATURE_DETAILS="$(codesign -dvvv "$APP_BUNDLE" 2>&1 || true)"
    if [[ "$ADHOC" == "1" ]]; then
      if grep -q "Signature=adhoc" <<<"$SIGNATURE_DETAILS"; then
        pass "bundle uses the expected ad-hoc signature"
      else
        fail "bundle is not ad-hoc signed"
      fi
      warn "Gatekeeper will not trust an ad-hoc signature; publish the checksum and first-launch instructions"
    else
      if grep -q "runtime" <<<"$SIGNATURE_DETAILS"; then
        pass "hardened runtime flag is present"
      else
        fail "hardened runtime flag is missing"
      fi
      if grep -q "Authority=Developer ID Application" <<<"$SIGNATURE_DETAILS"; then
        pass "bundle has a Developer ID Application authority"
      else
        fail "bundle is not signed with Developer ID Application"
      fi
    fi
  else
    fail "bundle code signature does not verify"
  fi

  verify_macho_metadata() {
    local binary_path="$1"
    local architectures
    local minimum_version

    if [[ ! -f "$binary_path" ]]; then
      fail "Mach-O file is missing: ${binary_path#"$APP_BUNDLE/"}"
      return
    fi

    architectures="$(lipo -archs "$binary_path" 2>/dev/null || true)"
    if [[ "$architectures" =~ ^(arm64|x86_64)$ ]]; then
      pass "Mach-O architecture: ${binary_path#"$APP_BUNDLE/"} ($architectures)"
    else
      fail "unexpected or unreadable Mach-O architecture: ${binary_path#"$APP_BUNDLE/"}"
    fi

    minimum_version="$(xcrun vtool -show-build "$binary_path" 2>/dev/null | awk '$1 == "minos" { print $2; exit }')"
    if [[ "$minimum_version" == "$MIN_SYSTEM_VERSION" ]]; then
      pass "deployment target is macOS $MIN_SYSTEM_VERSION: ${binary_path#"$APP_BUNDLE/"}"
    else
      fail "unexpected deployment target for ${binary_path#"$APP_BUNDLE/"}: ${minimum_version:-unknown}"
    fi
  }

  verify_macho_metadata "$APP_BUNDLE/Contents/MacOS/${EXECUTABLE_NAME:-Monknot}"
  verify_macho_metadata "$FRAMEWORK"
fi

if [[ "$ADHOC" != "1" ]]; then
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
fi

echo
if [[ "$ADHOC" == "1" ]]; then
  echo "Next command:"
  echo "  script/release_package.sh --adhoc"
else
  echo "Next command:"
  echo "  script/release_package.sh"
fi

echo
echo "Summary: $failures failure(s), $warnings warning(s)"

if [[ "$failures" -gt 0 ]]; then
  exit 2
fi
