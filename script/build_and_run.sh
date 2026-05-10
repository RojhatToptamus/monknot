#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Markprev"
BUNDLE_ID="com.local.Markprev"
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

CORE_SOURCES=(
  "Sources/MarkprevCore/Models/EditorMode.swift"
  "Sources/MarkprevCore/Models/ThemePreference.swift"
  "Sources/MarkprevCore/Models/AppTheme.swift"
  "Sources/MarkprevCore/Models/CodexThemeCatalog.swift"
  "Sources/MarkprevCore/Models/WorkspaceDocument.swift"
  "Sources/MarkprevCore/Models/MarkdownSourceLocation.swift"
  "Sources/MarkprevCore/Models/MarkdownOutlineItem.swift"
  "Sources/MarkprevCore/Models/MarkdownPDFExportOptions.swift"
  "Sources/MarkprevCore/Models/WorkspaceSearchResult.swift"
  "Sources/MarkprevCore/Models/WorkspaceTabState.swift"
  "Sources/MarkprevCore/Models/MarkprevKeyboardShortcut.swift"
  "Sources/MarkprevCore/Models/TerminalTabState.swift"
  "Sources/MarkprevCore/Models/SidebarNode.swift"
  "Sources/MarkprevCore/Services/WorkspaceDocumentScanner.swift"
  "Sources/MarkprevCore/Services/WorkspaceTabStatePersistence.swift"
  "Sources/MarkprevCore/Services/RecentWorkspaceStore.swift"
  "Sources/MarkprevCore/Services/MarkdownOutlineParser.swift"
  "Sources/MarkprevCore/Services/WorkspaceSearchService.swift"
  "Sources/MarkprevCore/Services/MarkdownRenderService.swift"
)

APP_SOURCES=(
  "Sources/Markprev/App/MarkprevApp.swift"
  "Sources/Markprev/Models/DocumentSaveState.swift"
  "Sources/Markprev/Models/DocumentSearchState.swift"
  "Sources/Markprev/Models/DocumentViewportState.swift"
  "Sources/Markprev/Models/TerminalWorkingDirectoryPolicy.swift"
  "Sources/Markprev/Models/WorkspaceSearchState.swift"
  "Sources/Markprev/Support/Color+Theme.swift"
  "Sources/Markprev/Support/CursorSupport.swift"
  "Sources/Markprev/Support/EditorMode+SwiftUI.swift"
  "Sources/Markprev/Support/InitialWorkspaceRestorationCoordinator.swift"
  "Sources/Markprev/Support/KeyboardShortcutMonitor.swift"
  "Sources/Markprev/Support/MarkprevCommandActions.swift"
  "Sources/Markprev/Support/PDFAnnotationHitTesting.swift"
  "Sources/Markprev/Support/ThemePreference+SwiftUI.swift"
  "Sources/Markprev/Support/WindowChromeSupport.swift"
  "Sources/Markprev/Support/WorkspaceWindowRequestCenter.swift"
  "Sources/Markprev/Services/MarkdownPDFExportService.swift"
  "Sources/Markprev/Services/WorkspacePasteboardImportService.swift"
  "Sources/Markprev/Services/WorkspaceFileWatcher.swift"
  "Sources/Markprev/Services/TerminalPTYSession.swift"
  "Sources/Markprev/Stores/MarkdownOutlineStore.swift"
  "Sources/Markprev/Stores/WorkspaceStore.swift"
  "Sources/Markprev/Stores/ThemeSettingsStore.swift"
  "Sources/Markprev/Stores/TerminalSessionStore.swift"
  "Sources/Markprev/Stores/TerminalSessionCollectionStore.swift"
  "Sources/Markprev/Views/ContentView.swift"
  "Sources/Markprev/Views/SidebarView.swift"
  "Sources/Markprev/Views/EditorPaneView.swift"
  "Sources/Markprev/Views/DocumentTabBar.swift"
  "Sources/Markprev/Views/TopNavigationBar.swift"
  "Sources/Markprev/Views/TerminalDrawerView.swift"
  "Sources/Markprev/Views/TerminalWebView.swift"
  "Sources/Markprev/Views/WorkspaceSearchView.swift"
  "Sources/Markprev/Views/MarkdownOutlinePanel.swift"
  "Sources/Markprev/Views/MarkdownPDFExportOptionsSheet.swift"
  "Sources/Markprev/Views/MarkdownTextEditor.swift"
  "Sources/Markprev/Views/MarkdownPreviewView.swift"
  "Sources/Markprev/Views/PDFPreviewView.swift"
  "Sources/Markprev/Views/MediaPreviewView.swift"
  "Sources/Markprev/Views/QuickLookPreviewView.swift"
  "Sources/Markprev/Views/PreferencesView.swift"
  "Sources/Markprev/Views/GeneralSettingsView.swift"
  "Sources/Markprev/Views/AppearanceSettingsView.swift"
  "Sources/Markprev/Views/SettingsComponents.swift"
)

"$SWIFTC_BIN" \
  -vfsoverlay "$OVERLAY_FILE" \
  -parse-as-library \
  -module-name MarkprevCore \
  -emit-library \
  -emit-module \
  -emit-module-path "$BUILD_DIR/MarkprevCore.swiftmodule" \
  -Xlinker -install_name \
  -Xlinker @rpath/libMarkprevCore.dylib \
  "${CORE_SOURCES[@]}" \
  -o "$BUILD_DIR/libMarkprevCore.dylib"

"$SWIFTC_BIN" \
  -vfsoverlay "$OVERLAY_FILE" \
  -I "$BUILD_DIR" \
  -L "$BUILD_DIR" \
  -lMarkprevCore \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  "${APP_SOURCES[@]}" \
  -o "$BUILD_DIR/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
cp "$BUILD_DIR/$APP_NAME" "$APP_BINARY"
cp "$BUILD_DIR/libMarkprevCore.dylib" "$APP_FRAMEWORKS/libMarkprevCore.dylib"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/Sources/MarkprevCore/Resources/preview.css" "$APP_RESOURCES/preview.css"
cp "$ROOT_DIR/Sources/MarkprevCore/Resources/renderer.js" "$APP_RESOURCES/renderer.js"
cp "$ROOT_DIR/Sources/Markprev/Resources/xterm.css" "$APP_RESOURCES/xterm.css"
cp "$ROOT_DIR/Sources/Markprev/Resources/xterm.js" "$APP_RESOURCES/xterm.js"
cp "$ROOT_DIR/Sources/Markprev/Resources/xterm-addon-fit.js" "$APP_RESOURCES/xterm-addon-fit.js"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
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
