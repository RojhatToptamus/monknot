#!/usr/bin/env bash
# Build and run the Monknot app bundle.
# Usage:
#   script/build_and_run.sh            # build and open dist/Monknot.app
#   script/build_and_run.sh --build    # build dist/Monknot.app without opening it
#   script/build_and_run.sh --verify   # build and confirm launch
#   script/build_and_run.sh --logs     # build and stream app logs
#   script/build_and_run.sh --debug    # build and run under lldb
# Add --development-sign to use one Apple Development identity from Keychain.
set -euo pipefail

MODE="run"
MODE_WAS_SET=0
SIGNING_MODE="${MONKNOT_SIGNING_MODE:-adhoc}"
DEVELOPMENT_IDENTITY_QUERY="${MONKNOT_DEVELOPMENT_IDENTITY:-Apple Development}"
DEVELOPMENT_TEAM_ID="${MONKNOT_DEVELOPMENT_TEAM_ID:-ZD35XP4V7D}"

usage() {
  cat <<USAGE
Usage: script/build_and_run.sh [mode] [--development-sign]

Modes:
  --build, build        Build without opening the app.
  --verify, verify      Build and confirm launch.
  --logs, logs          Build, open, and stream application logs.
  --telemetry, telemetry
                        Build, open, and stream subsystem logs.
  --debug, debug        Build and run under lldb.
  run                   Build and open the app (default).

Signing:
  --development-sign    Sign nested code and the app with a unique Apple
                        Development identity from the login Keychain.

Environment:
  MONKNOT_SIGNING_MODE          adhoc (default) or development.
  MONKNOT_DEVELOPMENT_IDENTITY  Identity name or SHA-1 query. Defaults to
                                "Apple Development" and must match exactly one
                                valid code-signing identity.
  MONKNOT_DEVELOPMENT_TEAM_ID   Expected signing TeamIdentifier. Defaults to
                                ZD35XP4V7D.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build|build|--verify|verify|--logs|logs|--telemetry|telemetry|--debug|debug|run)
      if [[ "$MODE_WAS_SET" == "1" ]]; then
        echo "only one build mode may be supplied" >&2
        exit 64
      fi
      MODE="$1"
      MODE_WAS_SET=1
      shift
      ;;
    --development-sign)
      SIGNING_MODE="development"
      shift
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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"
SPARKLE_PUBLIC_ED_KEY_FILE="$ROOT_DIR/SPARKLE_PUBLIC_ED_KEY"
APP_NAME="Monknot"
APP_COPYRIGHT="Copyright © 2026 Rojhat Toptamuş"
BUNDLE_ID="${MONKNOT_BUNDLE_ID:-com.monknot.app}"
MIN_SYSTEM_VERSION="14.0"
TARGET_ARCH="${MONKNOT_TARGET_ARCH:-$(uname -m)}"
TARGET_TRIPLE="${MONKNOT_TARGET_TRIPLE:-$TARGET_ARCH-apple-macosx$MIN_SYSTEM_VERSION}"
SPARKLE_VERSION="2.9.5"
SPARKLE_FEED_URL="${MONKNOT_SPARKLE_FEED_URL:-https://monknot.app/updates/appcast.xml}"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "missing release version file: $VERSION_FILE" >&2
  exit 66
fi
if [[ ! -f "$BUILD_NUMBER_FILE" ]]; then
  echo "missing build number file: $BUILD_NUMBER_FILE" >&2
  exit 66
fi
if [[ ! -f "$SPARKLE_PUBLIC_ED_KEY_FILE" ]]; then
  echo "missing Sparkle public key file: $SPARKLE_PUBLIC_ED_KEY_FILE" >&2
  echo "generate the key yourself with Sparkle's generate_keys tool and add only its public key to this file" >&2
  exit 66
fi

RELEASE_VERSION="$(tr -d '\r\n' <"$VERSION_FILE")"
DEFAULT_BUILD_NUMBER="$(tr -d '\r\n' <"$BUILD_NUMBER_FILE")"
BUILD_NUMBER="${MONKNOT_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"
DEFAULT_BUNDLE_VERSION="${RELEASE_VERSION%%[-+]*}"
BUNDLE_VERSION="${MONKNOT_VERSION:-$DEFAULT_BUNDLE_VERSION}"
SPARKLE_PUBLIC_ED_KEY="$(tr -d '\r\n' <"$SPARKLE_PUBLIC_ED_KEY_FILE")"

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_LEGAL_RESOURCES="$APP_RESOURCES/Legal"
APP_THIRD_PARTY_RESOURCES="$APP_LEGAL_RESOURCES/ThirdParty"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
BUILD_DIR="$ROOT_DIR/.build/manual"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
OVERLAY_FILE="$BUILD_DIR/swift-vfs-overlay.yaml"
EMPTY_MODULEMAP="$BUILD_DIR/empty.modulemap"
APP_ICON_NAME="AppIcon"
APP_ICON_ASSET_CATALOG="$ROOT_DIR/Sources/Monknot/Resources/Assets.xcassets"
APP_ICON_BUILD_DIR="$BUILD_DIR/AppIconAssets"
APP_ICON_INFO_PLIST="$BUILD_DIR/AppIcon-Info.plist"
APP_ICON_ICNS="$APP_ICON_BUILD_DIR/$APP_ICON_NAME.icns"
APP_ICON_ASSETS_CAR="$APP_ICON_BUILD_DIR/Assets.car"
SPARKLE_FRAMEWORK_SOURCE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_FRAMEWORK_PARENT="$(dirname "$SPARKLE_FRAMEWORK_SOURCE")"
SPARKLE_FRAMEWORK="$APP_FRAMEWORKS/Sparkle.framework"
SPARKLE_AUTOUPDATE="$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
SPARKLE_UPDATER_APP="$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
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

if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "invalid MONKNOT_BUNDLE_ID: $BUNDLE_ID" >&2
  exit 64
fi
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  echo "invalid VERSION (expected semantic version such as 1.2.3 or 1.2.3-alpha.1): $RELEASE_VERSION" >&2
  exit 64
fi
if [[ ! "$BUNDLE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid MONKNOT_VERSION (expected three numeric components): $BUNDLE_VERSION" >&2
  exit 64
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "invalid MONKNOT_BUILD_NUMBER (expected digits): $BUILD_NUMBER" >&2
  exit 64
fi
if [[ ! "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "SPARKLE_PUBLIC_ED_KEY must contain one 32-byte Ed25519 public key encoded as base64" >&2
  exit 64
fi
if [[ ! "$SPARKLE_FEED_URL" =~ ^https:// ]]; then
  echo "MONKNOT_SPARKLE_FEED_URL must be an HTTPS URL: $SPARKLE_FEED_URL" >&2
  exit 64
fi
if [[ ! "$TARGET_ARCH" =~ ^(arm64|x86_64)$ ]]; then
  echo "unsupported MONKNOT_TARGET_ARCH: $TARGET_ARCH" >&2
  exit 64
fi
if [[ ! "$SIGNING_MODE" =~ ^(adhoc|development)$ ]]; then
  echo "invalid MONKNOT_SIGNING_MODE: $SIGNING_MODE (expected adhoc or development)" >&2
  exit 64
fi
if [[ "$SIGNING_MODE" == "development" && -z "$DEVELOPMENT_IDENTITY_QUERY" ]]; then
  echo "MONKNOT_DEVELOPMENT_IDENTITY must not be empty for development signing" >&2
  exit 64
fi
if [[ "$SIGNING_MODE" == "development" && ! "$DEVELOPMENT_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "invalid MONKNOT_DEVELOPMENT_TEAM_ID: $DEVELOPMENT_TEAM_ID" >&2
  exit 64
fi
if [[ "$TARGET_TRIPLE" != "$TARGET_ARCH-apple-macosx$MIN_SYSTEM_VERSION" ]]; then
  echo "invalid MONKNOT_TARGET_TRIPLE (expected $TARGET_ARCH-apple-macosx$MIN_SYSTEM_VERSION): $TARGET_TRIPLE" >&2
  exit 64
fi
if ! command -v codesign >/dev/null 2>&1; then
  echo "codesign is required to create the bundle signature" >&2
  exit 69
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required to select the Xcode Swift toolchain" >&2
  exit 69
fi

SIGN_IDENTITY="-"
SIGN_IDENTITY_NAME="ad-hoc"
if [[ "$SIGNING_MODE" == "development" ]]; then
  if ! command -v security >/dev/null 2>&1; then
    echo "security is required to find an Apple Development identity" >&2
    exit 69
  fi

  IDENTITY_MATCHES="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -v query="$DEVELOPMENT_IDENTITY_QUERY" '
          index($0, query) {
            hash = $2
            if (match($0, /"[^"]+"/)) {
              name = substr($0, RSTART + 1, RLENGTH - 2)
              print hash "\t" name
            }
          }
        '
  )"
  IDENTITY_COUNT="$(printf '%s\n' "$IDENTITY_MATCHES" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$IDENTITY_COUNT" == "0" ]]; then
    echo "no valid code-signing identity matched: $DEVELOPMENT_IDENTITY_QUERY" >&2
    echo "inspect available identities with: security find-identity -v -p codesigning" >&2
    exit 65
  fi
  if [[ "$IDENTITY_COUNT" != "1" ]]; then
    echo "development identity query matched $IDENTITY_COUNT identities; use a full name or SHA-1 hash" >&2
    printf '%s\n' "$IDENTITY_MATCHES" >&2
    exit 65
  fi

  SIGN_IDENTITY="${IDENTITY_MATCHES%%$'\t'*}"
  SIGN_IDENTITY_NAME="${IDENTITY_MATCHES#*$'\t'}"
  echo "Development signing identity: $SIGN_IDENTITY_NAME ($SIGN_IDENTITY)"
fi

# A build-only invocation must not interrupt someone using an existing bundle.
case "$MODE" in
  --build|build) ;;
  *) pkill -x "$APP_NAME" >/dev/null 2>&1 || true ;;
esac

cd "$ROOT_DIR"
mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR" "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"

if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
  swift package resolve
fi
if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
  echo "Sparkle $SPARKLE_VERSION framework was not resolved at the expected SwiftPM artifact path" >&2
  exit 66
fi
ACTUAL_SPARKLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SPARKLE_FRAMEWORK_SOURCE/Versions/B/Resources/Info.plist" 2>/dev/null || true)"
if [[ "$ACTUAL_SPARKLE_VERSION" != "$SPARKLE_VERSION" ]]; then
  echo "resolved Sparkle version is ${ACTUAL_SPARKLE_VERSION:-unknown}; expected $SPARKLE_VERSION" >&2
  exit 1
fi

SWIFTC_BIN="$(xcrun --find swiftc)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TOOLCHAIN_DIR="$(cd "$(dirname "$SWIFTC_BIN")/.." && pwd)"
SWIFT_MODULEMAP="$TOOLCHAIN_DIR/include/swift/module.modulemap"
COMMON_SWIFT_FLAGS=(
  -target "$TARGET_TRIPLE"
  -sdk "$SDK_PATH"
  -module-cache-path "$MODULE_CACHE_DIR"
  -O
)

printf "" >"$EMPTY_MODULEMAP"
cat >"$OVERLAY_FILE" <<OVERLAY
{ "version": 0, "case-sensitive": "false", "roots": [ { "name": "$SWIFT_MODULEMAP", "type": "file", "external-contents": "$EMPTY_MODULEMAP" } ] }
OVERLAY

build_app_icon() {
  if [[ ! -d "$APP_ICON_ASSET_CATALOG" ]]; then
    echo "missing app icon asset catalog: $APP_ICON_ASSET_CATALOG" >&2
    exit 1
  fi

  rm -rf "$APP_ICON_BUILD_DIR"
  mkdir -p "$APP_ICON_BUILD_DIR"

  xcrun actool \
    --compile "$APP_ICON_BUILD_DIR" \
    --platform macosx \
    --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
    --target-device mac \
    --app-icon "$APP_ICON_NAME" \
    --standalone-icon-behavior all \
    --output-partial-info-plist "$APP_ICON_INFO_PLIST" \
    --warnings \
    --errors \
    --output-format human-readable-text \
    "$APP_ICON_ASSET_CATALOG"

  if [[ ! -f "$APP_ICON_ICNS" ]]; then
    echo "actool did not produce the expected app icon: $APP_ICON_ICNS" >&2
    exit 1
  fi
  if [[ ! -f "$APP_ICON_ASSETS_CAR" ]]; then
    echo "actool did not produce the expected asset archive: $APP_ICON_ASSETS_CAR" >&2
    exit 1
  fi
}

CORE_SOURCES=(
  "Sources/MonknotCore/Models/AppTheme.swift"
  "Sources/MonknotCore/Models/MonknotThemeCatalog.swift"
  "Sources/MonknotCore/Models/EditorMode.swift"
  "Sources/MonknotCore/Models/MarkdownOutlineItem.swift"
  "Sources/MonknotCore/Models/MarkdownPDFExportOptions.swift"
  "Sources/MonknotCore/Models/MarkdownSourceLocation.swift"
  "Sources/MonknotCore/Models/MonknotKeyboardShortcut.swift"
  "Sources/MonknotCore/Models/MonknotKeyboardShortcutCatalog.swift"
  "Sources/MonknotCore/Models/SidebarNode.swift"
  "Sources/MonknotCore/Models/TerminalTabState.swift"
  "Sources/MonknotCore/Models/ThemePreference.swift"
  "Sources/MonknotCore/Models/WorkspaceContextChunk.swift"
  "Sources/MonknotCore/Models/WorkspaceDocument.swift"
  "Sources/MonknotCore/Models/WorkspaceDocumentKind+SystemImage.swift"
  "Sources/MonknotCore/Models/WorkspaceReplaceScope.swift"
  "Sources/MonknotCore/Models/WorkspaceReplacePreview.swift"
  "Sources/MonknotCore/Models/WorkspaceSearchResult.swift"
  "Sources/MonknotCore/Models/WorkspaceTabState.swift"
  "Sources/MonknotCore/Models/WorkspaceTextRevision.swift"
  "Sources/MonknotCore/Services/BetaFeedbackRecorder.swift"
  "Sources/MonknotCore/Services/DailyNotePlanner.swift"
  "Sources/MonknotCore/Services/DocumentSplitViewPersistence.swift"
  "Sources/MonknotCore/Services/ExternalDocumentReconciliationService.swift"
  "Sources/MonknotCore/Services/FlowProtectedRangeService.swift"
  "Sources/MonknotCore/Services/HTMLScrollSync.swift"
  "Sources/MonknotCore/Services/MonknotCaptureURLBuilder.swift"
  "Sources/MonknotCore/Services/MarkdownOutlineParser.swift"
  "Sources/MonknotCore/Services/MarkdownRenderService.swift"
  "Sources/MonknotCore/Services/MarkdownLinkMovePlanner.swift"
  "Sources/MonknotCore/Services/MarkdownScrollSync.swift"
  "Sources/MonknotCore/Services/MonknotTextSearch.swift"
  "Sources/MonknotCore/Services/MarkdownSymbolQuickOpenMatcher.swift"
  "Sources/MonknotCore/Services/MarkdownWorkspaceLinkService.swift"
  "Sources/MonknotCore/Services/PDFAnnotationMarkdownExportService.swift"
  "Sources/MonknotCore/Services/RecentDocumentStore.swift"
  "Sources/MonknotCore/Services/RecentWorkspaceStore.swift"
  "Sources/MonknotCore/Services/MarkdownLinkInspectionService.swift"
  "Sources/MonknotCore/Services/MarkdownListEditPlanner.swift"
  "Sources/MonknotCore/Services/WikilinkAutocompleteService.swift"
  "Sources/MonknotCore/Services/WorkspaceContextAssembler.swift"
  "Sources/MonknotCore/Services/WorkspaceDocumentScanner.swift"
  "Sources/MonknotCore/Services/WorkspaceGitStatusService.swift"
  "Sources/MonknotCore/Services/WorkspaceContextOrdering.swift"
  "Sources/MonknotCore/Services/WorkspaceQuickOpenMatcher.swift"
  "Sources/MonknotCore/Services/WorkspaceReadOnlyExport.swift"
  "Sources/MonknotCore/Services/WorkspaceReplaceService.swift"
  "Sources/MonknotCore/Services/WorkspacePDFSearchIndex.swift"
  "Sources/MonknotCore/Services/WorkspacePDFTextCache.swift"
  "Sources/MonknotCore/Services/WorkspaceScanResultPatcher.swift"
  "Sources/MonknotCore/Services/WorkspaceSearchResultExporter.swift"
  "Sources/MonknotCore/Services/WorkspaceSearchIndex.swift"
  "Sources/MonknotCore/Services/WorkspaceSearchPrewarmService.swift"
  "Sources/MonknotCore/Services/WorkspaceSearchService.swift"
  "Sources/MonknotCore/Services/WorkspaceTabStatePersistence.swift"
  "Sources/MonknotCore/Services/WorkspaceTemplateService.swift"
  "Sources/MonknotCore/Services/WorkspaceTextContentCache.swift"
  "Sources/MonknotCore/Services/WorkspaceTextFileGuard.swift"
  "Sources/MonknotCore/Services/WorkspaceTreeFormatter.swift"
  "Sources/MonknotCore/Support/MonknotSignposting.swift"
)

APP_SOURCES=(
  "Sources/Monknot/App/MonknotApp.swift"
  "Sources/Monknot/Models/ContentWidthPreference.swift"
  "Sources/Monknot/Models/DocumentSaveState.swift"
  "Sources/Monknot/Models/DocumentSearchState.swift"
  "Sources/Monknot/Models/DocumentViewportState.swift"
  "Sources/Monknot/Models/MarkdownSymbolQuickOpenState.swift"
  "Sources/Monknot/Models/TerminalWorkingDirectoryPolicy.swift"
  "Sources/Monknot/Models/WorkspaceQuickOpenState.swift"
  "Sources/Monknot/Models/WorkspaceSearchState.swift"
  "Sources/Monknot/Models/MarkdownLinkInspectionState.swift"
  "Sources/Monknot/Services/FlowProseCompletionService.swift"
  "Sources/Monknot/Services/MarkdownPDFExportService.swift"
  "Sources/Monknot/Services/MarkdownSemanticPasteboardExportService.swift"
  "Sources/Monknot/Services/MonknotLaunchCaptureParser.swift"
  "Sources/Monknot/Services/TerminalPTYSession.swift"
  "Sources/Monknot/Services/WorkspaceFileWatcher.swift"
  "Sources/Monknot/Services/WorkspacePasteboardExportService.swift"
  "Sources/Monknot/Services/WorkspacePasteboardImportService.swift"
  "Sources/Monknot/Stores/MarkdownOutlineStore.swift"
  "Sources/Monknot/Stores/TerminalSessionCollectionStore.swift"
  "Sources/Monknot/Stores/TerminalSessionStore.swift"
  "Sources/Monknot/Stores/ThemeSettingsStore.swift"
  "Sources/Monknot/Stores/WorkspaceStore.swift"
  "Sources/Monknot/Support/Color+Theme.swift"
  "Sources/Monknot/Support/CursorSupport.swift"
  "Sources/Monknot/Support/DocumentSplitViewRatioAccessor.swift"
  "Sources/Monknot/Support/WorkspaceSplitView.swift"
  "Sources/Monknot/Support/Design/MonknotAccentButton.swift"
  "Sources/Monknot/Support/Design/MonknotChromePanel.swift"
  "Sources/Monknot/Support/Design/MonknotChromeSurfaceBackground.swift"
  "Sources/Monknot/Support/Design/MonknotIconButton.swift"
  "Sources/Monknot/Support/Design/HorizontalTabStripSupport.swift"
  "Sources/Monknot/Support/Design/MonknotMetrics.swift"
  "Sources/Monknot/Support/Design/MonknotMotion.swift"
  "Sources/Monknot/Support/Design/MonknotPanelCard.swift"
  "Sources/Monknot/Support/Design/MonknotRow.swift"
  "Sources/Monknot/Support/Design/MonknotScrollbarStyle.swift"
  "Sources/Monknot/Support/Design/MonknotSFSymbol.swift"
  "Sources/Monknot/Support/Design/MonknotSearchField.swift"
  "Sources/Monknot/Support/Design/MonknotSegmentedControl.swift"
  "Sources/Monknot/Support/Design/MonknotSettingsSegmentedControl.swift"
  "Sources/Monknot/Support/Design/MonknotShortcutLabel.swift"
  "Sources/Monknot/Support/Design/MonknotStatusSurface.swift"
  "Sources/Monknot/Support/Design/MonknotTypography.swift"
  "Sources/Monknot/Support/Design/MonknotWorkspaceIcons.swift"
  "Sources/Monknot/Support/EditorMode+SwiftUI.swift"
  "Sources/Monknot/Support/FileURLDropTarget.swift"
  "Sources/Monknot/Support/InitialWorkspaceRestorationCoordinator.swift"
  "Sources/Monknot/Support/KeyboardShortcutMonitor.swift"
  "Sources/Monknot/Support/MonknotCommandActions.swift"
  "Sources/Monknot/Support/PDFAnnotationHitTesting.swift"
  "Sources/Monknot/Support/ThemePreference+SwiftUI.swift"
  "Sources/Monknot/Support/WindowChromeSupport.swift"
  "Sources/Monknot/Support/WorkspaceDocumentKind+ResolvedSymbol.swift"
  "Sources/Monknot/Support/WorkspaceWindowRequestCenter.swift"
  "Sources/Monknot/Views/AppearanceSettingsView.swift"
  "Sources/Monknot/Views/ContentView.swift"
  "Sources/Monknot/Views/DocumentTabBar.swift"
  "Sources/Monknot/Views/EditorPaneView.swift"
  "Sources/Monknot/Views/ExternalDocumentChangeBanner.swift"
  "Sources/Monknot/Views/GeneralSettingsView.swift"
  "Sources/Monknot/Views/GoToLineView.swift"
  "Sources/Monknot/Views/HTMLPreviewView.swift"
  "Sources/Monknot/Views/MarkdownOutlineRail.swift"
  "Sources/Monknot/Views/MonknotCommandOverlay.swift"
  "Sources/Monknot/Views/MarkdownPDFExportOptionsSheet.swift"
  "Sources/Monknot/Views/MarkdownPreviewView.swift"
  "Sources/Monknot/Views/MarkdownSymbolQuickOpenView.swift"
  "Sources/Monknot/Views/MarkdownTextEditor.swift"
  "Sources/Monknot/Views/MonknotKeyboardShortcutsHelpView.swift"
  "Sources/Monknot/Views/NativeMarkdownEditorView.swift"
  "Sources/Monknot/Views/PDFPreviewView.swift"
  "Sources/Monknot/Views/PreferencesView.swift"
  "Sources/Monknot/Views/MarkdownLinkInspectionPanel.swift"
  "Sources/Monknot/Views/SettingsComponents.swift"
  "Sources/Monknot/Views/SidebarView.swift"
  "Sources/Monknot/Views/TerminalDrawerView.swift"
  "Sources/Monknot/Views/TerminalWebView.swift"
  "Sources/Monknot/Views/TopNavigationBar.swift"
  "Sources/Monknot/Views/WorkspaceQuickOpenView.swift"
  "Sources/Monknot/Views/WorkspaceSearchView.swift"
)

"$SWIFTC_BIN" \
  "${COMMON_SWIFT_FLAGS[@]}" \
  -vfsoverlay "$OVERLAY_FILE" \
  -parse-as-library \
  -module-name MonknotCore \
  -emit-library \
  -emit-module \
  -emit-module-path "$BUILD_DIR/MonknotCore.swiftmodule" \
  -Xlinker -install_name \
  -Xlinker @rpath/libMonknotCore.dylib \
  "${CORE_SOURCES[@]}" \
  -o "$BUILD_DIR/libMonknotCore.dylib"

"$SWIFTC_BIN" \
  "${COMMON_SWIFT_FLAGS[@]}" \
  -vfsoverlay "$OVERLAY_FILE" \
  -I "$BUILD_DIR" \
  -L "$BUILD_DIR" \
  -lMonknotCore \
  -F "$SPARKLE_FRAMEWORK_PARENT" \
  -framework Sparkle \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  "${APP_SOURCES[@]}" \
  -o "$BUILD_DIR/$APP_NAME"

build_app_icon

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS" "$APP_THIRD_PARTY_RESOURCES"
cp "$BUILD_DIR/$APP_NAME" "$APP_BINARY"
cp "$BUILD_DIR/libMonknotCore.dylib" "$APP_FRAMEWORKS/libMonknotCore.dylib"
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$SPARKLE_FRAMEWORK"
rm -rf "$SPARKLE_FRAMEWORK/Versions/B/XPCServices"
rm -f "$SPARKLE_FRAMEWORK/XPCServices"

thin_sparkle_binary() {
  local binary_path="$1"
  local temporary_path="$binary_path.$TARGET_ARCH"
  lipo "$binary_path" -thin "$TARGET_ARCH" -output "$temporary_path"
  mv "$temporary_path" "$binary_path"
}

thin_sparkle_binary "$SPARKLE_FRAMEWORK/Versions/B/Sparkle"
thin_sparkle_binary "$SPARKLE_AUTOUPDATE"
thin_sparkle_binary "$SPARKLE_UPDATER_APP/Contents/MacOS/Updater"
chmod +x "$APP_BINARY"
cp "$APP_ICON_ICNS" "$APP_RESOURCES/$APP_ICON_NAME.icns"
cp "$APP_ICON_ASSETS_CAR" "$APP_RESOURCES/Assets.car"
cp "$ROOT_DIR/Sources/MonknotCore/Resources/preview.css" "$APP_RESOURCES/preview.css"
cp "$ROOT_DIR/Sources/MonknotCore/Resources/renderer.js" "$APP_RESOURCES/renderer.js"
cp "$ROOT_DIR/Sources/Monknot/Resources/xterm.css" "$APP_RESOURCES/xterm.css"
cp "$ROOT_DIR/Sources/Monknot/Resources/xterm.js" "$APP_RESOURCES/xterm.js"
cp "$ROOT_DIR/Sources/Monknot/Resources/xterm-addon-fit.js" "$APP_RESOURCES/xterm-addon-fit.js"
cp "$ROOT_DIR/Sources/Monknot/Resources/xterm-addon-search.js" "$APP_RESOURCES/xterm-addon-search.js"
cp "$ROOT_DIR/LICENSE" "$APP_LEGAL_RESOURCES/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_LEGAL_RESOURCES/THIRD_PARTY_NOTICES.md"
cp "$ROOT_DIR/ThirdPartyLicenses/xterm-MIT.txt" "$APP_THIRD_PARTY_RESOURCES/xterm-MIT.txt"
cp "$ROOT_DIR/ThirdPartyLicenses/xterm-addon-fit-MIT.txt" "$APP_THIRD_PARTY_RESOURCES/xterm-addon-fit-MIT.txt"
cp "$ROOT_DIR/ThirdPartyLicenses/xterm-addon-search-MIT.txt" "$APP_THIRD_PARTY_RESOURCES/xterm-addon-search-MIT.txt"
cp "$ROOT_DIR/ThirdPartyLicenses/sparkle-MIT.txt" "$APP_THIRD_PARTY_RESOURCES/sparkle-MIT.txt"
for LICENSE_FILE in "${THEME_LICENSE_FILES[@]}"; do
  cp "$ROOT_DIR/ThirdPartyLicenses/$LICENSE_FILE" "$APP_THIRD_PARTY_RESOURCES/$LICENSE_FILE"
done

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME.icns</string>
  <key>CFBundleIconName</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$BUNDLE_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$BUNDLE_ID.capture</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>monknot</string>
      </array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Folders</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.folder</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Files</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.data</string>
      </array>
    </dict>
  </array>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSSupportsOpeningDocumentsInPlace</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>$APP_COPYRIGHT</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
</dict>
</plist>
PLIST

plutil -lint "$INFO_PLIST" >/dev/null
verify_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST")"
  if [[ "$actual" != "$expected" ]]; then
    echo "unexpected $key in generated Info.plist: $actual" >&2
    exit 1
  fi
}
verify_plist_value CFBundleIdentifier "$BUNDLE_ID"
verify_plist_value CFBundleName "$APP_NAME"
verify_plist_value CFBundleDisplayName "$APP_NAME"
verify_plist_value CFBundleExecutable "$APP_NAME"
verify_plist_value CFBundlePackageType APPL
verify_plist_value CFBundleShortVersionString "$BUNDLE_VERSION"
verify_plist_value CFBundleVersion "$BUILD_NUMBER"
verify_plist_value LSMinimumSystemVersion "$MIN_SYSTEM_VERSION"
verify_plist_value NSHumanReadableCopyright "$APP_COPYRIGHT"
verify_plist_value SUFeedURL "$SPARKLE_FEED_URL"
verify_plist_value SUPublicEDKey "$SPARKLE_PUBLIC_ED_KEY"
verify_plist_value SURequireSignedFeed true
verify_plist_value SUVerifyUpdateBeforeExtraction true

# Direct-distribution and local builds do not embed a provisioning profile.
# Sign nested code before the main application bundle.
rm -f "$APP_CONTENTS/embedded.provisionprofile"
codesign --force --sign "$SIGN_IDENTITY" "$SPARKLE_AUTOUPDATE"
codesign --force --sign "$SIGN_IDENTITY" "$SPARKLE_UPDATER_APP"
codesign --force --sign "$SIGN_IDENTITY" "$SPARKLE_FRAMEWORK"
codesign --force --sign "$SIGN_IDENTITY" "$APP_FRAMEWORKS/libMonknotCore.dylib"
codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [[ "$SIGNING_MODE" == "development" ]]; then
  SIGNATURE_DETAILS="$(codesign -dvvv "$APP_BUNDLE" 2>&1)"
  if ! grep -F "Authority=$SIGN_IDENTITY_NAME" <<<"$SIGNATURE_DETAILS" >/dev/null; then
    echo "application was not signed by the selected Apple Development identity" >&2
    exit 1
  fi
  TEAM_IDENTIFIER="$(awk -F= '$1 == "TeamIdentifier" { print $2; exit }' <<<"$SIGNATURE_DETAILS")"
  if [[ "$TEAM_IDENTIFIER" != "$DEVELOPMENT_TEAM_ID" ]]; then
    echo "development signature TeamIdentifier is ${TEAM_IDENTIFIER:-<missing>}; expected $DEVELOPMENT_TEAM_ID" >&2
    exit 1
  fi
  echo "Development signature verified (TeamIdentifier=$TEAM_IDENTIFIER)"
fi

verify_macho_release_metadata() {
  local binary_path="$1"
  local expected_minimum_version="$2"
  local architectures
  local minimum_version

  architectures="$(lipo -archs "$binary_path")"
  if [[ "$architectures" != "$TARGET_ARCH" ]]; then
    echo "unexpected architecture for $binary_path: $architectures (expected $TARGET_ARCH)" >&2
    exit 1
  fi

  minimum_version="$(xcrun vtool -show-build "$binary_path" | awk '$1 == "minos" { print $2; exit }')"
  if [[ "$minimum_version" != "$expected_minimum_version" ]]; then
    echo "unexpected deployment target for $binary_path: $minimum_version (expected $expected_minimum_version)" >&2
    exit 1
  fi
}

verify_macho_release_metadata "$APP_BINARY" "$MIN_SYSTEM_VERSION"
verify_macho_release_metadata "$APP_FRAMEWORKS/libMonknotCore.dylib" "$MIN_SYSTEM_VERSION"
verify_macho_release_metadata "$SPARKLE_FRAMEWORK/Versions/B/Sparkle" "11.0"
verify_macho_release_metadata "$SPARKLE_AUTOUPDATE" "11.0"
verify_macho_release_metadata "$SPARKLE_UPDATER_APP/Contents/MacOS/Updater" "11.0"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --build|build)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    LAUNCHED=0
    for _ in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        LAUNCHED=1
        break
      fi
      sleep 0.25
    done
    if [[ "$LAUNCHED" != "1" ]]; then
      echo "$APP_NAME did not remain running after launch" >&2
      exit 1
    fi
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: $0 [run|--build|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
