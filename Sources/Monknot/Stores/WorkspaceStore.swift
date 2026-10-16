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
            reconcileSelectedFolder()
        }
    }
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
    /// The folder selected in the sidebar. The sidebar has one selection: this folder, or the
    /// selected document while no folder is selected. Selecting a folder leaves the document open.
    @Published private(set) var selectedFolderID: String?
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
    @Published private(set) var recentDocumentChangeSerial = 0
    @Published var errorMessage: String?

    private var replaceUndoSnapshot: WorkspaceReplaceUndoSnapshot?

    private let scanner: any WorkspaceDocumentScanning
    private let moveItemToTrash: @Sendable (URL) throws -> Void
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
    nonisolated static let interactiveTextOpenMaxBytes: Int64 = 4 * 1024 * 1024
    private static let recentDocumentRecordDelayNanoseconds: UInt64 = 350_000_000
    @Published private var pendingDocumentTransfer: WorkspaceDocumentTransfer?
    /// The moves of a drop of several items, made one after another.
    private var moveRun: WorkspaceMoveRun?
    private var moveRunSerial = 0
    /// The store of every open window, so a Paste in one window can finish a Cut made in another.
    private static let openStores = NSHashTable<WorkspaceStore>.weakObjects()

    /// `moveItemToTrash` moves a file or folder to the Trash; tests pass one that leaves the
    /// user's Trash alone.
    init(
        scanner: any WorkspaceDocumentScanning = WorkspaceDocumentScanner(),
        userDefaults: UserDefaults = .standard,
        moveItemToTrash: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
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

    /// The path of the sidebar's selected item: the selected folder, otherwise the selected
    /// document while the sidebar selects it.
    var sidebarSelectionID: String? {
        selectedFolderID ?? (sidebarSelectsOpenDocument ? selectedDocumentID : nil)
    }

    /// The sidebar's selected item: the selected folder, otherwise the selected document while the
    /// sidebar selects it.
    var sidebarSelectionURL: URL? {
        if let selectedFolderID {
            return URL(fileURLWithPath: selectedFolderID, isDirectory: true)
        }
        return sidebarSelectsOpenDocument ? selectedDocument?.url : nil
    }

    /// Where New and Paste put items when no row names a folder: the selected folder, the selected
    /// document's folder, or the workspace root when nil.
    var sidebarTargetFolderURL: URL? {
        if let selectedFolderID {
            return URL(fileURLWithPath: selectedFolderID, isDirectory: true)
        }
        return sidebarSelectsOpenDocument ? selectedDocument?.url.deletingLastPathComponent() : nil
    }

    /// Selects a folder of the workspace tree in the sidebar; the workspace root is never selected.
    func selectFolder(id: String) {
        guard let rootNode,
              id != rootNode.id,
              rootNode.node(withID: id)?.kind == .folder
        else { return }
        selectedFolderID = id
    }

    /// Keeps the selected folder in the tree: when it is gone, the nearest folder above it that
    /// remains is selected instead, and nothing when that is the root. Moving the selection to the
    /// Trash from Monknot selects nothing instead (`SidebarSelectionAfterLoad.cleared`).
    private func reconcileSelectedFolder() {
        guard var folderID = selectedFolderID else { return }
        guard let rootNode else {
            selectedFolderID = nil
            return
        }
        while folderID != rootNode.id, WorkspaceDocumentSupport.isPath(folderID, containedIn: rootNode.id) {
            if rootNode.node(withID: folderID)?.kind == .folder {
                if folderID != selectedFolderID {
                    selectedFolderID = folderID
                }
                return
            }
            folderID = (folderID as NSString).deletingLastPathComponent
        }
        selectedFolderID = nil
    }

    private func selectOpenDocumentInSidebar() {
        selectedFolderID = nil
        sidebarSelectsOpenDocument = true
    }

    /// Leaves nothing selected in the sidebar.
    private func clearSidebarSelection() {
        selectedFolderID = nil
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
        guard !isBusy else { return }

        let restoreSnapshot = snapshot
        clearReplaceUndoSnapshot()
        let documentSnapshot = documents
        workspaceReplaceSummary = nil
        noteInternalFileMutation()
        let generation = beginWorkspaceOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let batch = try WorkspaceReplaceService().restoreAndWrite(
                    previousTextsByDocumentID: restoreSnapshot.previousTextsByDocumentID,
                    documents: documentSnapshot
                )
                guard !Task.isCancelled else { return }
                await self?.finishWorkspaceReplace(
                    batch: batch,
                    generation: generation,
                    summary: "Undid replace in \(batch.fileResults.count) file(s)."
                )
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
                try await Self.writeText(initialText, to: fileURL)
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
                try Data(initialText.utf8).write(to: revalidatedURL, options: .withoutOverwriting)
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
                try await Self.writeText(initialText, to: fileURL)
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

    func suggestedNewFileName(in directoryURL: URL? = nil) -> String {
        let targetDirectory = directoryURL ?? workspaceURL
        return Self.suggestedChildName(in: targetDirectory, baseName: "Untitled", pathExtension: "txt")
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
        return try Self.childURL(in: targetDirectory, proposedName: proposedName, isDirectory: isDirectory)
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
                guard FileManager.default.createFile(atPath: fileURL.path, contents: Data()) else {
                    throw WorkspaceDocumentOperationError.couldNotCreateFile(fileURL.lastPathComponent)
                }

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
            failureMessage: "Could not rename \(document.displayName)"
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
            failureMessage: "Could not rename \(sourceURL.lastPathComponent)"
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

    /// Marks a workspace file or folder to be copied by each later paste. A Copy made through the
    /// pasteboard passes the stamp of the item it wrote there.
    func copyItem(at url: URL, pasteboardStamp: WorkspacePasteboardTransferStamp? = nil) {
        setPendingTransfer(for: url, operation: .copy, pasteboardStamp: pasteboardStamp)
    }

    /// Marks a workspace file or folder to be moved by the next paste. A Cut made through the
    /// pasteboard passes the stamp of the item it wrote there.
    func cutItem(at url: URL, pasteboardStamp: WorkspacePasteboardTransferStamp? = nil) {
        setPendingTransfer(for: url, operation: .cut, pasteboardStamp: pasteboardStamp)
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

    /// Replaces any earlier transfer, which the newer Copy or Cut supersedes even when its item is
    /// not a workspace file or folder.
    private func setPendingTransfer(
        for url: URL,
        operation: WorkspaceDocumentTransferOperation,
        pasteboardStamp: WorkspacePasteboardTransferStamp?
    ) {
        let url = url.standardizedFileURL
        guard isWorkspaceItem(url) else {
            pendingDocumentTransfer = nil
            return
        }
        pendingDocumentTransfer = WorkspaceDocumentTransfer(
            url: url,
            operation: operation,
            pasteboardStamp: pasteboardStamp
        )
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

    /// Moves the item another window cut into `directoryURL` (the root when nil), as a Paste in
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
        guard !isBusy, owner?.isBusy != true else {
            errorMessage = Self.busyMessage
            return
        }
        guard ensureWritingToolsInactive(for: "changing the workspace") else { return }

        let targetDirectory = (directoryURL ?? workspaceURL).standardizedFileURL
        let sourceURL = transfer.url
        let displayName = sourceURL.lastPathComponent

        if transfer.operation == .cut,
           sourceURL.deletingLastPathComponent().standardizedFileURL == targetDirectory {
            completeTransfer(transfer)
            return
        }

        guard WorkspaceDocumentSupport.isURL(targetDirectory, containedIn: workspaceURL) else {
            errorMessage = "Paste items into the current workspace."
            return
        }
        guard !WorkspaceDocumentSupport.isURL(targetDirectory, containedIn: sourceURL) else {
            errorMessage = "A folder cannot be pasted into itself."
            return
        }
        let movesWithinWorkspace = transfer.operation == .cut
            && WorkspaceDocumentSupport.isURL(sourceURL, containedIn: workspaceURL)
        // A move within this workspace can rewrite the links in any note of it; a move from
        // another workspace takes only the item.
        if let owner, let unsaved = owner.unsavedDocument(at: movesWithinWorkspace ? workspaceURL : sourceURL) {
            errorMessage = "Save or close \(unsaved.displayName) in its window first."
            return
        }

        if movesWithinWorkspace {
            requestMarkdownLinkAwareMove(
                sourceURL: sourceURL,
                destinationURL: Self.uniqueDocumentURL(for: sourceURL, in: targetDirectory),
                workspaceURL: workspaceURL,
                failureMessage: "Could not paste \(displayName)",
                selectDestinationAfterMove: true,
                completedTransfer: transfer
            )
            return
        }

        // A Copy pastes the file as it was at Copy while its snapshot is on the pasteboard, as
        // a Paste in another app does.
        let snapshotURL = transfer.operation == .copy
            ? transfer.pasteboardStamp?.snapshotURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            : nil
        startItemTransfer(
            from: sourceURL,
            contentsOf: snapshotURL,
            into: targetDirectory,
            moving: transfer.operation == .cut,
            workspaceURL: workspaceURL,
            completedTransfer: transfer,
            failureMessage: "Could not paste \(displayName)"
        )
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

    /// Ends a pasted Cut, which also leaves the pasteboard while it still holds the item, so a
    /// second Paste does not copy the moved item back from its snapshot. A Copy stays pending, so
    /// every Paste of it makes another copy.
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
        duplicateItem(at: url, into: url.standardizedFileURL.deletingLastPathComponent())
    }

    /// Copies a workspace file or folder into `directoryURL` (the root when nil), with a "copy"
    /// suffix when its name is taken there.
    func duplicateItem(at url: URL, into directoryURL: URL?) {
        let sourceURL = url.standardizedFileURL
        guard let workspaceURL, isWorkspaceItem(sourceURL) else { return }
        guard ensureNotBusy(), ensureWritingToolsInactive(for: "changing the workspace") else { return }

        let targetDirectory = (directoryURL ?? workspaceURL).standardizedFileURL
        guard WorkspaceDocumentSupport.isURL(targetDirectory, containedIn: workspaceURL) else {
            errorMessage = "Copy items into the current workspace."
            return
        }
        guard !WorkspaceDocumentSupport.isURL(targetDirectory, containedIn: sourceURL) else {
            errorMessage = "A folder cannot be copied into itself."
            return
        }

        startItemTransfer(
            from: sourceURL,
            into: targetDirectory,
            moving: false,
            workspaceURL: workspaceURL,
            completedTransfer: nil,
            failureMessage: "Could not duplicate \(sourceURL.lastPathComponent)"
        )
    }

    /// Copies a file or folder, or moves one cut in another workspace, into `targetDirectory` and
    /// selects the result: a file opens, a folder is selected in the sidebar. A copy is made of
    /// `contentsURL`, a snapshot of the file, when given; otherwise it carries the unsaved text of
    /// the copied file, or of every document in the copied folder. Whatever was copied before a
    /// failure stays on disk, so a failure rescans too.
    private func startItemTransfer(
        from sourceURL: URL,
        contentsOf contentsURL: URL? = nil,
        into targetDirectory: URL,
        moving: Bool,
        workspaceURL: URL,
        completedTransfer: WorkspaceDocumentTransfer?,
        failureMessage: String
    ) {
        let sourceID = sourceURL.path
        let dirtyCopyTexts = moving || contentsURL != nil ? [] : unsavedTexts(inItemAt: sourceID)
        let preserveSelection = selectedDocumentID
        noteInternalFileMutation()
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                let destinationURL = Self.uniqueDocumentURL(for: sourceURL, in: targetDirectory)
                let isFolder = Self.isDirectory(sourceURL)
                if moving {
                    try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                } else {
                    try FileManager.default.copyItem(at: contentsURL ?? sourceURL, to: destinationURL)
                    for (subpath, text) in dirtyCopyTexts {
                        let copiedURL = subpath.isEmpty ? destinationURL : destinationURL.appendingPathComponent(subpath)
                        try await Self.writeText(text, to: copiedURL)
                    }
                }

                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishDocumentTransfer(
                    result: result,
                    workspaceURL: workspaceURL,
                    selectedURL: isFolder ? nil : destinationURL,
                    preserveSelection: preserveSelection,
                    sidebarSelection: isFolder ? .folder(destinationURL) : .document,
                    changedPaths: [sourceID, destinationURL.standardizedFileURL.path],
                    completedTransfer: completedTransfer,
                    generation: generation
                )
            } catch {
                let result = try? await Self.scanWorkspace(workspaceURL, scanner: scanner)
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
        let movedItems = workspaceItems.filter { url in
            !workspaceItems.contains { $0 != url && WorkspaceDocumentSupport.isURL(url, containedIn: $0) }
        }

        // The drop replaces a move waiting for its link review, as any other operation does.
        pendingMarkdownLinkMoveReview = nil
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
            moveRun = nil
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
            if !requestMarkdownLinkAwareMove(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                workspaceURL: workspaceURL,
                failureMessage: "Could not move \(sourceURL.lastPathComponent)",
                moveRunID: runID
            ) {
                moveRun = nil
            }
            return
        }

        moveRun = nil
        reportMoveRun(run)
    }

    /// Ends the run `runID` when its link review is cancelled, reporting the items left unmoved.
    private func cancelMoveRun(_ runID: Int?) {
        guard let runID, let run = moveRun, run.id == runID else { return }
        moveRun = nil
        reportMoveRun(run, unmovedCount: 1 + run.moves.count)
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

        startMovingToTrash(document.url, documentIDs: [document.id])
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

        startMovingToTrash(folderURL, documentIDs: Set(contained.map(\.id)))
    }

    /// Moves the item at `url`, which holds the documents `documentIDs`, to the Trash and rescans.
    /// A selected document among them closes, and nothing is selected in the sidebar once the
    /// selection, or the folder holding it, is in the Trash.
    private func startMovingToTrash(_ url: URL, documentIDs: Set<String>) {
        guard let workspaceURL else { return }
        let path = url.standardizedFileURL.path
        let containsSelection = selectedDocumentID.map(documentIDs.contains) == true
        let preserveSelection = containsSelection ? nil : selectedDocumentID
        let sidebarSelection: SidebarSelectionAfterLoad = sidebarSelectionID.map {
            WorkspaceDocumentSupport.isPath($0, containedIn: path)
        } == true ? .cleared : .unchanged
        noteInternalFileMutation()
        invalidateWorkspaceSearchCaches(paths: documentIDs)
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner, moveItemToTrash] in
            do {
                try moveItemToTrash(url)
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishWorkspaceLoad(
                    result: result,
                    workspaceURL: workspaceURL,
                    selectedURL: nil,
                    preserveSelection: preserveSelection,
                    reloadSelection: containsSelection,
                    sidebarSelection: sidebarSelection,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not move \(url.lastPathComponent) to the Trash")
            }
        }
    }

    /// Plans a rename or move that updates the Markdown links to the item, then runs it or asks
    /// for review. `moveRunID` names the move run it is a step of. Returns false when it cannot
    /// start.
    @discardableResult
    private func requestMarkdownLinkAwareMove(
        sourceURL: URL,
        destinationURL: URL,
        workspaceURL: URL,
        failureMessage: String,
        selectDestinationAfterMove: Bool = false,
        completedTransfer: WorkspaceDocumentTransfer? = nil,
        moveRunID: Int? = nil
    ) -> Bool {
        guard ensureNotBusy(), ensureWritingToolsInactive(for: "renaming or moving files") else { return false }

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
            moveRunID: moveRunID
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

                receipt = try Self.commitMarkdownLinkMove(
                    reviewedPlan,
                    workspaceURL: request.workspaceURL
                )
                try Task.checkCancellation()
                let result = try await Self.scanWorkspace(
                    request.workspaceURL,
                    scanner: scanner
                )
                try Task.checkCancellation()

                let applied = await self?.finishMarkdownLinkMove(
                    result: result,
                    plan: reviewedPlan,
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
        if let selectedFolderID {
            self.selectedFolderID = Self.path(selectedFolderID, afterMoving: sourcePath, to: destinationPath)
        }
        if let completedTransfer = request.completedTransfer {
            completeTransfer(completedTransfer)
        }
        if let transfer = pendingDocumentTransfer {
            pendingDocumentTransfer = transfer.following(movedItemAt: sourcePath, to: destinationPath)
        }

        let rewrittenPaths = plan.rewriteFiles.flatMap {
            [$0.originalURL.standardizedFileURL.path, $0.finalURL.standardizedFileURL.path]
        }
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
        if let runID = request.moveRunID, moveRun?.id == runID {
            moveRun?.movedCount += 1
            continueMoveRun(runID)
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
                try await Self.writeText(markdown, to: destinationURL)

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
                try await Self.writeText(markdown, to: destinationURL)

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
            moveRun = nil
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
        selectedFolderID = nil
        sidebarSelectsOpenDocument = true
        setDocumentTextIfChanged("")
        lastSavedText = ""
        setHasUnsavedChangesIfChanged(false)
        setSelectedDocumentExternalChangeIfChanged(false)
        setSelectedDocumentSignatureIfChanged(nil)
        clearReplaceUndoSnapshot()
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
                    previousTextsByDocumentID: batch.previousTextsByDocumentID
                )
                canUndoWorkspaceReplace = true
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
        return summary
    }

    private func finishDocumentTransfer(
        result: WorkspaceDocumentScanResult,
        workspaceURL: URL,
        selectedURL: URL?,
        preserveSelection: String?,
        sidebarSelection: SidebarSelectionAfterLoad,
        changedPaths: [String],
        completedTransfer: WorkspaceDocumentTransfer?,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        invalidateWorkspaceSearchCaches(paths: changedPaths)
        if let completedTransfer {
            completeTransfer(completedTransfer)
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
        documentIDRemapEvent = WorkspaceDocumentIDRemapEvent(
            serial: (documentIDRemapEvent?.serial ?? 0) + 1,
            itemSourcePath: sourcePath,
            itemDestinationPath: destinationPath,
            mappings: mappings.filter { $0.sourceID != $0.destinationID }
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
        guard bypassingSuppression || Date() >= suppressWatcherUntil else {
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
        let delay = max(0, suppressWatcherUntil.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func replaySuppressedWatcherEvent() {
        suppressedWatcherReplayWorkItem = nil
        guard Date() >= suppressWatcherUntil else {
            scheduleSuppressedWatcherReplay()
            return
        }
        guard let event = suppressedWatcherEvent else { return }
        suppressedWatcherEvent = nil
        guard let unmodelledEvent = unmodelledChanges(in: event) else { return }
        scheduleExternalWorkspaceRefresh(unmodelledEvent)
    }

    /// The part of a held watcher event that the sidebar does not already show. Monknot's own
    /// changes during the quiet window are in the model by now, so an item that is listed and on
    /// disk, or neither, is left out. A listed document that was replaced on disk stays as a
    /// content change, which is checked against the signature Monknot recorded for it.
    private func unmodelledChanges(in event: WorkspaceFileWatcher.Event) -> WorkspaceFileWatcher.Event? {
        guard !event.requiresFullRescan else { return event }
        var structuralPaths = Set<String>()
        var modifiedOnlyPaths = event.modifiedOnlyPaths
        for path in event.changedPaths.subtracting(event.modifiedOnlyPaths) {
            let isOnDisk = FileManager.default.fileExists(atPath: path)
            if isOnDisk, documentsByID[path] != nil {
                modifiedOnlyPaths.insert(path)
            } else if isOnDisk != (rootNode?.node(withID: path)?.kind == .folder) {
                structuralPaths.insert(path)
            }
        }
        let changedPaths = structuralPaths.union(modifiedOnlyPaths)
        guard !changedPaths.isEmpty else { return nil }
        return WorkspaceFileWatcher.Event(
            changedPaths: changedPaths,
            modifiedOnlyPaths: modifiedOnlyPaths,
            requiresFullRescan: false
        )
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
        rootNode = result.root
        replaceDocuments(with: result.documents)
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
    private func ensureNotBusy() -> Bool {
        guard !isBusy else {
            errorMessage = Self.busyMessage
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

    nonisolated private static func moveWorkspaceItem(
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

    nonisolated private static func isCanonicalURL(_ candidate: URL, containedIn root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func nextAvailableMarkdownURL(in rootURL: URL) -> URL {
        let fileManager = FileManager.default
        let baseName = "Untitled"
        var candidate = rootURL.appendingPathComponent("\(baseName).md")

        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        var index = 2
        repeat {
            candidate = rootURL.appendingPathComponent("\(baseName) \(index).md")
            index += 1
        } while fileManager.fileExists(atPath: candidate.path)

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
            try text.write(to: url, atomically: true, encoding: .utf8)
        }.value
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
        guard isDirectory else {
            throw WorkspaceDocumentOperationError.unsupportedFileType(name)
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
        guard !pathExtension.isEmpty,
              let typed = WorkspaceDocumentSupport.workspaceClassification(for: URL(fileURLWithPath: "_.\(pathExtension)"))
        else { return false }
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
    nonisolated private static func uniqueDocumentURL(for sourceURL: URL, in directoryURL: URL) -> URL {
        WorkspaceDocumentSupport.availableCopyURL(
            named: sourceURL.lastPathComponent,
            isDirectory: isDirectory(sourceURL),
            in: directoryURL
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
}

private struct WorkspaceMarkdownLinkMoveWrittenFile: Sendable {
    let url: URL
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
}

/// A file or folder Monknot renamed or moved, with the documents that moved with it.
struct WorkspaceDocumentIDRemapEvent: Equatable, Sendable {
    let serial: Int
    let itemSourcePath: String
    let itemDestinationPath: String
    let mappings: [WorkspaceDocumentIDMapping]

    /// Where `path` is now: the moved item and everything inside it follow it, any other path stays.
    func remappedPath(_ path: String) -> String {
        WorkspaceStore.path(path, afterMoving: itemSourcePath, to: itemDestinationPath)
    }
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
    let url: URL
    let operation: WorkspaceDocumentTransferOperation
    let pasteboardStamp: WorkspacePasteboardTransferStamp?

    /// The same transfer once Monknot has moved the item at `sourcePath`, or an item containing it.
    func following(movedItemAt sourcePath: String, to destinationPath: String) -> WorkspaceDocumentTransfer {
        let path = WorkspaceStore.path(url.path, afterMoving: sourcePath, to: destinationPath)
        guard path != url.path else { return self }
        return WorkspaceDocumentTransfer(
            url: URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath),
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
    case couldNotCreateFile(String)
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
    case unsupportedFileType(String)

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
        case .couldNotCreateFile(let name):
            return "Could not create \(name)."
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
        case .unsupportedFileType(let name):
            return "Monknot does not show files like \(name). Add an extension such as .md or .txt."
        }
    }
}
