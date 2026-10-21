import Foundation
import MonknotCore

/// A text document whose file could not be read into the editor (too large, not UTF-8). The pane
/// shows `message` read-only instead of an empty, editable editor that could be saved over the file.
struct DocumentLoadFailure: Equatable {
    let documentID: String
    let message: String
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var openingWorkspaceURL: URL?
    @Published private(set) var rootNode: SidebarNode? {
        didSet {
            rootNodeRevision &+= 1
            sidebarNodeKinds = Self.nodeKinds(in: rootNode)
            reconcileSidebarSelection()
        }
    }
    /// Every item of the tree, the root left out, by its path: what selection checks look up, once
    /// per scan rather than walking the tree per item.
    private var sidebarNodeKinds: [String: SidebarNode.Kind] = [:]
    /// Changes with every new tree, so views can follow the tree without comparing it.
    @Published private(set) var rootNodeRevision = 0
    @Published private(set) var documents: [WorkspaceDocument] = []
    private(set) var markdownDocuments: [WorkspaceDocument] = []
    private(set) var hasPDFDocuments = false
    private var documentsByID: [String: WorkspaceDocument] = [:]
    @Published private(set) var selectedDocumentID: String? {
        didSet {
            guard selectedDocumentID != oldValue else { return }
            cancelExternalDocumentReview()
        }
    }
    /// The items the sidebar selects itself: a clicked folder, or files and folders picked with the
    /// arrow keys, ⇧ or ⌘ (design.md §10.4). While it is empty the sidebar selects the open
    /// document, or nothing. Selecting items leaves the open document open.
    @Published private(set) var sidebarItemSelection = SidebarSelection()
    /// Whether the sidebar selects the open document while no folder is selected. It stops when
    /// the selection goes to the Trash or the selected document leaves the workspace, so the
    /// document a tab shows in its place is not selected until the user picks one.
    @Published private(set) var sidebarSelectsOpenDocument = true
    /// A folder the sidebar expands to show items pasted or dropped into it.
    @Published private(set) var revealedFolder: WorkspaceFolderReveal?
    @Published private(set) var documentText = ""
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var isBusy = false
    @Published private(set) var isDocumentLoading = false
    @Published private(set) var documentLoadFailure: DocumentLoadFailure?
    /// Documents asked for from outside the window (Finder, the Dock), in order. The window opens
    /// them as tabs once its workspace is ready, the same way as from the sidebar.
    @Published private(set) var pendingDocumentOpenIDs: [String] = []
    @Published private(set) var isSaving = false
    @Published private(set) var documentSaveStates: [String: DocumentSaveState] = [:]
    @Published private(set) var selectedDocumentExternalChange = false
    @Published private(set) var externalDocumentReview: ExternalDocumentReviewState?
    @Published private(set) var removedDirtyOpenDocumentIDs: Set<String> = []
    @Published private(set) var documentIDRemapEvent: WorkspaceDocumentIDRemapEvent?
    @Published private(set) var pendingMarkdownLinkMoveReview: MarkdownLinkMoveReviewState?
    @Published private(set) var gitStatusByRelativePath: [String: WorkspaceGitFileStatus] = [:]
    @Published private(set) var workspaceReplaceSummary: String?
    @Published private(set) var workspaceSearchContentChangeSerial = 0
    @Published private(set) var canUndoWorkspaceReplace = false
    /// What Edit › Undo and Redo offer for the moves and copies made in the sidebar.
    @Published private(set) var fileOperationUndo = WorkspaceFileOperationUndoState()
    /// An item an undo or redo moved or copied, which the sidebar shows and tints as it does an
    /// item a drop has just moved.
    @Published private(set) var fileOperationLanding: WorkspaceItemLanding?
    @Published private(set) var recentDocumentChangeSerial = 0
    @Published var errorMessage: String?

    private var replaceUndoSnapshot: WorkspaceReplaceUndoSnapshot?
    private var fileOperationHistory = WorkspaceFileOperationHistory()
    /// Counts the actions Edit › Undo can take back, so the newer of a file operation and a
    /// workspace Replace is undone first.
    private var workspaceUndoSerial = 0
    private var replaceUndoSerial = 0

    private let scanner: any WorkspaceDocumentScanning
    private let moveItemToTrash: @Sendable (URL) throws -> URL?
    private let recentDocumentStore: RecentDocumentStore
    private let fileWatcher = WorkspaceFileWatcher()
    private var lastSavedText = ""
    private var dirtyDocumentTexts: [String: String] = [:]
    private var dirtyDocumentBaselines: [String: String] = [:]
    private var dirtyDocumentRevisionExpectations: [String: WorkspaceTextRevisionExpectation] = [:]
    private var pdfDocumentBaselines: [String: Data] = [:]
    /// For a marked-up image, the file as it was when the markup began: the pixels a save draws the
    /// markup onto. It differs from the baseline only once a save has written the markup in while
    /// newer markup was still being added.
    private var imageMarkupSources: [String: Data] = [:]
    private var dirtyPDFDocumentData: [String: Data] = [:]
    private var dirtyPDFDocumentVersions: [String: Int] = [:]
    private var dirtyPDFDocumentEditCheckpoints: [String: PDFAnnotationEditCheckpoint] = [:]
    @Published private var pdfDocumentSavedEditCheckpoints: [String: PDFAnnotationEditCheckpoint] = [:]
    @Published private var pdfDocumentContentVersions: [String: Int] = [:]
    private var removedDirtyDocuments: [String: WorkspaceDocument] = [:]
    private var openDocumentIDs: Set<String> = []
    private var selectedDocumentSignature: FileSignature?
    private var externalRefreshWorkItem: DispatchWorkItem?
    private var suppressedWatcherEvent: WorkspaceFileWatcher.Event?
    private var suppressedWatcherReplayWorkItem: DispatchWorkItem?
    private var externalRefreshTask: Task<Void, Never>?
    private var externalReviewTask: Task<Void, Never>?
    private var externalRefreshGeneration = 0
    private var externalReviewGeneration = 0
    private var suppressWatcherUntil = Date.distantPast
    private var writingToolsDocumentID: String?
    private var deferredWritingToolsRefreshNeeded = false
    private var securityScopedURL: URL?
    private var workspaceTask: Task<Void, Never>?
    private var documentTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var markdownImageAssetTask: Task<Void, Never>?
    private var recentDocumentRecordTask: Task<Void, Never>?
    private var workspaceGeneration = 0
    private var documentGeneration = 0
    private var saveGeneration = 0
    private var markdownLinkMoveReviewSerial = 0
    private static let busyMessage = "Wait for the current file operation to finish, then try again."
    private static let savingMessage = "Wait for the save to finish, then try again."
    nonisolated static let interactiveTextOpenMaxBytes: Int64 = 4 * 1024 * 1024
    private static let recentDocumentRecordDelayNanoseconds: UInt64 = 350_000_000
    @Published private var pendingDocumentTransfer: WorkspaceDocumentTransfer?
    /// The moves of a drop of several items, made one after another.
    private var moveRun: WorkspaceMoveRun?
    private var moveRunSerial = 0
    /// The store of every open window, so a Paste in one window can finish a Cut made in another.
    private static let openStores = NSHashTable<WorkspaceStore>.weakObjects()

    /// `moveItemToTrash` moves a file or folder to the Trash and returns where the Trash keeps it,
    /// which Edit › Undo puts it back from; tests pass one that leaves the user's Trash alone. It
    /// never deletes: where there is no Trash (some network volumes) it fails.
    init(
        scanner: any WorkspaceDocumentScanning = WorkspaceDocumentScanner(),
        userDefaults: UserDefaults = .standard,
        moveItemToTrash: @escaping @Sendable (URL) throws -> URL? = { url in
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
            return trashedURL as URL?
        }
    ) {
        self.scanner = scanner
        self.moveItemToTrash = moveItemToTrash
        recentDocumentStore = RecentDocumentStore(userDefaults: userDefaults)
        Self.openStores.add(self)
    }

    var selectedDocument: WorkspaceDocument? {
        guard let selectedDocumentID else { return nil }
        return document(id: selectedDocumentID)
    }

    /// The folder selected in the sidebar when it is the one item the sidebar selects.
    var selectedFolderID: String? {
        guard sidebarItemSelection.count == 1,
              let itemID = sidebarItemSelection.itemIDs.first,
              sidebarNodeKinds[itemID] == .folder
        else { return nil }
        return itemID
    }

    /// The path of the sidebar's lead item: the item last picked, otherwise the selected document
    /// while the sidebar selects it.
    var sidebarSelectionID: String? {
        sidebarItemSelection.leadID ?? (sidebarSelectsOpenDocument ? selectedDocumentID : nil)
    }

    /// The paths of every item the sidebar selects: the items picked, otherwise the selected
    /// document while the sidebar selects it.
    var sidebarSelectionIDs: [String] {
        guard sidebarItemSelection.isEmpty else { return sidebarItemSelection.itemIDs }
        return sidebarSelectionID.map { [$0] } ?? []
    }

    /// The sidebar's lead item: the item last picked, otherwise the selected document while the
    /// sidebar selects it.
    var sidebarSelectionURL: URL? {
        sidebarSelectionID.map(sidebarItemURL(_:))
    }

    /// Every item the sidebar selects, in path order, leaving out any inside another selected
    /// folder, which goes with that folder.
    var sidebarSelectionURLs: [URL] {
        Self.outermostPaths(sidebarSelectionIDs).map(sidebarItemURL(_:))
    }

    /// Where New and Paste put items when no row names a folder: the lead item when it is a folder,
    /// otherwise its folder, or the workspace root when nil.
    var sidebarTargetFolderURL: URL? {
        guard let itemID = sidebarSelectionID else { return nil }
        let url = sidebarItemURL(itemID)
        return url.hasDirectoryPath ? url : url.deletingLastPathComponent()
    }

    private func sidebarItemURL(_ itemID: String) -> URL {
        let isFolder = documentsByID[itemID] == nil && sidebarNodeKinds[itemID] == .folder
        return URL(fileURLWithPath: itemID, isDirectory: isFolder)
    }

    /// Selects a folder of the workspace tree in the sidebar; the workspace root is never selected.
    func selectFolder(id: String) {
        guard sidebarNodeKinds[id] == .folder else { return }
        sidebarItemSelection = SidebarSelection(single: id)
    }

    /// Selects items of the workspace tree in the sidebar without opening any: what the arrow keys,
    /// ⇧ and ⌘ pick. Items the tree does not hold, and the workspace root, are left out; with none
    /// left, nothing is selected, not even the open document, until the user picks something.
    func selectSidebarItems(_ selection: SidebarSelection) {
        guard rootNode != nil else { return }
        let next = selection.filtered { sidebarNodeKinds[$0] != nil }
        guard !next.isEmpty else {
            clearSidebarSelection()
            return
        }
        if next != sidebarItemSelection {
            sidebarItemSelection = next
        }
    }

    /// Keeps the selected items in the tree: those that remain stay selected. When none remains
    /// (deleted or moved outside Monknot), nothing is selected, not its folder or the open document,
    /// so a key pressed next never acts on more than the user picked.
    private func reconcileSidebarSelection() {
        guard !sidebarItemSelection.isEmpty else { return }
        let remaining = rootNode == nil
            ? SidebarSelection()
            : sidebarItemSelection.filtered { sidebarNodeKinds[$0] != nil }
        guard remaining != sidebarItemSelection else { return }
        if remaining.isEmpty {
            clearSidebarSelection()
        } else {
            sidebarItemSelection = remaining
        }
    }

    /// The sidebar's selected items follow the item moved from `sourcePath` to `destinationPath`.
    private func followSidebarSelection(afterMoving sourcePath: String, to destinationPath: String) {
        guard !sidebarItemSelection.isEmpty else { return }
        sidebarItemSelection = sidebarItemSelection.mapped {
            Self.path($0, afterMoving: sourcePath, to: destinationPath)
        }
    }

    private func selectOpenDocumentInSidebar() {
        sidebarItemSelection = SidebarSelection()
        sidebarSelectsOpenDocument = true
    }

    /// Leaves nothing selected in the sidebar.
    private func clearSidebarSelection() {
        sidebarItemSelection = SidebarSelection()
        sidebarSelectsOpenDocument = false
    }

    /// Drops the selection of a document that is no longer in the workspace. The window's tabs then
    /// show the tab that takes its place, as when it closes, and the sidebar selects nothing in
    /// its place.
    private func deselectRemovedDocument() {
        selectedDocumentID = nil
        sidebarSelectsOpenDocument = false
    }

    /// Asks the sidebar to expand `directoryURL` so the items just added to it show.
    private func revealFolder(_ directoryURL: URL?) {
        guard let directoryURL,
              let workspaceURL,
              directoryURL.standardizedFileURL != workspaceURL.standardizedFileURL
        else { return }
        revealedFolder = WorkspaceFolderReveal(
            serial: (revealedFolder?.serial ?? 0) &+ 1,
            folderID: directoryURL.standardizedFileURL.path
        )
    }

    var isWorkspaceOpening: Bool {
        openingWorkspaceURL != nil || (workspaceURL != nil && rootNode == nil)
    }

    var canBootstrapStarterWorkspace: Bool {
        workspaceURL != nil && rootNode != nil && documents.isEmpty && !isBusy
    }

    func saveState(for documentID: String) -> DocumentSaveState {
        documentSaveStates[documentID] ?? .clean
    }

    var activeWritingToolsDocumentID: String? {
        writingToolsDocumentID
    }

    func openWorkspace(_ url: URL) {
        openWorkspace(url, selecting: nil)
    }

    func openWorkspace(_ url: URL, selecting selectedURL: URL?) {
        startWorkspaceLoad(url, selecting: selectedURL, preserveSelection: nil, reloadSelection: true)
    }

    func handleDroppedURL(_ url: URL) {
        Task { [weak self] in
            do {
                let target = try await Self.resolveDroppedTarget(for: url)
                guard let self else { return }

                switch target {
                case .workspace(let workspaceURL):
                    self.startWorkspaceLoad(workspaceURL, selecting: nil, preserveSelection: nil, reloadSelection: true)
                case .document(let workspaceURL, let selectedURL):
                    self.startWorkspaceLoad(workspaceURL, selecting: selectedURL, preserveSelection: nil, reloadSelection: true)
                case .unsupported:
                    break
                }
            } catch {
                self?.errorMessage = "Could not use dropped item: \(error.localizedDescription)"
            }
        }
    }

    func refresh() {
        guard workspaceURL != nil else { return }

        guard writingToolsDocumentID == nil else {
            deferExternalRefreshUntilWritingToolsEnd()
            return
        }

        runExternalWorkspaceRefresh()
        refreshGitStatus()
    }

    func replaceInWorkspace(
        find: String,
        replacement: String,
        options: MonknotSearchOptions = MonknotSearchOptions(),
        scope: WorkspaceReplaceScope = .entireWorkspace,
        searchResultDocumentIDs: Set<String> = []
    ) {
        guard ensureWritingToolsInactive(for: "replacing workspace text") else { return }
        guard workspaceURL != nil else {
            errorMessage = "Open a workspace before replacing text."
            return
        }

        let needle = find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        guard !isBusy else { return }

        if scope != .entireWorkspace, searchResultDocumentIDs.isEmpty {
            workspaceReplaceSummary = scope == .selectedSearchResult
                ? "Select a text search result to replace in."
                : "No searchable files in results."
            return
        }

        let skipDocumentIDs = Set(documentSaveStates.filter { !$0.value.isClean }.map(\.key))
        let limitToDocumentIDs = scope == .entireWorkspace ? nil : searchResultDocumentIDs
        let snapshot = documents
        workspaceReplaceSummary = nil
        clearReplaceUndoSnapshot()
        noteInternalFileMutation()
        let generation = beginWorkspaceOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let batch = try WorkspaceReplaceService().replaceAndWrite(
                    find: needle,
                    replacement: replacement,
                    options: options,
                    documents: snapshot,
                    skipDocumentIDs: skipDocumentIDs,
                    limitToDocumentIDs: limitToDocumentIDs
                )
                guard !Task.isCancelled else { return }
                await self?.finishWorkspaceReplace(batch: batch, generation: generation)
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not replace in workspace")
            }
        }
    }

    func undoLastWorkspaceReplace() {
        guard ensureWritingToolsInactive(for: "undoing workspace replace") else { return }
        guard let snapshot = replaceUndoSnapshot, workspaceURL != nil else { return }
        guard ensureNotBusy() else { return }
        // Undo writes each note's earlier text back: a note edited since and not saved would lose
        // the edit, so the undo waits for it, as the replace itself skipped unsaved notes.
        if let unsaved = snapshot.previousTextsByDocumentID.keys.sorted()
            .first(where: { !saveState(for: $0).isClean })
            .flatMap(document(id:)) {
            errorMessage = "Save \(unsaved.displayName) first: undoing the replace writes its earlier text."
            return
        }

        let restoreSnapshot = snapshot
        clearReplaceUndoSnapshot()
        let documentSnapshot = documents
        workspaceReplaceSummary = nil
        noteInternalFileMutation()
        let generation = beginWorkspaceOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let batch = try WorkspaceReplaceService().restoreAndWrite(restoreSnapshot, documents: documentSnapshot)
                guard !Task.isCancelled else { return }
                var summary = "Undid replace in \(batch.fileResults.count) file(s)."
                if batch.skippedChangedCount > 0 {
                    summary += " Left \(batch.skippedChangedCount) that changed since the replace."
                }
                await self?.finishWorkspaceReplace(batch: batch, generation: generation, summary: summary)
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not undo workspace replace")
            }
        }
    }

    func recentDocuments() -> [RecentDocumentEntry] {
        guard let workspaceURL else { return [] }
        return recentDocumentStore.entries(for: workspaceURL)
            .filter { document(id: $0.documentID) != nil }
    }

    func document(id: String) -> WorkspaceDocument? {
        documentsByID[id] ?? removedDirtyDocuments[id]
    }

    private func setDocumentTextIfChanged(_ text: String) {
        guard documentText != text else { return }
        documentText = text
    }

    private func setHasUnsavedChangesIfChanged(_ value: Bool) {
        guard hasUnsavedChanges != value else { return }
        hasUnsavedChanges = value
    }

    private func setDocumentLoadingIfChanged(_ value: Bool) {
        guard isDocumentLoading != value else { return }
        isDocumentLoading = value
    }

    private func setSavingIfChanged(_ value: Bool) {
        guard isSaving != value else { return }
        isSaving = value
    }

    private func setSelectedDocumentExternalChangeIfChanged(_ value: Bool) {
        guard selectedDocumentExternalChange != value else { return }
        selectedDocumentExternalChange = value
    }

    private func setSelectedDocumentSignatureIfChanged(_ signature: FileSignature?) {
        guard selectedDocumentSignature != signature else { return }
        selectedDocumentSignature = signature
    }

    private func changeTrackedSignature(for document: WorkspaceDocument?) -> FileSignature? {
        guard let document,
              document.capabilities.canEditText || document.kind.opensInPDFViewer
        else { return nil }
        return Self.fileSignature(for: document.url)
    }

    private func replaceDocuments(with nextDocuments: [WorkspaceDocument]) {
        documentsByID = Dictionary(
            nextDocuments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        markdownDocuments = nextDocuments.filter { $0.kind == .markdown }
        hasPDFDocuments = nextDocuments.contains { $0.kind == .pdf }
        documents = nextDocuments
    }

    func setOpenDocumentIDs(_ documentIDs: Set<String>) {
        guard openDocumentIDs != documentIDs else { return }
        openDocumentIDs = documentIDs
        pruneRemovedDirtyDocuments()
    }

    func requestDocumentOpen(at url: URL) {
        let documentID = url.standardizedFileURL.path
        guard !pendingDocumentOpenIDs.contains(documentID) else { return }
        pendingDocumentOpenIDs.append(documentID)
    }

    func takePendingDocumentOpens() -> [String] {
        defer { pendingDocumentOpenIDs = [] }
        return pendingDocumentOpenIDs
    }

    /// Opens the document `id` and, when `selectingInSidebar`, moves the sidebar selection to it;
    /// nil leaves no document open and keeps a selected folder. The window's tabs pass false when
    /// they show a document on their own, as after its neighbour left the workspace.
    @discardableResult
    func selectDocument(id: String?, selectingInSidebar: Bool = true) -> Bool {
        guard !isBusy else { return false }
        guard id != selectedDocumentID else {
            if id != nil, selectingInSidebar {
                selectOpenDocumentInSidebar()
            }
            return true
        }
        guard ensureWritingToolsInactive(for: "switching documents") else { return false }

        let signpostID = MonknotSignposting.documentSelection.beginInterval("SelectDocument")
        defer { MonknotSignposting.documentSelection.endInterval("SelectDocument", signpostID) }

        if id != nil, selectingInSidebar {
            selectOpenDocumentInSidebar()
        }
        selectedDocumentID = id
        loadSelectedDocument()
        if let id, let document = document(id: id), let workspaceURL {
            scheduleRecentDocumentRecord(document, workspaceURL: workspaceURL)
        }
        return true
    }

    func createMarkdownFile(in directoryURL: URL? = nil) {
        guard let workspaceURL else {
            errorMessage = "Open a workspace before creating a Markdown file."
            return
        }

        guard ensureNotBusy(), ensureWritingToolsInactive(for: "changing the workspace") else { return }

        noteInternalFileMutation()

        let targetDirectory = directoryURL ?? workspaceURL
        let fileURL = nextAvailableMarkdownURL(in: targetDirectory)
        let title = fileURL.deletingPathExtension().lastPathComponent
        let initialText = "# \(title)\n\n"
        let generation = beginWorkspaceOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                try Self.writeNewFile(initialText, to: fileURL)
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishCreatedFile(
                    result: result,
                    fileURL: fileURL,
                    workspaceURL: workspaceURL,
                    initialText: initialText,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not create a Markdown file")
            }
        }
    }

    func createMarkdownFile(at proposedURL: URL) {
        guard let workspaceURL else {
            errorMessage = "Open a workspace before creating a Markdown file."
            return
        }
        guard !isBusy,
              ensureWritingToolsInactive(for: "changing the workspace")
        else { return }

        let fileURL: URL
        do {
            fileURL = try Self.validatedMissingWikilinkCreationURL(
                proposedURL,
                workspaceURL: workspaceURL
            )
        } catch {
            errorMessage = "Could not create note: \(error.localizedDescription)"
            return
        }

        let title = fileURL.deletingPathExtension().lastPathComponent
        let initialText = "# \(title)\n\n"
        noteInternalFileMutation()
        let generation = beginWorkspaceOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                try Task.checkCancellation()
                let revalidatedURL = try Self.validatedMissingWikilinkCreationURL(
                    fileURL,
                    workspaceURL: workspaceURL
                )
                try Task.checkCancellation()
                try Self.writeNewFile(initialText, to: revalidatedURL)
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishCreatedFile(
                    result: result,
                    fileURL: revalidatedURL,
                    workspaceURL: workspaceURL,
                    initialText: initialText,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(
                    error,
                    generation: generation,
                    message: "Could not create note"
                )
            }
        }
    }

    func createDailyNote(on date: Date = Date()) {
        guard let workspaceURL else {
            errorMessage = "Open a workspace before creating a daily note."
            return
        }

        guard !isBusy,
              ensureWritingToolsInactive(for: "changing the workspace")
        else { return }

        let inboxURL = DailyNotePlanner.inboxDirectoryURL(workspaceURL: workspaceURL)
        let fileURL = DailyNotePlanner.dailyNoteURL(workspaceURL: workspaceURL, date: date)

        do {
            try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not create inbox folder: \(error.localizedDescription)"
            return
        }

        if let kept = keptUnsavedDocument(inItemAt: fileURL) {
            errorMessage = WorkspaceDocumentOperationError.keepsUnsavedText(kept.displayName).localizedDescription
            return
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            noteInternalFileMutation()
            let generation = beginWorkspaceOperation()
            workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
                do {
                    let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                    guard !Task.isCancelled else { return }
                    await self?.finishSelectExistingFile(
                        result: result,
                        fileURL: fileURL,
                        workspaceURL: workspaceURL,
                        generation: generation
                    )
                } catch {
                    await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not open daily note")
                }
            }
            return
        }

        noteInternalFileMutation()
        let initialText = DailyNotePlanner.initialContent(for: date)
        let generation = beginWorkspaceOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                try Self.writeNewFile(initialText, to: fileURL)
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishCreatedFile(
                    result: result,
                    fileURL: fileURL,
                    workspaceURL: workspaceURL,
                    initialText: initialText,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not create daily note")
            }
        }
    }

    func bootstrapStarterWorkspace() {
        guard let workspaceURL else {
            errorMessage = "Open a workspace before creating starter files."
            return
        }

        guard !isBusy,
              ensureWritingToolsInactive(for: "changing the workspace")
        else { return }

        noteInternalFileMutation()
        let generation = beginWorkspaceOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                let readmeURL = try WorkspaceTemplateService.bootstrapStarterWorkspace(at: workspaceURL)
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishSelectExistingFile(
                    result: result,
                    fileURL: readmeURL,
                    workspaceURL: workspaceURL,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not create starter workspace")
            }
        }
    }

    /// A new Markdown page for Preview's Page block: `name.md` beside the document at
    /// `documentURL` (`name 2.md` when that exists), titled with the name. The file watcher lists
    /// it; the open document and its unsaved text are untouched. Returns the page's URL.
    func createPage(named proposedName: String, besideDocumentAt documentURL: URL) async throws -> URL {
        guard let workspaceURL else {
            throw WorkspaceDocumentOperationError.invalidCreation("Open a workspace first.")
        }
        let directory = documentURL.deletingLastPathComponent().standardizedFileURL
        guard WorkspaceDocumentSupport.isURL(directory, containedIn: workspaceURL) else {
            throw WorkspaceDocumentOperationError.invalidCreation("Create pages inside the current workspace.")
        }
        var title = try Self.validatedItemName(proposedName)
        if (title as NSString).pathExtension.lowercased() == "md" {
            title = (title as NSString).deletingPathExtension
        }
        let fileName = Self.suggestedChildName(in: directory, baseName: title, pathExtension: "md")
        try Self.validateLength(of: fileName)
        try Self.validateVisibility(of: fileName, isDirectory: false)
        let fileURL = directory.appendingPathComponent(fileName)
        let text = "# \(title)\n\n"
        try await Task.detached(priority: .userInitiated) {
            try Data(text.utf8).write(to: fileURL, options: .withoutOverwriting)
        }.value
        return fileURL
    }

    func suggestedNewFileName(in directoryURL: URL? = nil) -> String {
        let targetDirectory = directoryURL ?? workspaceURL
        return Self.suggestedChildName(in: targetDirectory, baseName: "Untitled", pathExtension: "md")
    }

    func suggestedNewFolderName(in directoryURL: URL? = nil) -> String {
        let targetDirectory = directoryURL ?? workspaceURL
        return Self.suggestedChildName(in: targetDirectory, baseName: "New Folder", pathExtension: nil)
    }

    /// Why `proposedName` cannot name a new item in `directoryURL` (the root when nil), or nil when
    /// it can. `createFile` and `createFolder` refuse exactly these names.
    func validationMessage(forNewItemNamed proposedName: String, in directoryURL: URL?, isDirectory: Bool) -> String? {
        do {
            _ = try newItemURL(named: proposedName, in: directoryURL, isDirectory: isDirectory)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Why the item at `itemURL` cannot be renamed to `proposedName`, or nil when it can.
    /// `renameDocument` and `renameFolder` refuse exactly these names.
    func validationMessage(forRenaming itemURL: URL, to proposedName: String, isDirectory: Bool) -> String? {
        do {
            _ = try Self.renamedURL(for: itemURL, proposedName: proposedName, isDirectory: isDirectory)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func newItemURL(named proposedName: String, in directoryURL: URL?, isDirectory: Bool) throws -> URL {
        guard let workspaceURL else {
            throw WorkspaceDocumentOperationError.invalidCreation("Open a workspace first.")
        }
        let targetDirectory = directoryURL ?? workspaceURL
        guard WorkspaceDocumentSupport.isURL(targetDirectory, containedIn: workspaceURL) else {
            throw WorkspaceDocumentOperationError.invalidCreation("Create items inside the current workspace.")
        }
        let name = isDirectory ? proposedName : Self.newFileName(proposedName)
        let url = try Self.childURL(in: targetDirectory, proposedName: name, isDirectory: isDirectory)
        if let kept = keptUnsavedDocument(inItemAt: url) {
            throw WorkspaceDocumentOperationError.keepsUnsavedText(kept.displayName)
        }
        return url
    }

    /// A note Monknot keeps unsaved text for at `url`, or inside it, after its file was removed
    /// outside Monknot. No new or moved item may take that place, or the kept text would be lost
    /// to it.
    private func keptUnsavedDocument(inItemAt url: URL) -> WorkspaceDocument? {
        let path = url.standardizedFileURL.path
        return removedDirtyDocuments.values.first { WorkspaceDocumentSupport.isPath($0.id, containedIn: path) }
    }

    /// New files are Markdown: a name typed without the extension of a known file type gets `.md`
    /// ("Release 1.2", "John.Smith"). A name with one is kept, and names refused anyway (empty,
    /// dotfiles, paths) pass through unchanged.
    nonisolated static func newFileName(_ proposedName: String) -> String {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"),
              !WorkspaceDocumentSupport.isKnownFileExtension((name as NSString).pathExtension)
        else { return proposedName }
        return name + ".md"
    }

    func createFile(named proposedName: String, in directoryURL: URL? = nil) {
        guard let workspaceURL else {
            errorMessage = "Open a workspace before creating a file."
            return
        }

        guard ensureNotBusy(), ensureWritingToolsInactive(for: "changing the workspace") else { return }

        let fileURL: URL
        do {
            fileURL = try newItemURL(named: proposedName, in: directoryURL, isDirectory: false)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        noteInternalFileMutation()
        let generation = beginWorkspaceOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                try Self.writeNewFile("", to: fileURL)

                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishCreatedFile(
                    result: result,
                    fileURL: fileURL,
                    workspaceURL: workspaceURL,
                    initialText: "",
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not create \(fileURL.lastPathComponent)")
            }
        }
    }

    func createFolder(named proposedName: String, in directoryURL: URL? = nil) {
        guard let workspaceURL else {
            errorMessage = "Open a workspace before creating a folder."
            return
        }

        guard ensureNotBusy(), ensureWritingToolsInactive(for: "changing the workspace") else { return }

        let folderURL: URL
        do {
            folderURL = try newItemURL(named: proposedName, in: directoryURL, isDirectory: true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        noteInternalFileMutation()
        let preserveSelection = selectedDocumentID
        let generation = beginWorkspaceOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishWorkspaceLoad(
                    result: result,
                    workspaceURL: workspaceURL,
                    selectedURL: nil,
                    preserveSelection: preserveSelection,
                    reloadSelection: false,
                    sidebarSelection: .folder(folderURL),
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not create \(folderURL.lastPathComponent)")
            }
        }
    }

    func renameDocument(id: String, to proposedName: String) {
        guard let workspaceURL, let document = document(id: id) else { return }
        guard ensureNotBusy() else { return }

        let targetURL: URL
        do {
            targetURL = try Self.renamedURL(for: document.url, proposedName: proposedName, isDirectory: false)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard targetURL.standardizedFileURL != document.url.standardizedFileURL else {
            return
        }

        requestMarkdownLinkAwareMove(
            sourceURL: document.url,
            destinationURL: targetURL,
            workspaceURL: workspaceURL,
            failureMessage: "Could not rename \(document.displayName)",
            undoVerb: .rename
        )
    }

    func renameFolder(id: String, to proposedName: String) {
        guard let workspaceURL else { return }
        guard ensureNotBusy() else { return }

        let sourceURL = URL(fileURLWithPath: id, isDirectory: true).standardizedFileURL
        guard sourceURL != workspaceURL.standardizedFileURL else {
            errorMessage = "Rename the workspace folder in Finder."
            return
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let targetURL: URL
        do {
            targetURL = try Self.renamedURL(for: sourceURL, proposedName: proposedName, isDirectory: true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard targetURL.standardizedFileURL != sourceURL else {
            return
        }

        requestMarkdownLinkAwareMove(
            sourceURL: sourceURL,
            destinationURL: targetURL,
            workspaceURL: workspaceURL,
            failureMessage: "Could not rename \(sourceURL.lastPathComponent)",
            undoVerb: .rename
        )
    }

    /// Moves a workspace item into `directoryURL` (the root when nil). Returns false when the move
    /// is refused; an item already there is left alone.
    @discardableResult
    func moveItem(id: String, toDirectory directoryURL: URL?) -> Bool {
        guard let workspaceURL else { return false }
        guard ensureNotBusy() else { return false }

        let sourceURL = URL(fileURLWithPath: id).standardizedFileURL
        let targetDirectory = (directoryURL ?? workspaceURL).standardizedFileURL

        do {
            let destinationURL = try Self.moveDestinationURL(
                for: sourceURL,
                toDirectory: targetDirectory,
                workspaceURL: workspaceURL
            )

            guard destinationURL.standardizedFileURL != sourceURL else {
                return true
            }

            return requestMarkdownLinkAwareMove(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                workspaceURL: workspaceURL,
                failureMessage: "Could not move \(sourceURL.lastPathComponent)"
            )
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Marks workspace files and folders to be copied by each later paste, as long as the pasteboard
    /// holds the item stamped `pasteboardStamp` (`putItemsOnPasteboard`).
    func copyItems(at urls: [URL], pasteboardStamp: WorkspacePasteboardTransferStamp) {
        setPendingTransfer(for: urls, operation: .copy, pasteboardStamp: pasteboardStamp)
    }

    /// Marks workspace files and folders to be moved by the next paste, as long as the pasteboard
    /// holds the item stamped `pasteboardStamp` (`putItemsOnPasteboard`).
    func cutItems(at urls: [URL], pasteboardStamp: WorkspacePasteboardTransferStamp) {
        setPendingTransfer(for: urls, operation: .cut, pasteboardStamp: pasteboardStamp)
    }

    /// The stamp of the pasteboard item the pending Copy or Cut wrote, if it wrote one.
    var pendingTransferPasteboardStamp: WorkspacePasteboardTransferStamp? {
        pendingDocumentTransfer?.pasteboardStamp
    }

    /// Whether the pending transfer is a Cut, which the next paste in any window moves.
    var hasPendingCut: Bool {
        pendingDocumentTransfer?.operation == .cut
    }

    func discardPendingTransfer() {
        pendingDocumentTransfer = nil
    }

    /// The stores of the other open windows.
    var otherWindowStores: [WorkspaceStore] {
        Self.openStores.allObjects.filter { $0 !== self }
    }

    /// Replaces any earlier transfer, which the newer Copy or Cut supersedes even when its items
    /// are not all workspace files or folders.
    private func setPendingTransfer(
        for urls: [URL],
        operation: WorkspaceDocumentTransferOperation,
        pasteboardStamp: WorkspacePasteboardTransferStamp?
    ) {
        let urls = Self.outermostItems(urls.map(\.standardizedFileURL))
        guard !urls.isEmpty, urls.allSatisfy(isWorkspaceItem) else {
            pendingDocumentTransfer = nil
            return
        }
        pendingDocumentTransfer = WorkspaceDocumentTransfer(
            urls: urls,
            operation: operation,
            pasteboardStamp: pasteboardStamp
        )
    }

    /// `urls` without any inside another of them, which goes with that folder, or given twice, in the
    /// order given: a drop moves its items in the order they came.
    nonisolated static func outermostItems(_ urls: [URL]) -> [URL] {
        let standardized = urls.map(\.standardizedFileURL)
        let paths = Set(standardized.map(\.path))
        var seen = Set<String>()
        return standardized.filter { url in
            seen.insert(url.path).inserted && !hasAncestor(url.path, in: paths)
        }
    }

    /// `paths` without any inside another of them, in path order: one look-up per folder above
    /// each path, not a comparison per pair.
    nonisolated static func outermostPaths(_ paths: [String]) -> [String] {
        let pathSet = Set(paths)
        return pathSet.filter { !hasAncestor($0, in: pathSet) }.sorted()
    }

    /// Whether a folder above `path` is in `paths`.
    nonisolated static func hasAncestor(_ path: String, in paths: Set<String>) -> Bool {
        var folder = path
        while true {
            let parent = (folder as NSString).deletingLastPathComponent
            guard parent != folder, !parent.isEmpty else { return false }
            if paths.contains(parent) {
                return true
            }
            folder = parent
        }
    }

    private nonisolated static func nodeKinds(in root: SidebarNode?) -> [String: SidebarNode.Kind] {
        var kinds: [String: SidebarNode.Kind] = [:]
        func walk(_ nodes: [SidebarNode]) {
            for node in nodes {
                kinds[node.id] = node.kind
                if let children = node.children {
                    walk(children)
                }
            }
        }
        walk(root?.children ?? [])
        return kinds
    }

    /// Whether the standardized `url` is a document of the workspace or a folder inside it.
    private func isWorkspaceItem(_ url: URL) -> Bool {
        documentsByID[url.path] != nil || isWorkspaceFolder(url)
    }

    private func isWorkspaceFolder(_ url: URL) -> Bool {
        guard let workspaceURL,
              url.path != workspaceURL.standardizedFileURL.path,
              WorkspaceDocumentSupport.isURL(url, containedIn: workspaceURL)
        else { return false }
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func pasteDocumentTransfer(into directoryURL: URL? = nil) {
        guard let transfer = pendingDocumentTransfer else { return }
        paste(transfer, cutIn: nil, into: directoryURL)
    }

    /// Moves the items another window cut into `directoryURL` (the root when nil), as a Paste in
    /// that window would. An item with unsaved changes in that window stays where it is.
    func pasteCut(from owner: WorkspaceStore, into directoryURL: URL?) {
        guard owner !== self,
              let transfer = owner.pendingDocumentTransfer,
              transfer.operation == .cut
        else { return }
        paste(transfer, cutIn: owner, into: directoryURL)
    }

    /// Pastes a Copy or Cut into `directoryURL`. `owner` is the store of the window that made the
    /// Cut when that is another window.
    private func paste(_ transfer: WorkspaceDocumentTransfer, cutIn owner: WorkspaceStore?, into directoryURL: URL?) {
        guard let workspaceURL else { return }
        guard ensureNotBusy() else { return }
        guard owner?.isBusy != true, owner?.isSaving != true else {
            errorMessage = Self.busyMessage
            return
        }
        guard ensureWritingToolsInactive(for: "changing the workspace") else { return }

        let targetDirectory = (directoryURL ?? workspaceURL).standardizedFileURL
        let sourceURLs = transfer.urls
        let displayName = Self.itemsName(sourceURLs)
        let isInTarget = { (url: URL) in url.deletingLastPathComponent().standardizedFileURL == targetDirectory }

        if transfer.operation == .cut, sourceURLs.allSatisfy(isInTarget) {
            completeTransfer(transfer)
            return
        }

        guard WorkspaceDocumentSupport.isURL(targetDirectory, containedIn: workspaceURL) else {
            errorMessage = "Paste items into the current workspace."
            return
        }
        guard !sourceURLs.contains(where: { WorkspaceDocumentSupport.isURL(targetDirectory, containedIn: $0) }) else {
            errorMessage = "A folder cannot be pasted into itself."
            return
        }
        let movesWithinWorkspace = transfer.operation == .cut
            && sourceURLs.allSatisfy { WorkspaceDocumentSupport.isURL($0, containedIn: workspaceURL) }
        // A move within this workspace can rewrite the links in any note of it; a move from
        // another workspace takes only the items.
        if let owner,
           let unsaved = movesWithinWorkspace
               ? owner.unsavedDocument(at: workspaceURL)
               : sourceURLs.lazy.compactMap({ owner.unsavedDocument(at: $0) }).first {
            errorMessage = "Save or close \(unsaved.displayName) in its window first."
            return
        }

        if movesWithinWorkspace, sourceURLs.count == 1, let sourceURL = sourceURLs.first {
            requestMarkdownLinkAwareMove(
                sourceURL: sourceURL,
                destinationURL: Self.uniqueDocumentURL(
                    for: sourceURL,
                    in: targetDirectory,
                    reservedPaths: Set(removedDirtyDocuments.keys)
                ),
                workspaceURL: workspaceURL,
                failureMessage: "Could not paste \(displayName)",
                selectDestinationAfterMove: true,
                completedTransfer: transfer
            )
            return
        }
        if movesWithinWorkspace {
            // Several items move one after another, as a drop of them does; the Cut ends as they
            // start, so a second Paste cannot copy them back from its snapshots.
            completeTransfer(transfer)
            dropFileURLs(sourceURLs.filter { !isInTarget($0) }, into: targetDirectory)
            return
        }

        // A Copy pastes each file as it was at Copy while its snapshot is on the pasteboard, as a
        // Paste in another app does.
        let sources = sourceURLs.map { url in
            WorkspaceItemTransferSource(
                url: url,
                contentsURL: transfer.operation == .copy
                    ? transfer.pasteboardStamp?.snapshotURL(for: url).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                    : nil,
                targetDirectory: targetDirectory
            )
        }
        startItemTransfer(
            sources,
            moving: transfer.operation == .cut,
            workspaceURL: workspaceURL,
            completedTransfer: transfer,
            failureMessage: "Could not paste \(displayName)",
            undoVerb: transfer.operation == .cut ? .move : .copy
        )
    }

    /// An item's name, or how many items there are: what a message about them calls them.
    nonisolated private static func itemsName(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
    }

    /// The first document at or inside `url` with unsaved changes.
    private func unsavedDocument(at url: URL) -> WorkspaceDocument? {
        let path = url.standardizedFileURL.path
        return documentSaveStates
            .filter { !$0.value.isClean && WorkspaceDocumentSupport.isPath($0.key, containedIn: path) }
            .keys
            .sorted()
            .lazy
            .compactMap { self.document(id: $0) }
            .first
    }

    /// Ends a pasted Cut, which also leaves the pasteboard while it still holds the items, so a
    /// second Paste does not copy the moved items back from their snapshots. A Copy stays pending,
    /// so every Paste of it makes more copies.
    private func completeTransfer(_ transfer: WorkspaceDocumentTransfer) {
        guard transfer.operation == .cut else { return }
        if pendingDocumentTransfer == transfer {
            pendingDocumentTransfer = nil
        }
        if let stamp = transfer.pasteboardStamp {
            WorkspacePasteboardExportService.clearTransfer(stamp)
        }
    }

    /// Copies a workspace file or folder next to itself with a "copy" suffix.
    func duplicateItem(at url: URL) {
        duplicateItems(at: [url])
    }

    /// Copies workspace files and folders, each next to itself with a "copy" suffix, as one step.
    func duplicateItems(at urls: [URL]) {
        copyWorkspaceItems(urls) { $0.deletingLastPathComponent() }
    }

    /// Copies a workspace file or folder into `directoryURL` (the root when nil), with a "copy"
    /// suffix when its name is taken there.
    func duplicateItem(at url: URL, into directoryURL: URL?) {
        duplicateItems(at: [url], into: directoryURL)
    }

    /// Copies workspace files and folders into `directoryURL` (the root when nil), as one step.
    func duplicateItems(at urls: [URL], into directoryURL: URL?) {
        guard let workspaceURL else { return }
        let targetDirectory = (directoryURL ?? workspaceURL).standardizedFileURL
        copyWorkspaceItems(urls) { _ in targetDirectory }
    }

    /// Copies each workspace item of `urls` into the folder `targetDirectory` names for it. An item
    /// inside another one given goes with it.
    private func copyWorkspaceItems(_ urls: [URL], into targetDirectory: (URL) -> URL) {
        let sourceURLs = Self.outermostItems(urls).filter(isWorkspaceItem)
        guard let workspaceURL, !sourceURLs.isEmpty else { return }
        guard ensureNotBusy(), ensureWritingToolsInactive(for: "changing the workspace") else { return }

        var sources: [WorkspaceItemTransferSource] = []
        for sourceURL in sourceURLs {
            let target = targetDirectory(sourceURL).standardizedFileURL
            guard WorkspaceDocumentSupport.isURL(target, containedIn: workspaceURL) else {
                errorMessage = "Copy items into the current workspace."
                return
            }
            guard !WorkspaceDocumentSupport.isURL(target, containedIn: sourceURL) else {
                errorMessage = "A folder cannot be copied into itself."
                return
            }
            sources.append(WorkspaceItemTransferSource(url: sourceURL, contentsURL: nil, targetDirectory: target))
        }
        let duplicatesInPlace = sources.allSatisfy {
            $0.targetDirectory == $0.url.deletingLastPathComponent().standardizedFileURL
        }

        startItemTransfer(
            sources,
            moving: false,
            workspaceURL: workspaceURL,
            completedTransfer: nil,
            failureMessage: "Could not duplicate \(Self.itemsName(sourceURLs))",
            undoVerb: duplicatesInPlace ? .duplicate : .copy
        )
    }

    /// Copies files and folders, or moves ones cut in another workspace, each into its target
    /// folder, and selects the result: one file opens and one folder is selected in the sidebar;
    /// several items are selected in the sidebar. A copy is made of its source's `contentsURL`, a
    /// snapshot of the file, when given; otherwise it carries the unsaved text of the copied file,
    /// or of every document in the copied folder. Whatever was copied before a failure stays on
    /// disk, so a failure rescans too. A transfer that completes is one step of Edit › Undo, named
    /// by `undoVerb`.
    private func startItemTransfer(
        _ sources: [WorkspaceItemTransferSource],
        moving: Bool,
        workspaceURL: URL,
        completedTransfer: WorkspaceDocumentTransfer?,
        failureMessage: String,
        undoVerb: WorkspaceFileOperationVerb
    ) {
        var dirtyCopyTexts: [String: [(subpath: String, text: String)]] = [:]
        if !moving {
            for source in sources where source.contentsURL == nil {
                dirtyCopyTexts[source.url.path] = unsavedTexts(inItemAt: source.url.path)
            }
        }
        let copyTexts = dirtyCopyTexts
        let reservedPaths = Set(removedDirtyDocuments.keys)
        let preserveSelection = selectedDocumentID
        noteInternalFileMutation()
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            var undoSteps: [WorkspaceFileOperationStep] = []
            var landedItems: [WorkspaceLandedItem] = []
            do {
                for source in sources {
                    let sourceURL = source.url
                    let destinationURL = Self.uniqueDocumentURL(
                        for: sourceURL,
                        in: source.targetDirectory,
                        reservedPaths: reservedPaths
                    ).standardizedFileURL
                    let isFolder = Self.isDirectory(sourceURL)
                    if moving {
                        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                        undoSteps.append(.move(WorkspaceFileMoveStep(
                            sourceURL: sourceURL,
                            destinationURL: destinationURL,
                            isDirectory: isFolder,
                            usedCaseOnlyRenameHop: false,
                            rewrittenFiles: []
                        )))
                    } else {
                        try FileManager.default.copyItem(at: source.contentsURL ?? sourceURL, to: destinationURL)
                        // The copy exists from here on: it is recorded even when its unsaved text
                        // cannot be written, so Undo can still take it back.
                        var textError: Error?
                        do {
                            for (subpath, text) in copyTexts[sourceURL.path] ?? [] {
                                let copiedURL = subpath.isEmpty ? destinationURL : destinationURL.appendingPathComponent(subpath)
                                try await Self.writeText(text, to: copiedURL)
                            }
                        } catch {
                            textError = error
                        }
                        undoSteps.append(.copy(WorkspaceFileCopyStep(
                            sourceURL: sourceURL,
                            contentsURL: source.contentsURL,
                            copyURL: destinationURL,
                            isDirectory: isFolder,
                            fingerprint: WorkspaceItemFingerprint.read(destinationURL)
                        )))
                        if let textError {
                            landedItems.append(WorkspaceLandedItem(url: destinationURL, isFolder: isFolder))
                            throw textError
                        }
                    }
                    landedItems.append(WorkspaceLandedItem(url: destinationURL, isFolder: isFolder))
                }

                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishDocumentTransfer(
                    result: result,
                    workspaceURL: workspaceURL,
                    landedItems: landedItems,
                    preserveSelection: preserveSelection,
                    changedPaths: sources.map(\.url.path) + landedItems.map(\.url.path),
                    completedTransfer: completedTransfer,
                    undoSteps: undoSteps,
                    undoVerb: undoVerb,
                    generation: generation
                )
            } catch {
                let result = try? await Self.scanWorkspace(workspaceURL, scanner: scanner)
                await self?.finishPartialTransfer(
                    undoSteps: undoSteps,
                    undoVerb: undoVerb,
                    completedTransfer: completedTransfer,
                    generation: generation
                )
                await self?.finishCopyFailure(
                    error,
                    result: result,
                    workspaceURL: workspaceURL,
                    preserveSelection: preserveSelection,
                    message: failureMessage,
                    generation: generation
                )
            }
        }
    }

    /// What a copy or transfer made before it failed stays on disk, and can be undone; a Cut whose
    /// items moved in part ends, so the next Paste does not try the moved ones again.
    private func finishPartialTransfer(
        undoSteps: [WorkspaceFileOperationStep],
        undoVerb: WorkspaceFileOperationVerb,
        completedTransfer: WorkspaceDocumentTransfer?,
        generation: Int
    ) {
        guard generation == workspaceGeneration, !undoSteps.isEmpty else { return }
        recordFileOperation(undoVerb, steps: undoSteps)
        if let completedTransfer {
            completeTransfer(completedTransfer)
        }
    }

    /// The unsaved text of the document at `path` and of each document inside it, by its path
    /// relative to `path` ("" for the item itself).
    private func unsavedTexts(inItemAt path: String) -> [(subpath: String, text: String)] {
        dirtyDocumentTexts.compactMap { documentID, text in
            guard WorkspaceDocumentSupport.isPath(documentID, containedIn: path) else { return nil }
            return (String(documentID.dropFirst(path.count).drop { $0 == "/" }), text)
        }
    }

    /// Copies `items` into `directoryURL` (the root when nil). `moveRunID` names the move run whose
    /// drop the items came with, which goes on once they are in.
    func importPasteboardItems(
        _ items: [WorkspacePasteboardImportItem],
        into directoryURL: URL? = nil,
        moveRunID: Int? = nil
    ) {
        guard let workspaceURL else {
            errorMessage = "Open a workspace before pasting clipboard contents."
            return
        }
        guard !items.isEmpty else { return }
        guard ensureNotBusy(), ensureWritingToolsInactive(for: "changing the workspace") else { return }

        let targetDirectory = directoryURL ?? workspaceURL
        guard WorkspaceDocumentSupport.isURL(targetDirectory, containedIn: workspaceURL) else {
            errorMessage = "Paste clipboard contents into the current workspace."
            return
        }

        noteInternalFileMutation()
        let preserveSelection = selectedDocumentID
        let shouldSelectImportedCapture = items.contains { $0.prefersSelectionAfterImport }
        let generation = beginDocumentFileOperation(continuingMoveRun: moveRunID)
        revealFolder(targetDirectory)

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                let importedURLs = try WorkspacePasteboardImportService.importItems(items, into: targetDirectory)
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishPasteboardImport(
                    result: result,
                    importedURLs: importedURLs,
                    selectsImport: shouldSelectImportedCapture,
                    workspaceURL: workspaceURL,
                    preserveSelection: preserveSelection,
                    moveRunID: moveRunID,
                    generation: generation
                )
            } catch {
                // Items copied before the failure stay on disk, so the sidebar is rescanned.
                let result = try? await Self.scanWorkspace(workspaceURL, scanner: scanner)
                await self?.finishCopyFailure(
                    error,
                    result: result,
                    workspaceURL: workspaceURL,
                    preserveSelection: preserveSelection,
                    message: "Could not paste clipboard contents",
                    moveRunID: moveRunID,
                    generation: generation
                )
            }
        }
    }

    /// Shows imported items and selects an imported capture. Items the sidebar does not list are
    /// reported, as New File reports a file it would not show, at the end of the move run when the
    /// items came with one.
    private func finishPasteboardImport(
        result: WorkspaceDocumentScanResult,
        importedURLs: [URL],
        selectsImport: Bool,
        workspaceURL: URL,
        preserveSelection: String?,
        moveRunID: Int?,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        let selectedURL = selectsImport ? importedURLs.last : nil
        finishWorkspaceLoad(
            result: result,
            workspaceURL: workspaceURL,
            selectedURL: selectedURL,
            preserveSelection: preserveSelection,
            reloadSelection: selectedURL != nil,
            sidebarSelection: selectedURL != nil ? .document : .unchanged,
            generation: generation
        )

        let unlistedNames = importedURLs
            .filter { result.root.node(withID: $0.standardizedFileURL.path) == nil }
            .map(\.lastPathComponent)
        if let name = unlistedNames.first {
            let message = unlistedNames.count == 1
                ? "Pasted \(name), but Monknot does not show this kind of item."
                : "Pasted \(ListFormatter.localizedString(byJoining: unlistedNames)), but Monknot does not show these kinds of items."
            if let moveRunID, moveRun?.id == moveRunID {
                moveRun?.notes.append(message)
            } else {
                errorMessage = message
            }
        }
        continueMoveRun(moveRunID)
    }

    /// Imports files dropped from Finder into `directoryURL` (the root when nil). Items that are
    /// already in the workspace are moved there instead, one after another, unless the drop is
    /// `copying`. Without a workspace, one dropped item opens as the workspace.
    func dropFileURLs(_ urls: [URL], into directoryURL: URL? = nil, copying: Bool = false) {
        let fileURLs = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        guard !fileURLs.isEmpty else { return }

        guard let workspaceURL = workspaceURL?.standardizedFileURL else {
            guard fileURLs.count == 1 else {
                errorMessage = "Drop one folder to open it as a workspace."
                return
            }
            handleDroppedURL(fileURLs[0])
            return
        }
        guard ensureNotBusy() else { return }

        let isInsideWorkspace = { (url: URL) in url != workspaceURL && WorkspaceDocumentSupport.isURL(url, containedIn: workspaceURL) }
        let workspaceItems = copying ? [] : fileURLs.filter(isInsideWorkspace)
        let importedItems = copying ? fileURLs : fileURLs.filter { !isInsideWorkspace($0) }
        // An item inside another dropped folder moves with that folder.
        let movedItems = Self.outermostItems(workspaceItems)

        // The drop replaces a move waiting for its link review, as any other operation does.
        pendingMarkdownLinkMoveReview = nil
        endMoveRun()
        moveRunSerial &+= 1
        let runID = moveRunSerial
        moveRun = WorkspaceMoveRun(
            id: runID,
            moves: movedItems.map { WorkspaceQueuedMove(sourcePath: $0.path, directoryURL: directoryURL) }
        )
        guard !importedItems.isEmpty else {
            continueMoveRun(runID)
            return
        }
        importPasteboardItems(importedItems.map(WorkspacePasteboardImportItem.fileURL), into: directoryURL, moveRunID: runID)
        // The moves follow the import, and are dropped with it when it is refused.
        if !isBusy {
            endMoveRun()
        }
    }

    /// Starts the next move of the run `runID` once the step before it has finished. A move with
    /// nothing to do is skipped; one that cannot be made is skipped and reported when the run
    /// ends, as Finder does. A step that is not this run's, or a refused start, ends the run.
    private func continueMoveRun(_ runID: Int?) {
        guard let runID, var run = moveRun, run.id == runID,
              !isBusy, pendingMarkdownLinkMoveReview == nil,
              let workspaceURL
        else { return }

        while !run.moves.isEmpty {
            let move = run.moves.removeFirst()
            let sourceURL = URL(fileURLWithPath: move.sourcePath).standardizedFileURL
            let destinationURL: URL
            do {
                destinationURL = try Self.moveDestinationURL(
                    for: sourceURL,
                    toDirectory: (move.directoryURL ?? workspaceURL).standardizedFileURL,
                    workspaceURL: workspaceURL
                )
            } catch {
                run.failures.append(Self.notMovedMessage(sourceURL.lastPathComponent, error))
                continue
            }
            guard destinationURL.standardizedFileURL != sourceURL else { continue }

            moveRun = run
            if requestMarkdownLinkAwareMove(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                workspaceURL: workspaceURL,
                failureMessage: "Could not move \(sourceURL.lastPathComponent)",
                moveRunID: runID
            ) {
                return
            }
            // Refused before it started (a name a removed note's unsaved text holds): the run
            // goes on, and its report says why this item stayed.
            run.failures.append("\(sourceURL.lastPathComponent) wasn't moved: \(errorMessage ?? "it could not be moved.")")
            errorMessage = nil
        }

        endMoveRun()
        reportMoveRun(run)
    }

    /// Ends the run `runID` when its link review is cancelled, reporting the items left unmoved.
    private func cancelMoveRun(_ runID: Int?) {
        guard let runID, let run = moveRun, run.id == runID else { return }
        endMoveRun()
        reportMoveRun(run, unmovedCount: 1 + run.moves.count)
    }

    /// Ends the move run in progress. The moves it made are one step of Edit › Undo, however the
    /// run ended.
    private func endMoveRun() {
        guard let run = moveRun else { return }
        moveRun = nil
        recordFileOperation(.move, steps: run.undoSteps)
    }

    /// Skips a failed step of the move run `runID` while that run is in progress: the run reports
    /// `reason` when it ends, and goes on. Returns false when there is no such run, so the caller
    /// reports the failure itself.
    private func skipFailedMoveRunStep(_ runID: Int?, reason: @autoclosure () -> String) -> Bool {
        guard let runID, moveRun?.id == runID else { return false }
        isBusy = false
        moveRun?.failures.append(reason())
        continueMoveRun(runID)
        return true
    }

    /// Says how a move run went: nothing when every item moved, otherwise how many moved and why
    /// the others did not, then anything its import had to say.
    private func reportMoveRun(_ run: WorkspaceMoveRun, unmovedCount: Int = 0) {
        let reportsUnmoved = unmovedCount > 1
            || (unmovedCount == 1 && (run.movedCount > 0 || !run.failures.isEmpty))
        var sentences: [String] = []
        if run.movedCount > 0, reportsUnmoved || !run.failures.isEmpty {
            sentences.append(run.movedCount == 1 ? "Moved 1 item." : "Moved \(run.movedCount) items.")
        }
        sentences += run.failures
        if reportsUnmoved {
            sentences.append(unmovedCount == 1 ? "1 item wasn't moved." : "\(unmovedCount) items weren't moved.")
        }
        sentences += run.notes
        if !sentences.isEmpty {
            errorMessage = sentences.joined(separator: " ")
        }
    }

    nonisolated private static func notMovedMessage(_ name: String, _ error: Error) -> String {
        "\(name) wasn't moved: \(error.localizedDescription)"
    }

    func createMarkdownImageAsset(
        pngData: Data,
        documentID: String,
        commitInsertion: @escaping @MainActor (MarkdownImageAsset) -> Bool
    ) {
        guard ensureWritingToolsInactive(for: "inserting an image") else { return }
        guard let workspaceURL,
              let document = document(id: documentID),
              document.kind == .markdown
        else {
            errorMessage = "Open a Markdown document before pasting an image."
            return
        }

        markdownImageAssetTask?.cancel()
        noteInternalFileMutation()
        let workspacePath = workspaceURL.standardizedFileURL.path
        markdownImageAssetTask = Task { @MainActor [weak self] in
            do {
                let asset = try await Task.detached(priority: .userInitiated) {
                    try MarkdownImageAssetService.savePNG(
                        pngData,
                        workspaceURL: workspaceURL,
                        markdownDocumentURL: document.url
                    )
                }.value
                guard !Task.isCancelled,
                      let self,
                      self.writingToolsDocumentID == nil,
                      self.workspaceURL?.standardizedFileURL.path == workspacePath,
                      self.document(id: documentID) != nil
                else {
                    await Task.detached(priority: .utility) {
                        MarkdownImageAssetService.removeUncommittedAsset(asset, workspaceURL: workspaceURL)
                    }.value
                    return
                }

                guard commitInsertion(asset) else {
                    await Task.detached(priority: .utility) {
                        MarkdownImageAssetService.removeUncommittedAsset(asset, workspaceURL: workspaceURL)
                    }.value
                    return
                }
                self.noteInternalFileMutation()
                self.refresh()
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = "Could not save the pasted image: \(error.localizedDescription)"
            }
        }
    }

    func createMarkdownFileDropAssets(
        plan: MarkdownFileDropPlan,
        documentID: String,
        commitInsertion: @escaping @MainActor (MarkdownFileDropResult) -> Bool
    ) {
        guard ensureWritingToolsInactive(for: "inserting files") else { return }
        guard let workspaceURL,
              let document = document(id: documentID),
              document.kind == .markdown,
              plan.workspaceURL.standardizedFileURL.resolvingSymlinksInPath() ==
                workspaceURL.standardizedFileURL.resolvingSymlinksInPath(),
              plan.markdownDocumentURL.standardizedFileURL.resolvingSymlinksInPath() ==
                document.url.standardizedFileURL.resolvingSymlinksInPath()
        else {
            errorMessage = "Open the original Markdown document before inserting files."
            return
        }

        markdownImageAssetTask?.cancel()
        if plan.requiresImportConfirmation {
            noteInternalFileMutation()
        }
        let workspacePath = workspaceURL.standardizedFileURL.path
        markdownImageAssetTask = Task { @MainActor [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try MarkdownImageAssetService.importFileDrop(plan)
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled,
                      let self,
                      self.writingToolsDocumentID == nil,
                      self.workspaceURL?.standardizedFileURL.path == workspacePath,
                      self.document(id: documentID) != nil
                else {
                    await Task.detached(priority: .utility) {
                        MarkdownImageAssetService.removeUncommittedAssets(
                            result.importedAssets,
                            workspaceURL: workspaceURL
                        )
                    }.value
                    return
                }

                guard commitInsertion(result) else {
                    await Task.detached(priority: .utility) {
                        MarkdownImageAssetService.removeUncommittedAssets(
                            result.importedAssets,
                            workspaceURL: workspaceURL
                        )
                    }.value
                    return
                }
                if !result.importedAssets.isEmpty {
                    self.noteInternalFileMutation()
                    self.refresh()
                }
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = "Could not insert the files: \(error.localizedDescription)"
            }
        }
    }

    func deleteDocument(_ document: WorkspaceDocument) {
        guard workspaceURL != nil, documents.contains(where: { $0.id == document.id }) else { return }
        guard ensureNotBusy(), ensureWritingToolsInactive(for: "moving a document to the Trash") else { return }

        if openDocumentIDs.contains(document.id), saveState(for: document.id).isClean == false {
            errorMessage = "Save or close \(document.displayName) before moving it to the Trash."
            return
        }

        startMovingToTrash([document.url], documentIDs: [document.id])
    }

    /// Moves a folder and everything in it to the Trash, as `deleteDocument` does for one file.
    func deleteFolder(at folderURL: URL) {
        guard let workspaceURL else { return }
        let folderPath = folderURL.standardizedFileURL.path
        let rootPath = workspaceURL.standardizedFileURL.path
        guard folderPath != rootPath, WorkspaceDocumentSupport.isPath(folderPath, containedIn: rootPath) else { return }
        guard ensureNotBusy(), ensureWritingToolsInactive(for: "moving a folder to the Trash") else { return }

        let contained = documents.filter { WorkspaceDocumentSupport.isPath($0.id, containedIn: folderPath) }
        if let unsaved = contained.first(where: { openDocumentIDs.contains($0.id) && !saveState(for: $0.id).isClean }) {
            errorMessage = "Save or close \(unsaved.displayName) before moving \(folderURL.lastPathComponent) to the Trash."
            return
        }

        startMovingToTrash([folderURL], documentIDs: Set(contained.map(\.id)))
    }

    /// Moves several workspace files and folders to the Trash at once, as `deleteDocument` and
    /// `deleteFolder` do one. An item inside another one given goes with it.
    func deleteItems(at urls: [URL]) {
        guard let workspaceURL else { return }
        let rootPath = workspaceURL.standardizedFileURL.path
        let paths = urls.map(\.standardizedFileURL.path).filter {
            $0 != rootPath && WorkspaceDocumentSupport.isPath($0, containedIn: rootPath)
        }
        let topPaths = Self.outermostPaths(paths)
        guard !topPaths.isEmpty else { return }
        if topPaths.count == 1 {
            if let document = documentsByID[topPaths[0]] {
                deleteDocument(document)
            } else {
                deleteFolder(at: URL(fileURLWithPath: topPaths[0], isDirectory: true))
            }
            return
        }
        guard ensureNotBusy(), ensureWritingToolsInactive(for: "moving items to the Trash") else { return }

        let topPathSet = Set(topPaths)
        let contained = documents.filter { document in
            topPathSet.contains(document.id) || Self.hasAncestor(document.id, in: topPathSet)
        }
        if let unsaved = contained.first(where: { openDocumentIDs.contains($0.id) && !saveState(for: $0.id).isClean }) {
            errorMessage = "Save or close \(unsaved.displayName) before moving it to the Trash."
            return
        }
        let itemURLs = topPaths.map { path in
            URL(fileURLWithPath: path, isDirectory: documentsByID[path] == nil && Self.isDirectory(URL(fileURLWithPath: path)))
        }
        startMovingToTrash(itemURLs, documentIDs: Set(contained.map(\.id)))
    }

    /// Moves the items at `urls`, which hold the documents `documentIDs`, to the Trash and rescans.
    /// A selected document among them closes, and nothing is selected in the sidebar once every
    /// selected item, or the folder holding it, is in the Trash.
    private func startMovingToTrash(_ urls: [URL], documentIDs: Set<String>) {
        guard let workspaceURL, !urls.isEmpty else { return }
        let paths = urls.map(\.standardizedFileURL.path)
        let isTrashed = { (itemID: String) in paths.contains { WorkspaceDocumentSupport.isPath(itemID, containedIn: $0) } }
        let containsSelection = selectedDocumentID.map(documentIDs.contains) == true
        let preserveSelection = containsSelection ? nil : selectedDocumentID
        let sidebarSelectionIDs = sidebarSelectionIDs
        let sidebarSelection: SidebarSelectionAfterLoad = !sidebarSelectionIDs.isEmpty && sidebarSelectionIDs.allSatisfy(isTrashed)
            ? .cleared
            : .unchanged
        noteInternalFileMutation()
        invalidateWorkspaceSearchCaches(paths: documentIDs)
        endReplaceUndo(ifTouching: paths)
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner, moveItemToTrash] in
            var failure: (url: URL, error: Error)?
            var trashed: [WorkspaceFileOperationStep] = []
            for url in urls {
                do {
                    if let trashedURL = try moveItemToTrash(url) {
                        trashed.append(.trash(WorkspaceFileTrashStep(
                            originalURL: url.standardizedFileURL,
                            trashedURL: trashedURL,
                            isDirectory: url.hasDirectoryPath || Self.isDirectory(trashedURL)
                        )))
                    }
                } catch {
                    failure = (url, error)
                    break
                }
            }
            if let failure, failure.url == urls[0] {
                await self?.finishWorkspaceFailure(failure.error, generation: generation, message: "Could not move \(failure.url.lastPathComponent) to the Trash")
                return
            }
            // What went to the Trash, before a failure too, is one step of Edit › Undo.
            await self?.recordTrash(trashed, generation: generation)
            do {
                // Whatever went to the Trash before a failure stays there, so a failure rescans too.
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishWorkspaceLoad(
                    result: result,
                    workspaceURL: workspaceURL,
                    selectedURL: nil,
                    preserveSelection: preserveSelection,
                    reloadSelection: containsSelection,
                    sidebarSelection: failure == nil ? sidebarSelection : .unchanged,
                    generation: generation
                )
                if let failure {
                    await self?.reportTrashFailure(failure.error, url: failure.url, generation: generation)
                }
            } catch {
                let failed = failure ?? (urls[0], error)
                await self?.finishWorkspaceFailure(failed.error, generation: generation, message: "Could not move \(failed.url.lastPathComponent) to the Trash")
            }
        }
    }

    private func recordTrash(_ steps: [WorkspaceFileOperationStep], generation: Int) {
        guard generation == workspaceGeneration else { return }
        recordFileOperation(.trash, steps: steps)
    }

    private func reportTrashFailure(_ error: Error, url: URL, generation: Int) {
        guard generation == workspaceGeneration else { return }
        errorMessage = "Could not move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)"
    }

    /// Plans a rename or move that updates the Markdown links to the item, then runs it or asks
    /// for review. `moveRunID` names the move run it is a step of. Returns false when it cannot
    /// start. A move that is made is one step of Edit › Undo, named by `undoVerb`; a step of a
    /// move run is part of the run's step.
    @discardableResult
    private func requestMarkdownLinkAwareMove(
        sourceURL: URL,
        destinationURL: URL,
        workspaceURL: URL,
        failureMessage: String,
        selectDestinationAfterMove: Bool = false,
        completedTransfer: WorkspaceDocumentTransfer? = nil,
        moveRunID: Int? = nil,
        undoVerb: WorkspaceFileOperationVerb = .move
    ) -> Bool {
        guard ensureNotBusy(), ensureWritingToolsInactive(for: "renaming or moving files") else { return false }
        if destinationURL.standardizedFileURL != sourceURL.standardizedFileURL,
           let kept = keptUnsavedDocument(inItemAt: destinationURL) {
            errorMessage = WorkspaceDocumentOperationError.keepsUnsavedText(kept.displayName).localizedDescription
            return false
        }

        let mappings = Self.documentIDMappings(forMoving: sourceURL, to: destinationURL, documents: documents)
        let preserveSelection = selectedDocumentID
        let movesDocument = documentsByID[sourceURL.standardizedFileURL.path] != nil
        let selectsDocument = selectDestinationAfterMove && movesDocument
        let selectedURL = selectsDocument
            ? destinationURL.standardizedFileURL
            : mappings.first(where: { $0.sourceID == selectedDocumentID })?.destinationURL
        let sidebarSelection: SidebarSelectionAfterLoad = if !selectDestinationAfterMove {
            .unchanged
        } else if movesDocument {
            .document
        } else {
            .folder(destinationURL.standardizedFileURL)
        }
        let request = WorkspaceMarkdownLinkMoveRequest(
            workspaceURL: workspaceURL.standardizedFileURL,
            mappings: mappings,
            selectedURL: selectedURL,
            preserveSelection: selectsDocument ? nil : preserveSelection,
            reloadSelection: selectsDocument || selectedURL != nil,
            sidebarSelection: sidebarSelection,
            completedTransfer: completedTransfer,
            failureMessage: failureMessage,
            itemName: sourceURL.lastPathComponent,
            moveRunID: moveRunID,
            undoVerb: undoVerb
        )
        let documentSnapshot = documents
        let unsavedMarkdownTexts = dirtyDocumentTexts
            .compactMap { documentID, text in
                documentsByID[documentID].flatMap { $0.kind == .markdown ? (document: $0, text: text) : nil }
            }
            .sorted { $0.document.relativePath < $1.document.relativePath }
        let generation = beginDocumentFileOperation(continuingMoveRun: moveRunID)

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let planner = MarkdownLinkMovePlanner()
                let plan = try planner.plan(
                    moving: sourceURL,
                    to: destinationURL,
                    workspaceRootURL: workspaceURL,
                    documents: documentSnapshot
                )
                // The plan rewrites files on disk. A link the move would change in unsaved text
                // would break, so the move waits until that document is saved.
                let unsavedLinkingDocumentID = unsavedMarkdownTexts.first { document, text in
                    let rewrites = try? planner.rewrites(
                        in: text,
                        of: document,
                        moving: sourceURL,
                        to: destinationURL,
                        workspaceRootURL: workspaceURL,
                        documents: documentSnapshot
                    )
                    return rewrites?.isEmpty != true
                }?.document.id
                guard !Task.isCancelled else { return }
                await self?.finishMarkdownLinkMovePlanning(
                    plan: plan,
                    unsavedLinkingDocumentID: unsavedLinkingDocumentID,
                    request: request,
                    generation: generation
                )
            } catch {
                await self?.finishMarkdownLinkMoveFailure(error, request: request, generation: generation)
            }
        }
        return true
    }

    /// Cancels the move a link review was shown for, and the rest of its move run.
    func cancelMarkdownLinkMoveReview(id: Int) {
        guard !isBusy, let review = pendingMarkdownLinkMoveReview, review.id == id else { return }
        pendingMarkdownLinkMoveReview = nil
        cancelMoveRun(review.request.moveRunID)
    }

    func confirmMarkdownLinkMoveReview(id: Int) {
        guard !isBusy,
              let review = pendingMarkdownLinkMoveReview,
              review.id == id
        else { return }
        startMarkdownLinkMoveCommit(review)
    }

    /// Runs a planned move, or shows it for review. `unsavedLinkingDocumentID` is a document whose
    /// unsaved text links to what moves, which refuses the move as a rewritten file does.
    private func finishMarkdownLinkMovePlanning(
        plan: MarkdownLinkMovePlan,
        unsavedLinkingDocumentID: String?,
        request: WorkspaceMarkdownLinkMoveRequest,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }
        if let unsaved = unsavedDocumentRewritten(by: plan) ?? unsavedLinkingDocumentID.flatMap(document(id:)) {
            refuseMove(of: unsaved, request: request)
            return
        }

        markdownLinkMoveReviewSerial &+= 1
        let review = MarkdownLinkMoveReviewState(
            id: markdownLinkMoveReviewSerial,
            plan: plan,
            request: request
        )
        if plan.rewriteCount == 0 {
            startMarkdownLinkMoveCommit(review)
        } else {
            pendingMarkdownLinkMoveReview = review
            isBusy = false
        }
    }

    private func startMarkdownLinkMoveCommit(_ review: MarkdownLinkMoveReviewState) {
        guard writingToolsDocumentID == nil else {
            errorMessage = "Finish Writing Tools before confirming this move."
            return
        }
        guard workspaceURL?.standardizedFileURL == review.request.workspaceURL else {
            pendingMarkdownLinkMoveReview = nil
            isBusy = false
            errorMessage = "\(review.request.failureMessage): The workspace changed before the move was confirmed."
            return
        }
        if let unsaved = unsavedDocumentRewritten(by: review.plan) {
            refuseMove(of: unsaved, request: review.request)
            return
        }

        noteInternalFileMutation()
        let generation = beginDocumentFileOperation(continuingMoveRun: review.request.moveRunID)
        let reviewedPlan = review.plan
        let request = review.request

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            var receipt: WorkspaceMarkdownLinkMoveReceipt?
            do {
                let currentResult = try await Self.scanWorkspace(
                    request.workspaceURL,
                    scanner: scanner
                )
                let currentPlan = try MarkdownLinkMovePlanner().plan(
                    moving: reviewedPlan.sourceURL,
                    to: reviewedPlan.destinationURL,
                    workspaceRootURL: request.workspaceURL,
                    documents: currentResult.documents
                )
                guard currentPlan == reviewedPlan else {
                    throw WorkspaceMarkdownLinkMoveError.staleReview
                }
                try Task.checkCancellation()

                let committed = try Self.commitMarkdownLinkMove(
                    reviewedPlan,
                    workspaceURL: request.workspaceURL
                )
                receipt = committed
                try Task.checkCancellation()
                let result = try await Self.scanWorkspace(
                    request.workspaceURL,
                    scanner: scanner
                )
                try Task.checkCancellation()

                let applied = await self?.finishMarkdownLinkMove(
                    result: result,
                    plan: reviewedPlan,
                    receipt: committed,
                    request: request,
                    generation: generation
                ) ?? false
                guard applied else {
                    if let receipt {
                        try Self.rollbackMarkdownLinkMove(receipt)
                    }
                    return
                }
            } catch {
                let finalError: Error
                if let receipt {
                    do {
                        try Self.rollbackMarkdownLinkMove(receipt)
                        finalError = error
                    } catch let rollbackError {
                        finalError = WorkspaceMarkdownLinkMoveError.rollbackFailed(
                            operation: error.localizedDescription,
                            rollback: rollbackError.localizedDescription
                        )
                    }
                } else {
                    finalError = error
                }
                await self?.finishMarkdownLinkMoveFailure(finalError, request: request, generation: generation)
            }
        }
    }

    /// A document with unsaved changes whose file the move would rewrite to update its links. A
    /// moved document whose links stay as they are keeps its unsaved changes at its new path.
    private func unsavedDocumentRewritten(by plan: MarkdownLinkMovePlan) -> WorkspaceDocument? {
        plan.rewriteFiles
            .lazy
            .compactMap { self.document(id: $0.originalURL.standardizedFileURL.path) }
            .first { !self.saveState(for: $0.id).isClean }
    }

    /// Refuses a move that would rewrite the links in a document with unsaved changes. A step of
    /// a move run is reported when the run ends, and the run goes on.
    private func refuseMove(of unsavedDocument: WorkspaceDocument, request: WorkspaceMarkdownLinkMoveRequest) {
        pendingMarkdownLinkMoveReview = nil
        isBusy = false
        let error = WorkspaceMarkdownLinkMoveError.unsavedLinkingDocument(unsavedDocument.displayName)
        if !skipFailedMoveRunStep(request.moveRunID, reason: Self.notMovedMessage(request.itemName, error)) {
            errorMessage = error.errorDescription
        }
    }

    /// Reports a rename or move that failed. A step of a move run is reported when the run ends,
    /// and the run goes on.
    private func finishMarkdownLinkMoveFailure(
        _ error: Error,
        request: WorkspaceMarkdownLinkMoveRequest,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }
        setDocumentLoadingIfChanged(false)
        if !skipFailedMoveRunStep(request.moveRunID, reason: Self.notMovedMessage(request.itemName, error)) {
            finishWorkspaceFailure(error, generation: generation, message: request.failureMessage)
        }
    }

    private func finishMarkdownLinkMove(
        result: WorkspaceDocumentScanResult,
        plan: MarkdownLinkMovePlan,
        receipt: WorkspaceMarkdownLinkMoveReceipt,
        request: WorkspaceMarkdownLinkMoveRequest,
        generation: Int
    ) -> Bool {
        guard generation == workspaceGeneration,
              request.workspaceURL == workspaceURL?.standardizedFileURL
        else { return false }

        let sourcePath = plan.sourceURL.standardizedFileURL.path
        let destinationPath = plan.destinationURL.standardizedFileURL.path
        for mapping in request.mappings {
            moveDirtyState(from: mapping.sourceID, to: mapping.destinationID)
        }
        publishItemMove(from: sourcePath, to: destinationPath, mappings: request.mappings)
        followSidebarSelection(afterMoving: sourcePath, to: destinationPath)
        if let completedTransfer = request.completedTransfer {
            completeTransfer(completedTransfer)
        }
        if let transfer = pendingDocumentTransfer {
            pendingDocumentTransfer = transfer.following(movedItemAt: sourcePath, to: destinationPath)
        }

        let rewrittenPaths = plan.rewriteFiles.flatMap {
            [$0.originalURL.standardizedFileURL.path, $0.finalURL.standardizedFileURL.path]
        }
        endReplaceUndo(ifTouching: [sourcePath] + rewrittenPaths)
        invalidateWorkspaceSearchCaches(
            paths: request.mappings.flatMap { [$0.sourceID, $0.destinationID] } + rewrittenPaths
        )

        let selectedDocumentWasRewritten = request.preserveSelection.map { selectedID in
            plan.rewriteFiles.contains {
                $0.originalURL.standardizedFileURL.path == selectedID
            }
        } ?? false
        finishWorkspaceLoad(
            result: result,
            workspaceURL: request.workspaceURL,
            selectedURL: request.selectedURL,
            preserveSelection: request.preserveSelection,
            reloadSelection: request.reloadSelection || selectedDocumentWasRewritten,
            sidebarSelection: request.sidebarSelection,
            generation: generation
        )
        remapRecentDocuments(request.mappings)

        let undoStep = WorkspaceFileOperationStep.move(WorkspaceFileMoveStep(
            sourceURL: plan.sourceURL.standardizedFileURL,
            destinationURL: plan.destinationURL.standardizedFileURL,
            isDirectory: plan.sourceStamp.isDirectory,
            usedCaseOnlyRenameHop: receipt.usedCaseOnlyRenameHop,
            rewrittenFiles: receipt.writtenFiles.map {
                WorkspaceFileMoveRewrite(
                    originalURL: $0.originalURL.standardizedFileURL,
                    finalURL: $0.url.standardizedFileURL,
                    originalRevision: $0.originalRevision,
                    writtenRevision: $0.writtenRevision
                )
            }
        ))
        if let runID = request.moveRunID, moveRun?.id == runID {
            moveRun?.undoSteps.append(undoStep)
            moveRun?.movedCount += 1
            continueMoveRun(runID)
        } else {
            recordFileOperation(request.undoVerb, steps: [undoStep])
        }
        return true
    }

    /// Keeps the Recents entries of renamed or moved documents, at their new paths.
    private func remapRecentDocuments(_ mappings: [WorkspaceDocumentIDMapping]) {
        guard let workspaceURL else { return }
        let movedDocuments = Dictionary(
            mappings.compactMap { mapping in documentsByID[mapping.destinationID].map { (mapping.sourceID, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        guard !movedDocuments.isEmpty,
              recentDocumentStore.remap(movedDocuments, workspaceURL: workspaceURL)
        else { return }
        recentDocumentChangeSerial &+= 1
    }

    // MARK: Undo and redo of moves and copies (design.md §10.4)

    /// Whether Edit › Undo can take back the last move or copy now.
    var canUndoFileOperation: Bool {
        fileOperationHistory.nextUndo != nil && canRunFileOperationHistory
    }

    /// Whether Edit › Redo can make the last undone move or copy again now.
    var canRedoFileOperation: Bool {
        fileOperationHistory.nextRedo != nil && canRunFileOperationHistory
    }

    /// Nothing runs, and no move waits for its link review or for the move before it.
    private var canRunFileOperationHistory: Bool {
        workspaceURL != nil
            && !isBusy
            && pendingMarkdownLinkMoveReview == nil
            && moveRun == nil
            && writingToolsDocumentID == nil
    }

    func undoFileOperation() {
        runFileOperationHistory(.undo)
    }

    func redoFileOperation() {
        runFileOperationHistory(.redo)
    }

    /// A new move or copy goes on top of Edit › Undo and ends what Redo held.
    private func recordFileOperation(_ verb: WorkspaceFileOperationVerb, steps: [WorkspaceFileOperationStep]) {
        guard !steps.isEmpty, let workspaceURL else { return }
        workspaceUndoSerial &+= 1
        fileOperationHistory.record(WorkspaceFileOperation(
            verb: verb,
            steps: steps,
            workspaceURL: workspaceURL.standardizedFileURL,
            serial: workspaceUndoSerial
        ))
        publishFileOperationUndoState()
    }

    private func publishFileOperationUndoState() {
        let nextUndo = fileOperationHistory.nextUndo
        let state = WorkspaceFileOperationUndoState(
            undoActionName: nextUndo?.actionName,
            redoActionName: fileOperationHistory.nextRedo?.actionName,
            undoPrecedesWorkspaceReplace: nextUndo.map { replaceUndoSnapshot == nil || $0.serial > replaceUndoSerial } ?? false
        )
        if fileOperationUndo != state {
            fileOperationUndo = state
        }
    }

    /// Undoes or redoes the newest operation of that stack, as one step. It first refuses what
    /// would lose unsaved text; on disk, each of its moves and copies checks that the disk still
    /// matches what the operation left and is refused otherwise, putting back what it had done.
    /// An operation the disk no longer matches leaves the history.
    private func runFileOperationHistory(_ direction: WorkspaceFileOperationDirection) {
        guard let workspaceURL = workspaceURL?.standardizedFileURL,
              let operation = direction == .undo ? fileOperationHistory.nextUndo : fileOperationHistory.nextRedo
        else { return }
        let verb = direction == .undo ? "undo" : "redo"
        guard pendingMarkdownLinkMoveReview == nil, moveRun == nil else {
            errorMessage = Self.busyMessage
            return
        }
        guard ensureNotBusy(), ensureWritingToolsInactive(for: "\(verb)ing a file operation") else { return }
        let failureMessage = "Could not \(verb) \(operation.actionName)"
        if let reason = fileOperationRefusal(operation, direction) {
            errorMessage = "\(failureMessage): \(reason)"
            return
        }

        let effect = fileOperationEffect(operation, direction)
        var unsavedCopyTexts: [String: [WorkspaceUnsavedCopyText]] = [:]
        if direction == .redo {
            for case .copy(let copy) in operation.steps {
                let sourcePath = copy.sourceURL.standardizedFileURL.path
                unsavedCopyTexts[sourcePath] = unsavedTexts(inItemAt: sourcePath)
                    .map { WorkspaceUnsavedCopyText(subpath: $0.subpath, text: $0.text) }
            }
        }
        let disk = WorkspaceFileOperationDisk(
            workspaceURL: workspaceURL,
            moveItemToTrash: moveItemToTrash,
            unsavedCopyTexts: unsavedCopyTexts,
            unsavedMarkdown: dirtyDocumentTexts.compactMap { documentID, text in
                documentsByID[documentID].flatMap { $0.kind == .markdown ? WorkspaceUnsavedMarkdown(document: $0, text: text) : nil }
            },
            documents: documents
        )
        noteInternalFileMutation()
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            var made: WorkspaceFileOperation?
            do {
                let applied = try disk.apply(operation, direction)
                made = applied
                try Task.checkCancellation()
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                try Task.checkCancellation()
                let taken = await self?.finishFileOperationHistory(
                    result: result,
                    operation: applied,
                    direction: direction,
                    effect: effect,
                    generation: generation
                ) ?? false
                if !taken {
                    // The store moved on (another workspace) or cannot show the result: the disk goes
                    // back as it was, and a store still waiting on this step is told it ended.
                    made = nil
                    try disk.rollBack(applied, after: direction)
                    await self?.finishFileOperationHistoryFailure(
                        CancellationError(),
                        direction: direction,
                        message: failureMessage,
                        generation: generation
                    )
                }
            } catch {
                var finalError = error
                if let made {
                    do {
                        try disk.rollBack(made, after: direction, failure: error)
                    } catch let rollbackError {
                        finalError = rollbackError
                    }
                }
                await self?.finishFileOperationHistoryFailure(
                    finalError,
                    direction: direction,
                    message: failureMessage,
                    generation: generation
                )
            }
        }
    }

    /// Why the operation cannot be undone or redone without losing unsaved text: it would rewrite
    /// the links in a document with unsaved changes, put a copy with unsaved changes in the
    /// Trash, or take one out of the workspace.
    private func fileOperationRefusal(
        _ operation: WorkspaceFileOperation,
        _ direction: WorkspaceFileOperationDirection
    ) -> String? {
        let doing = direction == .undo ? "undoing" : "redoing"
        for step in operation.steps {
            // Nothing an undo or redo moves or makes may take the name of a removed note whose
            // unsaved text is still open, as the operation itself could not.
            let landing: URL? = switch (step, direction) {
            case (.move(let move), .undo): move.sourceURL
            case (.move(let move), .redo): move.destinationURL
            case (.copy(let copy), .redo): copy.copyURL
            case (.trash(let trash), .undo): trash.originalURL
            default: nil
            }
            if let landing, let kept = keptUnsavedDocument(inItemAt: landing) {
                return WorkspaceDocumentOperationError.keepsUnsavedText(kept.displayName).localizedDescription
            }
            switch step {
            case .move(let move):
                for rewrite in move.rewrittenFiles {
                    let path = (direction == .undo ? rewrite.finalURL : rewrite.originalURL).standardizedFileURL.path
                    if let document = document(id: path), !saveState(for: path).isClean {
                        return "Save \(document.displayName) first: \(doing) this move updates the links in it."
                    }
                }
                let (fromURL, toURL) = direction == .undo
                    ? (move.destinationURL, move.sourceURL)
                    : (move.sourceURL, move.destinationURL)
                if !isInsideWorkspace(toURL), let unsaved = unsavedDocument(at: fromURL) {
                    return "Save or close \(unsaved.displayName) first: \(doing) this move takes it out of the workspace."
                }
            case .copy(let copy):
                if direction == .undo, let unsaved = unsavedDocument(at: copy.copyURL) {
                    return "Save or close \(unsaved.displayName) first: undoing the copy moves it to the Trash."
                }
            case .trash(let trash):
                if direction == .redo, let unsaved = unsavedDocument(at: trash.originalURL) {
                    return "Save or close \(unsaved.displayName) first: redoing moves it to the Trash."
                }
            }
        }
        return nil
    }

    /// Whether `url` is inside the workspace, not the workspace itself.
    private func isInsideWorkspace(_ url: URL) -> Bool {
        guard let workspaceURL else { return false }
        let url = url.standardizedFileURL
        return url != workspaceURL.standardizedFileURL && WorkspaceDocumentSupport.isURL(url, containedIn: workspaceURL)
    }

    /// What an undo or redo changes for this window, worked out before the disk changes: the items
    /// it moves within the workspace and the documents that move with them, what leaves the
    /// workspace, the notes whose links it rewrites, and the item the sidebar shows landing.
    private func fileOperationEffect(
        _ operation: WorkspaceFileOperation,
        _ direction: WorkspaceFileOperationDirection
    ) -> WorkspaceFileOperationEffect {
        var effect = WorkspaceFileOperationEffect()
        let steps = direction == .undo ? Array(operation.steps.reversed()) : operation.steps
        for step in steps {
            switch step {
            case .move(let move):
                let (fromURL, toURL) = direction == .undo
                    ? (move.destinationURL, move.sourceURL)
                    : (move.sourceURL, move.destinationURL)
                effect.changedPaths += [fromURL.path, toURL.path]
                for rewrite in move.rewrittenFiles {
                    let currentURL = direction == .undo ? rewrite.finalURL : rewrite.originalURL
                    effect.rewrittenDocumentIDs.insert(currentURL.standardizedFileURL.path)
                    effect.changedPaths += [rewrite.originalURL.path, rewrite.finalURL.path]
                }
                switch (isInsideWorkspace(fromURL), isInsideWorkspace(toURL)) {
                case (true, true):
                    let mappings = Self.documentIDMappings(forMoving: fromURL, to: toURL, documents: documents)
                    effect.itemMoves.append(WorkspaceItemMoveRemap(
                        sourcePath: fromURL.standardizedFileURL.path,
                        destinationPath: toURL.standardizedFileURL.path,
                        mappings: mappings
                    ))
                    effect.changedPaths += mappings.flatMap { [$0.sourceID, $0.destinationID] }
                    effect.landingItemID = toURL.standardizedFileURL.path
                case (true, false):
                    effect.removedPaths.append(fromURL.standardizedFileURL.path)
                case (false, _):
                    effect.landingItemID = toURL.standardizedFileURL.path
                }
            case .copy(let copy):
                effect.changedPaths.append(copy.copyURL.path)
                if direction == .undo {
                    effect.removedPaths.append(copy.copyURL.standardizedFileURL.path)
                } else {
                    effect.createdCopies.append(copy)
                    effect.landingItemID = copy.copyURL.standardizedFileURL.path
                }
            case .trash(let trash):
                let path = trash.originalURL.standardizedFileURL.path
                effect.changedPaths.append(path)
                if direction == .undo {
                    effect.restoredPaths.append(path)
                    effect.landingItemID = path
                } else {
                    effect.removedPaths.append(path)
                }
            }
        }
        return effect
    }

    /// Shows what an undo or redo did as the operation itself showed it: open tabs, unsaved text,
    /// the selection and Recents follow a moved item; a copy made again is selected; and the item
    /// lands in the sidebar.
    private func finishFileOperationHistory(
        result: WorkspaceDocumentScanResult,
        operation: WorkspaceFileOperation,
        direction: WorkspaceFileOperationDirection,
        effect: WorkspaceFileOperationEffect,
        generation: Int
    ) -> Bool {
        guard generation == workspaceGeneration,
              operation.workspaceURL == workspaceURL?.standardizedFileURL
        else { return false }

        let previousSelection = selectedDocumentID
        let isRemoved = { (path: String) in
            effect.removedPaths.contains { WorkspaceDocumentSupport.isPath(path, containedIn: $0) }
        }
        let selectionIsRemoved = previousSelection.map(isRemoved) ?? false
        // Selected items that go leave the selection; nothing is selected once all of them go.
        let selectedIDs = sidebarSelectionIDs
        let sidebarSelectionIsRemoved = !selectedIDs.isEmpty && selectedIDs.allSatisfy(isRemoved)
        let selectedDocumentWasRewritten = previousSelection.map(effect.rewrittenDocumentIDs.contains) ?? false
        let movedSelection = previousSelection.map { selection in
            effect.itemMoves.reduce(selection) {
                Self.path($0, afterMoving: $1.sourcePath, to: $1.destinationPath)
            }
        }

        for move in effect.itemMoves {
            for mapping in move.mappings {
                moveDirtyState(from: mapping.sourceID, to: mapping.destinationID)
            }
            followSidebarSelection(afterMoving: move.sourcePath, to: move.destinationPath)
            if let transfer = pendingDocumentTransfer {
                pendingDocumentTransfer = transfer.following(movedItemAt: move.sourcePath, to: move.destinationPath)
            }
        }
        if !effect.itemMoves.isEmpty {
            publishItemMoves(effect.itemMoves)
        }
        invalidateWorkspaceSearchCaches(paths: effect.changedPaths)
        endReplaceUndo(ifTouching: effect.itemMoves.map(\.sourcePath) + effect.removedPaths + effect.rewrittenDocumentIDs)

        switch direction {
        case .undo:
            fileOperationHistory.didUndo()
        case .redo:
            workspaceUndoSerial &+= 1
            fileOperationHistory.didRedo(serial: workspaceUndoSerial, redone: operation)
        }
        publishFileOperationUndoState()

        var selectedURL = movedSelection.flatMap { $0 != previousSelection ? URL(fileURLWithPath: $0) : nil }
        var sidebarSelection: SidebarSelectionAfterLoad = sidebarSelectionIsRemoved ? .cleared : .unchanged
        // Copies made again are selected as the copy first selected them: one file opens and one
        // folder is selected; several are selected in the sidebar, none opened.
        if !effect.restoredPaths.isEmpty {
            // Items back from the Trash are selected, none opened.
            sidebarSelection = .items(effect.restoredPaths)
        } else if effect.createdCopies.count > 1 {
            sidebarSelection = .items(effect.createdCopies.map(\.copyURL.standardizedFileURL.path))
        } else if let copy = effect.createdCopies.first {
            if copy.isDirectory {
                sidebarSelection = .folder(copy.copyURL)
            } else {
                selectedURL = copy.copyURL
                sidebarSelection = .document
            }
        }
        finishWorkspaceLoad(
            result: result,
            workspaceURL: operation.workspaceURL,
            selectedURL: selectedURL,
            preserveSelection: selectionIsRemoved ? nil : previousSelection,
            reloadSelection: selectedURL != nil || selectionIsRemoved || selectedDocumentWasRewritten,
            sidebarSelection: sidebarSelection,
            generation: generation
        )
        remapRecentDocuments(effect.itemMoves.flatMap(\.mappings))
        if let itemID = effect.landingItemID {
            fileOperationLanding = WorkspaceItemLanding(
                serial: (fileOperationLanding?.serial ?? 0) &+ 1,
                itemID: itemID
            )
        }
        return true
    }

    /// Reports an undo or redo that was refused or failed. The disk has been put back as it was,
    /// and no longer matches the operation, so it leaves the history.
    private func finishFileOperationHistoryFailure(
        _ error: Error,
        direction: WorkspaceFileOperationDirection,
        message: String,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }
        let keepsOperation = error is CancellationError || (error as? WorkspaceFileOperationError)?.keepsOperation == true
        if !keepsOperation {
            fileOperationHistory.discardNext(direction)
            publishFileOperationUndoState()
        }
        if error is CancellationError {
            // Put back unseen: nothing happened, so nothing is reported.
            isBusy = false
            setDocumentLoadingIfChanged(false)
            return
        }
        finishWorkspaceFailure(error, generation: generation, message: message)
    }

    func setDocumentText(_ editedText: String) {
        guard !isBusy, selectedDocument?.capabilities.canEditText == true else { return }
        // Views and this store compare the document text on every update; native UTF-8 keeps
        // those comparisons from walking a bridged text-view string character by character.
        let text = NativeUTF8Text.copy(of: editedText)
        guard text != documentText else { return }

        let shouldAdoptExternalDiskVersion = text == lastSavedText
            && selectedDocumentExternalChange
        clearReplaceUndoSnapshot()
        setDocumentTextIfChanged(text)
        setHasUnsavedChangesIfChanged(text != lastSavedText)
        updateSaveStateForSelectedDocument()
        publishWorkspaceSearchContentChange()

        if shouldAdoptExternalDiskVersion, let selectedDocumentID {
            cancelExternalDocumentReview()
            discardUnsavedChangesWithoutWritingToolsGuard(for: selectedDocumentID)
        }
    }

    @discardableResult
    func setWritingToolsActive(_ isActive: Bool, documentID: String) -> Bool {
        if isActive {
            guard writingToolsDocumentID == nil,
                  !isBusy,
                  selectedDocumentID == documentID,
                  selectedDocument?.capabilities.canEditText == true
            else { return false }

            objectWillChange.send()
            writingToolsDocumentID = documentID
            if externalRefreshWorkItem != nil || externalRefreshTask != nil {
                deferExternalRefreshUntilWritingToolsEnd()
            }
            externalRefreshGeneration &+= 1
            externalRefreshWorkItem?.cancel()
            externalRefreshWorkItem = nil
            externalRefreshTask?.cancel()
            externalRefreshTask = nil
            markdownImageAssetTask?.cancel()
            markdownImageAssetTask = nil
            cancelExternalDocumentReview()
            return true
        }

        guard writingToolsDocumentID == documentID else { return false }
        objectWillChange.send()
        writingToolsDocumentID = nil
        guard deferredWritingToolsRefreshNeeded else { return true }
        guard let workspaceURL else { return true }
        scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [workspaceURL.path],
            modifiedOnlyPaths: [],
            requiresFullRescan: true
        ), bypassingSuppression: true)
        return true
    }

    func commitWritingToolsText(_ committedText: String, documentID: String) {
        guard writingToolsDocumentID == documentID,
              selectedDocumentID == documentID,
              let document = document(id: documentID),
              document.capabilities.canEditText
        else { return }
        let text = NativeUTF8Text.copy(of: committedText)
        guard text != documentText else { return }

        if (try? WorkspaceConditionalTextWriter.read(from: document.url))?.text != lastSavedText {
            setSelectedDocumentExternalChangeIfChanged(true)
        }
        clearReplaceUndoSnapshot()
        setDocumentTextIfChanged(text)
        setHasUnsavedChangesIfChanged(text != lastSavedText || selectedDocumentExternalChange)
        updateSaveStateForSelectedDocument()
        publishWorkspaceSearchContentChange()
    }

    @discardableResult
    func applyTextMutation(
        documentID: String,
        range: NSRange,
        expectedText: String,
        replacement: String
    ) -> WorkspaceTextMutation? {
        guard writingToolsDocumentID != documentID else { return nil }
        guard selectedDocumentID == documentID,
              selectedDocument?.capabilities.canEditText == true
        else { return nil }

        let current = documentText as NSString
        guard range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= current.length,
              current.substring(with: range) == expectedText
        else { return nil }

        let updated = current.replacingCharacters(in: range, with: replacement)
        setDocumentText(updated)
        return WorkspaceTextMutation(
            documentID: documentID,
            range: NSRange(location: range.location, length: (replacement as NSString).length),
            expectedText: replacement,
            replacement: expectedText
        )
    }

    func dirtyPDFData(for documentID: String) -> Data? {
        dirtyPDFDocumentData[documentID]
    }

    func dirtyPDFEditVersion(for documentID: String) -> Int? {
        dirtyPDFDocumentVersions[documentID]
    }

    func pdfContentVersion(for documentID: String) -> Int {
        pdfDocumentContentVersions[documentID] ?? 0
    }

    func pdfSavedEditCheckpoint(for documentID: String) -> PDFAnnotationEditCheckpoint? {
        pdfDocumentSavedEditCheckpoints[documentID]
    }

    var dirtyPDFDataByDocumentID: [String: Data] {
        dirtyPDFDocumentData
    }

    var dirtyTextByDocumentID: [String: String] {
        dirtyDocumentTexts
    }

    func markPDFDocumentEdited(
        id documentID: String,
        previousData: Data?,
        data: Data?,
        editCheckpoint: PDFAnnotationEditCheckpoint? = nil
    ) {
        guard let file = document(id: documentID), file.kind.opensInPDFViewer else { return }
        guard let data else {
            errorMessage = "Could not prepare PDF annotation data."
            return
        }

        if pdfDocumentBaselines[documentID] == nil {
            guard let previousData else {
                errorMessage = "Could not safely apply PDF annotations because the original PDF contents are unavailable."
                if selectedDocumentID == documentID {
                    publishPDFContentReplacement(for: documentID)
                }
                return
            }
            pdfDocumentBaselines[documentID] = previousData
        }
        if file.kind == .image, imageMarkupSources[documentID] == nil {
            imageMarkupSources[documentID] = pdfDocumentBaselines[documentID]
        }

        applyPDFData(data, editCheckpoint: editCheckpoint, to: file)
    }

    @discardableResult
    func restorePDFSavedEditCheckpoint(
        id documentID: String,
        checkpoint: PDFAnnotationEditCheckpoint
    ) -> Bool {
        guard pdfDocumentSavedEditCheckpoints[documentID] == checkpoint,
              let file = document(id: documentID),
              file.kind.opensInPDFViewer,
              let baseline = pdfDocumentBaselines[documentID]
        else { return false }

        guard let diskData = try? Data(contentsOf: file.url), diskData == baseline else {
            reportPDFViewerDiskConflict(file)
            return false
        }

        applyPDFData(baseline, editCheckpoint: checkpoint, to: file)
        return dirtyPDFDocumentData[documentID] == nil
    }

    func reportPDFAnnotationError(_ message: String) {
        errorMessage = message
    }

    func exportPDFAnnotationsToMarkdown(for document: WorkspaceDocument) {
        guard let workspaceURL else {
            errorMessage = "Open a workspace before exporting PDF annotations."
            return
        }
        // Starting an export cancels the running operation, which would drop its undo step.
        guard ensureNotBusy() else { return }
        guard document.kind == .pdf else {
            errorMessage = WorkspaceDocumentOperationError.unsupportedPDFAnnotationExport(document.displayName).localizedDescription
            return
        }
        guard let pdfData = currentPDFData(for: document) else {
            errorMessage = "Could not read \(document.displayName)."
            return
        }

        noteInternalFileMutation()
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                let notesURL = workspaceURL.appendingPathComponent("notes", isDirectory: true)
                try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)

                let markdown = try PDFAnnotationMarkdownExportService().exportMarkdown(
                    from: pdfData,
                    documentName: document.displayName,
                    relativePath: document.relativePath
                )
                let destinationURL = WorkspaceDocumentSupport.availableCopyURL(
                    named: "\(document.url.deletingPathExtension().lastPathComponent) Annotations.md",
                    isDirectory: false,
                    in: notesURL
                )
                try Self.writeNewFile(markdown, to: destinationURL)

                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishCreatedFile(
                    result: result,
                    fileURL: destinationURL,
                    workspaceURL: workspaceURL,
                    initialText: markdown,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not export PDF annotations")
            }
        }
    }

    func exportAllPDFAnnotationsToMarkdown() {
        guard ensureWritingToolsInactive(for: "exporting PDF annotations") else { return }
        guard let workspaceURL else {
            errorMessage = "Open a workspace before exporting PDF annotations."
            return
        }
        guard ensureNotBusy() else { return }

        let exportItems = documents
            .filter { $0.kind == .pdf }
            .compactMap { document -> PDFAnnotationMarkdownExportItem? in
                guard let data = currentPDFData(for: document) else { return nil }
                return PDFAnnotationMarkdownExportItem(
                    data: data,
                    documentName: document.displayName,
                    relativePath: document.relativePath
                )
            }

        guard !exportItems.isEmpty else {
            errorMessage = "No PDF documents found in this workspace."
            return
        }

        noteInternalFileMutation()
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                let notesURL = workspaceURL.appendingPathComponent("notes", isDirectory: true)
                try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)

                let markdown = try PDFAnnotationMarkdownExportService().exportMarkdown(
                    from: exportItems,
                    title: "Workspace PDF Annotations"
                )
                let destinationURL = WorkspaceDocumentSupport.availableCopyURL(
                    named: "Workspace PDF Annotations.md",
                    isDirectory: false,
                    in: notesURL
                )
                try Self.writeNewFile(markdown, to: destinationURL)

                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishCreatedFile(
                    result: result,
                    fileURL: destinationURL,
                    workspaceURL: workspaceURL,
                    initialText: markdown,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not export PDF annotations")
            }
        }
    }

    func exportAnnotatedPDFCopy(for document: WorkspaceDocument) {
        guard let workspaceURL else {
            errorMessage = "Open a workspace before exporting annotated PDF."
            return
        }
        guard ensureNotBusy() else { return }
        guard document.kind == .pdf else {
            errorMessage = WorkspaceDocumentOperationError.unsupportedPDFAnnotationExport(document.displayName).localizedDescription
            return
        }
        guard let pdfData = currentPDFData(for: document) else {
            errorMessage = "Could not read \(document.displayName)."
            return
        }

        noteInternalFileMutation()
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                let exportsURL = workspaceURL.appendingPathComponent("exports", isDirectory: true)
                try FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)

                let destinationURL = WorkspaceDocumentSupport.availableCopyURL(
                    named: "\(document.url.deletingPathExtension().lastPathComponent) Annotated.pdf",
                    isDirectory: false,
                    in: exportsURL
                )
                try WorkspaceConditionalDataWriter.write(
                    pdfData,
                    to: destinationURL,
                    expecting: .absent
                )

                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishCreatedFile(
                    result: result,
                    fileURL: destinationURL,
                    workspaceURL: workspaceURL,
                    initialText: "",
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not export annotated PDF")
            }
        }
    }

    func saveSelectedFile() {
        guard let selectedDocument else { return }
        // A file operation may be moving this file; the text stays unsaved until it ends.
        guard !isBusy else {
            errorMessage = Self.busyMessage
            return
        }

        guard writingToolsDocumentID != selectedDocument.id else {
            errorMessage = "Finish Writing Tools before saving \(selectedDocument.displayName)."
            return
        }

        if selectedDocument.kind.opensInPDFViewer {
            saveSelectedPDF(selectedDocument)
            return
        }

        guard selectedDocument.capabilities.canEditText else { return }
        // A clean document has nothing to save.
        guard !saveState(for: selectedDocument.id).isClean else { return }

        let file = selectedDocument
        let text = documentText
        guard let expectation = textWriteExpectation(for: file.id) else {
            setSelectedDocumentExternalChangeIfChanged(true)
            errorMessage = "Review the disk changes before saving \(file.displayName)."
            return
        }
        saveGeneration += 1
        let generation = saveGeneration
        setSaveState(.saving, for: file.id)
        setSavingIfChanged(true)
        noteInternalFileMutation()

        saveTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let writtenRevision = try WorkspaceConditionalTextWriter.write(
                    text,
                    to: file.url,
                    expecting: expectation
                )
                guard !Task.isCancelled else { return }
                await self?.finishSave(
                    fileID: file.id,
                    text: text,
                    writtenRevision: writtenRevision,
                    generation: generation
                )
            } catch {
                await self?.finishSaveFailure(error, file: file, generation: generation)
            }
        }
    }

    @discardableResult
    func saveDocument(id documentID: String) async -> Bool {
        guard let file = document(id: documentID) else { return false }
        guard !isBusy else {
            errorMessage = Self.busyMessage
            return false
        }
        guard writingToolsDocumentID != documentID else {
            errorMessage = "Finish Writing Tools before saving \(file.displayName)."
            return false
        }
        guard !saveState(for: documentID).isClean else { return true }

        if file.kind.opensInPDFViewer {
            return await savePDFDocument(file)
        }

        guard file.capabilities.canEditText else { return true }

        let text = selectedDocumentID == file.id ? documentText : dirtyDocumentTexts[file.id]
        guard let text else { return true }
        guard let expectation = textWriteExpectation(for: file.id) else {
            if selectedDocumentID == file.id {
                setSelectedDocumentExternalChangeIfChanged(true)
            }
            errorMessage = "Review the disk changes before saving \(file.displayName)."
            return false
        }

        saveGeneration += 1
        let generation = saveGeneration
        setSaveState(.saving, for: file.id)
        setSavingIfChanged(true)
        noteInternalFileMutation()

        do {
            let writtenRevision = try await Task.detached(priority: .utility) {
                try WorkspaceConditionalTextWriter.write(
                    text,
                    to: file.url,
                    expecting: expectation
                )
            }.value
            finishSave(
                fileID: file.id,
                text: text,
                writtenRevision: writtenRevision,
                generation: generation
            )
            return saveState(for: file.id).isClean
        } catch {
            finishSaveFailure(error, file: file, generation: generation)
            return false
        }
    }

    /// Saves dirty documents sequentially in the caller's stable order.
    /// Returns the first document that could not be saved; earlier saves stay
    /// committed and later documents remain untouched.
    func saveDocumentsInOrder(_ documentIDs: [String]) async -> String? {
        for documentID in documentIDs where !saveState(for: documentID).isClean {
            guard let file = document(id: documentID) else {
                errorMessage = "Could not save \(URL(fileURLWithPath: documentID).lastPathComponent): the document is no longer available."
                return documentID
            }
            guard await saveDocument(id: documentID) else {
                if errorMessage == nil {
                    errorMessage = "Could not save \(file.displayName). It remains unsaved."
                }
                return documentID
            }
        }
        return nil
    }

    var isSelectedDocumentRemovedExternally: Bool {
        guard let selectedDocumentID else { return false }
        return removedDirtyOpenDocumentIDs.contains(selectedDocumentID)
    }

    func prepareExternalDocumentReview() {
        guard let document = selectedDocument,
              writingToolsDocumentID != document.id,
              document.capabilities.canEditText,
              let localText = dirtyDocumentTexts[document.id] ?? (hasUnsavedChanges ? documentText : nil)
        else { return }

        externalReviewTask?.cancel()
        externalReviewGeneration &+= 1
        let generation = externalReviewGeneration
        let documentID = document.id
        let displayName = document.displayName
        let baselineText = dirtyDocumentBaselines[documentID] ?? lastSavedText
        let url = document.url

        externalReviewTask = Task.detached(priority: .userInitiated) { [weak self] in
            let revision: WorkspaceTextRevision?
            do {
                revision = try Self.externalTextRevision(at: url)
            } catch {
                await self?.finishExternalReviewFailure(
                    error,
                    documentID: documentID,
                    generation: generation
                )
                return
            }
            guard !Task.isCancelled else { return }
            let review = ExternalDocumentReconciliationService.review(
                baselineText: baselineText,
                localText: localText,
                diskRevision: revision
            )
            await self?.finishExternalReview(
                ExternalDocumentReviewState(
                    documentID: documentID,
                    displayName: displayName,
                    review: review,
                    diskToMineDiff: ExternalDocumentReconciliationService.unifiedDiff(
                        from: revision?.text ?? "",
                        to: localText
                    )
                ),
                generation: generation
            )
        }
    }

    func cancelExternalDocumentReview() {
        externalReviewGeneration &+= 1
        externalReviewTask?.cancel()
        externalReviewTask = nil
        externalDocumentReview = nil
    }

    func resolveExternalDocumentReview(_ resolution: ExternalDocumentResolution) {
        guard let state = externalDocumentReview,
              let document = document(id: state.documentID),
              writingToolsDocumentID != state.documentID
        else { return }

        let expectedDiskRevision = state.review.diskRevision
        let url = document.url
        externalReviewGeneration &+= 1
        let generation = externalReviewGeneration
        externalReviewTask?.cancel()

        externalReviewTask = Task.detached(priority: .userInitiated) { [weak self] in
            let currentDiskRevision: WorkspaceTextRevision?
            do {
                currentDiskRevision = try Self.externalTextRevision(at: url)
            } catch {
                await self?.finishExternalReviewFailure(
                    error,
                    documentID: state.documentID,
                    generation: generation
                )
                return
            }

            guard !Task.isCancelled else { return }
            guard currentDiskRevision == expectedDiskRevision else {
                await self?.refreshStaleExternalReview(
                    state: state,
                    currentDiskRevision: currentDiskRevision,
                    generation: generation
                )
                return
            }
            await self?.applyExternalDocumentResolution(
                resolution,
                state: state,
                currentDiskRevision: currentDiskRevision,
                generation: generation
            )
        }
    }

    func resolveSelectedExternalDocumentWithoutReview(_ resolution: ExternalDocumentResolution) {
        guard resolution != .merge,
              externalDocumentReview == nil,
              selectedDocumentExternalChange,
              let document = selectedDocument,
              writingToolsDocumentID != document.id,
              document.capabilities.canEditText,
              let localText = dirtyDocumentTexts[document.id] ?? (hasUnsavedChanges ? documentText : nil)
        else { return }

        let baselineText = dirtyDocumentBaselines[document.id] ?? lastSavedText
        externalReviewTask?.cancel()
        externalReviewGeneration &+= 1
        let generation = externalReviewGeneration

        externalReviewTask = Task.detached(priority: .userInitiated) { [weak self] in
            let currentDiskRevision: WorkspaceTextRevision?
            do {
                currentDiskRevision = try Self.externalTextRevision(at: document.url)
            } catch {
                await self?.finishExternalReviewFailure(
                    error,
                    documentID: document.id,
                    generation: generation
                )
                return
            }
            guard !Task.isCancelled else { return }

            let state = ExternalDocumentReviewState(
                documentID: document.id,
                displayName: document.displayName,
                review: ExternalDocumentReconciliationService.review(
                    baselineText: baselineText,
                    localText: localText,
                    diskRevision: currentDiskRevision
                ),
                diskToMineDiff: nil
            )
            await self?.applyExternalDocumentResolution(
                resolution,
                state: state,
                currentDiskRevision: currentDiskRevision,
                generation: generation
            )
        }
    }

    func saveExternalDocumentCopy(to destinationURL: URL) {
        guard selectedDocumentExternalChange,
              let document = selectedDocument,
              writingToolsDocumentID != document.id,
              document.capabilities.canEditText,
              let localText = dirtyDocumentTexts[document.id] ?? (hasUnsavedChanges ? documentText : nil)
        else { return }

        let destinationURL = destinationURL.standardizedFileURL
        guard !Self.externalCopyDestination(destinationURL, aliases: document.url) else {
            errorMessage = ExternalDocumentCopyError.sourceAlias.localizedDescription
            return
        }

        let baselineText = dirtyDocumentBaselines[document.id] ?? lastSavedText
        let reviewedState = externalDocumentReview
        externalReviewTask?.cancel()
        externalReviewGeneration &+= 1
        let generation = externalReviewGeneration

        externalReviewTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let currentDiskRevision = try Self.externalTextRevision(at: document.url)
                guard !Task.isCancelled else { return }

                if let reviewedState,
                   currentDiskRevision != reviewedState.review.diskRevision {
                    await self?.refreshStaleExternalReview(
                        state: reviewedState,
                        currentDiskRevision: currentDiskRevision,
                        generation: generation
                    )
                    return
                }

                let state = reviewedState ?? ExternalDocumentReviewState(
                    documentID: document.id,
                    displayName: document.displayName,
                    review: ExternalDocumentReconciliationService.review(
                        baselineText: baselineText,
                        localText: localText,
                        diskRevision: currentDiskRevision
                    ),
                    diskToMineDiff: nil
                )
                guard await self?.validateExternalDocumentState(
                    state,
                    currentDiskRevision: currentDiskRevision,
                    generation: generation,
                    refreshesVisibleReview: reviewedState != nil
                ) == true else { return }

                let destinationExpectation: WorkspaceDataRevisionExpectation
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    destinationExpectation = .present(try Data(contentsOf: destinationURL))
                } else {
                    destinationExpectation = .absent
                }

                guard !Task.isCancelled else { return }
                let latestDiskRevision = try Self.externalTextRevision(at: document.url)
                guard latestDiskRevision == currentDiskRevision else {
                    if let reviewedState {
                        await self?.refreshStaleExternalReview(
                            state: reviewedState,
                            currentDiskRevision: latestDiskRevision,
                            generation: generation
                        )
                    } else {
                        await self?.finishExternalCopyStale(
                            documentID: document.id,
                            generation: generation
                        )
                    }
                    return
                }
                guard !Task.isCancelled,
                      await self?.validateExternalDocumentState(
                        state,
                        currentDiskRevision: latestDiskRevision,
                        generation: generation,
                        refreshesVisibleReview: reviewedState != nil
                      ) == true
                else { return }
                guard !Self.externalCopyDestination(destinationURL, aliases: document.url) else {
                    throw ExternalDocumentCopyError.sourceAlias
                }

                try WorkspaceConditionalDataWriter.write(
                    Data(state.review.localText.utf8),
                    to: destinationURL,
                    expecting: destinationExpectation
                )
                await self?.finishExternalCopy(
                    documentID: document.id,
                    destinationURL: destinationURL,
                    generation: generation
                )
            } catch {
                await self?.finishExternalCopyFailure(
                    error,
                    documentID: document.id,
                    generation: generation
                )
            }
        }
    }

    func reloadSelectedDocumentFromDisk() {
        guard let selectedDocumentID else { return }
        discardUnsavedChanges(for: selectedDocumentID)
    }

    func discardUnsavedChanges(for documentID: String) {
        guard writingToolsDocumentID != documentID else {
            errorMessage = "Finish Writing Tools before discarding changes."
            return
        }
        discardUnsavedChangesWithoutWritingToolsGuard(for: documentID)
    }

    private func discardUnsavedChangesWithoutWritingToolsGuard(for documentID: String) {
        let isPDF = document(id: documentID)?.kind.opensInPDFViewer == true
        let hadSearchablePDFDirtyData = dirtyPDFDocumentData[documentID] != nil
        dirtyDocumentTexts.removeValue(forKey: documentID)
        dirtyDocumentBaselines.removeValue(forKey: documentID)
        dirtyDocumentRevisionExpectations.removeValue(forKey: documentID)
        pdfDocumentBaselines.removeValue(forKey: documentID)
        imageMarkupSources.removeValue(forKey: documentID)
        dirtyPDFDocumentData.removeValue(forKey: documentID)
        dirtyPDFDocumentVersions.removeValue(forKey: documentID)
        dirtyPDFDocumentEditCheckpoints.removeValue(forKey: documentID)
        pdfDocumentSavedEditCheckpoints.removeValue(forKey: documentID)
        removedDirtyDocuments.removeValue(forKey: documentID)
        setSaveState(.clean, for: documentID)
        pruneRemovedDirtyDocuments()
        if hadSearchablePDFDirtyData {
            publishWorkspaceSearchContentChange()
        }
        if isPDF {
            publishPDFContentReplacement(for: documentID)
        }

        guard selectedDocumentID == documentID else { return }
        setHasUnsavedChangesIfChanged(false)
        setSelectedDocumentExternalChangeIfChanged(false)

        if selectedDocument?.capabilities.canEditText == true {
            loadSelectedDocument()
        } else {
            setSelectedDocumentSignatureIfChanged(changeTrackedSignature(for: selectedDocument))
        }
    }

    private func saveSelectedPDF(_ file: WorkspaceDocument) {
        guard let dirtyVersion = dirtyPDFDocumentVersions[file.id],
              let pdfData = dirtyPDFDocumentData[file.id],
              let baseline = pdfDocumentBaselines[file.id] else {
            if dirtyPDFDocumentData[file.id] != nil {
                setSaveState(.failed("The original PDF could not be verified."), for: file.id)
                errorMessage = "Could not safely save \(file.displayName) because its original contents are unavailable."
            }
            return
        }
        let savedEditCheckpoint = dirtyPDFDocumentEditCheckpoints[file.id]
        let imageMarkupSource = self.imageMarkupSource(for: file, baseline: baseline)

        saveGeneration += 1
        let generation = saveGeneration
        setSaveState(.saving, for: file.id)
        setSavingIfChanged(true)
        noteInternalFileMutation()

        saveTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let writtenData = try WorkspaceConditionalDataWriter.write(
                    Self.fileData(forPDFViewerData: pdfData, imageMarkupSource: imageMarkupSource),
                    to: file.url,
                    expecting: .present(baseline)
                )
                guard !Task.isCancelled else { return }
                await self?.finishPDFSave(
                    fileID: file.id,
                    url: file.url,
                    dirtyVersion: dirtyVersion,
                    savedEditCheckpoint: savedEditCheckpoint,
                    writtenData: writtenData,
                    generation: generation
                )
            } catch {
                await self?.finishPDFSaveFailure(error, file: file, generation: generation)
            }
        }
    }

    private func savePDFDocument(_ file: WorkspaceDocument) async -> Bool {
        guard let dirtyVersion = dirtyPDFDocumentVersions[file.id],
              let pdfData = dirtyPDFDocumentData[file.id] else {
            return true
        }
        let savedEditCheckpoint = dirtyPDFDocumentEditCheckpoints[file.id]
        guard let baseline = pdfDocumentBaselines[file.id] else {
            setSaveState(.failed("The original PDF could not be verified."), for: file.id)
            errorMessage = "Could not safely save \(file.displayName) because its original contents are unavailable."
            return false
        }
        let imageMarkupSource = self.imageMarkupSource(for: file, baseline: baseline)

        saveGeneration += 1
        let generation = saveGeneration
        setSaveState(.saving, for: file.id)
        setSavingIfChanged(true)
        noteInternalFileMutation()

        do {
            let writtenData = try await Task.detached(priority: .utility) {
                try WorkspaceConditionalDataWriter.write(
                    Self.fileData(forPDFViewerData: pdfData, imageMarkupSource: imageMarkupSource),
                    to: file.url,
                    expecting: .present(baseline)
                )
            }.value
            finishPDFSave(
                fileID: file.id,
                url: file.url,
                dirtyVersion: dirtyVersion,
                savedEditCheckpoint: savedEditCheckpoint,
                writtenData: writtenData,
                generation: generation
            )
            return saveState(for: file.id).isClean
        } catch {
            finishPDFSaveFailure(error, file: file, generation: generation)
            return false
        }
    }

    /// For a marked-up image, the pixels a save draws the markup onto; nil for a PDF.
    private func imageMarkupSource(for file: WorkspaceDocument, baseline: Data) -> Data? {
        file.kind == .image ? imageMarkupSources[file.id] ?? baseline : nil
    }

    /// What a save writes for a document in the PDF viewer: the PDF itself, or for an image, the
    /// image with its markup drawn in, in the image's own format.
    nonisolated private static func fileData(
        forPDFViewerData pdfData: Data,
        imageMarkupSource: Data?
    ) throws -> Data {
        // Undo back to the original pixels publishes the image itself rather than markup.
        guard let imageMarkupSource, pdfData != imageMarkupSource else { return pdfData }
        return try ImageMarkupDocument.flattenedImageData(
            imageData: imageMarkupSource,
            markupData: pdfData
        )
    }

    private func currentPDFData(for file: WorkspaceDocument) -> Data? {
        if let dirtyData = dirtyPDFDocumentData[file.id] {
            return dirtyData
        }
        return try? Data(contentsOf: file.url)
    }

    private func applyPDFData(
        _ data: Data,
        editCheckpoint: PDFAnnotationEditCheckpoint?,
        to file: WorkspaceDocument
    ) {
        if let baseline = pdfDocumentBaselines[file.id], data == baseline {
            let shouldReloadExternalReplacement = selectedDocumentID == file.id
                && selectedDocumentExternalChange
            pdfDocumentBaselines.removeValue(forKey: file.id)
            imageMarkupSources.removeValue(forKey: file.id)
            dirtyPDFDocumentData.removeValue(forKey: file.id)
            dirtyPDFDocumentVersions.removeValue(forKey: file.id)
            dirtyPDFDocumentEditCheckpoints.removeValue(forKey: file.id)
            pdfDocumentSavedEditCheckpoints.removeValue(forKey: file.id)
            setSaveState(.clean, for: file.id)
            if selectedDocumentID == file.id {
                setHasUnsavedChangesIfChanged(false)
                setSelectedDocumentExternalChangeIfChanged(false)
                setSelectedDocumentSignatureIfChanged(Self.fileSignature(for: file.url))
            }
            publishWorkspaceSearchContentChange()
            if shouldReloadExternalReplacement {
                publishPDFContentReplacement(for: file.id)
            }
            return
        }

        dirtyPDFDocumentData[file.id] = data
        dirtyPDFDocumentVersions[file.id, default: 0] += 1
        if let editCheckpoint {
            dirtyPDFDocumentEditCheckpoints[file.id] = editCheckpoint
        } else {
            dirtyPDFDocumentEditCheckpoints.removeValue(forKey: file.id)
        }
        if selectedDocumentID == file.id {
            setHasUnsavedChangesIfChanged(true)
        }
        setSaveState(.edited, for: file.id)
        publishWorkspaceSearchContentChange()
    }

    private func publishPDFContentReplacement(for documentID: String) {
        pdfDocumentBaselines.removeValue(forKey: documentID)
        imageMarkupSources.removeValue(forKey: documentID)
        dirtyPDFDocumentEditCheckpoints.removeValue(forKey: documentID)
        pdfDocumentSavedEditCheckpoints.removeValue(forKey: documentID)
        pdfDocumentContentVersions[documentID, default: 0] &+= 1
    }

    func markdownTextForExport(_ document: WorkspaceDocument) async throws -> String {
        guard document.kind == .markdown else {
            throw WorkspaceDocumentOperationError.unsupportedPDFExport(document.displayName)
        }
        guard writingToolsDocumentID != document.id else {
            throw WorkspaceDocumentOperationError.writingToolsActive(document.displayName)
        }

        if selectedDocumentID == document.id, !isDocumentLoading {
            return documentText
        }

        if let dirtyText = dirtyDocumentTexts[document.id] {
            return dirtyText
        }

        return try await Self.readText(from: document.url)
    }

    private func startWorkspaceLoad(
        _ url: URL,
        selecting selectedURL: URL?,
        preserveSelection: String?,
        reloadSelection: Bool
    ) {
        guard writingToolsDocumentID == nil else {
            errorMessage = "Finish Writing Tools before opening another workspace."
            return
        }
        let standardizedURL = url.standardizedFileURL
        let previousWorkspaceURL = workspaceURL?.standardizedFileURL
        cancelExternalDocumentReview()
        updateSecurityScope(for: standardizedURL)
        let generation = beginWorkspaceOperation()
        openingWorkspaceURL = standardizedURL

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                let result = try await Self.scanWorkspace(standardizedURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishOpenedWorkspaceLoad(
                    result: result,
                    workspaceURL: standardizedURL,
                    selectedURL: selectedURL,
                    preserveSelection: preserveSelection,
                    reloadSelection: reloadSelection,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceOpenFailure(
                    error,
                    previousWorkspaceURL: previousWorkspaceURL,
                    generation: generation
                )
            }
        }
    }

    /// Starts an operation that replaces any in flight. It ends a move run unless it is the step of
    /// the run `continuingMoveRun`.
    private func beginWorkspaceOperation(continuingMoveRun moveRunID: Int? = nil) -> Int {
        workspaceTask?.cancel()
        documentTask?.cancel()
        recentDocumentRecordTask?.cancel()
        pendingMarkdownLinkMoveReview = nil
        if moveRunID == nil || moveRun?.id != moveRunID {
            endMoveRun()
        }
        workspaceGeneration += 1
        openingWorkspaceURL = nil
        isBusy = true
        setDocumentLoadingIfChanged(false)
        errorMessage = nil
        return workspaceGeneration
    }

    private func beginDocumentFileOperation(continuingMoveRun moveRunID: Int? = nil) -> Int {
        saveTask?.cancel()
        markdownImageAssetTask?.cancel()
        saveGeneration += 1
        setSavingIfChanged(false)
        return beginWorkspaceOperation(continuingMoveRun: moveRunID)
    }

    private func finishWorkspaceLoad(
        result: WorkspaceDocumentScanResult,
        workspaceURL: URL,
        selectedURL: URL?,
        preserveSelection: String?,
        reloadSelection: Bool,
        sidebarSelection: SidebarSelectionAfterLoad = .unchanged,
        opensFirstDocument: Bool = false,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        let previousDocuments = documents
        rootNode = result.root
        replaceDocuments(with: result.documents)
        pruneSaveStates(previousDocuments: previousDocuments)
        ensureFileWatcher(for: workspaceURL)

        if let selectedURL,
           let selectedDocument = documentsByID[selectedURL.standardizedFileURL.path] {
            selectedDocumentID = selectedDocument.id
        } else if let preserveSelection, documentsByID[preserveSelection] != nil {
            selectedDocumentID = preserveSelection
        } else if opensFirstDocument {
            selectedDocumentID = documents.first?.id
        } else if let selectedDocumentID, documentsByID[selectedDocumentID] == nil {
            deselectRemovedDocument()
        }

        switch sidebarSelection {
        case .unchanged:
            break
        case .document:
            selectOpenDocumentInSidebar()
        case .folder(let folderURL):
            selectFolder(id: folderURL.standardizedFileURL.path)
        case .cleared:
            clearSidebarSelection()
        case .items(let itemIDs):
            selectSidebarItems(.items(itemIDs))
        }

        isBusy = false

        if reloadSelection || documentText.isEmpty || selectedDocumentID != preserveSelection {
            loadSelectedDocument()
        }
        refreshGitStatus()
    }

    private func finishOpenedWorkspaceLoad(
        result: WorkspaceDocumentScanResult,
        workspaceURL: URL,
        selectedURL: URL?,
        preserveSelection: String?,
        reloadSelection: Bool,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        if self.workspaceURL?.standardizedFileURL != workspaceURL.standardizedFileURL {
            clearStateForWorkspaceTransition()
        }
        self.workspaceURL = workspaceURL.standardizedFileURL
        openingWorkspaceURL = nil
        finishWorkspaceLoad(
            result: result,
            workspaceURL: workspaceURL,
            selectedURL: selectedURL,
            preserveSelection: preserveSelection,
            reloadSelection: reloadSelection,
            opensFirstDocument: true,
            generation: generation
        )
        if let selectedURL,
           documentsByID[selectedURL.standardizedFileURL.path] == nil,
           !Self.isDirectory(selectedURL) {
            errorMessage = "Monknot can't open “\(selectedURL.lastPathComponent)”."
        }
    }

    private func finishWorkspaceOpenFailure(
        _ error: Error,
        previousWorkspaceURL: URL?,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        openingWorkspaceURL = nil
        if let previousWorkspaceURL {
            updateSecurityScope(for: previousWorkspaceURL)
            ensureFileWatcher(for: previousWorkspaceURL)
        } else {
            clearSecurityScope()
        }
        finishWorkspaceFailure(error, generation: generation, message: "Could not open workspace")
    }

    private func clearStateForWorkspaceTransition() {
        cancelSuppressedWatcherReplay()
        pendingDocumentTransfer = nil
        moveRun = nil
        dirtyDocumentTexts = [:]
        dirtyDocumentBaselines = [:]
        dirtyDocumentRevisionExpectations = [:]
        pdfDocumentBaselines = [:]
        imageMarkupSources = [:]
        dirtyPDFDocumentData = [:]
        dirtyPDFDocumentVersions = [:]
        dirtyPDFDocumentEditCheckpoints = [:]
        pdfDocumentSavedEditCheckpoints = [:]
        pdfDocumentContentVersions = [:]
        removedDirtyDocuments = [:]
        removedDirtyOpenDocumentIDs = []
        openDocumentIDs = []
        documentSaveStates = [:]
        selectedDocumentID = nil
        sidebarItemSelection = SidebarSelection()
        sidebarSelectsOpenDocument = true
        setDocumentTextIfChanged("")
        lastSavedText = ""
        setHasUnsavedChangesIfChanged(false)
        setSelectedDocumentExternalChangeIfChanged(false)
        setSelectedDocumentSignatureIfChanged(nil)
        clearReplaceUndoSnapshot()
        fileOperationHistory.removeAll()
        publishFileOperationUndoState()
        workspaceReplaceSummary = nil
        invalidateAllWorkspaceSearchCaches()
    }

    private func finishCreatedFile(
        result: WorkspaceDocumentScanResult,
        fileURL: URL,
        workspaceURL: URL,
        initialText: String,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        let previousDocuments = documents
        rootNode = result.root
        replaceDocuments(with: result.documents)
        pruneSaveStates(previousDocuments: previousDocuments)
        ensureFileWatcher(for: workspaceURL)
        guard let createdDocument = documentsByID[fileURL.standardizedFileURL.path] else {
            // The scan does not list the file, so the current document stays selected.
            isBusy = false
            if let selectedDocumentID, documentsByID[selectedDocumentID] == nil {
                deselectRemovedDocument()
                loadSelectedDocument()
            }
            errorMessage = "Created \(fileURL.lastPathComponent), but Monknot does not show this kind of file."
            return
        }
        selectedDocumentID = createdDocument.id
        selectOpenDocumentInSidebar()
        setDocumentTextIfChanged(initialText)
        lastSavedText = initialText
        setHasUnsavedChangesIfChanged(false)
        setSelectedDocumentExternalChangeIfChanged(false)
        setSelectedDocumentSignatureIfChanged(Self.fileSignature(for: fileURL))
        setSaveState(.clean, for: selectedDocumentID)
        invalidateWorkspaceSearchCaches(paths: [fileURL.path])
        // A file made on request opens in a tab, even after every tab was closed.
        requestDocumentOpen(at: fileURL)
        isBusy = false
    }

    private func finishSelectExistingFile(
        result: WorkspaceDocumentScanResult,
        fileURL: URL,
        workspaceURL: URL,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        let previousDocuments = documents
        rootNode = result.root
        replaceDocuments(with: result.documents)
        pruneSaveStates(previousDocuments: previousDocuments)
        ensureFileWatcher(for: workspaceURL)
        selectedDocumentID = documentsByID[fileURL.standardizedFileURL.path]?.id ?? documents.first?.id
        selectOpenDocumentInSidebar()
        loadSelectedDocument()
        // Today's note or the starter README opens in a tab, as a new file does.
        if documentsByID[fileURL.standardizedFileURL.path] != nil {
            requestDocumentOpen(at: fileURL)
        }
        isBusy = false
    }

    private func finishWorkspaceFailure(_ error: Error, generation: Int, message: String) {
        guard generation == workspaceGeneration else { return }

        isBusy = false
        setDocumentLoadingIfChanged(false)
        errorMessage = "\(message): \(error.localizedDescription)"
    }

    private func clearReplaceUndoSnapshot() {
        replaceUndoSnapshot = nil
        canUndoWorkspaceReplace = false
        publishFileOperationUndoState()
    }

    /// A workspace Replace's undo writes its notes back by path, so it ends once Monknot moves,
    /// renames or trashes one of them, or rewrites the links in one: the text it would write back
    /// belongs to what was there.
    private func endReplaceUndo(ifTouching paths: some Sequence<String>) {
        guard let snapshot = replaceUndoSnapshot else { return }
        let touched = Set(paths)
        guard !touched.isEmpty else { return }
        if snapshot.previousTextsByDocumentID.keys.contains(where: { touched.contains($0) || Self.hasAncestor($0, in: touched) }) {
            clearReplaceUndoSnapshot()
        }
    }

    private func finishWorkspaceReplace(
        batch: WorkspaceReplaceBatch,
        generation: Int,
        summary: String? = nil
    ) {
        guard generation == workspaceGeneration else { return }

        for (documentID, updatedText) in batch.updatedTextsByDocumentID {
            if selectedDocumentID == documentID {
                setDocumentTextIfChanged(updatedText)
                lastSavedText = updatedText
                setHasUnsavedChangesIfChanged(false)
                setSelectedDocumentExternalChangeIfChanged(false)
                if let url = document(id: documentID)?.url {
                    setSelectedDocumentSignatureIfChanged(Self.fileSignature(for: url))
                }
                setSaveState(.clean, for: documentID)
                dirtyDocumentRevisionExpectations.removeValue(forKey: documentID)
            } else {
                dirtyDocumentTexts.removeValue(forKey: documentID)
                dirtyDocumentBaselines.removeValue(forKey: documentID)
                dirtyDocumentRevisionExpectations.removeValue(forKey: documentID)
                setSaveState(.clean, for: documentID)
            }
        }
        if !batch.updatedTextsByDocumentID.isEmpty {
            invalidateWorkspaceSearchCaches(paths: batch.updatedTextsByDocumentID.keys)
        }

        if let summary {
            workspaceReplaceSummary = summary
        } else {
            workspaceReplaceSummary = Self.replaceSummary(for: batch)
            if batch.totalReplacements > 0, !batch.previousTextsByDocumentID.isEmpty {
                replaceUndoSnapshot = WorkspaceReplaceUndoSnapshot(
                    previousTextsByDocumentID: batch.previousTextsByDocumentID,
                    replacedTextsByDocumentID: batch.updatedTextsByDocumentID
                )
                canUndoWorkspaceReplace = true
                workspaceUndoSerial &+= 1
                replaceUndoSerial = workspaceUndoSerial
                publishFileOperationUndoState()
            }
        }

        isBusy = false
        refreshGitStatus()
        if !batch.fileResults.isEmpty {
            runExternalWorkspaceRefresh()
        }
    }

    private static func replaceSummary(for batch: WorkspaceReplaceBatch) -> String {
        if batch.totalReplacements == 0 {
            if batch.skippedChangedCount > 0 {
                return "Replaced nothing: \(batch.skippedChangedCount) file(s) changed on disk during the replace."
            }
            if batch.skippedDirtyCount > 0 {
                return "No matches in clean files. \(batch.skippedDirtyCount) unsaved file(s) skipped."
            }
            return "No matches replaced."
        }

        var summary = "Replaced \(batch.totalReplacements) in \(batch.fileResults.count) file(s)."
        if batch.skippedDirtyCount > 0 {
            summary += " Skipped \(batch.skippedDirtyCount) unsaved."
        }
        if batch.skippedLargeFileCount > 0 {
            summary += " Skipped \(batch.skippedLargeFileCount) large."
        }
        if batch.skippedChangedCount > 0 {
            summary += " Skipped \(batch.skippedChangedCount) changed on disk."
        }
        return summary
    }

    /// Shows what a copy or transfer made: one file opens and one folder is selected in the
    /// sidebar; several items are selected in the sidebar, none opened.
    private func finishDocumentTransfer(
        result: WorkspaceDocumentScanResult,
        workspaceURL: URL,
        landedItems: [WorkspaceLandedItem],
        preserveSelection: String?,
        changedPaths: [String],
        completedTransfer: WorkspaceDocumentTransfer?,
        undoSteps: [WorkspaceFileOperationStep],
        undoVerb: WorkspaceFileOperationVerb,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        invalidateWorkspaceSearchCaches(paths: changedPaths)
        if let completedTransfer {
            completeTransfer(completedTransfer)
        }
        recordFileOperation(undoVerb, steps: undoSteps)
        let selectedURL: URL?
        let sidebarSelection: SidebarSelectionAfterLoad
        if landedItems.count == 1, let item = landedItems.first {
            selectedURL = item.isFolder ? nil : item.url
            sidebarSelection = item.isFolder ? .folder(item.url) : .document
        } else {
            selectedURL = nil
            sidebarSelection = .items(landedItems.map(\.url.path))
        }
        finishWorkspaceLoad(
            result: result,
            workspaceURL: workspaceURL,
            selectedURL: selectedURL,
            preserveSelection: preserveSelection,
            reloadSelection: selectedURL != nil,
            sidebarSelection: sidebarSelection,
            generation: generation
        )
    }

    /// Shows what a copy or import left on disk before it failed, then reports the failure: at
    /// the end of the move run `moveRunID`, which goes on, when the import came with one.
    private func finishCopyFailure(
        _ error: Error,
        result: WorkspaceDocumentScanResult?,
        workspaceURL: URL,
        preserveSelection: String?,
        message: String,
        moveRunID: Int? = nil,
        generation: Int
    ) {
        if let result {
            finishWorkspaceLoad(
                result: result,
                workspaceURL: workspaceURL,
                selectedURL: nil,
                preserveSelection: preserveSelection,
                reloadSelection: false,
                generation: generation
            )
        }
        guard generation == workspaceGeneration else { return }
        if !skipFailedMoveRunStep(moveRunID, reason: "\(message): \(error.localizedDescription)") {
            finishWorkspaceFailure(error, generation: generation, message: message)
        }
    }

    private func updateSecurityScope(for url: URL) {
        if securityScopedURL == url {
            return
        }

        clearSecurityScope()
        securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    private func clearSecurityScope() {
        fileWatcher.stop()
        cancelSuppressedWatcherReplay()
        externalRefreshWorkItem?.cancel()
        externalRefreshWorkItem = nil
        externalRefreshTask?.cancel()
        externalRefreshTask = nil
        externalReviewTask?.cancel()
        externalReviewTask = nil
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    private func loadSelectedDocument() {
        documentTask?.cancel()
        documentGeneration += 1
        let generation = documentGeneration
        if documentLoadFailure != nil {
            documentLoadFailure = nil
        }

        guard let selectedDocument else {
            setDocumentTextIfChanged("")
            lastSavedText = ""
            setHasUnsavedChangesIfChanged(false)
            setSelectedDocumentSignatureIfChanged(nil)
            setSelectedDocumentExternalChangeIfChanged(false)
            setDocumentLoadingIfChanged(false)
            return
        }

        guard selectedDocument.capabilities.canEditText else {
            setDocumentTextIfChanged("")
            lastSavedText = ""
            let nextHasUnsavedChanges = dirtyPDFDocumentVersions[selectedDocument.id] != nil
            setHasUnsavedChangesIfChanged(nextHasUnsavedChanges)
            setSelectedDocumentSignatureIfChanged(
                nextHasUnsavedChanges ? nil : changeTrackedSignature(for: selectedDocument)
            )
            setSelectedDocumentExternalChangeIfChanged(removedDirtyDocuments[selectedDocument.id] != nil)
            setDocumentLoadingIfChanged(false)
            if selectedDocument.kind.opensInPDFViewer, hasUnsavedChanges, saveState(for: selectedDocument.id).isClean {
                setSaveState(.edited, for: selectedDocument.id)
            }
            return
        }

        let file = selectedDocument

        if let dirtyText = dirtyDocumentTexts[file.id] {
            setDocumentTextIfChanged(dirtyText)
            lastSavedText = dirtyDocumentBaselines[file.id] ?? dirtyText
            setHasUnsavedChangesIfChanged(dirtyText != lastSavedText)
            let currentRevision = try? WorkspaceConditionalTextWriter.read(from: file.url)
            setSelectedDocumentSignatureIfChanged(currentRevision?.signature)
            let expectedRevision = dirtyDocumentRevisionExpectations[file.id]
            let changedOnDisk: Bool
            switch (expectedRevision, currentRevision) {
            case (.present(let expected)?, let current?):
                changedOnDisk = expected != current
            case (.absent?, nil):
                changedOnDisk = false
            case (nil, _):
                changedOnDisk = false
            default:
                changedOnDisk = true
            }
            setSelectedDocumentExternalChangeIfChanged(
                removedDirtyDocuments[file.id] != nil || changedOnDisk
            )
            setDocumentLoadingIfChanged(false)
            setSaveState(hasUnsavedChanges ? .edited : .clean, for: file.id)
            return
        }

        do {
            try WorkspaceTextFileGuard.ensureWithinLimit(
                at: file.url,
                maxBytes: Self.interactiveTextOpenMaxBytes
            )
        } catch {
            finishDocumentLoadFailure(error, file: file, generation: generation)
            return
        }

        if let cachedText = WorkspaceTextContentCache.shared.text(for: file.url) {
            setDocumentTextIfChanged(cachedText)
            lastSavedText = cachedText
            setHasUnsavedChangesIfChanged(false)
            setSelectedDocumentSignatureIfChanged(Self.fileSignature(for: file.url))
            setSelectedDocumentExternalChangeIfChanged(false)
            setDocumentLoadingIfChanged(false)
            setSaveState(.clean, for: file.id)
            return
        }

        setDocumentTextIfChanged("")
        lastSavedText = ""
        setHasUnsavedChangesIfChanged(false)
        setSelectedDocumentSignatureIfChanged(nil)
        setSelectedDocumentExternalChangeIfChanged(false)
        setDocumentLoadingIfChanged(true)

        documentTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let text = try await Self.readText(from: file.url)
                guard !Task.isCancelled else { return }
                await self?.finishDocumentLoad(file: file, text: text, generation: generation)
            } catch {
                await self?.finishDocumentLoadFailure(error, file: file, generation: generation)
            }
        }
    }

    private func scheduleRecentDocumentRecord(_ document: WorkspaceDocument, workspaceURL: URL) {
        let documentID = document.id
        let workspacePath = workspaceURL.standardizedFileURL.path

        recentDocumentRecordTask?.cancel()
        recentDocumentRecordTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.recentDocumentRecordDelayNanoseconds)
            } catch {
                return
            }

            // A file that could not be opened is not a recent document. Checked here because a
            // too-large file fails while it is being selected, before this task exists.
            guard let self,
                  self.selectedDocumentID == documentID,
                  self.workspaceURL?.standardizedFileURL.path == workspacePath,
                  self.documentLoadFailure?.documentID != documentID
            else {
                return
            }

            self.recentDocumentStore.record(document, workspaceURL: workspaceURL)
            self.recentDocumentChangeSerial &+= 1
        }
    }

    private func finishDocumentLoad(file: WorkspaceDocument, text: String, generation: Int) {
        guard generation == documentGeneration, selectedDocumentID == file.id else { return }

        setDocumentTextIfChanged(text)
        lastSavedText = text
        setHasUnsavedChangesIfChanged(false)
        dirtyDocumentTexts.removeValue(forKey: file.id)
        dirtyDocumentBaselines.removeValue(forKey: file.id)
        dirtyDocumentRevisionExpectations.removeValue(forKey: file.id)
        setSelectedDocumentSignatureIfChanged(Self.fileSignature(for: file.url))
        setSelectedDocumentExternalChangeIfChanged(false)
        setSaveState(.clean, for: file.id)
        setDocumentLoadingIfChanged(false)
    }

    private func finishDocumentLoadFailure(_ error: Error, file: WorkspaceDocument, generation: Int) {
        guard generation == documentGeneration, selectedDocumentID == file.id else { return }

        setDocumentTextIfChanged("")
        lastSavedText = ""
        setHasUnsavedChangesIfChanged(false)
        setSelectedDocumentSignatureIfChanged(nil)
        setDocumentLoadingIfChanged(false)
        documentLoadFailure = DocumentLoadFailure(documentID: file.id, message: Self.loadFailureMessage(for: error))
    }

    nonisolated private static func loadFailureMessage(for error: Error) -> String {
        switch error {
        case WorkspaceTextFileGuard.Error.fileTooLarge(_, let size, let maxBytes):
            let megabytes = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / (1024 * 1024)) }
            return "This file is \(megabytes(size)) MB. The editor opens text files up to \(megabytes(maxBytes)) MB."
        case WorkspaceTextFileGuard.Error.unreadableEncoding:
            return "This file is not UTF-8 text, so it cannot be edited here."
        case WorkspaceTextFileGuard.Error.binaryContent:
            return "This file holds binary data, not text, so it cannot be edited here."
        default:
            return "The file could not be read: \(error.localizedDescription)"
        }
    }

    private func textWriteExpectation(for documentID: String) -> WorkspaceTextRevisionExpectation? {
        if let expectation = dirtyDocumentRevisionExpectations[documentID] {
            return expectation
        }
        guard let document = document(id: documentID),
              let baseline = dirtyDocumentBaselines[documentID],
              let revision = try? WorkspaceConditionalTextWriter.read(from: document.url),
              revision.text == baseline
        else {
            return nil
        }
        let expectation = WorkspaceTextRevisionExpectation.present(revision)
        dirtyDocumentRevisionExpectations[documentID] = expectation
        return expectation
    }

    private func finishExternalReview(
        _ state: ExternalDocumentReviewState,
        generation: Int
    ) {
        guard generation == externalReviewGeneration,
              selectedDocumentID == state.documentID,
              dirtyDocumentTexts[state.documentID] != nil || hasUnsavedChanges
        else { return }
        externalReviewTask = nil
        externalDocumentReview = state
    }

    private func finishExternalReviewFailure(
        _ error: Error,
        documentID: String,
        generation: Int
    ) {
        guard generation == externalReviewGeneration,
              selectedDocumentID == documentID
        else { return }
        externalReviewTask = nil
        errorMessage = "Could not review the disk copy: \(error.localizedDescription)"
    }

    private func validateExternalDocumentState(
        _ state: ExternalDocumentReviewState,
        currentDiskRevision: WorkspaceTextRevision?,
        generation: Int,
        refreshesVisibleReview: Bool
    ) -> Bool {
        guard generation == externalReviewGeneration,
              selectedDocumentID == state.documentID
        else { return false }

        let currentLocalText = dirtyDocumentTexts[state.documentID] ?? documentText
        guard currentLocalText == state.review.localText,
              dirtyDocumentBaselines[state.documentID] ?? lastSavedText == state.review.baselineText
        else {
            if refreshesVisibleReview {
                refreshStaleExternalReview(
                    state: state,
                    currentDiskRevision: currentDiskRevision,
                    generation: generation
                )
            } else {
                externalReviewTask = nil
                errorMessage = "Your local text changed before the operation could finish. Try again."
            }
            return false
        }
        return true
    }

    private func finishExternalCopy(
        documentID: String,
        destinationURL: URL,
        generation: Int
    ) {
        guard generation == externalReviewGeneration,
              selectedDocumentID == documentID
        else { return }
        externalReviewTask = nil
        guard let workspaceURL else { return }
        let canonicalRoot = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalDestination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        if Self.isCanonicalURL(canonicalDestination, containedIn: canonicalRoot) {
            refresh()
        }
    }

    private func finishExternalCopyStale(
        documentID: String,
        generation: Int
    ) {
        guard generation == externalReviewGeneration,
              selectedDocumentID == documentID
        else { return }
        externalReviewTask = nil
        errorMessage = "The disk copy changed again. No copy was saved; try again."
    }

    private func finishExternalCopyFailure(
        _ error: Error,
        documentID: String,
        generation: Int
    ) {
        guard generation == externalReviewGeneration,
              selectedDocumentID == documentID
        else { return }
        externalReviewTask = nil
        errorMessage = "Could not save a copy: \(error.localizedDescription)"
    }

    private func refreshStaleExternalReview(
        state: ExternalDocumentReviewState,
        currentDiskRevision: WorkspaceTextRevision?,
        generation: Int
    ) {
        guard generation == externalReviewGeneration,
              selectedDocumentID == state.documentID
        else { return }
        let currentLocalText = dirtyDocumentTexts[state.documentID] ?? documentText
        let currentBaseline = dirtyDocumentBaselines[state.documentID] ?? state.review.baselineText
        externalDocumentReview = ExternalDocumentReviewState(
            documentID: state.documentID,
            displayName: state.displayName,
            review: ExternalDocumentReconciliationService.review(
                baselineText: currentBaseline,
                localText: currentLocalText,
                diskRevision: currentDiskRevision
            ),
            diskToMineDiff: ExternalDocumentReconciliationService.unifiedDiff(
                from: currentDiskRevision?.text ?? "",
                to: currentLocalText
            )
        )
        externalReviewTask = nil
        errorMessage = "The disk copy changed while the review was open. The comparison has been refreshed; no changes were applied."
    }

    private func applyExternalDocumentResolution(
        _ resolution: ExternalDocumentResolution,
        state: ExternalDocumentReviewState,
        currentDiskRevision: WorkspaceTextRevision?,
        generation: Int
    ) {
        guard generation == externalReviewGeneration,
              selectedDocumentID == state.documentID
        else { return }

        guard validateExternalDocumentState(
            state,
            currentDiskRevision: currentDiskRevision,
            generation: generation,
            refreshesVisibleReview: state.diskToMineDiff != nil
        ) else { return }
        let currentLocalText = dirtyDocumentTexts[state.documentID] ?? documentText

        let newText: String
        switch resolution {
        case .useDisk:
            guard let currentDiskRevision else {
                externalReviewTask = nil
                errorMessage = "The file is still missing. Keep your local text or cancel the review."
                return
            }
            newText = currentDiskRevision.text
        case .keepLocal:
            newText = currentLocalText
        case .merge:
            guard currentDiskRevision != nil,
                  let mergedText = state.review.mergedText
            else {
                externalReviewTask = nil
                errorMessage = "These edits overlap. Choose a complete version or reconcile the text manually."
                return
            }
            newText = mergedText
        }

        let diskText = currentDiskRevision?.text ?? ""
        setDocumentTextIfChanged(newText)
        lastSavedText = diskText
        setSelectedDocumentSignatureIfChanged(currentDiskRevision?.signature)
        setSelectedDocumentExternalChangeIfChanged(false)
        externalDocumentReview = nil
        externalReviewTask = nil

        if newText == diskText, currentDiskRevision != nil {
            dirtyDocumentTexts.removeValue(forKey: state.documentID)
            dirtyDocumentBaselines.removeValue(forKey: state.documentID)
            dirtyDocumentRevisionExpectations.removeValue(forKey: state.documentID)
            removedDirtyDocuments.removeValue(forKey: state.documentID)
            setHasUnsavedChangesIfChanged(false)
            setSaveState(.clean, for: state.documentID)
            pruneRemovedDirtyDocuments()
            return
        }

        dirtyDocumentTexts[state.documentID] = newText
        dirtyDocumentBaselines[state.documentID] = diskText
        dirtyDocumentRevisionExpectations[state.documentID] = currentDiskRevision.map {
            .present($0)
        } ?? .absent
        setHasUnsavedChangesIfChanged(true)
        setSaveState(.edited, for: state.documentID)
    }

    nonisolated private static func externalTextRevision(at url: URL) throws -> WorkspaceTextRevision? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try WorkspaceConditionalTextWriter.read(from: url)
    }

    nonisolated private static func externalCopyDestination(
        _ destinationURL: URL,
        aliases sourceURL: URL
    ) -> Bool {
        let canonicalSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalDestination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        if canonicalSource == canonicalDestination { return true }

        guard FileManager.default.fileExists(atPath: canonicalSource.path),
              FileManager.default.fileExists(atPath: canonicalDestination.path),
              let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: canonicalSource.path),
              let destinationAttributes = try? FileManager.default.attributesOfItem(atPath: canonicalDestination.path),
              let sourceSystem = (sourceAttributes[.systemNumber] as? NSNumber)?.uint64Value,
              let sourceFile = (sourceAttributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let destinationSystem = (destinationAttributes[.systemNumber] as? NSNumber)?.uint64Value,
              let destinationFile = (destinationAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return false }

        return sourceSystem == destinationSystem && sourceFile == destinationFile
    }

    private func finishSave(
        fileID: String,
        text: String,
        writtenRevision: WorkspaceTextRevision,
        generation: Int
    ) {
        guard generation == saveGeneration else { return }
        setSavingIfChanged(false)

        let wasRemovedDirtyDocument = removedDirtyDocuments.removeValue(forKey: fileID) != nil
        pruneRemovedDirtyDocuments()
        if let url = document(id: fileID)?.url {
            invalidateWorkspaceSearchCaches(paths: [url.path])
        }
        guard selectedDocumentID == fileID else {
            if dirtyDocumentTexts[fileID] == nil || dirtyDocumentTexts[fileID] == text {
                dirtyDocumentTexts.removeValue(forKey: fileID)
                dirtyDocumentBaselines.removeValue(forKey: fileID)
                dirtyDocumentRevisionExpectations.removeValue(forKey: fileID)
                setSaveState(.clean, for: fileID)
            } else {
                dirtyDocumentBaselines[fileID] = text
                dirtyDocumentRevisionExpectations[fileID] = .present(writtenRevision)
                setSaveState(.edited, for: fileID)
            }
            if wasRemovedDirtyDocument {
                refresh()
            }
            return
        }

        lastSavedText = text
        setHasUnsavedChangesIfChanged(documentText != lastSavedText)
        setSelectedDocumentExternalChangeIfChanged(false)
        if hasUnsavedChanges {
            dirtyDocumentTexts[fileID] = documentText
            dirtyDocumentBaselines[fileID] = lastSavedText
            dirtyDocumentRevisionExpectations[fileID] = .present(writtenRevision)
        } else {
            dirtyDocumentTexts.removeValue(forKey: fileID)
            dirtyDocumentBaselines.removeValue(forKey: fileID)
            dirtyDocumentRevisionExpectations.removeValue(forKey: fileID)
        }
        setSelectedDocumentSignatureIfChanged(writtenRevision.signature)
        setSaveState(hasUnsavedChanges ? .edited : .clean, for: fileID)
        if wasRemovedDirtyDocument {
            refresh()
        }
    }

    private func finishPDFSave(
        fileID: String,
        url: URL,
        dirtyVersion: Int,
        savedEditCheckpoint: PDFAnnotationEditCheckpoint?,
        writtenData: Data,
        generation: Int
    ) {
        if generation == saveGeneration {
            setSavingIfChanged(false)
        }

        let wasRemovedDirtyDocument = removedDirtyDocuments.removeValue(forKey: fileID) != nil
        pruneRemovedDirtyDocuments()

        let currentDirtyVersion = dirtyPDFDocumentVersions[fileID]
        if currentDirtyVersion == nil || currentDirtyVersion == dirtyVersion {
            pdfDocumentBaselines.removeValue(forKey: fileID)
            dirtyPDFDocumentData.removeValue(forKey: fileID)
            dirtyPDFDocumentVersions.removeValue(forKey: fileID)
            dirtyPDFDocumentEditCheckpoints.removeValue(forKey: fileID)
            pdfDocumentSavedEditCheckpoints.removeValue(forKey: fileID)
            setSaveState(.clean, for: fileID)
            if selectedDocumentID == fileID {
                setHasUnsavedChangesIfChanged(false)
                setSelectedDocumentExternalChangeIfChanged(false)
                setSelectedDocumentSignatureIfChanged(Self.fileSignature(for: url))
            }
            invalidateWorkspaceSearchCaches(paths: [url.path])
            // The saved markup is now part of the image's pixels, as in Preview: reopen the file
            // so the next markup starts from it.
            if document(id: fileID)?.kind == .image {
                publishPDFContentReplacement(for: fileID)
            }
        } else {
            pdfDocumentBaselines[fileID] = writtenData
            if let savedEditCheckpoint {
                pdfDocumentSavedEditCheckpoints[fileID] = savedEditCheckpoint
            } else {
                pdfDocumentSavedEditCheckpoints.removeValue(forKey: fileID)
            }
            setSaveState(.edited, for: fileID)
            if selectedDocumentID == fileID {
                setHasUnsavedChangesIfChanged(true)
                setSelectedDocumentExternalChangeIfChanged(false)
                setSelectedDocumentSignatureIfChanged(Self.fileSignature(for: url))
            }
        }

        if wasRemovedDirtyDocument {
            refresh()
        }
    }

    private func finishPDFSaveFailure(_ error: Error, file: WorkspaceDocument, generation: Int) {
        if generation == saveGeneration {
            setSavingIfChanged(false)
        }
        setSaveState(.failed(error.localizedDescription), for: file.id)
        if error as? WorkspaceTextRevisionError == .changedOnDisk
            || error as? WorkspaceTextRevisionError == .unexpectedlyCreated {
            reportPDFViewerDiskConflict(file)
        } else {
            errorMessage = "Could not save \(file.displayName): \(error.localizedDescription)"
        }
    }

    /// Reports that the file of `file`, a PDF or image with unsaved markup, changed on disk.
    private func reportPDFViewerDiskConflict(_ file: WorkspaceDocument) {
        if selectedDocumentID == file.id {
            setSelectedDocumentExternalChangeIfChanged(true)
        }
        errorMessage = file.kind == .image
            ? "\(file.displayName) changed on disk. Reload it to continue."
            : "\(file.displayName) changed on disk. Reload it or save your annotated version as a copy."
    }

    private func finishSaveFailure(_ error: Error, file: WorkspaceDocument, generation: Int) {
        if generation == saveGeneration {
            setSavingIfChanged(false)
        }
        setSaveState(.failed(error.localizedDescription), for: file.id)
        if error as? WorkspaceTextRevisionError == .changedOnDisk
            || error as? WorkspaceTextRevisionError == .unexpectedlyCreated {
            if selectedDocumentID == file.id {
                setSelectedDocumentExternalChangeIfChanged(true)
            }
            errorMessage = "\(file.displayName) changed again on disk. Review the latest differences before saving."
        } else {
            errorMessage = "Could not save \(file.displayName): \(error.localizedDescription)"
        }
    }

    private func updateSaveStateForSelectedDocument() {
        guard let selectedDocumentID else { return }
        if hasUnsavedChanges {
            if dirtyDocumentBaselines[selectedDocumentID] == nil {
                dirtyDocumentBaselines[selectedDocumentID] = lastSavedText
                if let selectedDocumentSignature {
                    dirtyDocumentRevisionExpectations[selectedDocumentID] = .present(
                        WorkspaceTextRevision(
                            text: lastSavedText,
                            signature: selectedDocumentSignature
                        )
                    )
                } else if let document = selectedDocument,
                          let revision = try? WorkspaceConditionalTextWriter.read(from: document.url),
                          revision.text == lastSavedText {
                    dirtyDocumentRevisionExpectations[selectedDocumentID] = .present(revision)
                    setSelectedDocumentSignatureIfChanged(revision.signature)
                }
            }
            dirtyDocumentTexts[selectedDocumentID] = documentText
        } else {
            dirtyDocumentTexts.removeValue(forKey: selectedDocumentID)
            dirtyDocumentBaselines.removeValue(forKey: selectedDocumentID)
            dirtyDocumentRevisionExpectations.removeValue(forKey: selectedDocumentID)
        }
        setSaveState(hasUnsavedChanges ? .edited : .clean, for: selectedDocumentID)
    }

    private func setSaveState(_ state: DocumentSaveState, for documentID: String?) {
        guard let documentID else { return }
        guard saveState(for: documentID) != state else { return }

        if state.isClean {
            documentSaveStates.removeValue(forKey: documentID)
        } else {
            documentSaveStates[documentID] = state
        }
    }

    private func pruneSaveStates(previousDocuments: [WorkspaceDocument]) {
        let documentIDs = Set(documents.map(\.id))
        let previousDocumentsByID = Dictionary(uniqueKeysWithValues: previousDocuments.map { ($0.id, $0) })
        let dirtyDocumentIDs = Set(dirtyDocumentTexts.keys).union(dirtyPDFDocumentVersions.keys)
        let removedDirtyIDs = dirtyDocumentIDs
            .intersection(openDocumentIDs)
            .subtracting(documentIDs)

        for documentID in removedDirtyIDs {
            if removedDirtyDocuments[documentID] == nil, let document = previousDocumentsByID[documentID] {
                removedDirtyDocuments[documentID] = document
            }
        }

        pruneRemovedDirtyDocuments(availableDocumentIDs: documentIDs)
        let preservedDocumentIDs = documentIDs.union(removedDirtyOpenDocumentIDs)

        documentSaveStates = documentSaveStates.filter { preservedDocumentIDs.contains($0.key) }
        dirtyDocumentTexts = dirtyDocumentTexts.filter { preservedDocumentIDs.contains($0.key) }
        dirtyDocumentBaselines = dirtyDocumentBaselines.filter { preservedDocumentIDs.contains($0.key) }
        dirtyDocumentRevisionExpectations = dirtyDocumentRevisionExpectations.filter {
            preservedDocumentIDs.contains($0.key)
        }
        pdfDocumentBaselines = pdfDocumentBaselines.filter { preservedDocumentIDs.contains($0.key) }
        imageMarkupSources = imageMarkupSources.filter { preservedDocumentIDs.contains($0.key) }
        dirtyPDFDocumentData = dirtyPDFDocumentData.filter { preservedDocumentIDs.contains($0.key) }
        dirtyPDFDocumentVersions = dirtyPDFDocumentVersions.filter { preservedDocumentIDs.contains($0.key) }
        dirtyPDFDocumentEditCheckpoints = dirtyPDFDocumentEditCheckpoints.filter {
            preservedDocumentIDs.contains($0.key)
        }
        pdfDocumentSavedEditCheckpoints = pdfDocumentSavedEditCheckpoints.filter {
            preservedDocumentIDs.contains($0.key)
        }
        pdfDocumentContentVersions = pdfDocumentContentVersions.filter { preservedDocumentIDs.contains($0.key) }
        if let selectedDocumentID {
            setHasUnsavedChangesIfChanged(
                dirtyDocumentTexts[selectedDocumentID] != nil || dirtyPDFDocumentVersions[selectedDocumentID] != nil
            )
        }
    }

    private func pruneRemovedDirtyDocuments(availableDocumentIDs: Set<String>? = nil) {
        removedDirtyDocuments = removedDirtyDocuments.filter { entry in
            let documentID = entry.key
            let documentIsAvailable = availableDocumentIDs?.contains(documentID) ?? (documentsByID[documentID] != nil)
            return openDocumentIDs.contains(documentID) &&
                (dirtyDocumentTexts[documentID] != nil || dirtyPDFDocumentVersions[documentID] != nil) &&
                !documentIsAvailable
        }
        removedDirtyOpenDocumentIDs = Set(removedDirtyDocuments.keys)
    }

    private func moveDirtyState(from sourceID: String, to destinationID: String) {
        guard sourceID != destinationID else { return }

        if let text = dirtyDocumentTexts.removeValue(forKey: sourceID) {
            dirtyDocumentTexts[destinationID] = text
        }

        if let baseline = dirtyDocumentBaselines.removeValue(forKey: sourceID) {
            dirtyDocumentBaselines[destinationID] = baseline
        }

        if let expectation = dirtyDocumentRevisionExpectations.removeValue(forKey: sourceID) {
            dirtyDocumentRevisionExpectations[destinationID] = expectation
        }

        if let dirtyPDFVersion = dirtyPDFDocumentVersions.removeValue(forKey: sourceID) {
            dirtyPDFDocumentVersions[destinationID] = dirtyPDFVersion
        }

        if let editCheckpoint = dirtyPDFDocumentEditCheckpoints.removeValue(forKey: sourceID) {
            dirtyPDFDocumentEditCheckpoints[destinationID] = editCheckpoint
        }

        if let savedEditCheckpoint = pdfDocumentSavedEditCheckpoints.removeValue(forKey: sourceID) {
            pdfDocumentSavedEditCheckpoints[destinationID] = savedEditCheckpoint
        }

        if let contentVersion = pdfDocumentContentVersions.removeValue(forKey: sourceID) {
            pdfDocumentContentVersions[destinationID] = contentVersion
        }

        if let pdfBaseline = pdfDocumentBaselines.removeValue(forKey: sourceID) {
            pdfDocumentBaselines[destinationID] = pdfBaseline
        }

        if let imageMarkupSource = imageMarkupSources.removeValue(forKey: sourceID) {
            imageMarkupSources[destinationID] = imageMarkupSource
        }

        if let dirtyPDFData = dirtyPDFDocumentData.removeValue(forKey: sourceID) {
            dirtyPDFDocumentData[destinationID] = dirtyPDFData
        }

        if let state = documentSaveStates.removeValue(forKey: sourceID) {
            documentSaveStates[destinationID] = state
        }

        if selectedDocumentID == sourceID {
            selectedDocumentID = destinationID
        }
    }

    private func publishItemMove(
        from sourcePath: String,
        to destinationPath: String,
        mappings: [WorkspaceDocumentIDMapping]
    ) {
        publishItemMoves([
            WorkspaceItemMoveRemap(sourcePath: sourcePath, destinationPath: destinationPath, mappings: mappings),
        ])
    }

    /// One event for every item an operation moved, so a view that reads the latest event sees
    /// them all.
    private func publishItemMoves(_ moves: [WorkspaceItemMoveRemap]) {
        documentIDRemapEvent = WorkspaceDocumentIDRemapEvent(
            serial: (documentIDRemapEvent?.serial ?? 0) + 1,
            itemMoves: moves.map { WorkspaceItemPathMove(sourcePath: $0.sourcePath, destinationPath: $0.destinationPath) },
            mappings: moves.flatMap(\.mappings).filter { $0.sourceID != $0.destinationID }
        )
    }

    private func noteInternalFileMutation() {
        suppressWatcherUntil = Date().addingTimeInterval(suppressWatcherInterval)
    }

    private func publishWorkspaceSearchContentChange() {
        workspaceSearchContentChangeSerial &+= 1
    }

    private func invalidateWorkspaceSearchCaches(paths: some Sequence<String>) {
        let paths = Array(paths)
        guard !paths.isEmpty else { return }
        WorkspaceTextContentCache.shared.invalidate(paths: paths)
        WorkspaceSearchIndex.shared.invalidate(paths: paths)
        WorkspacePDFTextCache.shared.invalidate(paths: paths)
        WorkspacePDFSearchIndex.shared.invalidate(paths: paths)
        publishWorkspaceSearchContentChange()
    }

    private func invalidateAllWorkspaceSearchCaches() {
        WorkspaceTextContentCache.shared.invalidateAll()
        WorkspaceSearchIndex.shared.invalidateAll()
        WorkspacePDFTextCache.shared.invalidateAll()
        WorkspacePDFSearchIndex.shared.invalidateAll()
        publishWorkspaceSearchContentChange()
    }

    // MARK: - Testing Support

    internal var suppressWatcherInterval: TimeInterval { 1.2 }
    internal var testing_isWritingToolsActive: Bool { writingToolsDocumentID != nil }
    internal var testing_hasDeferredWritingToolsRefresh: Bool {
        deferredWritingToolsRefreshNeeded
    }

    internal func testing_clearWatcherSuppression() {
        suppressWatcherUntil = .distantPast
    }

    internal func testing_stopFileWatcher() {
        fileWatcher.stop()
        cancelSuppressedWatcherReplay()
        externalRefreshWorkItem?.cancel()
        externalRefreshWorkItem = nil
        externalRefreshTask?.cancel()
        externalRefreshTask = nil
    }

    internal func testing_scheduleExternalWorkspaceRefresh(_ event: WorkspaceFileWatcher.Event) {
        scheduleExternalWorkspaceRefresh(event)
    }

    private func ensureFileWatcher(for workspaceURL: URL) {
        fileWatcher.start(rootURL: workspaceURL) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.scheduleExternalWorkspaceRefresh(event)
            }
        }
    }

    private func scheduleExternalWorkspaceRefresh(
        _ event: WorkspaceFileWatcher.Event,
        bypassingSuppression: Bool = false
    ) {
        guard workspaceURL != nil else { return }
        guard event.requiresFullRescan || event.changedPaths.contains(where: { Self.isRelevantExternalChange(path: $0) }) else {
            return
        }
        guard writingToolsDocumentID == nil else {
            deferExternalRefreshUntilWritingToolsEnd()
            return
        }
        guard bypassingSuppression || !holdsWatcherEvents else {
            deferSuppressedWatcherEvent(event)
            return
        }

        let requiresFullRescan = event.requiresFullRescan || deferredWritingToolsRefreshNeeded

        if !requiresFullRescan,
           event.modifiedOnlyPaths.contains(where: { Self.isRelevantExternalChange(path: $0) }),
           event.changedPaths.isSubset(of: event.modifiedOnlyPaths) {
            applyIncrementalFileModifications(paths: event.modifiedOnlyPaths)
            return
        }

        if !requiresFullRescan, applyIncrementalFileChanges(paths: event.changedPaths) {
            return
        }

        if requiresFullRescan {
            invalidateAllWorkspaceSearchCaches()
        } else {
            invalidateWorkspaceSearchCaches(paths: event.changedPaths)
        }

        externalRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.externalRefreshWorkItem = nil
                self?.runExternalWorkspaceRefresh()
            }
        }
        externalRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Watcher events wait while a file operation runs, whose scan replaces the sidebar when it
    /// finishes, and while Monknot's own change settles.
    private var holdsWatcherEvents: Bool {
        isBusy || Date() < suppressWatcherUntil
    }

    /// Holds watcher events that arrive while Monknot's own file change settles and replays them
    /// once the window ends, so external changes made meanwhile still reach the sidebar.
    private func deferSuppressedWatcherEvent(_ event: WorkspaceFileWatcher.Event) {
        if let pending = suppressedWatcherEvent {
            let createdOrRemoved = pending.changedPaths.subtracting(pending.modifiedOnlyPaths)
                .union(event.changedPaths.subtracting(event.modifiedOnlyPaths))
            suppressedWatcherEvent = WorkspaceFileWatcher.Event(
                changedPaths: pending.changedPaths.union(event.changedPaths),
                modifiedOnlyPaths: pending.modifiedOnlyPaths.union(event.modifiedOnlyPaths)
                    .subtracting(createdOrRemoved),
                requiresFullRescan: pending.requiresFullRescan || event.requiresFullRescan
            )
        } else {
            suppressedWatcherEvent = event
        }
        if suppressedWatcherReplayWorkItem == nil {
            scheduleSuppressedWatcherReplay()
        }
    }

    private func scheduleSuppressedWatcherReplay() {
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.replaySuppressedWatcherEvent()
            }
        }
        suppressedWatcherReplayWorkItem = item
        // A running operation has no known end, so its events are checked again shortly.
        let delay = max(isBusy ? 0.3 : 0, suppressWatcherUntil.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func replaySuppressedWatcherEvent() {
        suppressedWatcherReplayWorkItem = nil
        guard !holdsWatcherEvents else {
            scheduleSuppressedWatcherReplay()
            return
        }
        guard let event = suppressedWatcherEvent, let workspaceURL else { return }
        suppressedWatcherEvent = nil
        // The held event mixes Monknot's own changes with any made meanwhile. A file added,
        // removed or renamed is settled by one scan of the disk rather than path by path.
        if event.requiresFullRescan || !event.changedPaths.isSubset(of: event.modifiedOnlyPaths) {
            scheduleExternalWorkspaceRefresh(.init(
                changedPaths: [workspaceURL.path],
                modifiedOnlyPaths: [],
                requiresFullRescan: true
            ))
        } else {
            scheduleExternalWorkspaceRefresh(event)
        }
    }

    private func cancelSuppressedWatcherReplay() {
        suppressedWatcherReplayWorkItem?.cancel()
        suppressedWatcherReplayWorkItem = nil
        suppressedWatcherEvent = nil
    }

    private func applyIncrementalFileChanges(paths: Set<String>) -> Bool {
        guard let workspaceURL else { return false }
        guard let rootNode else { return false }
        let relevantPaths = paths.filter { Self.isRelevantExternalChange(path: $0) }
        guard !relevantPaths.isEmpty else { return true }

        guard let result = WorkspaceScanResultPatcher.applyingFileChanges(
            to: WorkspaceDocumentScanResult(root: rootNode, documents: documents),
            rootURL: workspaceURL,
            changedPaths: relevantPaths
        ) else {
            return false
        }

        externalRefreshWorkItem?.cancel()
        externalRefreshWorkItem = nil
        externalRefreshTask?.cancel()
        externalRefreshTask = nil
        invalidateWorkspaceSearchCaches(paths: relevantPaths)
        applyExternalWorkspaceResult(result)
        refreshGitStatus()
        return true
    }

    private func applyIncrementalFileModifications(paths: Set<String>) {
        let relevantPaths = paths.filter { Self.isRelevantExternalChange(path: $0) }
        guard !relevantPaths.isEmpty else { return }

        invalidateWorkspaceSearchCaches(paths: relevantPaths)

        guard let selectedDocument else { return }
        let selectedPath = selectedDocument.url.standardizedFileURL.path
        guard relevantPaths.contains(selectedPath) else { return }

        let nextSignature = Self.fileSignature(for: selectedDocument.url)
        if selectedDocument.kind.opensInPDFViewer {
            reconcileSelectedPDFViewerDocument(selectedDocument, nextSignature: nextSignature)
            return
        }

        guard selectedDocument.capabilities.canEditText else { return }
        if hasUnsavedChanges,
           let expectation = dirtyDocumentRevisionExpectations[selectedDocument.id] {
            let currentRevision = try? WorkspaceConditionalTextWriter.read(from: selectedDocument.url)
            if !Self.revision(currentRevision, satisfies: expectation) {
                setSelectedDocumentExternalChangeIfChanged(true)
            }
        } else if !hasUnsavedChanges, !isSaving, nextSignature != selectedDocumentSignature {
            reloadSelectedTextIfChangedOnDisk(selectedDocument, signature: nextSignature)
        } else if selectedDocumentSignature == nil {
            setSelectedDocumentSignatureIfChanged(nextSignature)
        }
    }

    private func runExternalWorkspaceRefresh() {
        guard let workspaceURL else { return }
        guard writingToolsDocumentID == nil else {
            deferExternalRefreshUntilWritingToolsEnd()
            return
        }
        guard !isBusy else {
            scheduleExternalWorkspaceRefresh(.init(
                changedPaths: [workspaceURL.path],
                modifiedOnlyPaths: [],
                requiresFullRescan: true
            ), bypassingSuppression: deferredWritingToolsRefreshNeeded)
            return
        }

        externalRefreshGeneration += 1
        let generation = externalRefreshGeneration
        let workspaceOperationGeneration = workspaceGeneration
        externalRefreshTask?.cancel()
        externalRefreshTask = Task.detached(priority: .utility) { [weak self, scanner] in
            let signpostID = MonknotSignposting.externalRefresh.beginInterval("ExternalWorkspaceRefresh")
            defer { MonknotSignposting.externalRefresh.endInterval("ExternalWorkspaceRefresh", signpostID) }

            do {
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishExternalWorkspaceRefresh(
                    result: result,
                    workspaceURL: workspaceURL,
                    workspaceOperationGeneration: workspaceOperationGeneration,
                    generation: generation
                )
            } catch {
                await self?.finishExternalWorkspaceFailure(error, generation: generation)
            }
        }
    }

    private func deferExternalRefreshUntilWritingToolsEnd() {
        deferredWritingToolsRefreshNeeded = true
    }

    private func applyExternalWorkspaceResult(_ result: WorkspaceDocumentScanResult) {
        let previousSelection = selectedDocumentID
        let selectionStillExists = previousSelection.map { id in result.documents.contains { $0.id == id } } ?? false
        let dirtySelectionRemoved = previousSelection != nil && !selectionStillExists && hasUnsavedChanges

        let previousDocuments = documents
        // A scan that finds the workspace unchanged leaves the tree, and the views drawing it, alone.
        if rootNode != result.root {
            rootNode = result.root
        }
        if documents != result.documents {
            replaceDocuments(with: result.documents)
        }
        pruneSaveStates(previousDocuments: previousDocuments)

        if selectionStillExists {
            selectedDocumentID = previousSelection
        } else if dirtySelectionRemoved, let previousSelection {
            selectedDocumentID = previousSelection
            setSelectedDocumentExternalChangeIfChanged(true)
        } else {
            if previousSelection != nil {
                deselectRemovedDocument()
            }
            setSelectedDocumentSignatureIfChanged(nil)
        }

        guard !dirtySelectionRemoved else { return }
        guard let selectedDocument else { return }
        let nextSignature = Self.fileSignature(for: selectedDocument.url)
        if selectedDocument.kind.opensInPDFViewer {
            if selectionStillExists {
                reconcileSelectedPDFViewerDocument(selectedDocument, nextSignature: nextSignature)
            } else if selectedDocumentSignature == nil, !hasUnsavedChanges {
                setSelectedDocumentSignatureIfChanged(nextSignature)
            }
            return
        }

        guard selectedDocument.capabilities.canEditText else { return }
        if hasUnsavedChanges,
           let expectation = dirtyDocumentRevisionExpectations[selectedDocument.id] {
            let currentRevision = try? WorkspaceConditionalTextWriter.read(from: selectedDocument.url)
            if !Self.revision(currentRevision, satisfies: expectation) {
                setSelectedDocumentExternalChangeIfChanged(true)
            }
        } else if !hasUnsavedChanges,
                  !isSaving,
                  selectedDocumentSignature != nil,
                  nextSignature != selectedDocumentSignature {
            reloadSelectedTextIfChangedOnDisk(selectedDocument, signature: nextSignature)
        } else if selectedDocumentSignature == nil {
            setSelectedDocumentSignatureIfChanged(nextSignature)
        }
    }

    /// Reloads the clean selected text document when its file holds other text. A file that was
    /// only touched, or saved again with the same text, keeps the editor as it is and takes
    /// `signature`, read before the text so a later change still differs from it.
    private func reloadSelectedTextIfChangedOnDisk(_ document: WorkspaceDocument, signature: FileSignature?) {
        guard documentLoadFailure == nil,
              !isDocumentLoading,
              let text = try? WorkspaceTextFileGuard.readUTF8Text(
                  from: document.url,
                  maxBytes: Self.interactiveTextOpenMaxBytes
              ),
              text == lastSavedText
        else {
            loadSelectedDocument()
            return
        }
        setSelectedDocumentSignatureIfChanged(signature)
    }

    /// Compares the selected PDF or image with its file on disk. A file other than the one
    /// Monknot last loaded or saved is an external change: a conflict while markup is unsaved,
    /// otherwise a reload. A file that was only touched, or saved again with the same bytes, is
    /// not. A save in progress settles the signature when it finishes.
    private func reconcileSelectedPDFViewerDocument(_ document: WorkspaceDocument, nextSignature: FileSignature?) {
        guard selectedDocumentSignature != nil else {
            if !hasUnsavedChanges {
                setSelectedDocumentSignatureIfChanged(nextSignature)
            }
            return
        }
        guard !isSaving, nextSignature != selectedDocumentSignature else { return }
        if hasUnsavedChanges {
            if let baseline = pdfDocumentBaselines[document.id],
               (try? Data(contentsOf: document.url)) == baseline {
                setSelectedDocumentSignatureIfChanged(nextSignature)
            } else {
                setSelectedDocumentExternalChangeIfChanged(true)
            }
        } else {
            setSelectedDocumentSignatureIfChanged(nextSignature)
            publishPDFContentReplacement(for: document.id)
        }
    }

    private func finishExternalWorkspaceRefresh(
        result: WorkspaceDocumentScanResult,
        workspaceURL: URL,
        workspaceOperationGeneration: Int,
        generation: Int
    ) {
        guard generation == externalRefreshGeneration else { return }
        externalRefreshTask = nil
        guard workspaceURL.standardizedFileURL == self.workspaceURL?.standardizedFileURL else { return }
        guard workspaceOperationGeneration == workspaceGeneration else { return }
        guard writingToolsDocumentID == nil else {
            deferExternalRefreshUntilWritingToolsEnd()
            return
        }

        applyExternalWorkspaceResult(result)
        deferredWritingToolsRefreshNeeded = false
        refreshGitStatus()
    }

    private func finishExternalWorkspaceFailure(_ error: Error, generation: Int) {
        guard generation == externalRefreshGeneration else { return }
        externalRefreshTask = nil
        if writingToolsDocumentID != nil {
            deferExternalRefreshUntilWritingToolsEnd()
            return
        }
        errorMessage = "Could not refresh workspace changes: \(error.localizedDescription)"
    }

    private func refreshGitStatus() {
        guard !gitStatusByRelativePath.isEmpty else { return }
        gitStatusByRelativePath = [:]
    }

    /// Whether no file operation is running; otherwise says to wait for it.
    /// File operations wait for each other and for a save: a save written while its file moves
    /// would put the file back at its old path and split the edits across two files.
    private func ensureNotBusy() -> Bool {
        guard !isBusy, !isSaving else {
            errorMessage = isBusy ? Self.busyMessage : Self.savingMessage
            return false
        }
        return true
    }

    @discardableResult
    private func ensureWritingToolsInactive(for action: String) -> Bool {
        guard writingToolsDocumentID == nil else {
            errorMessage = "Finish Writing Tools before \(action)."
            return false
        }
        return true
    }

    private static func isRelevantExternalChange(path: String) -> Bool {
        let ignored = WorkspaceDocumentScanner.defaultIgnoredDirectoryNames
        let components = URL(fileURLWithPath: path).pathComponents
        return !components.contains { component in
            ignored.contains(component) || (component.hasPrefix(".") && component != "." && component != "..")
        }
    }

    nonisolated private static func commitMarkdownLinkMove(
        _ plan: MarkdownLinkMovePlan,
        workspaceURL: URL
    ) throws -> WorkspaceMarkdownLinkMoveReceipt {
        let root = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let source = plan.sourceURL.standardizedFileURL
        let destination = plan.destinationURL.standardizedFileURL
        let canonicalSource = source.resolvingSymlinksInPath()
        let canonicalDestinationParent = destination.deletingLastPathComponent().resolvingSymlinksInPath()

        guard canonicalSource != root,
              isCanonicalURL(canonicalSource, containedIn: root)
        else {
            throw WorkspaceMarkdownLinkMoveError.sourceOutsideWorkspace
        }
        guard isCanonicalURL(canonicalDestinationParent, containedIn: root) else {
            throw WorkspaceMarkdownLinkMoveError.destinationOutsideWorkspace
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw WorkspaceMarkdownLinkMoveError.sourceMissing
        }

        for examined in plan.examinedFiles {
            try Task.checkCancellation()
            guard isCanonicalURL(
                examined.url.standardizedFileURL.resolvingSymlinksInPath(),
                containedIn: root
            ),
                  let current = try? WorkspaceConditionalTextWriter.read(from: examined.url),
                  current == examined.revision
            else {
                throw WorkspaceMarkdownLinkMoveError.staleReview
            }
        }
        guard let currentSourceStamp = try? MarkdownLinkMoveFileStamp.read(from: source),
              currentSourceStamp == plan.sourceStamp
        else {
            throw WorkspaceMarkdownLinkMoveError.staleReview
        }
        let currentDestinationParent = destination
            .deletingLastPathComponent()
            .standardizedFileURL
        let currentCanonicalDestinationParent = currentDestinationParent.resolvingSymlinksInPath()
        guard isCanonicalURL(currentCanonicalDestinationParent, containedIn: root) else {
            throw WorkspaceMarkdownLinkMoveError.destinationOutsideWorkspace
        }
        guard let currentDestinationParentStamp = try? MarkdownLinkMoveFileStamp.read(
            from: currentDestinationParent
        ),
              currentDestinationParentStamp == plan.destinationParentStamp
        else {
            throw WorkspaceMarkdownLinkMoveError.staleReview
        }
        let usesCaseOnlyRenameHop = WorkspaceFileIdentity.isCaseOnlyRename(
            from: source,
            to: destination
        )
        guard !FileManager.default.fileExists(atPath: destination.path)
                || usesCaseOnlyRenameHop
        else {
            throw WorkspaceMarkdownLinkMoveError.destinationExists
        }
        try Task.checkCancellation()

        try moveWorkspaceItem(
            from: source,
            to: destination,
            usingCaseOnlyRenameHop: usesCaseOnlyRenameHop
        )
        var receipt = WorkspaceMarkdownLinkMoveReceipt(
            plan: plan,
            writtenFiles: [],
            usedCaseOnlyRenameHop: usesCaseOnlyRenameHop
        )
        do {
            for filePlan in plan.rewriteFiles {
                try Task.checkCancellation()
                guard isCanonicalURL(
                    filePlan.finalURL.standardizedFileURL.resolvingSymlinksInPath(),
                    containedIn: root
                ) else {
                    throw WorkspaceMarkdownLinkMoveError.destinationOutsideWorkspace
                }
                let writtenRevision = try WorkspaceConditionalTextWriter.write(
                    filePlan.updatedText,
                    to: filePlan.finalURL,
                    expecting: .present(filePlan.originalRevision)
                )
                receipt.writtenFiles.append(WorkspaceMarkdownLinkMoveWrittenFile(
                    url: filePlan.finalURL,
                    originalURL: filePlan.originalURL,
                    originalRevision: filePlan.originalRevision,
                    writtenRevision: writtenRevision
                ))
            }
            return receipt
        } catch {
            let operationError = error
            do {
                try rollbackMarkdownLinkMove(receipt)
            } catch let rollbackError {
                throw WorkspaceMarkdownLinkMoveError.rollbackFailed(
                    operation: operationError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw operationError
        }
    }

    nonisolated private static func rollbackMarkdownLinkMove(
        _ receipt: WorkspaceMarkdownLinkMoveReceipt
    ) throws {
        var failures: [String] = []
        for writtenFile in receipt.writtenFiles.reversed() {
            do {
                try WorkspaceConditionalTextWriter.write(
                    writtenFile.originalRevision.text,
                    to: writtenFile.url,
                    expecting: .present(writtenFile.writtenRevision)
                )
            } catch {
                failures.append("\(writtenFile.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        do {
            try moveWorkspaceItem(
                from: receipt.plan.destinationURL,
                to: receipt.plan.sourceURL,
                usingCaseOnlyRenameHop: receipt.usedCaseOnlyRenameHop
            )
        } catch {
            failures.append("move: \(error.localizedDescription)")
        }

        guard failures.isEmpty else {
            throw WorkspaceMarkdownLinkMoveError.rollbackIncomplete(failures.joined(separator: "; "))
        }
    }

    nonisolated static func moveWorkspaceItem(
        from sourceURL: URL,
        to destinationURL: URL,
        usingCaseOnlyRenameHop: Bool
    ) throws {
        guard usingCaseOnlyRenameHop else {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return
        }

        let temporaryURL = uniqueCaseRenameTemporaryURL(nextTo: sourceURL)
        try FileManager.default.moveItem(at: sourceURL, to: temporaryURL)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            let operationError = error
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: sourceURL)
            } catch let rollbackError {
                throw WorkspaceMarkdownLinkMoveError.rollbackFailed(
                    operation: operationError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw operationError
        }
    }

    nonisolated private static func uniqueCaseRenameTemporaryURL(nextTo sourceURL: URL) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        var candidate: URL
        repeat {
            candidate = directory.appendingPathComponent(
                ".monknot-rename-\(UUID().uuidString)",
                isDirectory: false
            )
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    nonisolated static func isCanonicalURL(_ candidate: URL, containedIn root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func nextAvailableMarkdownURL(in rootURL: URL) -> URL {
        let baseName = "Untitled"
        var candidate = rootURL.appendingPathComponent("\(baseName).md")
        // A name whose file is gone but whose unsaved text Monknot keeps is taken too.
        func isTaken(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path) || keptUnsavedDocument(inItemAt: url) != nil
        }

        guard isTaken(candidate) else {
            return candidate
        }

        var index = 2
        repeat {
            candidate = rootURL.appendingPathComponent("\(baseName) \(index).md")
            index += 1
        } while isTaken(candidate)

        return candidate
    }

    nonisolated private static func scanWorkspace(
        _ rootURL: URL,
        scanner: any WorkspaceDocumentScanning
    ) async throws -> WorkspaceDocumentScanResult {
        try Task.checkCancellation()
        return try scanner.scan(rootURL: rootURL)
    }

    nonisolated private static func readText(from url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try WorkspaceTextFileGuard.readUTF8Text(
                from: url,
                maxBytes: interactiveTextOpenMaxBytes
            )
        }.value
    }

    nonisolated private static func writeText(_ text: String, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try WorkspaceTextFileGuard.writeUTF8Text(text, to: url)
        }.value
    }

    /// Writes a new file, failing rather than replacing one that appeared at `url` since its name
    /// was chosen (another app, a sync client).
    nonisolated private static func writeNewFile(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    }

    nonisolated private static func fileSignature(for url: URL) -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path) else {
            return nil
        }

        return FileSignature(
            modificationDate: attributes[.modificationDate] as? Date,
            fileSize: (attributes[.size] as? NSNumber)?.int64Value
        )
    }

    nonisolated private static func revision(
        _ revision: WorkspaceTextRevision?,
        satisfies expectation: WorkspaceTextRevisionExpectation
    ) -> Bool {
        switch (expectation, revision) {
        case (.present(let expected), let current?):
            return expected == current
        case (.absent, nil):
            return true
        default:
            return false
        }
    }

    private static func suggestedChildName(in directoryURL: URL?, baseName: String, pathExtension: String?) -> String {
        guard let directoryURL else {
            if let pathExtension, !pathExtension.isEmpty {
                return "\(baseName).\(pathExtension)"
            }
            return baseName
        }

        let fileManager = FileManager.default
        let firstName = childName(baseName: baseName, pathExtension: pathExtension)
        var candidate = firstName
        var candidateURL = directoryURL.appendingPathComponent(candidate)

        guard fileManager.fileExists(atPath: candidateURL.path) else {
            return candidate
        }

        var index = 2
        repeat {
            candidate = childName(baseName: "\(baseName) \(index)", pathExtension: pathExtension)
            candidateURL = directoryURL.appendingPathComponent(candidate)
            index += 1
        } while fileManager.fileExists(atPath: candidateURL.path)

        return candidate
    }

    nonisolated private static func childURL(in directoryURL: URL, proposedName: String, isDirectory: Bool) throws -> URL {
        let fileName = try validatedItemName(proposedName)
        try validateLength(of: fileName)
        try validateVisibility(of: fileName, isDirectory: isDirectory)

        let destinationURL = directoryURL.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceDocumentOperationError.destinationExists(fileName)
        }

        return destinationURL
    }

    nonisolated private static func validatedMissingWikilinkCreationURL(
        _ proposedURL: URL,
        workspaceURL: URL
    ) throws -> URL {
        let workspaceURL = workspaceURL.standardizedFileURL
        let fileURL = proposedURL.standardizedFileURL
        guard fileURL != workspaceURL, WorkspaceDocumentSupport.isURL(fileURL, containedIn: workspaceURL) else {
            throw WorkspaceDocumentOperationError.invalidCreation("The note must be inside the workspace.")
        }

        let relativeComponents = Array(fileURL.pathComponents.dropFirst(workspaceURL.pathComponents.count))
        guard !relativeComponents.isEmpty,
              relativeComponents.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") })
        else {
            throw WorkspaceDocumentOperationError.invalidCreation("Hidden and invalid paths are not supported.")
        }

        let fileExtension = fileURL.pathExtension.lowercased()
        guard WorkspaceDocumentSupport.markdownExtensions.contains(fileExtension) else {
            throw WorkspaceDocumentOperationError.invalidCreation("The destination must be a Markdown file.")
        }

        let parentURL = fileURL.deletingLastPathComponent().standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw WorkspaceDocumentOperationError.notDirectory(parentURL.lastPathComponent)
        }

        let relativeParentComponents = relativeComponents.dropLast()
        let expectedCanonicalParent = relativeParentComponents.reduce(
            workspaceURL.resolvingSymlinksInPath()
        ) { partialURL, component in
            partialURL.appendingPathComponent(component, isDirectory: true)
        }.standardizedFileURL
        guard parentURL.resolvingSymlinksInPath().standardizedFileURL == expectedCanonicalParent else {
            throw WorkspaceDocumentOperationError.invalidCreation("The destination cannot pass through a symbolic link.")
        }

        let validatedChild = try childURL(in: parentURL, proposedName: fileURL.lastPathComponent, isDirectory: false)
        guard validatedChild.standardizedFileURL == fileURL,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)) == nil
        else {
            throw WorkspaceDocumentOperationError.destinationExists(fileURL.lastPathComponent)
        }
        return fileURL
    }

    nonisolated private static func childName(baseName: String, pathExtension: String?) -> String {
        guard let pathExtension, !pathExtension.isEmpty else {
            return baseName
        }

        return "\(baseName).\(pathExtension)"
    }

    /// The trimmed name, or an error for an empty name, a path, `.` or `..`.
    nonisolated private static func validatedItemName(_ proposedName: String) throws -> String {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw WorkspaceDocumentOperationError.emptyName
        }

        guard name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:")) == nil else {
            throw WorkspaceDocumentOperationError.nestedName
        }

        guard name != "." && name != ".." else {
            throw WorkspaceDocumentOperationError.invalidName(name)
        }
        return name
    }

    /// Refuses a name longer than macOS allows, before anything is written.
    nonisolated private static func validateLength(of name: String) throws {
        guard WorkspaceDocumentSupport.fileNameLength(name) <= WorkspaceDocumentSupport.maximumFileNameLength else {
            throw WorkspaceDocumentOperationError.nameTooLong
        }
    }

    /// Refuses names the workspace scan leaves out, so a new or renamed item never vanishes.
    nonisolated private static func validateVisibility(of name: String, isDirectory: Bool) throws {
        guard WorkspaceDocumentScanner.hidesItem(named: name, isDirectory: isDirectory) else { return }
        if name.hasPrefix(".") {
            throw WorkspaceDocumentOperationError.hiddenName(name)
        }
        if WorkspaceDocumentSupport.isPackageName(name) {
            throw WorkspaceDocumentOperationError.packageFolderName(name)
        }
        throw WorkspaceDocumentOperationError.ignoredFolderName(name)
    }

    /// A file keeps its extension unless the new name ends in an extension of the same kind of
    /// document, so "Release 1.2" renames `notes.md` to `Release 1.2.md`, "notes.txt" makes it
    /// plain text, and "photo.md" renames `photo.png` to `photo.md.png`.
    nonisolated private static func renamedURL(
        for sourceURL: URL,
        proposedName: String,
        isDirectory: Bool
    ) throws -> URL {
        var fileName = try validatedItemName(proposedName)

        let sourceExtension = sourceURL.pathExtension
        if !isDirectory, !sourceExtension.isEmpty {
            let typedExtension = (fileName as NSString).pathExtension
            if !isSameKindOfDocument(extension: typedExtension, as: sourceURL) {
                fileName += ".\(sourceExtension)"
            }
        }
        try validateLength(of: fileName)
        try validateVisibility(of: fileName, isDirectory: isDirectory)

        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL
                || WorkspaceFileIdentity.isCaseOnlyRename(
                    from: sourceURL,
                    to: destinationURL
                ) {
                return destinationURL
            }

            throw WorkspaceDocumentOperationError.destinationExists(fileName)
        }

        return destinationURL
    }

    /// Whether a file named with `pathExtension` holds the same kind of content as `sourceURL`:
    /// both are text that the editor opens, or both are the same file type (`.jpg` and `.jpeg`).
    nonisolated private static func isSameKindOfDocument(extension pathExtension: String, as sourceURL: URL) -> Bool {
        guard WorkspaceDocumentSupport.isKnownFileExtension(pathExtension) else { return false }
        let typed = WorkspaceDocumentSupport.classification(for: URL(fileURLWithPath: "_.\(pathExtension)"))
        let source = WorkspaceDocumentSupport.classification(for: sourceURL)
        if typed.capabilities.canEditText && source.capabilities.canEditText {
            return true
        }
        return typed.kind == source.kind
            && typed.contentTypeIdentifier != nil
            && typed.contentTypeIdentifier == source.contentTypeIdentifier
    }

    /// Where a copy or move of `sourceURL` into `directoryURL` lands: its own name, or a "copy"
    /// name when that is taken.
    nonisolated private static func uniqueDocumentURL(
        for sourceURL: URL,
        in directoryURL: URL,
        reservedPaths: Set<String> = []
    ) -> URL {
        WorkspaceDocumentSupport.availableCopyURL(
            named: sourceURL.lastPathComponent,
            isDirectory: isDirectory(sourceURL),
            in: directoryURL,
            reservedPaths: reservedPaths
        )
    }

    /// Whether `url` is a folder (or package); false when it cannot be read.
    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    nonisolated private static func moveDestinationURL(
        for sourceURL: URL,
        toDirectory targetDirectory: URL,
        workspaceURL: URL
    ) throws -> URL {
        let sourceURL = sourceURL.standardizedFileURL
        let targetDirectory = targetDirectory.standardizedFileURL
        let workspaceURL = workspaceURL.standardizedFileURL

        guard WorkspaceDocumentSupport.isURL(sourceURL, containedIn: workspaceURL) else {
            throw WorkspaceDocumentOperationError.invalidMove("Move items from inside the current workspace.")
        }

        var targetIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: targetDirectory.path, isDirectory: &targetIsDirectory),
              targetIsDirectory.boolValue else {
            throw WorkspaceDocumentOperationError.notDirectory(targetDirectory.lastPathComponent)
        }

        guard WorkspaceDocumentSupport.isURL(targetDirectory, containedIn: workspaceURL) else {
            throw WorkspaceDocumentOperationError.invalidMove("Move items into the current workspace.")
        }

        var sourceIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory) else {
            throw WorkspaceDocumentOperationError.invalidMove("The item no longer exists.")
        }

        if sourceIsDirectory.boolValue, WorkspaceDocumentSupport.isURL(targetDirectory, containedIn: sourceURL) {
            throw WorkspaceDocumentOperationError.invalidMove("A folder cannot be moved into itself.")
        }

        if sourceURL.deletingLastPathComponent().standardizedFileURL == targetDirectory {
            return sourceURL
        }

        let destinationURL = targetDirectory.appendingPathComponent(sourceURL.lastPathComponent).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceDocumentOperationError.destinationExists(sourceURL.lastPathComponent)
        }

        return destinationURL
    }

    nonisolated private static func documentIDMappings(
        forMoving sourceURL: URL,
        to destinationURL: URL,
        documents: [WorkspaceDocument]
    ) -> [WorkspaceDocumentIDMapping] {
        let sourcePath = sourceURL.standardizedFileURL.path
        let destinationPath = destinationURL.standardizedFileURL.path

        return documents.compactMap { document in
            let documentPath = document.url.standardizedFileURL.path
            let remappedPath = path(documentPath, afterMoving: sourcePath, to: destinationPath)
            guard remappedPath != documentPath else { return nil }
            return WorkspaceDocumentIDMapping(sourceID: documentPath, destinationID: remappedPath)
        }
    }

    /// Where `path` is once the item at `sourcePath` moves to `destinationPath`: the item and
    /// everything inside it follow, and any other path stays.
    nonisolated static func path(
        _ path: String,
        afterMoving sourcePath: String,
        to destinationPath: String
    ) -> String {
        if path == sourcePath {
            return destinationPath
        }
        let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        guard path.hasPrefix(sourcePrefix) else { return path }
        return destinationPath + "/" + path.dropFirst(sourcePrefix.count)
    }

    nonisolated private static func resolveDroppedTarget(for url: URL) async throws -> DroppedTarget {
        try await Task.detached(priority: .userInitiated) {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

            if resourceValues.isDirectory == true {
                return .workspace(url)
            }

            if resourceValues.isRegularFile == true {
                return .document(workspaceURL: url.deletingLastPathComponent(), selectedURL: url)
            }

            return .unsupported
        }.value
    }

    deinit {
        fileWatcher.stop()
        externalRefreshWorkItem?.cancel()
        externalRefreshTask?.cancel()
        externalReviewTask?.cancel()
        workspaceTask?.cancel()
        documentTask?.cancel()
        saveTask?.cancel()
        markdownImageAssetTask?.cancel()
        recentDocumentRecordTask?.cancel()
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
}

private typealias FileSignature = WorkspaceFileSignature

private enum ExternalDocumentCopyError: LocalizedError {
    case sourceAlias

    var errorDescription: String? {
        "Choose a different location so the disk copy remains unchanged."
    }
}

struct MarkdownLinkMoveReviewState: Identifiable, Equatable, Sendable {
    let id: Int
    let plan: MarkdownLinkMovePlan
    fileprivate let request: WorkspaceMarkdownLinkMoveRequest

    var workspaceURL: URL { request.workspaceURL }
}

private struct WorkspaceMarkdownLinkMoveRequest: Equatable, Sendable {
    let workspaceURL: URL
    let mappings: [WorkspaceDocumentIDMapping]
    let selectedURL: URL?
    let preserveSelection: String?
    let reloadSelection: Bool
    let sidebarSelection: SidebarSelectionAfterLoad
    let completedTransfer: WorkspaceDocumentTransfer?
    let failureMessage: String
    let itemName: String
    /// The move run this move is a step of.
    let moveRunID: Int?
    /// What Edit › Undo calls the move.
    let undoVerb: WorkspaceFileOperationVerb
}

private struct WorkspaceMarkdownLinkMoveWrittenFile: Sendable {
    /// Where the file is after the move, which the move wrote.
    let url: URL
    /// Where it was before the move.
    let originalURL: URL
    let originalRevision: WorkspaceTextRevision
    let writtenRevision: WorkspaceTextRevision
}

private struct WorkspaceMarkdownLinkMoveReceipt: Sendable {
    let plan: MarkdownLinkMovePlan
    var writtenFiles: [WorkspaceMarkdownLinkMoveWrittenFile]
    let usedCaseOnlyRenameHop: Bool
}

private enum WorkspaceMarkdownLinkMoveError: LocalizedError {
    case unsavedLinkingDocument(String)
    case staleReview
    case sourceOutsideWorkspace
    case destinationOutsideWorkspace
    case sourceMissing
    case destinationExists
    case rollbackFailed(operation: String, rollback: String)
    case rollbackIncomplete(String)

    var errorDescription: String? {
        switch self {
        case .unsavedLinkingDocument(let name):
            return "Save \(name) first: this move updates the links in it."
        case .staleReview:
            return "Workspace files changed after the link preview. Review the move again."
        case .sourceOutsideWorkspace:
            return "The item to move is no longer safely inside the workspace."
        case .destinationOutsideWorkspace:
            return "The move destination is no longer safely inside the workspace."
        case .sourceMissing:
            return "The item to move no longer exists."
        case .destinationExists:
            return "An item now exists at the move destination."
        case .rollbackFailed(let operation, let rollback):
            return "The move failed (\(operation)), and rollback was incomplete (\(rollback))."
        case .rollbackIncomplete(let details):
            return "Rollback was incomplete: \(details)"
        }
    }
}

struct ExternalDocumentReviewState: Identifiable, Equatable, Sendable {
    let documentID: String
    let displayName: String
    let review: ExternalDocumentReconciliationReview
    let diskToMineDiff: ExternalDocumentUnifiedDiff?

    var id: String { documentID }

    var canMerge: Bool {
        guard review.diskRevision != nil,
              let mergedText = review.mergedText
        else { return false }
        return mergedText != review.localText && mergedText != review.diskText
    }

    var hasMergeConflict: Bool {
        review.diskRevision != nil
            && review.localText != review.diskText
            && review.mergedText == nil
    }
}

enum ExternalDocumentResolution: Equatable, Sendable {
    case useDisk
    case keepLocal
    case merge
}

struct WorkspaceTextMutation: Equatable, Sendable {
    let documentID: String
    let range: NSRange
    let expectedText: String
    let replacement: String
}

struct WorkspaceFolderReveal: Equatable, Sendable {
    let serial: Int
    let folderID: String
}

/// What the sidebar selects once an operation's rescan lands.
private enum SidebarSelectionAfterLoad: Equatable, Sendable {
    /// The selection stays; a selected folder that moved is followed to its new path.
    case unchanged
    /// The selection moves to the document the operation selected.
    case document
    /// A folder the operation created or pasted.
    case folder(URL)
    /// Nothing: the operation moved the selection to the Trash.
    case cleared
    /// Several items the operation made, without opening any.
    case items([String])
}

/// A file or folder to copy, or to move from another workspace, and the folder it goes into.
private struct WorkspaceItemTransferSource: Sendable {
    let url: URL
    /// A snapshot of the file, copied in its place while it exists.
    let contentsURL: URL?
    let targetDirectory: URL
}

/// An item a copy or transfer made.
private struct WorkspaceLandedItem: Sendable {
    let url: URL
    let isFolder: Bool
}

/// The files or folders Monknot renamed or moved in one operation, with the documents that moved
/// with them.
struct WorkspaceDocumentIDRemapEvent: Equatable, Sendable {
    let serial: Int
    /// In the order they moved; an undo of a drop of several items moves several.
    let itemMoves: [WorkspaceItemPathMove]
    let mappings: [WorkspaceDocumentIDMapping]

    var itemSourcePath: String { itemMoves.first?.sourcePath ?? "" }
    var itemDestinationPath: String { itemMoves.first?.destinationPath ?? "" }

    /// Where `path` is now: each moved item and everything inside it follow it, any other path stays.
    func remappedPath(_ path: String) -> String {
        itemMoves.reduce(path) { WorkspaceStore.path($0, afterMoving: $1.sourcePath, to: $1.destinationPath) }
    }
}

struct WorkspaceItemPathMove: Equatable, Sendable {
    let sourcePath: String
    let destinationPath: String
}

/// An item moved within the workspace, with the documents that moved with it.
private struct WorkspaceItemMoveRemap {
    let sourcePath: String
    let destinationPath: String
    let mappings: [WorkspaceDocumentIDMapping]
}

/// What an undo or redo of a file operation changes for the window (`fileOperationEffect`).
private struct WorkspaceFileOperationEffect {
    var itemMoves: [WorkspaceItemMoveRemap] = []
    /// Items going to the Trash and items going back to another workspace.
    var removedPaths: [String] = []
    /// The notes whose links it rewrites, by their paths before it.
    var rewrittenDocumentIDs: Set<String> = []
    /// The copies a redo makes again, which are selected as the copy selected them.
    var createdCopies: [WorkspaceFileCopyStep] = []
    /// The items an undo puts back from the Trash, which are selected.
    var restoredPaths: [String] = []
    var landingItemID: String?
    var changedPaths: [String] = []
}

/// An item an undo or redo moved or copied, which the sidebar shows landing (design.md §10.4).
struct WorkspaceItemLanding: Equatable, Sendable {
    let serial: Int
    let itemID: String
}

struct WorkspaceDocumentIDMapping: Equatable, Sendable {
    let sourceID: String
    let destinationID: String

    var destinationURL: URL {
        URL(fileURLWithPath: destinationID)
    }
}

private enum DroppedTarget: Sendable {
    case workspace(URL)
    case document(workspaceURL: URL, selectedURL: URL)
    case unsupported
}

/// A workspace file or folder waiting for Paste, with the pasteboard item its Copy or Cut wrote.
private struct WorkspaceDocumentTransfer: Equatable, Sendable {
    /// The items, none inside another, in the order they were copied or cut.
    let urls: [URL]
    let operation: WorkspaceDocumentTransferOperation
    let pasteboardStamp: WorkspacePasteboardTransferStamp?

    /// The same transfer once Monknot has moved the item at `sourcePath`, or an item containing
    /// some of these.
    func following(movedItemAt sourcePath: String, to destinationPath: String) -> WorkspaceDocumentTransfer {
        let followed = urls.map { url in
            let path = WorkspaceStore.path(url.path, afterMoving: sourcePath, to: destinationPath)
            return path == url.path ? url : URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath)
        }
        guard followed != urls else { return self }
        return WorkspaceDocumentTransfer(
            urls: followed,
            operation: operation,
            pasteboardStamp: pasteboardStamp
        )
    }
}

/// A move waiting for the one before it to finish.
private struct WorkspaceQueuedMove: Equatable, Sendable {
    let sourcePath: String
    let directoryURL: URL?
}

/// The moves of a drop of several items, made one after another, and what the run reports when
/// it ends.
private struct WorkspaceMoveRun {
    let id: Int
    var moves: [WorkspaceQueuedMove]
    var movedCount = 0
    /// The moves made, which Edit › Undo takes back as one step.
    var undoSteps: [WorkspaceFileOperationStep] = []
    /// Why items were not moved, in order.
    var failures: [String] = []
    /// What the drop's import had to say.
    var notes: [String] = []
}

private enum WorkspaceDocumentTransferOperation: Equatable, Sendable {
    case copy
    case cut
}

private enum WorkspaceDocumentOperationError: LocalizedError {
    case emptyName
    case nestedName
    case invalidName(String)
    case nameTooLong
    case unsupportedPDFExport(String)
    case writingToolsActive(String)
    case unsupportedPDFAnnotationExport(String)
    case destinationExists(String)
    case invalidMove(String)
    case invalidCreation(String)
    case notDirectory(String)
    case hiddenName(String)
    case ignoredFolderName(String)
    case packageFolderName(String)
    case keepsUnsavedText(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "File name cannot be empty."
        case .nestedName:
            return "File name cannot contain path separators."
        case .invalidName(let name):
            return "\(name) is not a valid file name."
        case .nameTooLong:
            return "This name is longer than macOS allows. Shorten it."
        case .unsupportedPDFExport(let name):
            return "\(name) is not a Markdown file."
        case .writingToolsActive(let name):
            return "Finish Writing Tools before exporting \(name)."
        case .unsupportedPDFAnnotationExport(let name):
            return "\(name) is not a PDF file."
        case .destinationExists(let name):
            return "An item named \(name) already exists."
        case .invalidMove(let message):
            return message
        case .invalidCreation(let message):
            return message
        case .notDirectory(let name):
            return "\(name) is not a folder."
        case .hiddenName(let name):
            return "Names starting with a period are hidden, so \(name) would not appear in the sidebar."
        case .ignoredFolderName(let name):
            return "Monknot hides folders named \(name)."
        case .packageFolderName(let name):
            return "\(name) would be a package, which Finder shows as one file, so Monknot hides it."
        case .keepsUnsavedText(let name):
            return "\(name) was removed from disk, but its unsaved changes are still open. Save or discard them first."
        }
    }
}
