# Markprev Agent Guide

This file orients AI agents and contributors working in this repository. Keep it current when major files, targets, or workflows move.

## Project Overview

Markprev is a SwiftPM macOS app for browsing a workspace, opening multiple files in lightweight tabs, editing Markdown and text-like files, previewing Markdown, viewing PDFs, previewing system-supported files with Quick Look, searching text/PDF documents, exporting Markdown to PDF, and running an embedded terminal.

The app is split into two main targets:

- `MarkprevCore`: reusable model and service logic with minimal UI coupling.
- `Markprev`: the macOS application layer built with SwiftUI, AppKit bridges, WebKit, PDFKit, FSEvents, and PTY support.

The package currently declares one test target:

- `MarkprevTests`: XCTest coverage for `MarkprevCore`.

There are also smoke-test source files under `Tests/MarkprevSmokeTests` and `Tests/MarkprevStoreSmokeTests`; these are not declared in `Package.swift` unless the package is updated.

## Repository Map

- `Package.swift`: SwiftPM manifest. Add new compile targets or resources here if they should be part of SwiftPM builds/tests.
- `Sources/MarkprevCore/Models`: value types and enums shared by the app and tests.
- `Sources/MarkprevCore/Services`: core services for scanning workspaces, rendering Markdown HTML, parsing outlines, and searching workspaces.
- `Sources/MarkprevCore/Resources`: Markdown preview CSS and JavaScript renderer used by WebKit preview and PDF export.
- `Sources/Markprev/App`: app entry point and application delegate.
- `Sources/Markprev/Stores`: `@MainActor` observable state containers for workspace, themes, terminal state, and Markdown outline state.
- `Sources/Markprev/Models`: app-layer UI state models such as save state and document search state.
- `Sources/Markprev/Views`: SwiftUI views and AppKit/WebKit/PDFKit representables.
- `Sources/Markprev/Services`: app-layer services that need platform APIs, including PDF export, FSEvents, and PTY management.
- `Sources/Markprev/Support`: SwiftUI support types, command wiring, keyboard monitoring, color/theme bridging, and window chrome helpers.
- `Sources/Markprev/Resources`: bundled terminal web assets.
- `Tests/MarkprevTests`: XCTest unit tests for core services and models.
- `script/build_and_run.sh`: manual app bundle builder/runner. It compiles explicit source-file lists and copies runtime resources into `dist/Markprev.app`.
- `dist`: local build output. Treat as generated.

## Main Runtime Flow

1. `MarkprevApp` creates shared `WorkspaceStore` and `ThemeSettingsStore`, then renders `ContentView`.
2. `ContentView` owns UI preferences via `@AppStorage`, restores the previous workspace, coordinates lightweight document tabs, sidebar/detail layout, document search, workspace search, Markdown outline parsing, source jumps, terminal visibility, and Markdown PDF export.
3. `SidebarView` displays the workspace tree from `WorkspaceStore.rootNode`, opens folders, handles drops, manages file/folder context menu actions, routes file opens through `ContentView` tab actions, and presents `WorkspaceSearchView`.
4. `EditorPaneView` switches on `WorkspaceDocument.kind`:
   - The `DocumentTabBar` above the editor renders open tab metadata only; inactive tabs do not instantiate hidden editors/previews.
   - Markdown source: `MarkdownTextEditor`.
   - Markdown preview: `MarkdownPreviewView`.
   - Text/source/data text files: `MarkdownTextEditor` as a generic plain text editor.
   - PDF: `PDFPreviewView`.
   - Native preview files: `QuickLookPreviewView`.
   - Unsupported file: unsupported document view.
5. `WorkspaceStore` is the main app state owner for workspace selection, document loading, dirty text, save state, file operations, security-scoped bookmarks, external file refresh, and selected document state.
6. `WorkspaceDocumentScanner` builds the sidebar tree and document list from the selected workspace.

## Core Domain And Service Boundaries

Prefer putting logic in `MarkprevCore` when it can be tested without SwiftUI/AppKit view state.

- Workspace model:
  - `WorkspaceDocument`: document identity, path, relative path, kind, content type metadata, capabilities, and depth.
  - `WorkspaceDocumentCapabilities`: explicit preview/edit/search/export/outline capability flags.
  - `WorkspaceTabState`: lightweight tab order, active document ID, pinned state, document snapshots, close behavior, and rename/move ID remapping.
  - `WorkspaceDocumentSupport`: UTType-backed classification, conservative extension fallback groups, capability mapping, and relative path helpers.
  - `SidebarNode`: folder/file tree model for the sidebar.
- Markdown rendering:
  - `MarkdownRenderService`: builds the HTML shell with theme variables, CSP, base URL, CSS, and renderer JavaScript.
  - `Sources/MarkprevCore/Resources/renderer.js`: custom Markdown renderer, document search highlighting, source-jump events, and dynamic appearance updates.
  - `Sources/MarkprevCore/Resources/preview.css`: preview styling and print/export styling.
- Search and outline:
  - `WorkspaceSearchService`: searches editable text documents and searchable PDFs using `PDFKit.PDFDocument`.
  - `WorkspaceSearchResult`: normalized result model for text and PDF matches.
  - `MarkdownOutlineParser`: extracts Markdown headings while ignoring fenced code blocks.
  - `MarkdownOutlineItem` and `MarkdownSourceLocation`: outline/source-jump models.
- PDF export options:
  - `MarkdownPDFExportOptions`: page size, margins, theme mode, scale, clamping, and last-used persistence.

App-layer code should stay in `Sources/Markprev` when it uses SwiftUI state, AppKit, WebKit, PDFKit UI classes, FSEvents, PTYs, window behavior, menus, or user defaults tied directly to UI.

## Important App-Layer Owners

- `WorkspaceStore`: central workspace state machine. It uses generation counters and cancellable tasks to prevent stale async results from overwriting newer state. Preserve this pattern when adding async workspace, document, save, or refresh behavior.
- Tab state is owned by `ContentView`, but `WorkspaceStore` remains the source of truth for the active document text, dirty buffers, save state, external refresh, and file operations. Do not create per-tab editor state or per-tab preview instances.
- `WorkspaceStore` publishes document-ID remap events for rename/cut-paste operations so inactive tabs can survive path changes.
- `WorkspaceStore` tracks open document IDs so dirty open documents removed externally are not silently pruned before the UI can surface the conflict.
- `WorkspaceFileWatcher`: wraps macOS FSEvents and reports changed paths/full-rescan requirements back to `WorkspaceStore`.
- `ThemeSettingsStore`: persists selected light/dark theme IDs and sanitized per-theme customizations in `UserDefaults`.
- `MarkdownOutlineStore`: debounces outline parsing off the main actor.
- `WorkspaceSearchState`: debounces workspace search and runs search work off the main actor.
- `TerminalSessionStore`: owns terminal transcript, working directory, lifecycle, resize, and PTY interaction.
- `TerminalPTYSession`: low-level `/bin/zsh` PTY process management using `forkpty`, dispatch read sources, and wait handling.
- `MarkdownPDFExportService`: uses an offscreen `WKWebView`, `WKPDFConfiguration`, and `PDFKit.PDFDocument` to export paginated PDFs.

## Platform API Usage

Use Apple-native APIs where they fit the feature:

- PDF viewing: `PDFView` in `PDFPreviewView`.
- PDF search/text extraction: `PDFDocument` and `PDFSelection` in `WorkspaceSearchService` and `PDFPreviewView`.
- Markdown preview/export rendering: `WKWebView`; the HTML shell comes from `MarkdownRenderService`.
- PDF export: `WKWebView.createPDF(configuration:)` plus `PDFKit.PDFDocument` pagination.
- Generic native previews: `QLPreviewView` in `QuickLookPreviewView`.
- File type detection: `UniformTypeIdentifiers.UTType` in `WorkspaceDocumentSupport`, with extension fallbacks for formats UTType may not classify consistently.
- Text editing: `NSTextView` through `MarkdownTextEditor`, used for Markdown source and generic editable text/source/data files.
- File watching: FSEvents in `WorkspaceFileWatcher`.
- Folder access persistence: security-scoped bookmarks in `WorkspaceStore`.
- File/folder open panels, reveal in Finder, and pasteboard interactions: AppKit in the app layer.
- Terminal: Darwin PTY APIs in `TerminalPTYSession`.

Before adding custom parsing, indexing, PDF handling, file watching, or rendering code, check whether Foundation, AppKit, PDFKit, WebKit, CoreServices, or UniformTypeIdentifiers already provides the behavior.


## State And Concurrency Conventions

- Keep UI state owners on `@MainActor`.
- Run file scanning, searching, outline parsing, loading, saving, and rendering preparation off the main actor when work can block.
- Use task cancellation and generation tokens for debounced or replaceable work.
- Do not let stale async completions update `@Published` state.
- Update `WorkspaceStore` rather than duplicating workspace/document state in views.
- Keep save/dirty state transitions centralized in `WorkspaceStore`.
- Preserve security-scoped access behavior when changing workspace open/restore logic.
- Use `WorkspaceDocument.id` as the canonical document identifier; it is the standardized file path.

## UI Conventions

- Main layout is `NavigationSplitView` in `ContentView`.
- Sidebar-specific state and tree presentation live in `SidebarView`.
- Detail/editor state lives in `EditorPaneView`.
- File tabs are rendered by `DocumentTabBar` under `TopNavigationBar`. Keep tabs lightweight: labels, pinned state, close/pin actions, and save indicators only.
- App menu commands flow through `MarkprevCommandActions` and `FocusedValues`.
- Markdown preview behavior belongs in `MarkdownPreviewView` and `renderer.js`, not scattered across unrelated views.
- PDF viewing behavior belongs in `PDFPreviewView`.
- Native preview-only behavior belongs in `QuickLookPreviewView`.
- Route behavior by `WorkspaceDocument.capabilities` when possible. Keep `WorkspaceDocumentKind` coarse; do not add one enum case per file extension.
- Theme colors should flow through `AppTheme` and `Color+Theme.swift`.
- User-facing persisted UI preferences generally use `@AppStorage` keys prefixed with `Markprev.`.

## Manual Build Script Warning

`script/build_and_run.sh` does not discover Swift files automatically. It contains explicit `CORE_SOURCES` and `APP_SOURCES` arrays.

When adding, moving, or deleting Swift files that must be included in the manually built app, update this script as well as `Package.swift` if needed.

The script also manually copies these runtime resources into the app bundle:

- `Sources/MarkprevCore/Resources/preview.css`
- `Sources/MarkprevCore/Resources/renderer.js`
- `Sources/Markprev/Resources/xterm.css`
- `Sources/Markprev/Resources/xterm.js`
- `Sources/Markprev/Resources/xterm-addon-fit.js`

When adding a Swift source file to the app or core target, update `script/build_and_run.sh`. The declared XCTest suite includes a build-script sync check, but the local SwiftPM command may be blocked until the current CommandLineTools issue is fixed.

## Testing

Primary command:

```sh
swift test
```

Current local caveat: on this machine, `swift test` has been observed to fail before test compilation with a CommandLineTools module-map issue (`SwiftBridging` redefinition and Foundation/CoreServices module build failures). If that happens, record the exact output and use the manual build/smoke verification paths below until the toolchain is repaired.

Current XCTest coverage focuses on `MarkprevCore`:

- `WorkspaceDocumentScannerTests`: tree scanning, file classification, sorting, symlink skipping, relative paths.
- `MarkdownRenderServiceTests`: HTML shell generation, theme variables, escaping, export styling.
- `WorkspaceSearchServiceTests`: Markdown and PDF search behavior.
- `MarkdownOutlineParserTests`: Markdown heading extraction behavior.
- `MarkdownPDFExportOptionsTests`: export option defaults, clamping, persistence behavior.
- `BuildScriptSyncTests`: manual build script source/resource sync.
- Manual smoke coverage includes `WorkspaceTabState` open/dedupe/pin/close/prune/remap behavior and `WorkspaceStore` remap/delete guard behavior.

Manual smoke verification used in this repo when SwiftPM is blocked:

```sh
script/build_and_run.sh --verify
swiftc -vfsoverlay .build/manual/swift-vfs-overlay.yaml -I .build/manual -L .build/manual -lMarkprevCore -Xlinker -rpath -Xlinker .build/manual Tests/MarkprevSmokeTests/main.swift -o .build/manual/MarkprevSmokeTests
.build/manual/MarkprevSmokeTests
swiftc -parse-as-library -vfsoverlay .build/manual/swift-vfs-overlay.yaml -I .build/manual -L .build/manual -lMarkprevCore -Xlinker -rpath -Xlinker .build/manual Sources/Markprev/Models/DocumentSaveState.swift Sources/Markprev/Services/WorkspaceFileWatcher.swift Sources/Markprev/Stores/WorkspaceStore.swift Tests/MarkprevStoreSmokeTests/main.swift -o .build/manual/MarkprevStoreSmokeTests
.build/manual/MarkprevStoreSmokeTests
```

When adding logic:

- Put pure logic in `MarkprevCore` and add XCTest coverage in `Tests/MarkprevTests`.
- Add tests for cancellation-safe service behavior when feasible.
- Add regression tests for path handling, file type classification, Markdown parsing, search matching, theme persistence, and PDF export option logic.
- Add regression tests for capability classification, editable text support, Quick Look routing, and PDF workspace-result targets.
- For AppKit/SwiftUI/WebKit/PDFKit UI behavior, prefer small testable model/service seams plus manual verification until a UI test target exists.

## Common Commands

Run unit tests:

```sh
swift test
```

Build and open the app bundle:

```sh
script/build_and_run.sh
```

Build the app bundle and verify the process launches:

```sh
script/build_and_run.sh --verify
```

Run with logs:

```sh
script/build_and_run.sh --logs
```

Debug the built binary:

```sh
script/build_and_run.sh --debug
```

## Generated And Local Files

- Do not hand-edit `dist` unless the task is specifically about generated bundle output.
- Do not commit local `.build` artifacts.
- Be careful with uncommitted files. This repo often contains active feature work; do not revert changes you did not make.

## Guidance For Future Agents

- Read `WorkspaceStore` before changing workspace, document, save, dirty-state, bookmark, or external-refresh behavior.
- Read `WorkspaceTabState`, `DocumentTabBar`, `ContentView`, and `WorkspaceStore` before changing tab behavior. Tabs are metadata around the active `WorkspaceStore` document, not independent document runtimes.
- Read `MarkdownRenderService`, `MarkdownPreviewView`, `renderer.js`, and `preview.css` together before changing Markdown preview or export behavior.
- Read `PDFPreviewView`, `WorkspaceSearchService`, and `MarkdownPDFExportService` before changing PDF behavior.
- Read `QuickLookPreviewView` and `WorkspaceDocumentSupport` before changing generic preview or file-format support.
- Read `ThemeSettingsStore`, `AppTheme`, and `Color+Theme.swift` before changing theming.
- Read `TerminalSessionStore`, `TerminalPTYSession`, `TerminalDrawerView`, and `TerminalWebView` before changing terminal behavior.
- Keep `MarkprevCore` independent from SwiftUI/AppKit view types unless there is a deliberate architectural change.
- Prefer narrowly scoped changes and focused tests over broad refactors.
- Avoid adding duplicate state to views when the state already belongs to a store.
- Avoid adding new global singletons; inject services where the current design already supports it.
- If a feature needs platform integration, put the platform wrapper in `Sources/Markprev/Services` and keep reusable policy/model code in `MarkprevCore`.
- When implementing a feature, first consult the official Apple Developer Documentation and related Apple guides/articles first. Prefer Apple-recommended APIs and lifecycle patterns over ad hoc implementations, and record the relevant docs links in research notes or implementation docs when the decision affects architecture.
