#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="monknot"
BUNDLE_ID="com.local.monknot"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
BUILD_DIR="$ROOT_DIR/.build/manual"
OVERLAY_FILE="$BUILD_DIR/swift-vfs-overlay.yaml"
EMPTY_MODULEMAP="$BUILD_DIR/empty.modulemap"
APP_ICON_NAME="AppIcon"
APP_ICON_SOURCE="$ROOT_DIR/Sources/Monknot/Resources/AppIcon.svg"
APP_ICONSET_SOURCE="$ROOT_DIR/Sources/Monknot/Resources/AppIcon.iconset"
APP_ICON_FLATTENED_SVG="$BUILD_DIR/$APP_ICON_NAME-full-background.svg"
APP_ICON_BASE_PNG="$BUILD_DIR/$APP_ICON_NAME-base.png"
APP_ICONSET_BUILD="$BUILD_DIR/$APP_ICON_NAME.iconset"
APP_ICON_ICNS="$BUILD_DIR/$APP_ICON_NAME.icns"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
mkdir -p "$BUILD_DIR" "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"

SWIFTC_BIN="$(command -v swiftc)"
TOOLCHAIN_SWIFTC="$(xcrun --find swiftc)"
TOOLCHAIN_DIR="$(cd "$(dirname "$TOOLCHAIN_SWIFTC")/.." && pwd)"
SWIFT_MODULEMAP="$TOOLCHAIN_DIR/include/swift/module.modulemap"

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
  "Sources/MonknotCore/Models/EditorMode.swift"
  "Sources/MonknotCore/Models/ThemePreference.swift"
  "Sources/MonknotCore/Models/AppTheme.swift"
  "Sources/MonknotCore/Models/CodexThemeCatalog.swift"
  "Sources/MonknotCore/Models/WorkspaceDocument.swift"
  "Sources/MonknotCore/Models/MarkdownSourceLocation.swift"
  "Sources/MonknotCore/Models/MarkdownOutlineItem.swift"
  "Sources/MonknotCore/Models/MarkdownPDFExportOptions.swift"
  "Sources/MonknotCore/Models/WorkspaceSearchResult.swift"
  "Sources/MonknotCore/Models/WorkspaceTabState.swift"
  "Sources/MonknotCore/Models/MonknotKeyboardShortcut.swift"
  "Sources/MonknotCore/Models/TerminalTabState.swift"
  "Sources/MonknotCore/Models/SidebarNode.swift"
  "Sources/MonknotCore/Services/WorkspaceDocumentScanner.swift"
  "Sources/MonknotCore/Services/WorkspaceTabStatePersistence.swift"
  "Sources/MonknotCore/Services/RecentWorkspaceStore.swift"
  "Sources/MonknotCore/Services/MarkdownOutlineParser.swift"
  "Sources/MonknotCore/Services/WorkspaceSearchService.swift"
  "Sources/MonknotCore/Services/MarkdownRenderService.swift"
)

APP_SOURCES=(
  "Sources/Monknot/App/MonknotApp.swift"
  "Sources/Monknot/Models/DocumentSaveState.swift"
  "Sources/Monknot/Models/DocumentSearchState.swift"
  "Sources/Monknot/Models/DocumentViewportState.swift"
  "Sources/Monknot/Models/TerminalWorkingDirectoryPolicy.swift"
  "Sources/Monknot/Models/WorkspaceSearchState.swift"
  "Sources/Monknot/Support/Color+Theme.swift"
  "Sources/Monknot/Support/CursorSupport.swift"
  "Sources/Monknot/Support/EditorMode+SwiftUI.swift"
  "Sources/Monknot/Support/InitialWorkspaceRestorationCoordinator.swift"
  "Sources/Monknot/Support/KeyboardShortcutMonitor.swift"
  "Sources/Monknot/Support/MonknotCommandActions.swift"
  "Sources/Monknot/Support/PDFAnnotationHitTesting.swift"
  "Sources/Monknot/Support/ThemePreference+SwiftUI.swift"
  "Sources/Monknot/Support/WindowChromeSupport.swift"
  "Sources/Monknot/Support/WorkspaceWindowRequestCenter.swift"
  "Sources/Monknot/Services/MarkdownPDFExportService.swift"
  "Sources/Monknot/Services/WorkspacePasteboardImportService.swift"
  "Sources/Monknot/Services/WorkspaceFileWatcher.swift"
  "Sources/Monknot/Services/TerminalPTYSession.swift"
  "Sources/Monknot/Stores/MarkdownOutlineStore.swift"
  "Sources/Monknot/Stores/WorkspaceStore.swift"
  "Sources/Monknot/Stores/ThemeSettingsStore.swift"
  "Sources/Monknot/Stores/TerminalSessionStore.swift"
  "Sources/Monknot/Stores/TerminalSessionCollectionStore.swift"
  "Sources/Monknot/Views/ContentView.swift"
  "Sources/Monknot/Views/SidebarView.swift"
  "Sources/Monknot/Views/EditorPaneView.swift"
  "Sources/Monknot/Views/DocumentTabBar.swift"
  "Sources/Monknot/Views/TopNavigationBar.swift"
  "Sources/Monknot/Views/TerminalDrawerView.swift"
  "Sources/Monknot/Views/TerminalWebView.swift"
  "Sources/Monknot/Views/WorkspaceSearchView.swift"
  "Sources/Monknot/Views/MarkdownOutlinePanel.swift"
  "Sources/Monknot/Views/MarkdownPDFExportOptionsSheet.swift"
  "Sources/Monknot/Views/MarkdownTextEditor.swift"
  "Sources/Monknot/Views/MarkdownPreviewView.swift"
  "Sources/Monknot/Views/PDFPreviewView.swift"
  "Sources/Monknot/Views/MediaPreviewView.swift"
  "Sources/Monknot/Views/QuickLookPreviewView.swift"
  "Sources/Monknot/Views/PreferencesView.swift"
  "Sources/Monknot/Views/GeneralSettingsView.swift"
  "Sources/Monknot/Views/AppearanceSettingsView.swift"
  "Sources/Monknot/Views/SettingsComponents.swift"
)

"$SWIFTC_BIN" \
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
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
cp "$BUILD_DIR/$APP_NAME" "$APP_BINARY"
cp "$BUILD_DIR/libMonknotCore.dylib" "$APP_FRAMEWORKS/libMonknotCore.dylib"
chmod +x "$APP_BINARY"
cp "$APP_ICON_ICNS" "$APP_RESOURCES/$APP_ICON_NAME.icns"
cp "$ROOT_DIR/Sources/MonknotCore/Resources/preview.css" "$APP_RESOURCES/preview.css"
cp "$ROOT_DIR/Sources/MonknotCore/Resources/renderer.js" "$APP_RESOURCES/renderer.js"
cp "$ROOT_DIR/Sources/Monknot/Resources/xterm.css" "$APP_RESOURCES/xterm.css"
cp "$ROOT_DIR/Sources/Monknot/Resources/xterm.js" "$APP_RESOURCES/xterm.js"
cp "$ROOT_DIR/Sources/Monknot/Resources/xterm-addon-fit.js" "$APP_RESOURCES/xterm-addon-fit.js"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME.icns</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
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
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
