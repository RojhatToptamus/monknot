# Monknot Agent Guide

This file orients AI agents and contributors working in this repository. Keep it current when major files, targets, or workflows move.

## Project Overview

Monknot is a SwiftPM macOS app for browsing a workspace, opening multiple files in lightweight tabs, editing Markdown and text-like files, editing Markdown visually in Preview, viewing and marking up PDFs and images, playing video and audio, showing Jupyter notebooks, listing every other file (archives, Office documents and other binary files open in their own app), searching text/PDF documents, exporting Markdown to PDF, and running an embedded terminal.

Direct releases use Sparkle 2 for standard in-app updates. The custom bundle
builder embeds and signs Sparkle.framework; GitHub Releases host immutable
DMGs and the signed appcast.

The package is organized around these main SwiftPM targets and helper executables:

- `MonknotCore`: reusable model and service logic with minimal UI coupling.
- `MonknotApp`: macOS application layer (SwiftUI, AppKit bridges, stores, views) including `@main`.
- `MonknotExport`: stdio/CLI read-only workspace export (`monknot-export --workspace PATH --json`).
- `MonknotCapture`: CLI helper for building and opening `monknot://capture` URLs (`monknot-capture`).
- `MonknotThemeCatalogExport`: build-time JSON export of the canonical theme catalog for the
  product website.

The package declares these test targets:

- `MonknotTests`: XCTest coverage for `MonknotCore`.
- `MonknotAppTests`: XCTest integration coverage for `MonknotApp` (`WorkspaceStore` conflict and dirty-state behavior).
- `RepositoryContractTests`: XCTest coverage for build, release, workflow, license, and repository policy.
- `MonknotSmokeTests`: one scanner-to-search-to-render executable smoke path.
- `MonknotStoreSmokeTests`: one executable `WorkspaceStore` open, edit, save, and external-change path.

## Copy and Documentation

All user-facing copy must describe Monknot concretely. This applies to the website, README, documentation, release notes, onboarding text, feature descriptions, empty states, and other product copy.

### Core rule

Do not write text simply because a section has space for text. Every sentence must either:

- explain what Monknot does,
- explain why a feature is useful,
- help the user complete a task,
- communicate an important limitation or behavior, or
- provide information the user genuinely needs.

If a sentence does none of these, remove it instead of replacing it with different filler.

### Avoid generic marketing copy

Do not use vague statements that could describe hundreds of unrelated products.

Avoid copy such as:

- "Open a folder and start."
- "Built for focus."
- "Everything you need in one place."
- "Your workspace, your way."
- "Stay in flow."
- "A seamless experience."
- "Powerful yet simple."
- "Designed for productivity."
- "Take your workflow to the next level."

Do not replace bad copy with a different version of the same idea.

### Describe the real product

Copy must be based on the current implementation, not assumptions or old marketing text.

Monknot is a native macOS application for working with local files. Its capabilities include, where relevant:

- Markdown editing
- Markdown preview and export
- PDF tools
- an integrated terminal
- local/offline AI writing features such as autocomplete and autocorrection

Only mention features that actually exist in the current repository.

Prefer concrete wording such as:

> Native macOS Markdown editor with PDF tools, an integrated terminal, and offline AI writing assistance.

over abstract positioning such as:

> A native workspace for the files already on your disk.

### Headlines and feature copy

Headlines should communicate the feature or benefit directly.

Bad:

> Work without interruptions

Better:

> Edit Markdown beside your terminal

Bad:

> Smarter writing

Better:

> Offline autocomplete and autocorrection

Supporting text should add information that is not already obvious from the heading or screenshot.

### README

The README is technical product documentation, not a landing page.

It should quickly communicate:

1. what Monknot is,
2. its main capabilities,
3. what platforms it supports,
4. how to install or run it,
5. anything contributors or users need to know.

Keep it factual and easy to scan. Do not fill it with slogans or repeat website copy unnecessarily.

### Website

Website copy may be more concise than documentation, but it must still communicate real product value.

Prefer screenshots, demonstrations, and concrete feature descriptions over paragraphs of positioning language.

Do not explain obvious interactions such as clicking a button, opening a folder, or starting the app unless the instruction is genuinely necessary.

### Editing existing copy

When modifying existing product copy:

1. Read the surrounding page or document first.
2. Check the implementation when necessary to verify claims.
3. Remove redundant, vague, or repeated text.
4. Preserve useful information even if the wording changes.
5. Keep terminology consistent across the website, README, and application.
6. Review the final page as a whole rather than optimizing sentences independently.

Shorter and more specific is preferable to polished but meaningless copy.

## Repository Map

- `Package.swift`: SwiftPM manifest. Add new compile targets or resources here if they should be part of SwiftPM builds/tests.
- `Sources/MonknotCore/Models`: value types and enums shared by the app and tests.
- `Sources/MonknotCore/Services`: core services for scanning workspaces, rendering Markdown HTML, parsing outlines, and searching workspaces.
- `Sources/MonknotCore/Resources`: `renderer.js` (the one Markdown parser and renderer, used by the preview, PDF export and the editor; every block and inline node records its source range) and `preview.css`; `editor.js` and `editor.css`, the visual editor loaded only into an editable Preview.
- `Sources/Monknot/App`: app entry point and application delegate.
- `Sources/Monknot/Stores`: `@MainActor` observable state containers for workspace, themes, terminal state, and Markdown outline state.
- `Sources/Monknot/Models`: app-layer UI state models such as save state and document search state.
- `Sources/Monknot/Views`: SwiftUI views and AppKit/WebKit/PDFKit representables.
- `Sources/Monknot/Services`: app-layer services that need platform APIs, including PDF export, FSEvents, and PTY management.
- `Sources/Monknot/Support`: SwiftUI support types, command wiring, keyboard monitoring, color/theme bridging, and window chrome helpers.
- `Sources/Monknot/Resources`: bundled terminal web assets.
- `Sources/MonknotThemeCatalogExport`: canonical theme-catalog JSON exporter used by the website
  build.
- `website`: dependency-free single-page product site. `npm run build` produces `website/dist`
  and derives its theme explorer data from `MonknotThemeCatalog`.
- `Tests/MonknotTests`: XCTest unit tests for core services and models.
- `Tests/MonknotAppTests`: XCTest integration tests for app-layer store behavior.
- `Tests/RepositoryContractTests`: repository, workflow, release, security, license, and real CLI process contracts.
- `Tests/MonknotSmokeTests`: scanner-to-search-to-render executable smoke test.
- `Tests/MonknotStoreSmokeTests`: executable `WorkspaceStore` lifecycle smoke test.
- `script/build_and_run.sh`: manual ad-hoc-signed app bundle builder/runner. It compiles explicit source-file lists and copies runtime resources into `dist/Monknot.app`.
- `dist`: local build output. Treat as generated.

## Main Runtime Flow

1. `MonknotApp` creates shared `WorkspaceStore` and `ThemeSettingsStore`, then renders `ContentView`.
2. `ContentView` owns UI preferences via `@AppStorage`, restores the previous workspace, coordinates lightweight document tabs, sidebar/detail layout, document search, workspace search, Markdown outline parsing, source jumps, terminal visibility, and Markdown PDF export.
3. `SidebarView` displays the workspace tree from `WorkspaceStore.rootNode`, recent documents, optional git status badges when a status map is supplied, selects and opens folders, selects several items with ⇧/⌘-click, takes keyboard focus when clicked (arrow keys, Home/End and type-to-select move the selection without opening files; ⌘↓ opens; Return, ⌘D, ⌘⌫ and ⌘A act on the selection), handles drops, manages file/folder context menu actions, routes file opens through `ContentView` tab actions, and presents `WorkspaceSearchView`.
4. Markdown/HTML split editor: `EditorPaneView` can show source and preview side by side via `HSplitView` when split view is enabled (View menu or ⌘\\). Split view preference persists per document via `DocumentSplitViewPersistence` (`Monknot.markdownSplitView.<path-hash>` with legacy fallback to `Monknot.markdownSplitView`). Split divider ratio (source pane fraction) persists per document via `Monknot.markdownSplitRatio.<path-hash>` and is applied through `DocumentSplitViewRatioAccessor` (NSSplitView delegate on the editor split). Markdown split syncs scroll by source line via `MarkdownScrollSync`, `renderer.js` (`monknotScrollToLine` / `monknotVisibleSourceLine`), and `MarkdownPreviewView`/`NativeMarkdownEditorView` callbacks. HTML split uses proportional line sync via `HTMLScrollSync` and `HTMLPreviewView` (`monknotHTMLScrollToLine` / `monknotHTMLVisibleSourceLine`). PDF and other kinds are unchanged.
5. `EditorPaneView` switches on `WorkspaceDocument.kind`:
   - The `DocumentTabBar` above the editor renders open tab metadata only; inactive tabs do not instantiate hidden editors/previews.
   - Sidebar/recent/search/quick-open navigation opens regular lightweight tabs. Inactive tabs keep metadata only and do not instantiate hidden editors/previews.
   - Markdown source: `MarkdownTextEditor`.
   - Markdown preview: `MarkdownPreviewView`. In Preview (not beside Source) an editable Markdown document gets a `MarkdownVisualEditingConfiguration` and is edited in place; see "Visual editing in Preview" below.
   - Text/source/data text files: `MarkdownTextEditor` as a generic plain text editor.
   - PDF: `PDFPreviewView`.
   - Image (raster formats in `WorkspaceDocumentSupport.imageExtensions`): `PDFPreviewView` on an `ImageMarkupPage`. SVG stays a text document.
   - Media (video and audio in `WorkspaceDocumentSupport.mediaExtensions`): `MediaPlayerView`, AVKit's `AVPlayerView` with inline controls.
   - Jupyter notebooks (`.ipynb`, `canPreviewNotebook`): `MarkdownTextEditor` on their JSON in Source; Preview renders `JupyterNotebookMarkdown`'s Markdown of their cells and outputs read-only in `MarkdownPreviewView`.
   - Every other file (archives, Office documents, binaries, `.unsupported`): listed in the sidebar and never read; `UnsupportedDocumentView` offers to open it in the app macOS uses for it. Generic Quick Look preview is intentionally disabled for performance.
6. `WorkspaceStore` is the main app state owner for workspace selection, document loading, dirty text, save state, file operations, security-scoped bookmarks, external file refresh, selected document state, and the sidebar's own selection (`sidebarItemSelection`, a `SidebarSelection` of one or more items with an anchor and a lead; empty while the sidebar selects the open document). `selectedFolderID` is the one selected folder, `sidebarSelectionIDs`/`sidebarSelectionURLs` every selected item, and `sidebarTargetFolderURL` is where New and Paste put items. Copy, Cut, Paste, Duplicate, Move to Trash and drags take several items (`putItemsOnPasteboard`, `duplicateItems`, `deleteItems`, a move run for several moves); moves, copies and Move to Trash of several items record one undo step each. Return, ⌘D and ⌘⌫ act only on items a row shows selected, and a selection whose items vanish outside Monknot clears rather than widening to their folder. `sidebarNodeKinds` indexes the tree's items once per scan, so selection checks never walk the tree per item.
7. `WorkspaceDocumentScanner` builds the sidebar tree and document list from the selected workspace.

## Visual Editing In Preview

- The Markdown source is the only document. `editor.js` renders it with `renderer.js` and turns every
  edit on the page into one patch `{from, to, inserted}` on the source; it never converts HTML back to
  Markdown. Unrendered Markdown therefore survives byte for byte.
- Each editable unit (paragraph, heading, item text, table cell, code block, raw block, empty line)
  maps visible text offsets to source offsets. Every node (a block at any depth, or a list item) keeps
  the offsets it was parsed at plus a `shift` relative to its `parent`, so an edit moves what follows
  it by changing a few numbers; read a node's offsets with `atNode`/`bStart`/`bEnd`, and a unit's own
  with `S`. A unit's `top` is its top-level block (handles, `blockIndex`, list targets).
- After a patch only the affected blocks are re-parsed, resynchronising at the next unchanged block:
  at the top level, or inside the toggle body, quote or list holding the changed lines
  (`applyInside`), so typing in a 5,000-paragraph toggle costs what a plain paragraph does. A change
  that would move where that container ends (a fence or `<details>` line in a toggle, a line losing
  its `>`, a list's first marker) re-parses at the level above. The page replaces only the changed
  blocks' or items' elements; an item keeps its `<li>`, since a new one makes WebKit renumber every
  item after it. A container's own line lists (`body`, `lines`, `inner`) go stale after edits inside
  it, so they are read from the source (`nodeLines`). A footnote's text is updated in place, and only
  a changed link reference or footnote key renders the whole document again.
- `renderer.js` reads CommonMark backslash escapes (`\*` shows `*`); an escape's backslash is markup
  that typing stays outside of, and that is deleted, styled and copied with its character. `editor.js`
  `keepBackslashes` keeps a shown backslash shown wherever an edit would put punctuation after it,
  except in code. `htmlToMarkdown` (HTML pasted from other apps), Remove Inline Code and code-to-text
  escape text that would otherwise read as Markdown, such as `2020\. A year` or `snake\_case`.
- The read-only page watches `#content`'s subtree for the element holding its reading anchor, since an
  edit inside a container replaces nested elements or what a kept `<li>` holds.
- The page is the single writer while Preview is editable. It posts each patch with a version number
  to `MarkdownPreviewView.Coordinator` (`monknotEditor` message), which mirrors the page's text,
  moves local edits past app patches the page has not applied yet, applies the patch through
  `WorkspaceStore.applyTextMutation` and records undo in `MarkdownVisualEditingSession`. Store changes
  the page did not make (file changed on disk) are diffed against the text already sent, go to the page
  as patches and clear Preview's undo history. Undo and redo apply to the store first, as one combined
  patch checked against the text it removes and 32 characters on each side; a step that no longer fits
  beeps and changes nothing. A mismatch resets the page to the store's text. Files dropped on the page
  go through the same import as the Image, Video, Audio and File blocks (`dropFiles`).
- `MarkdownVisualEditingSession` is owned by `EditorPaneView`, so Preview's undo history survives a
  switch to Source and back; steps verify the text they change. `MarkdownEditorWebView` hands the Edit
  menu that undo manager and drops WebKit's own undo registrations.
- Menus (slash, block menu with its Turn Into submenu, callout kind, wikilinks, table, code language),
  the floating format bar, link card and editor, and table bar live in the page (`editor.js` `UI`);
  the block handles and drag-and-drop are `editor.js` `Handles`. All are styled by `editor.css` from
  theme tokens; SF Symbols come from `MarkdownEditorSymbolAssets` as mask images, and
  `MarkdownPresentationTokenTests` checks the glyphs the page asks for and the glyphs drawn match,
  both ways. There is no docked
  Markdown toolbar in any view mode; the word count is `MarkdownWordCountLabel` in the editor's corner.
  design.md §10.10 is the interaction spec.
- Notion's blocks map to Markdown the renderer parses: toggles are `<details>`/`<summary>` (an unclosed
  one runs to the end, which keeps re-parsing local), callouts are `> [!KIND]` quotes, `[TOC]` lists the
  top-level h1–h3. A toggle's open state on the page is view state carried across re-parses
  (`carryToggleState`), never written to the file. Units carry `scope` (the toggle whose body holds
  them); joins never cross it, so toggle markup cannot be broken by Delete or Backspace.
- Whole-block operations (`planMoveBlock`, `planDuplicateBlock`, `planDeleteBlock`, `planWrapToggle`,
  `planWrapCallout`, `planUnwrapQuote`) move source lines: a top-level block, or a list item with its
  nested items. The page messages `requestFile` (image, video, audio, file), `createPage`,
  `showEmoji` and `copyText` reach `MarkdownPreviewView.Coordinator`; `WorkspaceStore.createPage`
  writes the Page block's file beside the note.
- Typing `[[` posts `wikilinkQuery` messages; the coordinator ranks `wikilinkDocuments` with
  `WikilinkAutocompleteService` off the main actor and answers `MonknotEditor.wikilinkSuggestions`
  with the query's serial, so Preview lists the same notes, in the same order, as Source completes.
- Writing assistance (Flow) works while Preview edits: `MarkdownPreviewFlowCoordinator`
  (`MarkdownPreviewFlow.swift`, owned and torn down by `MarkdownPreviewView.Coordinator`) hosts the
  `EditorFlowPipeline` Source runs (`EditorFlowCheckPlanner`, the `EditorFlowCheckingClient` checker,
  `FlowSentenceRepairService`, `FlowProseCompletionService`, cooldowns and suppression) on the
  coordinator's mirror of the source and the caret's source offset, and every repair decision, the
  timings (`EditorFlowTiming`) and the model cooldowns (`EditorFlowModelCooldown`) come from
  `EditorFlowRepairPolicy.swift`; only the presentation and taking a fix or completion are per editor. Preview scans for protected Markdown
  only while a Flow setting is on, and its context menu's Ignore Spelling also reaches Flow's spell
  document tag. The page reports `focus`, its version and focus with each `selection`, and `flow` messages
  (accept, dismiss, cancel, unrendered, declined, settled, revert); the coordinator answers with
  `MonknotEditor.flow` (`configure`, `review`, `ghost`, `clear`, `apply`, `revertRefused`, after which
  the page deletes as ⌫ would have). ⌫ takes a fix back only while its `⌫ undo` hint shows, which
  `settled` reports. editor.js's `Flow` draws a
  review, a completion or a fix's mark as skipped non-editable spans or wrappers the text model never
  sees, and anything taken arrives as an `apply` patch (change kind `flow`, one undo step named as in
  Source) checked against the source first. `FlowProtectedRangeService` keeps both editors out of
  code, link addresses, URLs, HTML, front matter and a table's pipes; Preview also runs nothing while
  the caret is in a table cell (the page reports `cell` with each edit and selection), and checks
  nothing and asks its models nothing while a menu or the link field is open (the page posts `menu`
  when one opens or the last one closes). Tests inject fakes through
  `EnvironmentValues.markdownPreviewFlowDependencies`. WebKit's own inline predictions stay off.
- Edit › Check Document Now in Preview checks the sentence before the caret at once; Show Writing Tools
  switches to Source (`MarkdownTextEditor`'s `writingToolsRequested`) and opens them there. Beside
  Source the preview is read-only.

## Core Domain And Service Boundaries

Prefer putting logic in `MonknotCore` when it can be tested without SwiftUI/AppKit view state.

- Workspace model:
  - `WorkspaceDocument`: document identity, path, relative path, kind, content type metadata, capabilities, and depth.
  - `WorkspaceDocumentCapabilities`: explicit preview/edit/search/export/outline capability flags.
  - `WorkspaceTabState`: lightweight tab order, active document ID, pinned state, document snapshots, close behavior, and rename/move ID remapping.
  - `SavedWorkspaceStore`: ordered saved-folder metadata, custom labels, opaque bookmark data, last-active workspace, and legacy recent-workspace migration.
  - `WorkspaceTreeExpansionPersistence`: per-workspace expanded sidebar folder IDs.
  - `WorkspaceDocumentSupport`: UTType-backed classification, conservative extension fallback groups, capability mapping, and relative path helpers. The scan lists every file except hidden ones and those in ignored build folders (`WorkspaceDocumentScanner.defaultIgnoredDirectoryNames`) and packages: a type the system does not know is text, opened and searched through `WorkspaceTextFileGuard` (which refuses a large file from its first bytes when they are not text, and `WorkspaceTextContentCache` remembers that until the file changes); a type it knows as binary, and `ownAppExtensions` (undeclared binary formats, RTF), is `.unsupported`. `isKnownFileExtension` decides what New File and Rename count as an extension, so "Release 1.2", "Release v1.0-beta" and "John.Smith" do not change a note's type. An old saved kind that no longer exists decodes as `.unsupported`.
  - `JupyterNotebookMarkdown`: a notebook's cells and outputs as Markdown for Preview (text, `data:` images, errors; HTML outputs are named, not shown).
  - `SidebarNode`: folder/file tree model for the sidebar.
  - `SidebarSelection` and `SidebarTypeSelect`: the sidebar's multi-item selection over the rows it shows (⇧ ranges from an anchor, ⌘ toggles, arrow-key moves, ⌘A) and type-to-select by name.
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
  - `WikilinkAutocompleteService`: `[[` prefix detection and markdown title suggestions (Tab completes in Source; Preview's `[[` menu uses the same ranking).
  - `WorkspaceContextAssembler`: builds local excerpt chunks for agent-friendly export and terminal workflows, optionally prioritizing Related Notes paths from the active document.
  - `DocumentSplitViewPersistence`: per-document split-view toggle and source-pane ratio persistence keyed by standardized document path hash; remaps stored preferences when documents are renamed or moved on disk.
  - `DocumentSplitViewRatioAccessor`: AppKit bridge that applies persisted split ratios to SwiftUI `HSplitView` and writes divider drags back to `DocumentSplitViewPersistence`.
  - `WorkspaceDocumentSupport.displayName(forRelativePath:)`: shared relative-path display label used by Related Notes and context chips.
  - `HTMLScrollSync`: proportional source-line ↔ scroll-position math for HTML split-view sync scroll.
  - `WorkspaceGitStatusService`: parses `git status --porcelain` for optional sidebar git badges. The app no longer runs git status automatically during workspace open because that background work can compete with early file switching.
  - `RecentDocumentStore`: per-workspace recent document list for the sidebar.
  - `MonknotKeyboardShortcutCatalog`: static shortcut list for the keyboard-shortcuts help overlay.
  - `BetaFeedbackRecorder`: appends local beta feedback to Application Support JSONL (no network).
  - `WorkspaceSearchResult`: normalized result model for text and PDF matches.
  - `MarkdownOutlineParser`: extracts Markdown headings while ignoring fenced code blocks.
  - `MarkdownOutlineItem` and `MarkdownSourceLocation`: outline/source-jump models.
- PDF export options:
  - `MarkdownPDFExportOptions`: page size, margins, theme mode, scale, clamping, and last-used persistence.
- Document column:
  - `DocumentMeasure`: the comfortable line length shared by Source (`ContentWidthPreference.textColumnWidth`, points) and Preview (`--content-measure`, `em`); the Content Width setting scales it and 100 % removes it. Both modes centre the same width so text starts at the same x (design.md §10.11).

App-layer code should stay in `Sources/Monknot` when it uses SwiftUI state, AppKit, WebKit, PDFKit UI classes, FSEvents, PTYs, window behavior, menus, or user defaults tied directly to UI.

## Important App-Layer Owners

- `WorkspaceStore`: central workspace state machine. It uses generation counters and cancellable tasks to prevent stale async results from overwriting newer state. Preserve this pattern when adding async workspace, document, save, or refresh behavior.
- New files are Markdown: the sidebar's New File suggests `Untitled.md`, and `WorkspaceStore.newFileName` gives a name typed without an extension `.md` (a name with an extension keeps it).
- `WorkspaceLibraryStore`: app-wide observable owner for saved workspace order, labels, bookmark resolution, and reversible removal. Saved workspaces are folder references, not on-disk manifests.
- Tab state is owned by `ContentView`, but `WorkspaceStore` remains the source of truth for the active document text, dirty buffers, save state, external refresh, and file operations. Do not create per-tab editor state or per-tab preview instances.
- `WorkspaceStore` publishes document-ID remap events for rename/cut-paste operations so inactive tabs can survive path changes; each event also names the moved item, so the sidebar's open folders, Recents and a pending Copy or Cut follow it.
- Every window's `WorkspaceStore` registers in a weak table, so a Paste in one window can finish a Cut made in another (moving the item, or refusing while that window has unsaved changes the move would touch).
- `WorkspaceStore` records every sidebar move, rename, copy and Move to Trash (drag, Option-drag, Cut + Paste, Duplicate, a drop's moves as one step, ⌘⌫) in `WorkspaceFileOperationHistory` (`Stores/WorkspaceFileOperationHistory.swift`) for Edit › Undo/Redo (`undoFileOperation()` / `redoFileOperation()`, named by `fileOperationUndo`). A move keeps the revisions of the notes whose links it rewrote, so undo writes the old text back with conditional writes and redo writes the new; `WorkspaceFileOperationDisk` checks the disk still matches before each step, never overwrites, and puts back a partly made operation. Undo runs as a generation-counted workspace operation like the move itself, publishes one remap event for every item it moves, and `fileOperationLanding` for the sidebar's landing tint. The stacks are bounded (50 operations, 16 MB of rewritten text; an operation over that clears the history rather than being skipped) and cleared when the workspace changes. Undo and redo refuse, keeping the operation, while an unsaved note links to what they move; an undo of a copy refuses once the copy changed (`WorkspaceItemFingerprint`). Undoing Move to Trash moves each item back from where `moveItemToTrash` reported the Trash keeps it, only to a name still free. A workspace Replace's undo ends once a move, rename or trash touches one of its notes, and ⌘Z never runs it past a newer file operation; it writes a note back only while the note still holds the replaced text (`WorkspaceReplaceUndoSnapshot`), and waits while one of its notes has unsaved changes. Saves and file operations never overlap (`ensureNotBusy` refuses while a save runs, and a save refuses while an operation runs, each saying to try again), and nothing new or moved may take the name of a removed note whose unsaved text is still open (`keptUnsavedDocument`). `monknotUndoCommandDestination` routes ⌘Z to them from any focus but text, the terminal or a document view. The Edit menu's focus checks read the key window through `MonknotKeyFocus.window`, which a test may point at its own window (and must restore), since a test process cannot always become the active app (`UndoKeyRoutingTests`).
- `WorkspaceStore` tracks open document IDs so dirty open documents removed externally are not silently pruned before the UI can surface the conflict.
- `WorkspaceFileWatcher`: wraps macOS FSEvents and reports changed paths, modification-only paths, and full-rescan requirements back to `WorkspaceStore`. Modification-only events can refresh the active document without a full workspace scan.
- `ThemeSettingsStore`: persists selected light/dark theme IDs and sanitized per-theme customizations in `UserDefaults`.
- `MarkdownOutlineStore`: debounces outline parsing off the main actor.
- `WorkspaceSearchState`: debounces workspace search and runs search work off the main actor.
- `TerminalSessionCollectionStore`: owns the terminal tab collection, active terminal selection, and per-terminal create/switch/kill/restart actions.
- `TerminalSessionStore`: owns one terminal's transcript, working directory, lifecycle, resize, and PTY interaction.
- `TerminalPTYSession`: low-level `/bin/zsh` PTY process management using `forkpty`, dispatch read sources, and wait handling.
- `MarkdownPDFExportService`: uses an offscreen `WKWebView`, `WKPDFConfiguration`, and `PDFKit.PDFDocument` to export paginated PDFs.
- Writing assistance: `EditorFlowPipeline` (`Support/EditorFlowPipeline.swift`) runs it once for both editors: request tokens, tasks and deadlines, the checker → candidates → validation chain, the model's repairs and completions, and the protected-range scan. `MarkdownTextEditor.Coordinator` (Source) and `MarkdownPreviewFlowCoordinator` (Preview) host it through `EditorFlowPipelineHost`: each supplies its text, selection, revision, what holds Flow back (`EditorFlowHold`) and how a fix or completion is shown, and records how each attempt ended (Source in its diagnostics and AppKit's inline predictions; Preview records nothing). Repair decisions come from `EditorFlowRepairPolicy` (`Support/EditorFlowRepairPolicy.swift`) and `EditorFlowAIRepairValidator`, timings and cooldowns from `EditorFlowTiming` / `EditorFlowModelCooldown` in the same file. Change a decision there and the async flow in the pipeline, not in one editor.

## Platform API Usage

Use Apple-native APIs where they fit the feature:

- PDF viewing: `PDFPreviewView` renders PDFs in-app with PDFKit, including annotation/search state. Generic Quick Look preview remains disabled for file-switching performance.
- Image viewing and markup: images reuse `PDFPreviewView` through a `PDFPage` subclass (`ImageMarkupPage`) that draws the decoded `CGImage`; `PDFPage(image:)` is not used because PDFKit recompresses the pixels. Decoding, orientation, DPI and saving go through ImageIO (`CGImageSource` / `CGImageDestination`). Unsaved markup travels as a small annotations-only PDF; never serialize the image into it on each edit. `WorkspaceDocumentKind.opensInPDFViewer` covers both kinds in the store and commands.
- PDF search/text extraction: `PDFDocument` and `PDFSelection` in `WorkspaceSearchService`; keep this out of the file-selection/render hot path.
- Markdown preview/export rendering: `WKWebView`; the HTML shell comes from `MarkdownRenderService`.
- PDF export: `WKWebView.createPDF(configuration:)` plus `PDFKit.PDFDocument` pagination.
- Video and audio playback: `MediaPlayerView` hosts AVKit's `AVPlayerView` (`MediaPlayerNSView`). Media files are listed by extension only (`WorkspaceDocumentSupport.mediaExtensions`, formats AVFoundation plays; AVI, which it seldom plays, is listed as `.unsupported` and opens in its own app) and are never read during scanning or search. The player is created only while a media document is the visible tab, never autoplays, and is paused and released when the tab is switched or closed or the window closes. Missing or unplayable files show Monknot's empty state with a warning glyph, as a damaged PDF or image does. Space plays and pauses while the player has focus.
- Generic native previews: disabled. Raster images and video/audio are workspace documents opened on demand in their own viewers, never decoded during scanning or search; Office, archive and other binary files are listed as `.unsupported` documents that are never read and open in their own app; do not route them into Quick Look without an explicit performance decision.
- File type detection: `UniformTypeIdentifiers.UTType` in `WorkspaceDocumentSupport`, with extension fallbacks for formats UTType may not classify consistently.
- Text editing: `NSTextView` through `MarkdownTextEditor`, used for Markdown source and generic editable text/source/data files. Interactive editor opens are capped by `WorkspaceStore.interactiveTextOpenMaxBytes` so very large text files do not block file switching; search/export services can still use their own guarded limits. `WorkspaceTextFileGuard` rejects files that are not UTF-8 or that hold NUL bytes (binary data under a text name): the editor shows the reason instead of the bytes, and search and replace skip the file.
- File watching: FSEvents in `WorkspaceFileWatcher`.
- Saved folder access: `WorkspaceLibraryStore` creates and resolves Foundation security-scoped bookmarks; `WorkspaceStore` owns only the active access scope. Relevant docs: https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/withsecurityscope and https://developer.apple.com/documentation/foundation/url/init%28resolvingbookmarkdata%3Aoptions%3Arelativeto%3Abookmarkdataisstale%3A%29-3ic6f.
- File/folder open panels, reveal in Finder, and pasteboard interactions: AppKit in the app layer.
- Terminal: Darwin PTY APIs in `TerminalPTYSession`.

Terminal lifecycle notes:

- Multi-terminal UI is explicit: `TerminalSessionCollectionStore` owns tab metadata and one `TerminalSessionStore` per terminal. Each session owns one `TerminalWebController` (a `WKWebView` running xterm.js) for its lifetime, so an inactive tab or a hidden drawer keeps its screen and scrollback; `TerminalWebView` only hosts the active session's view. Session output is kept in a bounded `TerminalOutputLog` (2 MB) for replay after a web process crash.
- Hiding the terminal drawer does not kill sessions. Terminal tabs use a single VS Code-style destructive action: killing a terminal stops its PTY if needed and removes that one session/tab.
- New terminals start in the active document directory when possible, then the workspace directory, then the user's home directory. Existing running terminals keep their original working directory.
- `TerminalPTYSession` follows Apple's Dispatch source guidance: a read source owns its file descriptor while active, and the cancellation handler closes it after the source releases the descriptor. Relevant docs: https://developer.apple.com/documentation/dispatch/dispatch_source_cancel and https://developer.apple.com/documentation/dispatch/dispatchsource/makereadsource%28filedescriptor%3Aqueue%3A%29.
- `TerminalWebController` removes its WebKit script message handlers when its session stops (kill or quit), not when the view is dismantled. Relevant docs: https://developer.apple.com/documentation/webkit/wkscriptmessagehandler.

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

- `design.md` is the authoritative design-language and interface-metrics guide. Before any UI work,
  read its opening sections (how to use it, the bar, the workflow, the generic patterns that do not
  belong) and the sections its table names for what you are touching; verify the rendered app the
  way its workflow says (light and dark, zoom 0.8 and 2.0, frame-by-frame for motion), and update it
  in the same change when a rule changes.
- The outline rail and its panel live in `MarkdownOutlineRail.swift` (design.md §10.5): a bounded
  column of marks that never scrolls, and a panel on the context menu's surface that opens after the
  pointer stays on the rail, is at most 380 tall and keeps its highlighted heading in view
  (`MarkdownOutlinePeek` decides when it shows and what is highlighted). Keep its features: hover to
  peek, click to jump, the current section following the scroll, Full Keyboard Access on the marks.

- Main layout is owned by `WorkspaceSplitView`, an `NSSplitViewController`
  bridge in `ContentView`. The existing `SidebarView` remains the leading pane;
  AppKit owns divider interaction, accessibility, collapse behavior, window
  resizing, full-screen transitions, and autosaved divider positions.
- The window is one chrome tone (`AppTheme.chromeSurfaceColor`): titlebar, sidebar and the gaps.
  The document and terminal sit on rounded cards (`WorkspaceCardView`, styled by
  `WorkspaceCardStyle`) inside their split panes. The 6pt dividers are the gaps, and a collapsed
  pane keeps its divider as the window margin, so the fit math always counts both dividers
  (design.md §10.0). The titlebar's edges sit on the columns below them: the traffic lights start on
  the sidebar's glyph column and the last control ends over the terminal bar's buttons
  (`MonknotMetrics.titlebarLeadingInset` / `titlebarTrailingInset`, design.md §10.1). The first window
  under the split's autosave name opens its sidebar at the default width and records that in
  `WorkspaceSplitMetrics.defaultSidebarWidthAppliedKey`; later windows restore AppKit's saved layout. Controls are fills, never outlines; selection is the neutral
  `chromeSelectedFillColor`; the active tab on the chrome and a selected segment are the one chip
  (`chipFillColor`, `chipRingColor`, `chipShadowColor`). The ink ladder is derived per theme
  (`AppTheme.labelInkOpacity` / `glyphInkOpacity`, scaled by the theme's contrast) and shared with the
  Preview editor's `--mk-ink2/3/4`. Build chrome from the shared components in
  `Sources/Monknot/Support/Design`, never a local copy: `MonknotIconButton` (28/17 in bars, 22/13 in
  rows and fields) and `MonknotMenuButton`, `MonknotTab` (files and terminal sessions),
  `MonknotBar` (every 40 pt bar below the titlebar; the `.list` inset for a header over a list) and
  `MonknotBanner` (the file-changed banner and the PDF markup hint), `MonknotChip` (the active tab and
  the selected segment), `MonknotSegmentedControl`, `MonknotPopUpButton`,
  `View.monknotField`, `MonknotStepper`, `MonknotSlider`, `MonknotColorWell`, `MonknotListRowLabel`
  with `MonknotListRowButtonStyle` (sidebar and its header, Recents, Find in Workspace's results,
  Links, Settings' sections), `MonknotMenuRowLabel` with
  `MonknotMenuRowButtonStyle` (popovers and overlays), `View.monknotPopover` (every popover, on
  `MonknotPopoverController`'s floating surface), `MonknotDocumentGlyph` (a file's glyph with its
  save state), and `MonknotTypography`'s three styles (label 13/400, title 13/600, secondary 12/400).
  Every component, Settings' included, takes `zoomScale`. `danger` comes from `dangerColor` /
  `dangerSoftFillColor`, never `semanticColors.diffRemoved`.
  Panel toggles never take an on state. A state change animates only its colour or opacity
  (`monknotStateStyle`, `monknotStateOpacity` in `MonknotMotion.swift`); a control never takes
  `.animation(_:value:)`, which also slides a frame that moves in the same update
  (`MonknotMotionContractTests`). Every scroll bar except an HTML file's own page (which keeps WebKit's) is `MonknotScrollbarStyle`'s thumb; Preview draws it with `html.mk-legacy-scrollbars`
  (CSS the shell gets from `MarkdownRenderService`, built from `ScrollThumbGeometry`, which
  `MonknotScrollbarStyle` takes its numbers from too) when the system shows scroll bars always, a class `MarkdownRenderService` puts on
  the shell's root (`legacyScrollbars`) so WebKit's own bar never paints first. During a
  side-pane transition the document is laid out live on every frame (Source and the
  SwiftUI chrome reflow natively), and `WorkspaceSplitViewController` posts
  `WorkspacePaneTransition` notifications (`WorkspacePaneTransition.swift`: will
  begin, did start, did end) with the card's start and end frames and the clock. A
  web view cannot follow a moving edge, so `PaneTransitionWebView` (Preview's
  `MarkdownEditorWebView`, the HTML preview) holds still through
  `WebViewPaneTransitionHold` over the card's old and new areas; Preview's page
  lays out in the part the card shows (`--mk-pane-left/right` in preview.css,
  animated by renderer.js `monknotPaneTransition` on the same clock) and reflows
  with it, and a snapshot covers the web view only while its frame really
  changes. Both modes keep the line at the top of the window in place across width
  changes (renderer.js's reading anchor, `MarkdownNSTextView`'s, which also undoes
  AppKit's scroll to the insertion point at the end of a live resize). WebKit runs
  no animations in a test process, so Preview's reflow is seen only in the app. The terminal
  taking the full width collapses the document item with AppKit's animation and leaving it undoes
  that collapse, staged at the width it returns to; `WorkspaceDetailPaneController`'s card follows
  the part of the pane the split shows while the document keeps its width under it, and takes back
  the 3pt each halved divider gives up while the terminal is full width.
- Context menus in the chrome are Monknot's own (design.md §5.8): views declare a SwiftUI
  `.contextMenu` built from `MonknotMenuCommand` buttons (`MonknotMenuCommandButton`), and
  `MonknotContextMenuController` (`Support/Design/MonknotContextMenu.swift`, installed at launch)
  takes the right-click, asks the hit SwiftUI host for that menu as AppKit would, and draws its rows
  on a non-key floating panel. Each window reports its theme and zoom with
  `MonknotContextMenuAppearance`. Text views, web views, PDFs and the player keep the system's menu.
  A control's menu is the same menu, opened below it by `MonknotMenuPresenter` through
  `MonknotContextMenuController.presentMenu`: the PDF bar's More (`MonknotMenuButton`) and every
  `MonknotPopUpButton`'s values (the current one checked with `MonknotMenuRowCheck`, a colour's
  `MonknotColorSwatch` or a tool's glyph in the glyph column, past 380 tall scrolling under the
  chrome thumb). Never show a system `NSMenu` from a chrome control.
- Popovers in the chrome are Monknot's own too (design.md §5.9): a control attaches
  `View.monknotPopover(isPresented:label:contentKind:listRows:theme:zoomScale:content:)`
  (`Support/Design/MonknotPopover.swift`) and holds its open state while the binding is true.
  `MonknotPopoverController` shows one at a time, on the context menu's surface, in a
  `MonknotPopoverPanel`: a child panel that becomes key (its controls take focus) but never main (the
  window keeps its active chrome). It places the surface with `MonknotPopoverPlacement`, follows the
  content's size, closes on a click outside (which does nothing else), Esc, scrolling outside, the
  window moving, resizing or closing, another window or app, the menu bar and the control going away,
  sends a ⌘ shortcut on to the window, and gives focus back to what had it. The workspace switcher
  (`.list`) and the PDF bar's Stroke Width and Text Style (`.form`) use it; no `NSPopover` or
  SwiftUI `.popover` remains in the chrome. While a popover is open the context-menu controller
  steps aside. A list passes `listRows`; its event monitor then gives the list a context menu's keys
  (↑ ↓ ⌃P ⌃N, Home/End, typing, ↩/Space, ⌫ for a row's `remove`) without Full Keyboard Access, while
  Tab and a form's keys stay with the focused control. `MonknotPopoverListModel`, in the content's
  environment, owns the list's one highlight: rows report the pointer
  (`monknotPopoverListHover`) and keyboard focus to it and draw it with
  `MonknotMenuRowButtonStyle(isHighlighted:)`.
- Glyph sizes come from `MonknotSymbolOptics` (`Support/Design/MonknotMetrics.swift`): pictures are
  sized by their measured ink (`SymbolInkMetrics`) to one optical size, marks (open strokes,
  lettering) keep their nominal; never hand-pick a point size for one glyph (design.md §8.2). Every
  menu draws one instant highlight for the pointer and the keys (`MonknotMenuRowButtonStyle`,
  `MonknotCommandOverlayResults(hover:)`, design.md §5.6).
- Moving files in the sidebar is `SidebarDragSession` (`Views/SidebarDrag.swift`) driven by the rows'
  drag gesture in `SidebarView`: the floating copy, Option, Esc, spring-loading, auto-scroll, the
  `accsoft` target region and landing tint, and the hand-off to a system file drag once the pointer
  leaves the sidebar (design.md §10.4, Moving files).
- Sidebar-specific state and tree presentation live in `SidebarView`.
- Detail/editor state lives in `EditorPaneView`.
- File tabs are rendered by `DocumentTabBar` under `TopNavigationBar`. Keep tabs lightweight: labels, pinned state, close/pin actions, and save indicators only. Inactive tabs must remain metadata only; do not create per-tab editor/preview runtimes. When split view is active for markdown/HTML documents, `TopNavigationBar` shows an active split indicator (click to turn off; ⌘\\ also toggles).
- App menu commands flow through `MonknotCommandActions` and `FocusedValues`. Quick Open uses ⌘P; Export PDF is menu-only.
- Markdown preview behavior belongs in `MarkdownPreviewView` and `renderer.js`, not scattered across unrelated views.
- PDF and image viewing behavior belongs in `PDFPreviewView`; image decoding and saving belong in `ImageMarkupDocument`.
- Video and audio playback belongs in `MediaPlayerView`. Keep one player per visible media tab; inactive tabs must not hold an `AVPlayer`.
- Generic preview-only behavior is intentionally disabled; files Monknot does not show (`.unsupported`) are listed but must not mount preview runtimes.
- Route behavior by `WorkspaceDocument.capabilities` when possible. Keep `WorkspaceDocumentKind` coarse; do not add one enum case per file extension.
- Theme colors should flow through `AppTheme` and `Color+Theme.swift`.
- User-facing persisted UI preferences generally use `@AppStorage` keys prefixed with `Monknot.`.

## Manual Build Script Warning

`script/build_and_run.sh` does not discover Swift files automatically. It contains explicit `CORE_SOURCES` and `APP_SOURCES` arrays.

When adding, moving, or deleting Swift files that must be included in the manually built app, update this script as well as `Package.swift` if needed.

The script also manually copies these runtime resources into the app bundle:

- `Sources/MonknotCore/Resources/preview.css`
- `Sources/MonknotCore/Resources/renderer.js`
- `Sources/MonknotCore/Resources/editor.css`
- `Sources/MonknotCore/Resources/editor.js`
- `Sources/Monknot/Resources/xterm.css`
- `Sources/Monknot/Resources/xterm.js`
- `Sources/Monknot/Resources/xterm-addon-fit.js`
- `Sources/Monknot/Resources/xterm-addon-search.js`
- `LICENSE`
- `THIRD_PARTY_NOTICES.md`
- `ThirdPartyLicenses/xterm-MIT.txt`
- `ThirdPartyLicenses/xterm-addon-fit-MIT.txt`
- `ThirdPartyLicenses/xterm-addon-search-MIT.txt`
- `ThirdPartyLicenses/sparkle-MIT.txt`
- Verified theme MIT texts listed by `THEME_LICENSE_FILES` in
  `script/build_and_run.sh`

When adding a Swift source file to the app or core target, update `script/build_and_run.sh`. The declared XCTest suite includes a build-script sync check, but the local SwiftPM command may be blocked until the current CommandLineTools issue is fixed.

## Testing

The full app target requires Xcode 26 or newer because
`WindowChromeSupport.swift` conditionally references `NSGlassEffectView`.
GitHub Actions pins Xcode 26.3 on its arm64 macOS runner. This build
SDK requirement is separate from the macOS 14.0 deployment target, which the
release scripts and artifact verifier enforce.

Primary command:

```sh
script/test_suite.sh
swift run MonknotSmokeTests
swift run MonknotStoreSmokeTests
swift run monknot-export --help
swift run monknot-capture --help
```

The XCTest command parallelizes only the audited editor-flow allowlist with two workers and
runs all remaining tests serially. See `Tests/README.md` for the isolation classification.
Use `MONKNOT_TEST_WORKERS=1 script/test_suite.sh` for a fully serial diagnostic run. Do not
enable whole-suite parallel testing.

If SwiftPM fails before test compilation with a CommandLineTools module-map issue (`SwiftBridging` redefinition and Foundation/CoreServices module build failures), record the exact output and use the manual build/smoke verification paths below until the toolchain is repaired.

Current XCTest coverage focuses on `MonknotCore`:

- `WorkspaceDocumentScannerTests` and `WorkspaceDocumentSupportTests`: scanning, classification, capabilities, paths, and symlink boundaries.
- `MarkdownRenderServiceTests`, `ThemeCatalogTests`, and `ThemePreferenceTests`: rendering and theme contracts.
- `WorkspaceTextSearchServiceTests` and `WorkspacePDFSearchServiceTests`: text and PDF search behavior.
- Search cache and index suites: observable reuse, invalidation, and bounded eviction.
- `MarkdownOutlineParserTests`: Markdown heading extraction behavior.
- `JupyterNotebookMarkdownTests`: notebook cells, outputs, fences, attachments, nbformat 3 and unreadable files.
- `MarkdownPDFExportOptionsTests`: export option defaults, clamping, persistence behavior.
- `MarkdownScrollSyncTests`: source line ↔ character offset math for split-view scroll sync.
- `HTMLScrollSyncTests`: proportional line ↔ scroll fraction math for HTML split-view sync scroll.
- `DocumentSplitViewPersistenceTests`: per-document split-view storage keys, split ratio persistence/clamping/remap, legacy global fallback, and rename/move key remapping.
- `WorkspaceDocumentSupportTests`: shared relative-path display name helper.
- `WorkspaceReplaceScopeTests`: replace scope metadata for workspace search replace UI.
- `WorkspaceContextAssemblerTests`: excerpt assembly, stop-word term extraction, preferred related-note path priority.
- `WorkspaceReplaceServiceTests`: dry-run `preview()`, scoped replace, undo snapshots, summary message formatting.
- `WorkspaceContextOrderingTests`: related-note-first ordering for context chips.
- `RepositoryContractTests`: manual build, workflow, release, security, license, governance, Sparkle, and CLI process contracts.
- `WorkspaceTabStateTests`: open, order, pin, close, remap, prune, and closed-tab history behavior.
- `UnsavedChangesIntegrityTests` (app target): hosted editor and PDF viewer sweeps showing that opening, viewing, switching, saving, renaming and reviewing documents never marks unedited files as unsaved, and that a file only counts as changed on disk when its contents changed.
- `MarkdownRendererJavaScriptTests`: renderer output in JavaScriptCore.
- `MarkdownPreviewFlowTests` (app target): writing assistance in Preview in real WebKit with fake checker and models: a certain fix as one undo step that ⌫ takes back (only while its hint shows; a refused revert still deletes), a declined fix offered again, fixes after emoji and in list items and headings, reviewed repairs (Tab, →, Esc, a trailing space), Apple Intelligence's reviewed repair, completions (gating by setting and availability, Tab word and hold, typing that consumes, Esc, a dead-key composition right after a taken word), stale checks, Return, code, link addresses and table cells, nothing checked or asked of the models while a menu is open, a decline for an old caret, Ignore Spelling in the page's menu, Tab's list/table/menu meanings, settings off, Check Document Now and Show Writing Tools.
- `EditorFlowRepairPolicyTests` (app target): the shared repair decisions without an editor: which fixes wait for review, issues overlapping protected Markdown, validation sentence offsets, routing after a check, the model cooldowns and the protected-range rebase.
- `EditorFlowPipelineTests` (app target): the shared pipeline with a stand-in host: protected ranges count only for the text they were scanned from, a paused or suspended editor asks the checker nothing, a clean check clears the gate, and a check whose sentence changed ends stale for its own token.
- `MarkdownVisualEditorTests` (app target): Preview editing in real WebKit: typing, Return and Delete, Markdown shortcuts, Edit-menu undo and redo (also across a switch to Source, after a Source edit or a change on disk, and refused without half-applying), an outside change racing a typed character, composition through `NSTextInputClient`, a click below the last block, smart dashes in code, a dropped file, formatting, tasks, links, paste and copy, composition, tables, external changes, the slash rule, toggles, callouts, the + handle, drag-and-drop, the block menu and its shortcuts, 50 KB and 1 MB keystroke timing, and theme and narrow-window snapshots of the page, menus and handles (written to `MONKNOT_EDITOR_SNAPSHOT_DIR` when set).
- `MarkdownEditorMenuTests` (app target): the Preview editor's menus in real WebKit: one menu at a time, the table menu and bar, the code language, the link card, Turn Into's timing and every surface following a moved column.
- `MonknotPopUpMenuTests` (app target): a real `MonknotPopUpButton` clicked open: Monknot's menu below it (above it at the screen's bottom) with the value checked and highlighted, ↓ and ↩ choosing, Esc choosing nothing, a value missing from the list, a 300-item list scrolling with Home, End and type-select keeping the row in view and the thumb fading, Settings-style previews restored on Esc, a menu button's commands, and a pop-up inside a popover leaving the popover open. With `MONKNOT_POPUP_MENU_SNAPSHOT_DIR` set, renders the zoom, colour, tool and long font menus off screen.
- `MonknotContextMenuTests` (app target): real right-clicks over the real sidebar open Monknot's menu with the row's items, Control-click too; choosing acts on the clicked row; a quick release over a row only highlights it and a release never runs Move to Trash; the keys (↑↓, ⌃N ⌃P, Home/End, type-select, ↩, Esc); a click elsewhere only closes; a right-click elsewhere opens there; scrolling and losing key close it; text views and unreported windows keep the system's menu; layout at every zoom; placement and flipping; every command's glyph. With `MONKNOT_CONTEXT_MENU_SNAPSHOT_DIR` set, renders the surface off screen and captures it on screen.
- `MarkdownOutlineRailTests` (app target): the rail stays a bounded column at zoom 0.8, 1 and 2 with a slot for every heading; the panel is bounded, as wide as its longest title as the menu row lays it out, opens centred on its heading and keeps each heading the rail moves to in view with the least scroll; the panel opens only after the pointer stays on the rail, the trip from rail to panel keeps it open, keyboard focus opens it at once; the document keeps its clicks around the rail. With `MONKNOT_OUTLINE_SNAPSHOT_DIR` set, captures the rail and panel in four themes at three zooms and records the panel opening and closing frame by frame.
- `MonknotPopoverTests` (app target): real clicks on real controls open the shared popover surface 4 below the control at zoom 0.8, 1 and 2 (a list 6 outside, above where the screen ends, moved in only where it would leave the screen); the panel takes key but never main and moves with its window; controls inside take clicks and the surface follows its content; Esc and `cancelOperation` close it and give focus back; a ⌘ shortcut goes on to the window; a click outside (its own control included) only closes; a right-click outside opens no menu; scrolling, the window moving, resizing or closing, another window or app, its control going away and its binding close it; a window it opened keeps it open; one at a time; the real switcher opens below the sidebar header with its rows on the header's edges; on the real sidebar with saved workspaces, its keys move one highlight over the enabled rows without wrapping (Home/End, ⌃P/⌃N, typing with a pause starting over and a space continuing a name), ↩, Enter and Space choose and close it, ⌫ removes the highlighted workspace once and keeps it open, the pointer's row and the keys' row are one highlight, keyboard focus is that highlight and Space goes to a focused Remove, and past seven rows the keys' row stays in view (the Full Keyboard Access Tab test skips with it off). With `MONKNOT_POPOVER_SNAPSHOT_DIR` set, renders the PDF popovers off screen and captures the switcher and the PDF popovers on screen.
- `UndoKeyRoutingTests` (app target): ⌘Z through a hosted `ContentView`'s key handling with real focus in Source and in Preview with nothing to undo: an older workspace Replace waits for a newer move, the sidebar undoes the move, then the Replace undoes from the text.
- `SidebarSelectionTests`: ranges, toggles, arrow moves, Home/End, select all, following moves, and type-to-select.
- `SidebarMultipleSelectionTests` (app target): real clicks and keys over the hosted sidebar: ⇧- and ⌘-click without opening, arrows and ⇧-arrows, ←/→ and ⌥/⌘ variants, type-to-select, ⌘↓, ⌘D and ⌘⌫ on several items (and refusal with unsaved text), row menus acting on the selection (and a row outside it on that row alone), a collapse handing a hidden selection to the folder's row, dragging and Option-dragging several rows, multi-item Copy/Cut/Paste as one undo step, and the selection following moves. With `MONKNOT_SIDEBAR_SELECTION_SNAPSHOT_DIR` set, captures a selection in both themes.
- `WorkspaceFileOperationsTests` and `FileOperationsScenarioTests` (app target): every file operation on real stores over temporary workspaces, through the pasteboard path the app uses: create, rename (case-only, extensions, invalid and hidden names), move, copy, Cut + Paste (across windows too), drops and imports, Move to Trash's guards, operations the disk refuses changing nothing, names a removed note's kept unsaved text holds, and saves and operations never overlapping. Each asserts what is on disk, not only what the store reports.
- `WorkspaceFileOperationUndoTests` (app target): Edit › Undo/Redo of moves (with unsaved text and with link rewrites, including the moved note's own links), renames, Cut + Paste, a multi-item drop as one step, duplicates and copies to the Trash and back; Move to Trash undone and redone (refused when the name is taken or the Trash was emptied, waiting for unsaved changes, a partial failure keeping what reached the Trash undoable, no Trash deleting nothing); refusals when the old name is taken, the moved item is gone, a rewritten note changed, or a note or copy has unsaved changes; ordering against workspace Replace; Edit menu routing by focus; and an undone move landing back in the hosted sidebar with its folders open.
- `SidebarDragTests` (app target): real mouse and key events over the real sidebar: the floating copy and the landing (destination open, file not opened), Esc, a drop moving what the drag picked up when the tree changes under it, a drop on no target, Option duplicating into its own folder, spring-loading opening and closing a folder, auto-scroll, refused no-op file drops and the copy's size. With `MONKNOT_SIDEBAR_DRAG_SNAPSHOT_DIR` set, captures the drag's states.
- `MonknotControlTests` (app target): every 28 pt control measures 28 at each zoom, the bar insets, icon-button open state, pop-up and menu-button commands, slider and stepper values, the switch's disabled state, the zoom level mapping and the danger tokens. `MonknotMotionContractTests` keeps `.animation(_:value:)` out of the app.
- `WorkspacePaneTransitionTests` (app target): a sidebar hidden at launch first opening at its default width, a saved layout surviving the next window, an animated reveal announcing where the card goes without starting layer animations of its own, a web view holding still while a pane moves and taking the card again after, and ContentView toggling panes outside a scene. `WorkspaceSplitFullscreenTests` records the terminal taking the full width and giving it back, frame by frame. `ContentWidthPreferenceTests` checks Source keeping the line at the top through a width change and the end of a live resize.
- `WorkspaceUITourTests` (app target): with `MONKNOT_UI_TRANSITION_DIR` set, `testCaptureTheSidePaneTransitions` records the window every few milliseconds while a side pane closes and opens (`MONKNOT_UI_TRANSITION_PANE=terminal`, `=fullscreen` for the terminal taking the full width and back, `=folder` for a sidebar folder clicked open and closed, `_COLD`, `_SOURCE`, `_TERMINAL`, `_FILE`, and `_LIKE_APP` for a large zoom in a full-screen window, vary it). Pages in a test process count as hidden, so it shows Source and the chrome moving but not Preview's reflow. With `MONKNOT_UI_TOUR_DIR` set, captures the whole workspace window (sidebar open and collapsed, terminal, Source and Preview, light and dark, narrow and wide, tabs, no workspace, Settings) for design reviews; `MONKNOT_UI_TOUR_ONLY` picks stops by name (`a|b`) and `MONKNOT_UI_TOUR_RAW` also keeps the window server's own image (with WebKit's scroll bars). It skips otherwise. `ContentView.InitialLayout` sets the side panes a window starts with and an overlay it opens once its document shows (Quick Open, Find, Find in Workspace, Keyboard Shortcuts).
- `NewFileOpensTabTests` (app target): in a hosted `ContentView`, New Markdown and New File open the file they make in its own tab beside the open tabs, and after every tab was closed.
- `DocumentViewerRoutingTests` (app target): generated fixtures of every file type (text, unknown source formats, extensionless, uppercase, binary and oversized text, PDF, raster images, video and audio, notebooks, files that open in their own app) are scanned and opened in a hosted `EditorPaneView`, and a notebook's cells render in Preview; also image fit, media playback lifecycle, Open With and Recents.

Manual Core smoke verification used in this repo when SwiftPM is blocked:

```sh
script/build_and_run.sh --verify
swiftc -vfsoverlay .build/manual/swift-vfs-overlay.yaml -I .build/manual -L .build/manual -lMonknotCore -Xlinker -rpath -Xlinker .build/manual Tests/MonknotSmokeTests/main.swift -o .build/manual/MonknotSmokeTests
.build/manual/MonknotSmokeTests
```

When adding logic:

- Write tests to discover real issues in the app, not tests shaped only to pass the current implementation.
- Cover realistic workflows, edge cases, failure paths, regressions, and cross-component behavior when the feature touches app-level state.
- A passing test suite is not enough if the tests do not exercise the risky behavior introduced or changed by the feature.
- Put pure logic in `MonknotCore` and add XCTest coverage in `Tests/MonknotTests`.
- Add tests for cancellation-safe service behavior when feasible.
- Add regression tests for path handling, file type classification, Markdown parsing, search matching, theme persistence, and PDF export option logic.
- Add regression tests for capability classification, editable text support, files that open in their own app, and PDF workspace-result targets.
- For AppKit/SwiftUI/WebKit/PDFKit UI behavior, prefer small testable model/service seams plus manual verification until a UI test target exists.

## Common Commands

Run unit tests:

```sh
script/test_suite.sh
swift run MonknotSmokeTests
swift run MonknotStoreSmokeTests
swift run monknot-export --help
swift run monknot-capture --help
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
- Read `editor.js`, `MarkdownVisualEditing.swift`, the editing parts of `MarkdownPreviewView`, and design.md §10.10 before changing Preview editing. Keep every edit a source patch; never serialize the page back to Markdown.
- Read `PDFPreviewView`, `WorkspaceSearchService`, and `MarkdownPDFExportService` before changing PDF behavior.
- Read `PDFPreviewView`, `MediaPlayerView`, and `WorkspaceDocumentSupport` before changing PDF, image or media viewing or file-format support.
- Read `ThemeSettingsStore`, `AppTheme`, and `Color+Theme.swift` before changing theming.
- Read `TerminalSessionCollectionStore`, `TerminalSessionStore`, `TerminalPTYSession`, `TerminalDrawerView`, and `TerminalWebView` before changing terminal behavior.
- Keep `MonknotCore` independent from SwiftUI/AppKit view types unless there is a deliberate architectural change.
- Prefer narrowly scoped changes and focused tests over broad refactors.
- Avoid adding duplicate state to views when the state already belongs to a store.
- Avoid adding new global singletons; inject services where the current design already supports it.
- If a feature needs platform integration, put the platform wrapper in `Sources/Monknot/Services` and keep reusable policy/model code in `MonknotCore`.
- When implementing a feature, first consult the official Apple Developer Documentation and related Apple guides/articles first. Prefer Apple-recommended APIs and lifecycle patterns over ad hoc implementations, and record the relevant docs links in research notes or implementation docs when the decision affects architecture.
