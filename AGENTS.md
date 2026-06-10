# Monknot Agent Guide

This file orients AI agents and contributors working in this repository. Keep it current when major files, targets, or workflows move.

## Project Overview

Monknot is a SwiftPM macOS app for browsing a workspace, opening multiple files in lightweight tabs, editing Markdown and text-like files, previewing Markdown, viewing PDFs, skipping unsupported binary/media file types, searching text/PDF documents, exporting Markdown to PDF, and running an embedded terminal.

The package is organized around these main SwiftPM targets and helper executables:

- `MonknotCore`: reusable model and service logic with minimal UI coupling.
- `MonknotApp`: macOS application layer (SwiftUI, AppKit bridges, stores, views) including `@main`.
- `MonknotExport`: stdio/CLI read-only workspace export (`monknot-export --workspace PATH --json`).
- `MonknotCapture`: CLI helper for building and opening `monknot://capture` URLs (`monknot-capture`).
- `MonknotWorkspaceExport`: executable smoke/export coverage target used by local verification.

The package declares these test targets:

- `MonknotTests`: XCTest coverage for `MonknotCore`.
- `MonknotAppTests`: XCTest integration coverage for `MonknotApp` (`WorkspaceStore` conflict and dirty-state behavior).
- `MonknotSmokeTests`: executable smoke coverage for core workflows (scanner, tabs, search, render).
- `MonknotStoreSmokeTests`: executable smoke coverage for `WorkspaceStore` save, paste, conflict, and file operations.
- Additional executable smoke targets cover recent workspaces and shortcut routing.

## Repository Map

- `Package.swift`: SwiftPM manifest. Add new compile targets or resources here if they should be part of SwiftPM builds/tests.
- `Sources/MonknotCore/Models`: value types and enums shared by the app and tests.
- `Sources/MonknotCore/Services`: core services for scanning workspaces, rendering Markdown HTML, parsing outlines, and searching workspaces.
- `Sources/MonknotCore/Resources`: Markdown preview CSS and JavaScript renderer used by WebKit preview and PDF export.
- `Sources/Monknot/App`: app entry point and application delegate.
- `Sources/Monknot/Stores`: `@MainActor` observable state containers for workspace, themes, terminal state, and Markdown outline state.
- `Sources/Monknot/Models`: app-layer UI state models such as save state and document search state.
- `Sources/Monknot/Views`: SwiftUI views and AppKit/WebKit/PDFKit representables.
- `Sources/Monknot/Services`: app-layer services that need platform APIs, including PDF export, FSEvents, and PTY management.
- `Sources/Monknot/Support`: SwiftUI support types, command wiring, keyboard monitoring, color/theme bridging, and window chrome helpers.
- `Sources/Monknot/Resources`: bundled terminal web assets.
- `Tests/MonknotTests`: XCTest unit tests for core services and models.
- `Tests/MonknotAppTests`: XCTest integration tests for app-layer store behavior.
- `Tests/MonknotSmokeTests`: executable smoke tests for core workflows.
- `Tests/MonknotStoreSmokeTests`: executable smoke tests for `WorkspaceStore`.
- `Tests/MonknotRecentWorkspaceSmokeTests`, `Tests/MonknotShortcutSmokeTests`: additional SwiftPM executable smoke tests for core integration edges.
- `Tests/MonknotPDFAnnotationSmokeTests`, `Tests/MonknotPDFExportSmokeTests`, `Tests/MonknotTerminalSmokeTests`, `Tests/MonknotWindowSmokeTests`: historical manual smoke sources that exercise app-internal types; prefer XCTest in `MonknotAppTests` or manual compile paths when reviving them.
- `script/build_and_run.sh`: manual app bundle builder/runner. It compiles explicit source-file lists and copies runtime resources into `dist/monknot.app`.
- `dist`: local build output. Treat as generated.

## Main Runtime Flow

1. `MonknotApp` creates shared `WorkspaceStore` and `ThemeSettingsStore`, then renders `ContentView`.
2. `ContentView` owns UI preferences via `@AppStorage`, restores the previous workspace, coordinates lightweight document tabs, sidebar/detail layout, document search, workspace search, Markdown outline parsing, source jumps, terminal visibility, and Markdown PDF export.
3. `SidebarView` displays the workspace tree from `WorkspaceStore.rootNode`, recent documents, optional git status badges when a status map is supplied, opens folders, handles drops, manages file/folder context menu actions, routes file opens through `ContentView` tab actions, and presents `WorkspaceSearchView`.
4. Markdown/HTML split editor: `EditorPaneView` can show source and preview side by side via `HSplitView` when split view is enabled (View menu or ⌘\\). Split view preference persists per document via `DocumentSplitViewPersistence` (`Monknot.markdownSplitView.<path-hash>` with legacy fallback to `Monknot.markdownSplitView`). Split divider ratio (source pane fraction) persists per document via `Monknot.markdownSplitRatio.<path-hash>` and is applied through `DocumentSplitViewRatioAccessor` (NSSplitView delegate on the editor split). Markdown split syncs scroll by source line via `MarkdownScrollSync`, `renderer.js` (`monknotScrollToLine` / `monknotVisibleSourceLine`), and `MarkdownPreviewView`/`NativeMarkdownEditorView` callbacks. HTML split uses proportional line sync via `HTMLScrollSync` and `HTMLPreviewView` (`monknotHTMLScrollToLine` / `monknotHTMLVisibleSourceLine`). PDF and other kinds are unchanged.
5. `EditorPaneView` switches on `WorkspaceDocument.kind`:
   - The `DocumentTabBar` above the editor renders open tab metadata only; inactive tabs do not instantiate hidden editors/previews.
   - Sidebar/recent/search/quick-open navigation opens regular lightweight tabs. Inactive tabs keep metadata only and do not instantiate hidden editors/previews.
   - Markdown source: `MarkdownTextEditor`.
   - Markdown preview: `MarkdownPreviewView`.
   - Text/source/data text files: `MarkdownTextEditor` as a generic plain text editor.
   - PDF: `PDFPreviewView`.
   - Media/native preview/unsupported files: skipped by the scanner when possible. Generic Quick Look/media preview is intentionally disabled for performance.
6. `WorkspaceStore` is the main app state owner for workspace selection, document loading, dirty text, save state, file operations, security-scoped bookmarks, external file refresh, and selected document state.
7. `WorkspaceDocumentScanner` builds the sidebar tree and document list from the selected workspace.

## Core Domain And Service Boundaries

Prefer putting logic in `MonknotCore` when it can be tested without SwiftUI/AppKit view state.

- Workspace model:
  - `WorkspaceDocument`: document identity, path, relative path, kind, content type metadata, capabilities, and depth.
  - `WorkspaceDocumentCapabilities`: explicit preview/edit/search/export/outline capability flags.
  - `WorkspaceTabState`: lightweight tab order, active document ID, pinned state, document snapshots, close behavior, and rename/move ID remapping.
  - `WorkspaceDocumentSupport`: UTType-backed classification, conservative extension fallback groups, capability mapping, and relative path helpers.
  - `SidebarNode`: folder/file tree model for the sidebar.
- Markdown rendering:
  - `MarkdownRenderService`: builds the HTML shell with theme variables, CSP, base URL, CSS, and renderer JavaScript.
  - `Sources/MonknotCore/Resources/renderer.js`: custom Markdown renderer, document search highlighting, source-jump events, and dynamic appearance updates.
  - `Sources/MonknotCore/Resources/preview.css`: preview styling and print/export styling.
- Search and outline:
  - `WorkspaceSearchService`: searches editable text documents and searchable PDFs using `PDFKit.PDFDocument`. Returns `WorkspaceSearchBatch` with `results` and `skippedLargeFileCount`. Text reads go through `WorkspaceTextFileGuard` (size/encoding guard), `WorkspaceTextContentCache`, `WorkspaceSearchIndex`, `WorkspacePDFTextCache`, and `WorkspacePDFSearchIndex`; caches are bounded and invalidated from FSEvents-driven workspace changes.
  - `WorkspaceReplaceService`: case-insensitive workspace-wide find/replace for editable text/markdown files on disk. Skips unsaved (dirty) documents. Supports `limitToDocumentIDs` for scoped replace (`WorkspaceReplaceScope`: all files, all search-result files, or selected search-result file only). `preview(...)` returns a dry-run `WorkspaceReplacePreview` (file list + counts) before Replace All confirmation. Captures `previousTextsByDocumentID` for batch undo. `WorkspaceStore.replaceInWorkspace(find:replacement:scope:searchResultDocumentIDs:)` writes files, refreshes open clean tabs, publishes `workspaceReplaceSummary`, and exposes `undoLastWorkspaceReplace()` (⌘Z) for the last batch.
  - `WorkspaceSearchResultExporter`: tab-separated export of workspace search hits for clipboard copy from `WorkspaceSearchView`.
  - `WorkspaceReadOnlyExportService`: read-only stdio JSON export for workspace document metadata (`list_documents`) and workspace search (`search` with `query`). One-shot CLI via `swift run monknot-export --workspace PATH --json`.
  - `WorkspaceQuickOpenMatcher`: fuzzy path ranking for Quick Open (⌘P).
  - `DailyNotePlanner`: dated `inbox/YYYY-MM-DD.md` paths for Daily Note (⇧⌘N).
  - `MarkdownSymbolQuickOpenMatcher`: heading ranking for Go to Symbol (⇧⌘O).
  - `WikilinkAutocompleteService`: `[[` prefix detection and markdown title suggestions (Tab completes in editor).
  - `WorkspaceContextAssembler`: builds local excerpt chunks for agent-friendly export and terminal workflows, optionally prioritizing Related Notes paths from the active document.
  - `DocumentSplitViewPersistence`: per-document split-view toggle and source-pane ratio persistence keyed by standardized document path hash; remaps stored preferences when documents are renamed or moved on disk.
  - `DocumentSplitViewRatioAccessor`: AppKit bridge that applies persisted split ratios to SwiftUI `HSplitView` and writes divider drags back to `DocumentSplitViewPersistence`.
  - `WorkspaceDocumentSupport.displayName(forRelativePath:)`: shared relative-path display label used by Related Notes and context chips.
  - `HTMLScrollSync`: proportional source-line ↔ scroll-position math for HTML split-view sync scroll.
  - `WorkspaceGitStatusService`: parses `git status --porcelain` for optional sidebar git badges. The app no longer runs git status automatically during workspace open because that background work can compete with early file switching.
  - `RecentDocumentStore`: per-workspace recent document list for the sidebar.
  - `MonknotKeyboardShortcutCatalog`: static shortcut list for the `?` help overlay.
  - `BetaFeedbackRecorder`: appends local beta feedback to Application Support JSONL (no network).
  - `WorkspaceSearchResult`: normalized result model for text and PDF matches.
  - `MarkdownOutlineParser`: extracts Markdown headings while ignoring fenced code blocks.
  - `MarkdownOutlineItem` and `MarkdownSourceLocation`: outline/source-jump models.
- PDF export options:
  - `MarkdownPDFExportOptions`: page size, margins, theme mode, scale, clamping, and last-used persistence.

App-layer code should stay in `Sources/Monknot` when it uses SwiftUI state, AppKit, WebKit, PDFKit UI classes, FSEvents, PTYs, window behavior, menus, or user defaults tied directly to UI.

## Important App-Layer Owners

- `WorkspaceStore`: central workspace state machine. It uses generation counters and cancellable tasks to prevent stale async results from overwriting newer state. Preserve this pattern when adding async workspace, document, save, or refresh behavior.
- Tab state is owned by `ContentView`, but `WorkspaceStore` remains the source of truth for the active document text, dirty buffers, save state, external refresh, and file operations. Do not create per-tab editor state or per-tab preview instances.
- `WorkspaceStore` publishes document-ID remap events for rename/cut-paste operations so inactive tabs can survive path changes.
- `WorkspaceStore` tracks open document IDs so dirty open documents removed externally are not silently pruned before the UI can surface the conflict.
- `WorkspaceFileWatcher`: wraps macOS FSEvents and reports changed paths, modification-only paths, and full-rescan requirements back to `WorkspaceStore`. Modification-only events can refresh the active document without a full workspace scan.
- `ThemeSettingsStore`: persists selected light/dark theme IDs and sanitized per-theme customizations in `UserDefaults`.
- `MarkdownOutlineStore`: debounces outline parsing off the main actor.
- `WorkspaceSearchState`: debounces workspace search and runs search work off the main actor.
- `TerminalSessionCollectionStore`: owns the terminal tab collection, active terminal selection, and per-terminal create/switch/kill/restart actions.
- `TerminalSessionStore`: owns one terminal's transcript, working directory, lifecycle, resize, and PTY interaction.
- `TerminalPTYSession`: low-level `/bin/zsh` PTY process management using `forkpty`, dispatch read sources, and wait handling.
- `MarkdownPDFExportService`: uses an offscreen `WKWebView`, `WKPDFConfiguration`, and `PDFKit.PDFDocument` to export paginated PDFs.

## Platform API Usage

Use Apple-native APIs where they fit the feature:

- PDF viewing: `PDFPreviewView` renders PDFs in-app with PDFKit, including annotation/search state. Generic Quick Look/media preview remains disabled for file-switching performance.
- PDF search/text extraction: `PDFDocument` and `PDFSelection` in `WorkspaceSearchService`; keep this out of the file-selection/render hot path.
- Markdown preview/export rendering: `WKWebView`; the HTML shell comes from `MarkdownRenderService`.
- PDF export: `WKWebView.createPDF(configuration:)` plus `PDFKit.PDFDocument` pagination.
- Generic native previews: disabled. Do not route image/video/Office/native files into Quick Look or the workspace document list without an explicit performance decision.
- File type detection: `UniformTypeIdentifiers.UTType` in `WorkspaceDocumentSupport`, with extension fallbacks for formats UTType may not classify consistently.
- Text editing: `NSTextView` through `MarkdownTextEditor`, used for Markdown source and generic editable text/source/data files. Interactive editor opens are capped by `WorkspaceStore.interactiveTextOpenMaxBytes` so very large text files do not block file switching; search/export services can still use their own guarded limits.
- File watching: FSEvents in `WorkspaceFileWatcher`.
- Folder access persistence: security-scoped bookmarks in `WorkspaceStore`.
- File/folder open panels, reveal in Finder, and pasteboard interactions: AppKit in the app layer.
- Terminal: Darwin PTY APIs in `TerminalPTYSession`.

Terminal lifecycle notes:

- Multi-terminal UI is explicit: `TerminalSessionCollectionStore` owns tab metadata and one `TerminalSessionStore` per terminal. `TerminalWebView` renders only the active terminal, so inactive terminals do not keep hidden WebKit/xterm views mounted.
- Hiding the terminal drawer does not kill sessions. Terminal tabs use a single VS Code-style destructive action: killing a terminal stops its PTY if needed and removes that one session/tab.
- New terminals start in the active document directory when possible, then the workspace directory, then the user's home directory. Existing running terminals keep their original working directory.
- `TerminalPTYSession` follows Apple's Dispatch source guidance: a read source owns its file descriptor while active, and the cancellation handler closes it after the source releases the descriptor. Relevant docs: https://developer.apple.com/documentation/dispatch/dispatch_source_cancel and https://developer.apple.com/documentation/dispatch/dispatchsource/makereadsource%28filedescriptor%3Aqueue%3A%29.
- `TerminalWebView` removes WebKit script message handlers during dismantle. Relevant docs: https://developer.apple.com/documentation/webkit/wkscriptmessagehandler.

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

## Implementation Quality And Performance

- Consider performance, memory, CPU usage, and lifecycle cleanup as part of every feature implementation, not as a separate cleanup pass.
- Avoid designs that introduce retain cycles, orphaned processes, leaked file descriptors, unbounded buffers, unnecessary background work, repeated expensive recomputation, or main-thread blocking.
- Bound memory growth for transcripts, search results, cached previews, and other accumulative state.
- Prefer simple, platform-aligned implementations over custom machinery when native APIs already handle the behavior.
- If a feature creates long-lived tasks, watchers, WebViews, PDF views, PTYs, timers, dispatch sources, or observers, define and verify its teardown path.
- Do not accept an implementation as complete if it works functionally but introduces high CPU usage, memory leaks, poor async patterns, or brittle architecture.

## UI Conventions

- Main layout is `NavigationSplitView` in `ContentView`.
- Sidebar-specific state and tree presentation live in `SidebarView`.
- Detail/editor state lives in `EditorPaneView`.
- File tabs are rendered by `DocumentTabBar` under `TopNavigationBar`. Keep tabs lightweight: labels, pinned state, close/pin actions, and save indicators only. Inactive tabs must remain metadata only; do not create per-tab editor/preview runtimes. When split view is active for markdown/HTML documents, `TopNavigationBar` shows an active split indicator (click to turn off; ⌘\\ also toggles).
- App menu commands flow through `MonknotCommandActions` and `FocusedValues`. Quick Open uses ⌘P; Export PDF is menu-only.
- Markdown preview behavior belongs in `MarkdownPreviewView` and `renderer.js`, not scattered across unrelated views.
- PDF viewing behavior belongs in `PDFPreviewView`.
- Generic preview-only behavior is intentionally disabled; media/native preview files should be skipped by scanning and must not mount preview runtimes.
- Route behavior by `WorkspaceDocument.capabilities` when possible. Keep `WorkspaceDocumentKind` coarse; do not add one enum case per file extension.
- Theme colors should flow through `AppTheme` and `Color+Theme.swift`.
- User-facing persisted UI preferences generally use `@AppStorage` keys prefixed with `Monknot.`.

## Manual Build Script Warning

`script/build_and_run.sh` does not discover Swift files automatically. It contains explicit `CORE_SOURCES` and `APP_SOURCES` arrays.

When adding, moving, or deleting Swift files that must be included in the manually built app, update this script as well as `Package.swift` if needed.

The script also manually copies these runtime resources into the app bundle:

- `Sources/MonknotCore/Resources/preview.css`
- `Sources/MonknotCore/Resources/renderer.js`
- `Sources/Monknot/Resources/xterm.css`
- `Sources/Monknot/Resources/xterm.js`
- `Sources/Monknot/Resources/xterm-addon-fit.js`

When adding a Swift source file to the app or core target, update `script/build_and_run.sh`. The declared XCTest suite includes a build-script sync check, but the local SwiftPM command may be blocked until the current CommandLineTools issue is fixed.

## Testing

Primary command:

```sh
swift test
swift run MonknotSmokeTests
swift run MonknotStoreSmokeTests
swift run MonknotRecentWorkspaceSmokeTests
swift run MonknotShortcutSmokeTests
swift run MonknotWorkspaceExport
swift run monknot-export --workspace /path/to/workspace --json
```

If SwiftPM fails before test compilation with a CommandLineTools module-map issue (`SwiftBridging` redefinition and Foundation/CoreServices module build failures), record the exact output and use the manual build/smoke verification paths below until the toolchain is repaired.

Current XCTest coverage focuses on `MonknotCore`:

- `WorkspaceDocumentScannerTests`: tree scanning, file classification, sorting, symlink skipping, relative paths.
- `MarkdownRenderServiceTests`: HTML shell generation, theme variables, escaping, export styling.
- `WorkspaceSearchServiceTests`: Markdown and PDF search behavior.
- `WorkspaceSearchIndexTests`, `WorkspaceSearchCacheTests`, and `WorkspaceSearchBenchmarkTests`: bounded text/PDF index reuse, invalidation, and large-workspace search regressions.
- `MarkdownOutlineParserTests`: Markdown heading extraction behavior.
- `MarkdownPDFExportOptionsTests`: export option defaults, clamping, persistence behavior.
- `MarkdownScrollSyncTests`: source line ↔ character offset math for split-view scroll sync.
- `HTMLScrollSyncTests`: proportional line ↔ scroll fraction math for HTML split-view sync scroll.
- `DocumentSplitViewPersistenceTests`: per-document split-view storage keys, split ratio persistence/clamping/remap, legacy global fallback, and rename/move key remapping.
- `WorkspaceDocumentSupportTests`: shared relative-path display name helper.
- `WorkspaceReplaceScopeTests`: replace scope metadata for workspace search replace UI.
- `WorkspaceContextAssemblerTests`: excerpt assembly, stop-word term extraction, preferred related-note path priority.
- `WorkspaceReplaceServiceTests`: dry-run `preview()`, scoped replace, undo snapshots, summary message formatting.
- `WorkspaceContextOrderingTests`: related-note-first ordering for context chips.
- `BuildScriptSyncTests`: manual build script source/resource sync.
- Manual smoke coverage includes `WorkspaceTabState` open/dedupe/pin/close/prune/remap behavior and `WorkspaceStore` remap/delete guard behavior.

Manual smoke verification used in this repo when SwiftPM is blocked:

```sh
script/build_and_run.sh --verify
swiftc -vfsoverlay .build/manual/swift-vfs-overlay.yaml -I .build/manual -L .build/manual -lMonknotCore -Xlinker -rpath -Xlinker .build/manual Tests/MonknotSmokeTests/main.swift -o .build/manual/MonknotSmokeTests
.build/manual/MonknotSmokeTests
swiftc -parse-as-library -vfsoverlay .build/manual/swift-vfs-overlay.yaml -I .build/manual -L .build/manual -lMonknotCore -Xlinker -rpath -Xlinker .build/manual Sources/Monknot/Models/DocumentSaveState.swift Sources/Monknot/Services/WorkspaceFileWatcher.swift Sources/Monknot/Services/WorkspacePasteboardImportService.swift Sources/Monknot/Stores/WorkspaceStore.swift Tests/MonknotStoreSmokeTests/MonknotStoreSmokeTestsSupport.swift Tests/MonknotStoreSmokeTests/MonknotStoreSmokeTests.swift -o .build/manual/MonknotStoreSmokeTests
.build/manual/MonknotStoreSmokeTests
```

When adding logic:

- Write tests to discover real issues in the app, not tests shaped only to pass the current implementation.
- Cover realistic workflows, edge cases, failure paths, regressions, and cross-component behavior when the feature touches app-level state.
- A passing test suite is not enough if the tests do not exercise the risky behavior introduced or changed by the feature.
- Put pure logic in `MonknotCore` and add XCTest coverage in `Tests/MonknotTests`.
- Add tests for cancellation-safe service behavior when feasible.
- Add regression tests for path handling, file type classification, Markdown parsing, search matching, theme persistence, and PDF export option logic.
- Add regression tests for capability classification, editable text support, unsupported file skipping, and PDF workspace-result targets.
- For AppKit/SwiftUI/WebKit/PDFKit UI behavior, prefer small testable model/service seams plus manual verification until a UI test target exists.

## Common Commands

Run unit tests:

```sh
swift test
swift run MonknotSmokeTests
swift run MonknotStoreSmokeTests
swift run MonknotRecentWorkspaceSmokeTests
swift run MonknotShortcutSmokeTests
swift run MonknotWorkspaceExport
swift run monknot-export --workspace /path/to/workspace --json
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
- Read `PDFPreviewView` and `WorkspaceDocumentSupport` before changing PDF viewing or file-format support.
- Read `ThemeSettingsStore`, `AppTheme`, and `Color+Theme.swift` before changing theming.
- Read `TerminalSessionCollectionStore`, `TerminalSessionStore`, `TerminalPTYSession`, `TerminalDrawerView`, and `TerminalWebView` before changing terminal behavior.
- Keep `MonknotCore` independent from SwiftUI/AppKit view types unless there is a deliberate architectural change.
- Prefer narrowly scoped changes and focused tests over broad refactors.
- Avoid adding duplicate state to views when the state already belongs to a store.
- Avoid adding new global singletons; inject services where the current design already supports it.
- If a feature needs platform integration, put the platform wrapper in `Sources/Monknot/Services` and keep reusable policy/model code in `MonknotCore`.
- When implementing a feature, first consult the official Apple Developer Documentation and related Apple guides/articles first. Prefer Apple-recommended APIs and lifecycle patterns over ad hoc implementations, and record the relevant docs links in research notes or implementation docs when the decision affects architecture.
