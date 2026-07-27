#!/usr/bin/env bash
# Build and run the ad-hoc-signed Monknot app bundle.
# Usage:
#   script/build_and_run.sh            # build and open dist/Monknot.app
#   script/build_and_run.sh --build    # build dist/Monknot.app without opening it
#   script/build_and_run.sh --verify   # build and confirm launch
#   script/build_and_run.sh --logs     # build and stream app logs
#   script/build_and_run.sh --debug    # build and run under lldb
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
APP_NAME="Monknot"
BUNDLE_ID="${MONKNOT_BUNDLE_ID:-io.github.rojhattoptamus.monknot}"
BUILD_NUMBER="${MONKNOT_BUILD_NUMBER:-1}"
MIN_SYSTEM_VERSION="14.0"
TARGET_ARCH="${MONKNOT_TARGET_ARCH:-$(uname -m)}"
TARGET_TRIPLE="${MONKNOT_TARGET_TRIPLE:-$TARGET_ARCH-apple-macosx$MIN_SYSTEM_VERSION}"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "missing release version file: $VERSION_FILE" >&2
  exit 66
fi

RELEASE_VERSION="$(tr -d '\r\n' <"$VERSION_FILE")"
DEFAULT_BUNDLE_VERSION="${RELEASE_VERSION%%[-+]*}"
BUNDLE_VERSION="${MONKNOT_VERSION:-$DEFAULT_BUNDLE_VERSION}"

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
APP_ICON_SOURCE="$ROOT_DIR/Sources/Monknot/Resources/AppIcon.svg"
APP_ICONSET_SOURCE="$ROOT_DIR/Sources/Monknot/Resources/AppIcon.iconset"
APP_ICON_FLATTENED_SVG="$BUILD_DIR/$APP_ICON_NAME-full-background.svg"
APP_ICON_BASE_PNG="$BUILD_DIR/$APP_ICON_NAME-base.png"
APP_ICONSET_BUILD="$BUILD_DIR/$APP_ICON_NAME.iconset"
APP_ICON_ICNS="$BUILD_DIR/$APP_ICON_NAME.icns"

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
if [[ ! "$TARGET_ARCH" =~ ^(arm64|x86_64)$ ]]; then
  echo "unsupported MONKNOT_TARGET_ARCH: $TARGET_ARCH" >&2
  exit 64
fi
if [[ "$TARGET_TRIPLE" != "$TARGET_ARCH-apple-macosx$MIN_SYSTEM_VERSION" ]]; then
  echo "invalid MONKNOT_TARGET_TRIPLE (expected $TARGET_ARCH-apple-macosx$MIN_SYSTEM_VERSION): $TARGET_TRIPLE" >&2
  exit 64
fi
if ! command -v codesign >/dev/null 2>&1; then
  echo "codesign is required to create the ad-hoc bundle signature" >&2
  exit 69
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required to select the Xcode Swift toolchain" >&2
  exit 69
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR" "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"

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
  if [[ -d "$APP_ICONSET_SOURCE" ]]; then
    iconutil -c icns "$APP_ICONSET_SOURCE" -o "$APP_ICON_ICNS"
    return
  fi

  if [[ ! -f "$APP_ICON_SOURCE" ]]; then
    echo "missing app icon source: $APP_ICON_SOURCE" >&2
    exit 1
  fi

  rm -rf "$APP_ICONSET_BUILD"
  mkdir -p "$APP_ICONSET_BUILD"

  if command -v rsvg-convert >/dev/null 2>&1; then
    awk '
      index($0, "<g clip-path=") && !inserted {
        print "  <rect width=\"1024\" height=\"1024\" fill=\"url(#bg)\"/>"
        inserted = 1
      }
      { print }
    ' "$APP_ICON_SOURCE" >"$APP_ICON_FLATTENED_SVG"
    rsvg-convert -w 1024 -h 1024 "$APP_ICON_FLATTENED_SVG" -o "$APP_ICON_BASE_PNG"
  else
    echo "rsvg-convert is required to preserve the SVG app icon background." >&2
    exit 1
  fi

  sips -z 16 16 "$APP_ICON_BASE_PNG" --out "$APP_ICONSET_BUILD/icon_16x16.png" >/dev/null
  sips -z 32 32 "$APP_ICON_BASE_PNG" --out "$APP_ICONSET_BUILD/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$APP_ICON_BASE_PNG" --out "$APP_ICONSET_BUILD/icon_32x32.png" >/dev/null
  sips -z 64 64 "$APP_ICON_BASE_PNG" --out "$APP_ICONSET_BUILD/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$APP_ICON_BASE_PNG" --out "$APP_ICONSET_BUILD/icon_128x128.png" >/dev/null
  sips -z 256 256 "$APP_ICON_BASE_PNG" --out "$APP_ICONSET_BUILD/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$APP_ICON_BASE_PNG" --out "$APP_ICONSET_BUILD/icon_256x256.png" >/dev/null
  sips -z 512 512 "$APP_ICON_BASE_PNG" --out "$APP_ICONSET_BUILD/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$APP_ICON_BASE_PNG" --out "$APP_ICONSET_BUILD/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$APP_ICON_BASE_PNG" --out "$APP_ICONSET_BUILD/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$APP_ICONSET_BUILD" -o "$APP_ICON_ICNS"
}

CORE_SOURCES=(
  "Sources/MonknotCore/Models/AppTheme.swift"
  "Sources/MonknotCore/Models/CodexThemeCatalog.swift"
  "Sources/MonknotCore/Models/EditorMode.swift"
  "Sources/MonknotCore/Models/MarkdownOutlineItem.swift"
  "Sources/MonknotCore/Models/MarkdownPDFExportOptions.swift"
  "Sources/MonknotCore/Models/MarkdownSourceLocation.swift"
  "Sources/MonknotCore/Models/MonknotKeyboardShortcut.swift"
  "Sources/MonknotCore/Models/MonknotKeyboardShortcutCatalog.swift"
  "Sources/MonknotCore/Models/SidebarNode.swift"
  "Sources/MonknotCore/Models/TerminalTabState.swift"
  "Sources/MonknotCore/Models/ThemePreference.swift"
  "Sources/MonknotCore/Models/TypingAssistance.swift"
  "Sources/MonknotCore/Models/TypingAssistanceTelemetry.swift"
  "Sources/MonknotCore/Models/WorkspaceContextChunk.swift"
  "Sources/MonknotCore/Models/WorkspaceDocument.swift"
  "Sources/MonknotCore/Models/WorkspaceDocumentKind+SystemImage.swift"
  "Sources/MonknotCore/Models/WorkspaceReplaceScope.swift"
  "Sources/MonknotCore/Models/WorkspaceReplacePreview.swift"
  "Sources/MonknotCore/Models/WorkspaceSearchResult.swift"
  "Sources/MonknotCore/Models/WorkspaceTabState.swift"
  "Sources/MonknotCore/Services/BetaFeedbackRecorder.swift"
  "Sources/MonknotCore/Services/DailyNotePlanner.swift"
  "Sources/MonknotCore/Services/DocumentSplitViewPersistence.swift"
  "Sources/MonknotCore/Services/HTMLScrollSync.swift"
  "Sources/MonknotCore/Services/MonknotCaptureURLBuilder.swift"
  "Sources/MonknotCore/Services/MarkdownOutlineParser.swift"
  "Sources/MonknotCore/Services/MarkdownRenderService.swift"
  "Sources/MonknotCore/Services/MarkdownScrollSync.swift"
  "Sources/MonknotCore/Services/MarkdownSymbolQuickOpenMatcher.swift"
  "Sources/MonknotCore/Services/PDFAnnotationMarkdownExportService.swift"
  "Sources/MonknotCore/Services/RecentDocumentStore.swift"
  "Sources/MonknotCore/Services/RecentWorkspaceStore.swift"
  "Sources/MonknotCore/Services/RelatedNotesService.swift"
  "Sources/MonknotCore/Services/TypingAssistancePolicy.swift"
  "Sources/MonknotCore/Services/TypingAssistanceTelemetryRecorder.swift"
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
  "Sources/Monknot/Models/DocumentSaveState.swift"
  "Sources/Monknot/Models/DocumentSearchState.swift"
  "Sources/Monknot/Models/DocumentViewportState.swift"
  "Sources/Monknot/Models/MarkdownSymbolQuickOpenState.swift"
  "Sources/Monknot/Models/TerminalWorkingDirectoryPolicy.swift"
  "Sources/Monknot/Models/WorkspaceQuickOpenState.swift"
  "Sources/Monknot/Models/WorkspaceSearchState.swift"
  "Sources/Monknot/Services/MarkdownPDFExportService.swift"
  "Sources/Monknot/Services/LocalTypingAssistantRuntime.swift"
  "Sources/Monknot/Services/MonknotLaunchCaptureParser.swift"
  "Sources/Monknot/Services/TerminalPTYSession.swift"
  "Sources/Monknot/Services/WorkspaceFileWatcher.swift"
  "Sources/Monknot/Services/WorkspacePasteboardExportService.swift"
  "Sources/Monknot/Services/WorkspacePasteboardImportService.swift"
  "Sources/Monknot/Stores/MarkdownOutlineStore.swift"
  "Sources/Monknot/Stores/TerminalSessionCollectionStore.swift"
  "Sources/Monknot/Stores/TerminalSessionStore.swift"
  "Sources/Monknot/Stores/ThemeSettingsStore.swift"
  "Sources/Monknot/Stores/TypingAssistantSession.swift"
  "Sources/Monknot/Stores/WorkspaceStore.swift"
  "Sources/Monknot/Support/Color+Theme.swift"
  "Sources/Monknot/Support/CursorSupport.swift"
  "Sources/Monknot/Support/DocumentSplitViewRatioAccessor.swift"
  "Sources/Monknot/Support/Design/MonknotAccentButton.swift"
  "Sources/Monknot/Support/Design/MonknotChromeBackground.swift"
  "Sources/Monknot/Support/Design/MonknotChromePanel.swift"
  "Sources/Monknot/Support/Design/MonknotChromeSurfaceBackground.swift"
  "Sources/Monknot/Support/Design/MonknotIconButton.swift"
  "Sources/Monknot/Support/Design/MonknotMetrics.swift"
  "Sources/Monknot/Support/Design/MonknotMotion.swift"
  "Sources/Monknot/Support/Design/MonknotPanelCard.swift"
  "Sources/Monknot/Support/Design/MonknotRow.swift"
  "Sources/Monknot/Support/Design/MonknotScrollbarStyle.swift"
  "Sources/Monknot/Support/Design/MonknotSFSymbol.swift"
  "Sources/Monknot/Support/Design/MonknotSearchField.swift"
  "Sources/Monknot/Support/Design/MonknotSegmentedControl.swift"
  "Sources/Monknot/Support/Design/MonknotSettingsSegmentedControl.swift"
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
  "Sources/Monknot/Views/HTMLPreviewView.swift"
  "Sources/Monknot/Views/MarkdownOutlinePanel.swift"
  "Sources/Monknot/Views/MarkdownPDFExportOptionsSheet.swift"
  "Sources/Monknot/Views/MarkdownPreviewView.swift"
  "Sources/Monknot/Views/MarkdownSymbolQuickOpenView.swift"
  "Sources/Monknot/Views/MarkdownTextEditor.swift"
  "Sources/Monknot/Views/MonknotKeyboardShortcutsHelpView.swift"
  "Sources/Monknot/Views/NativeMarkdownEditorView.swift"
  "Sources/Monknot/Views/PDFPreviewView.swift"
  "Sources/Monknot/Views/PreferencesView.swift"
  "Sources/Monknot/Views/RelatedNotesPanel.swift"
  "Sources/Monknot/Views/SettingsComponents.swift"
  "Sources/Monknot/Views/SidebarView.swift"
  "Sources/Monknot/Views/TerminalDrawerView.swift"
  "Sources/Monknot/Views/TerminalWebView.swift"
  "Sources/Monknot/Views/TopNavigationBar.swift"
  "Sources/Monknot/Views/TypingAssistantBar.swift"
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
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  "${APP_SOURCES[@]}" \
  -o "$BUILD_DIR/$APP_NAME"

build_app_icon

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS" "$APP_THIRD_PARTY_RESOURCES"
cp "$BUILD_DIR/$APP_NAME" "$APP_BINARY"
cp "$BUILD_DIR/libMonknotCore.dylib" "$APP_FRAMEWORKS/libMonknotCore.dylib"
chmod +x "$APP_BINARY"
cp "$APP_ICON_ICNS" "$APP_RESOURCES/$APP_ICON_NAME.icns"
cp "$ROOT_DIR/Sources/MonknotCore/Resources/preview.css" "$APP_RESOURCES/preview.css"
cp "$ROOT_DIR/Sources/MonknotCore/Resources/renderer.js" "$APP_RESOURCES/renderer.js"
cp "$ROOT_DIR/Sources/Monknot/Resources/xterm.css" "$APP_RESOURCES/xterm.css"
cp "$ROOT_DIR/Sources/Monknot/Resources/xterm.js" "$APP_RESOURCES/xterm.js"
cp "$ROOT_DIR/Sources/Monknot/Resources/xterm-addon-fit.js" "$APP_RESOURCES/xterm-addon-fit.js"
cp "$ROOT_DIR/LICENSE" "$APP_LEGAL_RESOURCES/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_LEGAL_RESOURCES/THIRD_PARTY_NOTICES.md"
cp "$ROOT_DIR/ThirdPartyLicenses/xterm-MIT.txt" "$APP_THIRD_PARTY_RESOURCES/xterm-MIT.txt"
cp "$ROOT_DIR/ThirdPartyLicenses/xterm-addon-fit-MIT.txt" "$APP_THIRD_PARTY_RESOURCES/xterm-addon-fit-MIT.txt"

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
  <string>Copyright © 2026 Monknot contributors.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signing detects bundle changes locally but provides no developer
# identity and is not accepted by Gatekeeper as trusted distribution signing.
codesign --force --sign - "$APP_FRAMEWORKS/libMonknotCore.dylib"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

verify_macho_release_metadata() {
  local binary_path="$1"
  local architectures
  local minimum_version

  architectures="$(lipo -archs "$binary_path")"
  if [[ "$architectures" != "$TARGET_ARCH" ]]; then
    echo "unexpected architecture for $binary_path: $architectures (expected $TARGET_ARCH)" >&2
    exit 1
  fi

  minimum_version="$(xcrun vtool -show-build "$binary_path" | awk '$1 == "minos" { print $2; exit }')"
  if [[ "$minimum_version" != "$MIN_SYSTEM_VERSION" ]]; then
    echo "unexpected deployment target for $binary_path: $minimum_version (expected $MIN_SYSTEM_VERSION)" >&2
    exit 1
  fi
}

verify_macho_release_metadata "$APP_BINARY"
verify_macho_release_metadata "$APP_FRAMEWORKS/libMonknotCore.dylib"

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
