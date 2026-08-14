import Foundation
import MonknotCore

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var rootNode: SidebarNode?
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
    @Published private(set) var documentText = ""
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var isBusy = false
    @Published private(set) var isDocumentLoading = false
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
    private let recentDocumentStore = RecentDocumentStore()
    private let fileWatcher = WorkspaceFileWatcher()
    private let bookmarkKey = "Monknot.workspaceBookmark"
    private var lastSavedText = ""
    private var dirtyDocumentTexts: [String: String] = [:]
    private var dirtyDocumentBaselines: [String: String] = [:]
    private var dirtyDocumentRevisionExpectations: [String: WorkspaceTextRevisionExpectation] = [:]
    private var pdfDocumentBaselines: [String: Data] = [:]
    private var dirtyPDFDocumentData: [String: Data] = [:]
    private var dirtyPDFDocumentVersions: [String: Int] = [:]
    private var dirtyPDFDocumentEditCheckpoints: [String: PDFAnnotationEditCheckpoint] = [:]
    @Published private var pdfDocumentSavedEditCheckpoints: [String: PDFAnnotationEditCheckpoint] = [:]
    @Published private var pdfDocumentContentVersions: [String: Int] = [:]
    private var removedDirtyDocuments: [String: WorkspaceDocument] = [:]
    private var openDocumentIDs: Set<String> = []
    private var selectedDocumentSignature: FileSignature?
    private var externalRefreshWorkItem: DispatchWorkItem?
    private var externalRefreshTask: Task<Void, Never>?
    private var externalReviewTask: Task<Void, Never>?
    private var externalRefreshGeneration = 0
    private var externalReviewGeneration = 0
    private var suppressWatcherUntil = Date.distantPast
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
    nonisolated static let interactiveTextOpenMaxBytes: Int64 = 4 * 1024 * 1024
    private static let recentDocumentRecordDelayNanoseconds: UInt64 = 350_000_000
    @Published private var pendingDocumentTransfer: WorkspaceDocumentTransfer?

    init(scanner: any WorkspaceDocumentScanning = WorkspaceDocumentScanner()) {
        self.scanner = scanner
    }

    var selectedDocument: WorkspaceDocument? {
        guard let selectedDocumentID else { return nil }
        return document(id: selectedDocumentID)
    }

    var isWorkspaceOpening: Bool {
        workspaceURL != nil && (isBusy || rootNode == nil)
    }

    var canBootstrapStarterWorkspace: Bool {
        workspaceURL != nil && rootNode != nil && documents.isEmpty && !isBusy
    }

    var canPasteDocumentTransfer: Bool {
        pendingDocumentTransfer != nil && workspaceURL != nil
    }

    private var hasDirtyMarkdownDocuments: Bool {
        markdownDocuments.contains { !saveState(for: $0.id).isClean }
    }

    func saveState(for documentID: String) -> DocumentSaveState {
        documentSaveStates[documentID] ?? .clean
    }

    func restoreWorkspace() {
        guard workspaceURL == nil, let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            startWorkspaceLoad(url, selecting: nil, persistBookmark: isStale, preserveSelection: nil, reloadSelection: true)
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            errorMessage = "Could not restore the previous workspace: \(error.localizedDescription)"
        }
    }

    func openWorkspace(_ url: URL) {
        openWorkspace(url, selecting: nil)
    }

    func openWorkspace(_ url: URL, selecting selectedURL: URL?) {
        startWorkspaceLoad(url, selecting: selectedURL, persistBookmark: true, preserveSelection: nil, reloadSelection: true)
    }

    func handleDroppedURL(_ url: URL) {
        Task { [weak self] in
            do {
                let target = try await Self.resolveDroppedTarget(for: url)
                guard let self else { return }

                switch target {
                case .workspace(let workspaceURL):
                    self.startWorkspaceLoad(workspaceURL, selecting: nil, persistBookmark: true, preserveSelection: nil, reloadSelection: true)
                case .document(let workspaceURL, let selectedURL):
                    self.startWorkspaceLoad(workspaceURL, selecting: selectedURL, persistBookmark: true, preserveSelection: nil, reloadSelection: true)
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
              document.capabilities.canEditText || document.kind == .pdf
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

    @discardableResult
    func selectDocument(id: String?) -> Bool {
        guard !isBusy else { return false }
        guard id != selectedDocumentID else { return true }

        let signpostID = MonknotSignposting.documentSelection.beginInterval("SelectDocument")
        defer { MonknotSignposting.documentSelection.endInterval("SelectDocument", signpostID) }

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

        guard !isBusy else { return }

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
        guard !isBusy else { return }

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

        guard !isBusy else { return }

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

        guard !isBusy else { return }

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

    func createFile(named proposedName: String, in directoryURL: URL? = nil) {
        guard let workspaceURL else {
            errorMessage = "Open a workspace before creating a file."
            return
        }

        guard !isBusy else { return }

        let targetDirectory = directoryURL ?? workspaceURL
        let fileURL: URL
        do {
            fileURL = try Self.childURL(in: targetDirectory, proposedName: proposedName)
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

        guard !isBusy else { return }

        let targetDirectory = directoryURL ?? workspaceURL
        let folderURL: URL
        do {
            folderURL = try Self.childURL(in: targetDirectory, proposedName: proposedName)
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
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not create \(folderURL.lastPathComponent)")
            }
        }
    }

    func renameDocument(id: String, to proposedName: String) {
        guard let workspaceURL, !isBusy, let document = document(id: id) else { return }

        let targetURL: URL
        do {
            targetURL = try Self.renamedURL(for: document.url, proposedName: proposedName)
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
        guard let workspaceURL, !isBusy else { return }

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
            targetURL = try Self.renamedURL(for: sourceURL, proposedName: proposedName, preservingExtension: false)
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

    func moveItem(id: String, toDirectory directoryURL: URL?) {
        guard let workspaceURL, !isBusy else { return }

        let sourceURL = URL(fileURLWithPath: id).standardizedFileURL
        let targetDirectory = (directoryURL ?? workspaceURL).standardizedFileURL

        do {
            let destinationURL = try Self.moveDestinationURL(
                for: sourceURL,
                toDirectory: targetDirectory,
                workspaceURL: workspaceURL
            )

            guard destinationURL.standardizedFileURL != sourceURL else {
                return
            }

            requestMarkdownLinkAwareMove(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                workspaceURL: workspaceURL,
                failureMessage: "Could not move \(sourceURL.lastPathComponent)"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyDocument(_ document: WorkspaceDocument) {
        guard documents.contains(where: { $0.id == document.id }) else { return }
        pendingDocumentTransfer = WorkspaceDocumentTransfer(document: document, operation: .copy)
    }

    func cutDocument(_ document: WorkspaceDocument) {
        guard documents.contains(where: { $0.id == document.id }) else { return }
        pendingDocumentTransfer = WorkspaceDocumentTransfer(document: document, operation: .cut)
    }

    func pasteDocumentTransfer(into directoryURL: URL? = nil) {
        guard let workspaceURL, !isBusy, let transfer = pendingDocumentTransfer else { return }

        let targetDirectory = directoryURL ?? workspaceURL
        let sourceURL = transfer.document.url
        let sourceID = transfer.document.id
        let dirtyCopyText = transfer.operation == .copy ? dirtyDocumentTexts[sourceID] : nil

        if transfer.operation == .cut,
           sourceURL.deletingLastPathComponent().standardizedFileURL == targetDirectory.standardizedFileURL {
            pendingDocumentTransfer = nil
            return
        }

        if transfer.operation == .cut {
            let destinationURL = Self.uniqueDocumentURL(for: sourceURL, in: targetDirectory)
            requestMarkdownLinkAwareMove(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                workspaceURL: workspaceURL,
                failureMessage: "Could not paste \(transfer.document.displayName)",
                selectDestinationAfterMove: true,
                clearDocumentTransferOnSuccess: true
            )
            return
        }

        noteInternalFileMutation()
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                let destinationURL = Self.uniqueDocumentURL(for: sourceURL, in: targetDirectory)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                if let dirtyCopyText {
                    try await Self.writeText(dirtyCopyText, to: destinationURL)
                }

                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishDocumentTransfer(
                    result: result,
                    workspaceURL: workspaceURL,
                    selectedURL: destinationURL,
                    sourceID: sourceID,
                    destinationID: destinationURL.standardizedFileURL.path,
                    operation: .copy,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not paste \(transfer.document.displayName)")
            }
        }
    }

    func importPasteboardItems(_ items: [WorkspacePasteboardImportItem], into directoryURL: URL? = nil) {
        guard let workspaceURL else {
            errorMessage = "Open a workspace before pasting clipboard contents."
            return
        }

        guard !isBusy, !items.isEmpty else { return }

        let targetDirectory = directoryURL ?? workspaceURL
        guard Self.isURL(targetDirectory, containedIn: workspaceURL) else {
            errorMessage = "Paste clipboard contents into the current workspace."
            return
        }

        noteInternalFileMutation()
        let preserveSelection = selectedDocumentID
        let shouldSelectImportedCapture = items.contains { $0.prefersSelectionAfterImport }
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                let importedURLs = try WorkspacePasteboardImportService.importItems(items, into: targetDirectory)
                let selectedURL = shouldSelectImportedCapture ? importedURLs.last : nil
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishWorkspaceLoad(
                    result: result,
                    workspaceURL: workspaceURL,
                    selectedURL: selectedURL,
                    preserveSelection: preserveSelection,
                    reloadSelection: selectedURL != nil,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not paste clipboard contents")
            }
        }
    }

    func createMarkdownImageAsset(
        pngData: Data,
        documentID: String,
        commitInsertion: @escaping @MainActor (MarkdownImageAsset) -> Bool
    ) {
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

    func deleteDocument(_ document: WorkspaceDocument) {
        guard let workspaceURL, documents.contains(where: { $0.id == document.id }) else { return }

        if openDocumentIDs.contains(document.id), saveState(for: document.id).isClean == false {
            errorMessage = "Save or close \(document.displayName) before deleting it."
            return
        }

        let preserveSelection = selectedDocumentID
        let didDeleteSelectedDocument = selectedDocumentID == document.id
        noteInternalFileMutation()
        invalidateWorkspaceSearchCaches(paths: [document.id])
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: document.url, resultingItemURL: &trashedURL)
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishWorkspaceLoad(
                    result: result,
                    workspaceURL: workspaceURL,
                    selectedURL: nil,
                    preserveSelection: didDeleteSelectedDocument ? nil : preserveSelection,
                    reloadSelection: didDeleteSelectedDocument,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not delete \(document.displayName)")
            }
        }
    }

    private func requestMarkdownLinkAwareMove(
        sourceURL: URL,
        destinationURL: URL,
        workspaceURL: URL,
        failureMessage: String,
        selectDestinationAfterMove: Bool = false,
        clearDocumentTransferOnSuccess: Bool = false
    ) {
        guard !isBusy else { return }
        guard !hasDirtyMarkdownDocuments else {
            errorMessage = WorkspaceMarkdownLinkMoveError.unsavedMarkdown.errorDescription
            return
        }

        let mappings = Self.documentIDMappings(forMoving: sourceURL, to: destinationURL, documents: documents)
        let preserveSelection = selectedDocumentID
        let selectedURL = selectDestinationAfterMove
            ? destinationURL.standardizedFileURL
            : mappings.first(where: { $0.sourceID == selectedDocumentID })?.destinationURL
        let request = WorkspaceMarkdownLinkMoveRequest(
            workspaceURL: workspaceURL.standardizedFileURL,
            mappings: mappings,
            selectedURL: selectedURL,
            preserveSelection: selectDestinationAfterMove ? nil : preserveSelection,
            reloadSelection: selectDestinationAfterMove || selectedURL != nil,
            clearDocumentTransferOnSuccess: clearDocumentTransferOnSuccess,
            failureMessage: failureMessage
        )
        let documentSnapshot = documents
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let plan = try MarkdownLinkMovePlanner().plan(
                    moving: sourceURL,
                    to: destinationURL,
                    workspaceRootURL: workspaceURL,
                    documents: documentSnapshot
                )
                guard !Task.isCancelled else { return }
                await self?.finishMarkdownLinkMovePlanning(
                    plan: plan,
                    request: request,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(
                    error,
                    generation: generation,
                    message: failureMessage
                )
            }
        }
    }

    func cancelMarkdownLinkMoveReview(id: Int) {
        guard !isBusy, pendingMarkdownLinkMoveReview?.id == id else { return }
        pendingMarkdownLinkMoveReview = nil
    }

    func confirmMarkdownLinkMoveReview(id: Int) {
        guard !isBusy,
              let review = pendingMarkdownLinkMoveReview,
              review.id == id
        else { return }
        startMarkdownLinkMoveCommit(review)
    }

    private func finishMarkdownLinkMovePlanning(
        plan: MarkdownLinkMovePlan,
        request: WorkspaceMarkdownLinkMoveRequest,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

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
        guard workspaceURL?.standardizedFileURL == review.request.workspaceURL else {
            pendingMarkdownLinkMoveReview = nil
            isBusy = false
            errorMessage = "\(review.request.failureMessage): The workspace changed before the move was confirmed."
            return
        }
        guard !hasDirtyMarkdownDocuments else {
            pendingMarkdownLinkMoveReview = nil
            isBusy = false
            errorMessage = WorkspaceMarkdownLinkMoveError.unsavedMarkdown.errorDescription
            return
        }

        noteInternalFileMutation()
        let generation = beginDocumentFileOperation()
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
                await self?.finishWorkspaceFailure(
                    finalError,
                    generation: generation,
                    message: request.failureMessage
                )
            }
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

        for mapping in request.mappings {
            moveDirtyState(from: mapping.sourceID, to: mapping.destinationID)
        }
        publishDocumentIDRemaps(request.mappings)
        if request.clearDocumentTransferOnSuccess {
            pendingDocumentTransfer = nil
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
            generation: generation
        )
        return true
    }

    func setDocumentText(_ text: String) {
        guard selectedDocument?.capabilities.canEditText == true else { return }
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
            discardUnsavedChanges(for: selectedDocumentID)
        }
    }

    @discardableResult
    func applyTextMutation(
        documentID: String,
        range: NSRange,
        expectedText: String,
        replacement: String
    ) -> WorkspaceTextMutation? {
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
        guard let file = document(id: documentID), file.kind == .pdf else { return }
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

        applyPDFData(data, editCheckpoint: editCheckpoint, to: file)
    }

    @discardableResult
    func restorePDFSavedEditCheckpoint(
        id documentID: String,
        checkpoint: PDFAnnotationEditCheckpoint
    ) -> Bool {
        guard pdfDocumentSavedEditCheckpoints[documentID] == checkpoint,
              let file = document(id: documentID),
              file.kind == .pdf,
              let baseline = pdfDocumentBaselines[documentID]
        else { return false }

        guard let diskData = try? Data(contentsOf: file.url), diskData == baseline else {
            if selectedDocumentID == documentID {
                setSelectedDocumentExternalChangeIfChanged(true)
            }
            errorMessage = "\(file.displayName) changed on disk. Reload it or save your annotated version as a copy."
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
                let destinationURL = Self.uniqueDocumentURL(
                    for: notesURL.appendingPathComponent("\(document.url.deletingPathExtension().lastPathComponent) Annotations.md"),
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
                let destinationURL = Self.uniqueDocumentURL(
                    for: notesURL.appendingPathComponent("Workspace PDF Annotations.md"),
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

                let destinationURL = Self.uniqueDocumentURL(
                    for: exportsURL.appendingPathComponent("\(document.url.deletingPathExtension().lastPathComponent) Annotated.pdf"),
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

        if selectedDocument.kind == .pdf {
            saveSelectedPDF(selectedDocument)
            return
        }

        guard selectedDocument.capabilities.canEditText else { return }

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
        guard !saveState(for: documentID).isClean else { return true }

        if file.kind == .pdf {
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
              let document = document(id: state.documentID)
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
        let isPDF = document(id: documentID)?.kind == .pdf
        let hadSearchablePDFDirtyData = dirtyPDFDocumentData[documentID] != nil
        dirtyDocumentTexts.removeValue(forKey: documentID)
        dirtyDocumentBaselines.removeValue(forKey: documentID)
        dirtyDocumentRevisionExpectations.removeValue(forKey: documentID)
        pdfDocumentBaselines.removeValue(forKey: documentID)
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

        saveGeneration += 1
        let generation = saveGeneration
        setSaveState(.saving, for: file.id)
        setSavingIfChanged(true)
        noteInternalFileMutation()

        saveTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let writtenData = try WorkspaceConditionalDataWriter.write(
                    pdfData,
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

        saveGeneration += 1
        let generation = saveGeneration
        setSaveState(.saving, for: file.id)
        setSavingIfChanged(true)
        noteInternalFileMutation()

        do {
            let writtenData = try await Task.detached(priority: .utility) {
                try WorkspaceConditionalDataWriter.write(
                    pdfData,
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
        dirtyPDFDocumentEditCheckpoints.removeValue(forKey: documentID)
        pdfDocumentSavedEditCheckpoints.removeValue(forKey: documentID)
        pdfDocumentContentVersions[documentID, default: 0] &+= 1
    }

    func markdownTextForExport(_ document: WorkspaceDocument) async throws -> String {
        guard document.kind == .markdown else {
            throw WorkspaceDocumentOperationError.unsupportedPDFExport(document.displayName)
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
        persistBookmark: Bool,
        preserveSelection: String?,
        reloadSelection: Bool,
        recordRecentWorkspace: Bool = true
    ) {
        let standardizedURL = url.standardizedFileURL
        cancelExternalDocumentReview()
        updateSecurityScope(for: standardizedURL)

        if persistBookmark {
            do {
                let bookmarkData = try standardizedURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
            } catch {
                errorMessage = "Could not persist workspace access: \(error.localizedDescription)"
            }
        }

        if workspaceURL?.standardizedFileURL != standardizedURL {
            pendingDocumentTransfer = nil
            dirtyDocumentTexts = [:]
            dirtyDocumentBaselines = [:]
            dirtyDocumentRevisionExpectations = [:]
            pdfDocumentBaselines = [:]
            dirtyPDFDocumentData = [:]
            dirtyPDFDocumentVersions = [:]
            dirtyPDFDocumentEditCheckpoints = [:]
            pdfDocumentSavedEditCheckpoints = [:]
            pdfDocumentContentVersions = [:]
            removedDirtyDocuments = [:]
            removedDirtyOpenDocumentIDs = []
            openDocumentIDs = []
            documentSaveStates = [:]
            invalidateAllWorkspaceSearchCaches()
        }

        workspaceURL = standardizedURL
        let generation = beginWorkspaceOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                let result = try await Self.scanWorkspace(standardizedURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishWorkspaceLoad(
                    result: result,
                    workspaceURL: standardizedURL,
                    selectedURL: selectedURL,
                    preserveSelection: preserveSelection,
                    reloadSelection: reloadSelection,
                    recordRecentWorkspace: recordRecentWorkspace,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not open workspace")
            }
        }
    }

    private func beginWorkspaceOperation() -> Int {
        workspaceTask?.cancel()
        documentTask?.cancel()
        recentDocumentRecordTask?.cancel()
        pendingMarkdownLinkMoveReview = nil
        workspaceGeneration += 1
        isBusy = true
        setDocumentLoadingIfChanged(false)
        errorMessage = nil
        return workspaceGeneration
    }

    private func beginDocumentFileOperation() -> Int {
        saveTask?.cancel()
        markdownImageAssetTask?.cancel()
        saveGeneration += 1
        setSavingIfChanged(false)
        return beginWorkspaceOperation()
    }

    private func finishWorkspaceLoad(
        result: WorkspaceDocumentScanResult,
        workspaceURL: URL,
        selectedURL: URL?,
        preserveSelection: String?,
        reloadSelection: Bool,
        recordRecentWorkspace: Bool = false,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        let previousDocuments = documents
        rootNode = result.root
        replaceDocuments(with: result.documents)
        pruneSaveStates(previousDocuments: previousDocuments)
        ensureFileWatcher(for: workspaceURL)
        if recordRecentWorkspace {
            RecentWorkspaceStore().record(workspaceURL)
        }

        if let selectedURL,
           let selectedDocument = documentsByID[selectedURL.standardizedFileURL.path] {
            selectedDocumentID = selectedDocument.id
        } else if let preserveSelection, documentsByID[preserveSelection] != nil {
            selectedDocumentID = preserveSelection
        } else {
            selectedDocumentID = documents.first?.id
        }

        isBusy = false

        if reloadSelection || documentText.isEmpty || selectedDocumentID != preserveSelection {
            loadSelectedDocument()
        }
        refreshGitStatus()
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
        selectedDocumentID = documentsByID[fileURL.standardizedFileURL.path]?.id
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
        selectedURL: URL,
        sourceID: String,
        destinationID: String,
        operation: WorkspaceDocumentTransferOperation,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        guard operation == .copy else { return }
        invalidateWorkspaceSearchCaches(paths: [sourceID, destinationID])
        pendingDocumentTransfer = nil
        finishWorkspaceLoad(
            result: result,
            workspaceURL: workspaceURL,
            selectedURL: selectedURL,
            preserveSelection: nil,
            reloadSelection: true,
            generation: generation
        )
    }

    private func updateSecurityScope(for url: URL) {
        if securityScopedURL == url {
            return
        }

        fileWatcher.stop()
        externalRefreshWorkItem?.cancel()
        externalRefreshTask?.cancel()
        externalReviewTask?.cancel()

        if let securityScopedURL {
            securityScopedURL.stopAccessingSecurityScopedResource()
        }

        securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    private func loadSelectedDocument() {
        documentTask?.cancel()
        documentGeneration += 1
        let generation = documentGeneration

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
            if selectedDocument.kind == .pdf, hasUnsavedChanges, saveState(for: selectedDocument.id).isClean {
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

            guard let self,
                  self.selectedDocumentID == documentID,
                  self.workspaceURL?.standardizedFileURL.path == workspacePath
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
        if case WorkspaceTextFileGuard.Error.fileTooLarge = error {
            errorMessage = "\(file.displayName) is too large to open in the editor. \(error.localizedDescription)"
        } else {
            errorMessage = "Could not read \(file.displayName): \(error.localizedDescription)"
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
            if selectedDocumentID == file.id {
                setSelectedDocumentExternalChangeIfChanged(true)
            }
            errorMessage = "\(file.displayName) changed on disk. Reload it or save your annotated version as a copy."
        } else {
            errorMessage = "Could not save \(file.displayName): \(error.localizedDescription)"
        }
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

    private func publishDocumentIDRemaps(_ mappings: [WorkspaceDocumentIDMapping]) {
        let mappings = mappings.filter { $0.sourceID != $0.destinationID }
        guard !mappings.isEmpty else { return }
        let serial = (documentIDRemapEvent?.serial ?? 0) + 1
        documentIDRemapEvent = WorkspaceDocumentIDRemapEvent(
            serial: serial,
            mappings: mappings
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

    internal func testing_clearWatcherSuppression() {
        suppressWatcherUntil = .distantPast
    }

    internal func testing_stopFileWatcher() {
        fileWatcher.stop()
        externalRefreshWorkItem?.cancel()
        externalRefreshWorkItem = nil
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

    private func scheduleExternalWorkspaceRefresh(_ event: WorkspaceFileWatcher.Event) {
        guard workspaceURL != nil else { return }
        guard Date() >= suppressWatcherUntil else { return }
        guard event.requiresFullRescan || event.changedPaths.contains(where: { Self.isRelevantExternalChange(path: $0) }) else {
            return
        }

        if !event.requiresFullRescan,
           event.modifiedOnlyPaths.contains(where: { Self.isRelevantExternalChange(path: $0) }),
           event.changedPaths.isSubset(of: event.modifiedOnlyPaths) {
            applyIncrementalFileModifications(paths: event.modifiedOnlyPaths)
            return
        }

        if !event.requiresFullRescan, applyIncrementalFileChanges(paths: event.changedPaths) {
            return
        }

        if event.requiresFullRescan {
            invalidateAllWorkspaceSearchCaches()
        } else {
            invalidateWorkspaceSearchCaches(paths: event.changedPaths)
        }

        externalRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.runExternalWorkspaceRefresh()
            }
        }
        externalRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
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
        externalRefreshTask?.cancel()
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
        if selectedDocument.kind == .pdf {
            if hasUnsavedChanges {
                setSelectedDocumentExternalChangeIfChanged(true)
                return
            }
            guard !isSaving else { return }
            setSelectedDocumentSignatureIfChanged(nextSignature)
            publishPDFContentReplacement(for: selectedDocument.id)
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
            loadSelectedDocument()
        } else if selectedDocumentSignature == nil {
            setSelectedDocumentSignatureIfChanged(nextSignature)
        }
    }

    private func runExternalWorkspaceRefresh() {
        guard let workspaceURL else { return }
        guard !isBusy else {
            scheduleExternalWorkspaceRefresh(.init(
                changedPaths: [workspaceURL.path],
                modifiedOnlyPaths: [],
                requiresFullRescan: true
            ))
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
        } else if previousSelection == nil {
            selectedDocumentID = nil
            setSelectedDocumentSignatureIfChanged(nil)
        } else {
            selectedDocumentID = documents.first?.id
            setSelectedDocumentSignatureIfChanged(nil)
        }

        guard !dirtySelectionRemoved else { return }
        guard let selectedDocument else { return }
        let nextSignature = Self.fileSignature(for: selectedDocument.url)
        if selectedDocument.kind == .pdf {
            if hasUnsavedChanges,
               selectionStillExists,
               selectedDocumentSignature != nil,
               nextSignature != selectedDocumentSignature {
                setSelectedDocumentExternalChangeIfChanged(true)
            } else if !hasUnsavedChanges,
               !isSaving,
               selectionStillExists,
               selectedDocumentSignature != nil,
               nextSignature != selectedDocumentSignature {
                setSelectedDocumentSignatureIfChanged(nextSignature)
                publishPDFContentReplacement(for: selectedDocument.id)
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
            loadSelectedDocument()
        } else if selectedDocumentSignature == nil {
            setSelectedDocumentSignatureIfChanged(nextSignature)
        }
    }

    private func finishExternalWorkspaceRefresh(
        result: WorkspaceDocumentScanResult,
        workspaceURL: URL,
        workspaceOperationGeneration: Int,
        generation: Int
    ) {
        guard generation == externalRefreshGeneration else { return }
        guard workspaceURL.standardizedFileURL == self.workspaceURL?.standardizedFileURL else { return }
        guard workspaceOperationGeneration == workspaceGeneration else { return }

        applyExternalWorkspaceResult(result)
        refreshGitStatus()
    }

    private func finishExternalWorkspaceFailure(_ error: Error, generation: Int) {
        guard generation == externalRefreshGeneration else { return }
        errorMessage = "Could not refresh workspace changes: \(error.localizedDescription)"
    }

    private func refreshGitStatus() {
        guard !gitStatusByRelativePath.isEmpty else { return }
        gitStatusByRelativePath = [:]
    }

    private static func isRelevantExternalChange(path: String) -> Bool {
        let ignored = Set([".git", ".build", "DerivedData", "dist", "node_modules"])
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

    nonisolated private static func childURL(in directoryURL: URL, proposedName: String) throws -> URL {
        let fileName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileName.isEmpty else {
            throw WorkspaceDocumentOperationError.emptyName
        }

        guard fileName.rangeOfCharacter(from: CharacterSet(charactersIn: "/:")) == nil else {
            throw WorkspaceDocumentOperationError.nestedName
        }

        guard fileName != "." && fileName != ".." else {
            throw WorkspaceDocumentOperationError.invalidName(fileName)
        }

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
        guard fileURL != workspaceURL, isURL(fileURL, containedIn: workspaceURL) else {
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

        let validatedChild = try childURL(in: parentURL, proposedName: fileURL.lastPathComponent)
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

    nonisolated private static func renamedURL(
        for sourceURL: URL,
        proposedName: String,
        preservingExtension: Bool = true
    ) throws -> URL {
        var fileName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileName.isEmpty else {
            throw WorkspaceDocumentOperationError.emptyName
        }

        guard fileName.rangeOfCharacter(from: CharacterSet(charactersIn: "/:")) == nil else {
            throw WorkspaceDocumentOperationError.nestedName
        }

        if preservingExtension, URL(fileURLWithPath: fileName).pathExtension.isEmpty, !sourceURL.pathExtension.isEmpty {
            fileName += ".\(sourceURL.pathExtension)"
        }

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

    nonisolated private static func moveDestinationURL(
        for sourceURL: URL,
        toDirectory targetDirectory: URL,
        workspaceURL: URL
    ) throws -> URL {
        let sourceURL = sourceURL.standardizedFileURL
        let targetDirectory = targetDirectory.standardizedFileURL
        let workspaceURL = workspaceURL.standardizedFileURL

        guard isURL(sourceURL, containedIn: workspaceURL) else {
            throw WorkspaceDocumentOperationError.invalidMove("Move items from inside the current workspace.")
        }

        var targetIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: targetDirectory.path, isDirectory: &targetIsDirectory),
              targetIsDirectory.boolValue else {
            throw WorkspaceDocumentOperationError.notDirectory(targetDirectory.lastPathComponent)
        }

        guard isURL(targetDirectory, containedIn: workspaceURL) else {
            throw WorkspaceDocumentOperationError.invalidMove("Move items into the current workspace.")
        }

        var sourceIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory) else {
            throw WorkspaceDocumentOperationError.invalidMove("The item no longer exists.")
        }

        if sourceIsDirectory.boolValue, isURL(targetDirectory, containedIn: sourceURL) {
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
        let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"

        return documents.compactMap { document in
            let documentPath = document.url.standardizedFileURL.path
            let remappedPath: String?

            if documentPath == sourcePath {
                remappedPath = destinationPath
            } else if documentPath.hasPrefix(sourcePrefix) {
                remappedPath = destinationPath + "/" + documentPath.dropFirst(sourcePrefix.count)
            } else {
                remappedPath = nil
            }

            guard let remappedPath, remappedPath != documentPath else {
                return nil
            }

            return WorkspaceDocumentIDMapping(sourceID: documentPath, destinationID: remappedPath)
        }
    }

    nonisolated private static func isURL(_ candidate: URL, containedIn directory: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return candidatePath == directoryPath || candidatePath.hasPrefix(prefix)
    }

    nonisolated private static func uniqueDocumentURL(for sourceURL: URL, in directoryURL: URL) -> URL {
        let fileManager = FileManager.default
        let sourceExtension = sourceURL.pathExtension
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        var candidate = directoryURL.appendingPathComponent(sourceURL.lastPathComponent)

        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        var index = 1
        repeat {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let name = sourceExtension.isEmpty
                ? "\(baseName)\(suffix)"
                : "\(baseName)\(suffix).\(sourceExtension)"
            candidate = directoryURL.appendingPathComponent(name)
            index += 1
        } while fileManager.fileExists(atPath: candidate.path)

        return candidate
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
    let clearDocumentTransferOnSuccess: Bool
    let failureMessage: String
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
    case unsavedMarkdown
    case staleReview
    case sourceOutsideWorkspace
    case destinationOutsideWorkspace
    case sourceMissing
    case destinationExists
    case rollbackFailed(operation: String, rollback: String)
    case rollbackIncomplete(String)

    var errorDescription: String? {
        switch self {
        case .unsavedMarkdown:
            return "Save Markdown changes before renaming or moving workspace items."
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

struct WorkspaceDocumentIDRemapEvent: Equatable, Sendable {
    let serial: Int
    let mappings: [WorkspaceDocumentIDMapping]

    var sourceID: String {
        mappings.first?.sourceID ?? ""
    }

    var destinationID: String {
        mappings.first?.destinationID ?? ""
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

private struct WorkspaceDocumentTransfer: Sendable {
    let document: WorkspaceDocument
    let operation: WorkspaceDocumentTransferOperation
}

private enum WorkspaceDocumentTransferOperation: Sendable {
    case copy
    case cut
}

private enum WorkspaceDocumentOperationError: LocalizedError {
    case emptyName
    case nestedName
    case invalidName(String)
    case couldNotCreateFile(String)
    case unsupportedPDFExport(String)
    case unsupportedPDFAnnotationExport(String)
    case destinationExists(String)
    case invalidMove(String)
    case invalidCreation(String)
    case notDirectory(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "File name cannot be empty."
        case .nestedName:
            return "File name cannot contain path separators."
        case .invalidName(let name):
            return "\(name) is not a valid file name."
        case .couldNotCreateFile(let name):
            return "Could not create \(name)."
        case .unsupportedPDFExport(let name):
            return "\(name) is not a Markdown file."
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
        }
    }
}
