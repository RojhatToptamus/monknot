import Foundation
import MarkprevCore

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var rootNode: SidebarNode?
    @Published private(set) var documents: [WorkspaceDocument] = []
    @Published private(set) var selectedDocumentID: String?
    @Published private(set) var documentText = ""
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var isBusy = false
    @Published private(set) var isDocumentLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var documentSaveStates: [String: DocumentSaveState] = [:]
    @Published private(set) var selectedDocumentExternalChange = false
    @Published var errorMessage: String?

    private let scanner: any WorkspaceDocumentScanning
    private let fileWatcher = WorkspaceFileWatcher()
    private let bookmarkKey = "Markprev.workspaceBookmark"
    private var lastSavedText = ""
    private var dirtyDocumentTexts: [String: String] = [:]
    private var dirtyDocumentBaselines: [String: String] = [:]
    private var selectedDocumentSignature: FileSignature?
    private var externalRefreshWorkItem: DispatchWorkItem?
    private var externalRefreshTask: Task<Void, Never>?
    private var externalRefreshGeneration = 0
    private var suppressWatcherUntil = Date.distantPast
    private var securityScopedURL: URL?
    private var workspaceTask: Task<Void, Never>?
    private var documentTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var workspaceGeneration = 0
    private var documentGeneration = 0
    private var saveGeneration = 0
    @Published private var pendingDocumentTransfer: WorkspaceDocumentTransfer?

    init(scanner: any WorkspaceDocumentScanning = WorkspaceDocumentScanner()) {
        self.scanner = scanner
    }

    var selectedDocument: WorkspaceDocument? {
        documents.first { $0.id == selectedDocumentID }
    }

    var canPasteDocumentTransfer: Bool {
        pendingDocumentTransfer != nil && workspaceURL != nil
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
        startWorkspaceLoad(url, selecting: nil, persistBookmark: true, preserveSelection: nil, reloadSelection: true)
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
    }

    func selectDocument(id: String?) {
        guard id != selectedDocumentID, !isBusy else { return }

        selectedDocumentID = id
        loadSelectedDocument()
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
        guard let workspaceURL, let document = documents.first(where: { $0.id == id }) else { return }

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

        let preserveSelection = selectedDocumentID
        let selectedURL = preserveSelection == document.id ? targetURL : nil
        let shouldReloadSelection = preserveSelection == document.id
        let sourceID = document.id
        noteInternalFileMutation()
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                try FileManager.default.moveItem(at: document.url, to: targetURL)
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishRenamedDocument(
                    result: result,
                    workspaceURL: workspaceURL,
                    sourceID: sourceID,
                    destinationID: targetURL.standardizedFileURL.path,
                    selectedURL: selectedURL,
                    preserveSelection: preserveSelection,
                    reloadSelection: shouldReloadSelection,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not rename \(document.displayName)")
            }
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
        guard let workspaceURL, let transfer = pendingDocumentTransfer else { return }

        let targetDirectory = directoryURL ?? workspaceURL
        let sourceURL = transfer.document.url
        let sourceID = transfer.document.id
        let dirtyCopyText = transfer.operation == .copy ? dirtyDocumentTexts[sourceID] : nil

        if transfer.operation == .cut,
           sourceURL.deletingLastPathComponent().standardizedFileURL == targetDirectory.standardizedFileURL {
            pendingDocumentTransfer = nil
            return
        }

        noteInternalFileMutation()
        let generation = beginDocumentFileOperation()

        workspaceTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            do {
                let destinationURL = Self.uniqueDocumentURL(for: sourceURL, in: targetDirectory)
                switch transfer.operation {
                case .copy:
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    if let dirtyCopyText {
                        try await Self.writeText(dirtyCopyText, to: destinationURL)
                    }
                case .cut:
                    try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                }

                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishDocumentTransfer(
                    result: result,
                    workspaceURL: workspaceURL,
                    selectedURL: destinationURL,
                    sourceID: sourceID,
                    destinationID: destinationURL.standardizedFileURL.path,
                    operation: transfer.operation,
                    generation: generation
                )
            } catch {
                await self?.finishWorkspaceFailure(error, generation: generation, message: "Could not paste \(transfer.document.displayName)")
            }
        }
    }

    func deleteDocument(_ document: WorkspaceDocument) {
        guard let workspaceURL, documents.contains(where: { $0.id == document.id }) else { return }

        let preserveSelection = selectedDocumentID
        let didDeleteSelectedDocument = selectedDocumentID == document.id
        noteInternalFileMutation()
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

    func setDocumentText(_ text: String) {
        guard selectedDocument?.capabilities.canEditText == true else { return }
        guard text != documentText else { return }

        documentText = text
        hasUnsavedChanges = text != lastSavedText
        updateSaveStateForSelectedDocument()
    }

    func saveSelectedFile() {
        guard let selectedDocument, selectedDocument.capabilities.canEditText else { return }

        let file = selectedDocument
        let text = documentText
        saveGeneration += 1
        let generation = saveGeneration
        setSaveState(.saving, for: file.id)
        isSaving = true
        noteInternalFileMutation()

        saveTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Self.writeText(text, to: file.url)
                guard !Task.isCancelled else { return }
                await self?.finishSave(fileID: file.id, text: text, generation: generation)
            } catch {
                await self?.finishSaveFailure(error, file: file, generation: generation)
            }
        }
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
        reloadSelection: Bool
    ) {
        let standardizedURL = url.standardizedFileURL
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
            documentSaveStates = [:]
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
        workspaceGeneration += 1
        isBusy = true
        isDocumentLoading = false
        errorMessage = nil
        return workspaceGeneration
    }

    private func beginDocumentFileOperation() -> Int {
        saveTask?.cancel()
        saveGeneration += 1
        isSaving = false
        return beginWorkspaceOperation()
    }

    private func finishWorkspaceLoad(
        result: WorkspaceDocumentScanResult,
        workspaceURL: URL,
        selectedURL: URL?,
        preserveSelection: String?,
        reloadSelection: Bool,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        rootNode = result.root
        documents = result.documents
        pruneSaveStates()
        ensureFileWatcher(for: workspaceURL)

        if let selectedURL {
            selectedDocumentID = WorkspaceDocument(url: selectedURL, rootURL: workspaceURL).id
        } else if let preserveSelection, documents.contains(where: { $0.id == preserveSelection }) {
            selectedDocumentID = preserveSelection
        } else {
            selectedDocumentID = documents.first?.id
        }

        isBusy = false

        if reloadSelection || documentText.isEmpty || selectedDocumentID != preserveSelection {
            loadSelectedDocument()
        }
    }

    private func finishCreatedFile(
        result: WorkspaceDocumentScanResult,
        fileURL: URL,
        workspaceURL: URL,
        initialText: String,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        rootNode = result.root
        documents = result.documents
        pruneSaveStates()
        ensureFileWatcher(for: workspaceURL)
        selectedDocumentID = WorkspaceDocument(url: fileURL, rootURL: workspaceURL).id
        documentText = initialText
        lastSavedText = initialText
        hasUnsavedChanges = false
        selectedDocumentExternalChange = false
        selectedDocumentSignature = Self.fileSignature(for: fileURL)
        setSaveState(.clean, for: selectedDocumentID)
        isBusy = false
    }

    private func finishWorkspaceFailure(_ error: Error, generation: Int, message: String) {
        guard generation == workspaceGeneration else { return }

        isBusy = false
        isDocumentLoading = false
        errorMessage = "\(message): \(error.localizedDescription)"
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

        if operation == .cut {
            moveDirtyState(from: sourceID, to: destinationID)
        }
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

    private func finishRenamedDocument(
        result: WorkspaceDocumentScanResult,
        workspaceURL: URL,
        sourceID: String,
        destinationID: String,
        selectedURL: URL?,
        preserveSelection: String?,
        reloadSelection: Bool,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        moveDirtyState(from: sourceID, to: destinationID)
        finishWorkspaceLoad(
            result: result,
            workspaceURL: workspaceURL,
            selectedURL: selectedURL,
            preserveSelection: preserveSelection,
            reloadSelection: reloadSelection,
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
            documentText = ""
            lastSavedText = ""
            hasUnsavedChanges = false
            selectedDocumentSignature = nil
            selectedDocumentExternalChange = false
            isDocumentLoading = false
            return
        }

        guard selectedDocument.capabilities.canEditText else {
            documentText = ""
            lastSavedText = ""
            hasUnsavedChanges = false
            selectedDocumentSignature = nil
            selectedDocumentExternalChange = false
            isDocumentLoading = false
            return
        }

        let file = selectedDocument

        if let dirtyText = dirtyDocumentTexts[file.id] {
            documentText = dirtyText
            lastSavedText = dirtyDocumentBaselines[file.id] ?? dirtyText
            hasUnsavedChanges = dirtyText != lastSavedText
            selectedDocumentSignature = Self.fileSignature(for: file.url)
            selectedDocumentExternalChange = false
            isDocumentLoading = false
            setSaveState(hasUnsavedChanges ? .edited : .clean, for: file.id)
            return
        }

        isDocumentLoading = true

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

    private func finishDocumentLoad(file: WorkspaceDocument, text: String, generation: Int) {
        guard generation == documentGeneration, selectedDocumentID == file.id else { return }

        documentText = text
        lastSavedText = text
        hasUnsavedChanges = false
        dirtyDocumentTexts.removeValue(forKey: file.id)
        dirtyDocumentBaselines.removeValue(forKey: file.id)
        selectedDocumentSignature = Self.fileSignature(for: file.url)
        selectedDocumentExternalChange = false
        setSaveState(.clean, for: file.id)
        isDocumentLoading = false
    }

    private func finishDocumentLoadFailure(_ error: Error, file: WorkspaceDocument, generation: Int) {
        guard generation == documentGeneration, selectedDocumentID == file.id else { return }

        documentText = ""
        lastSavedText = ""
        hasUnsavedChanges = false
        selectedDocumentSignature = nil
        isDocumentLoading = false
        errorMessage = "Could not read \(file.displayName): \(error.localizedDescription)"
    }

    private func finishSave(fileID: String, text: String, generation: Int) {
        if generation == saveGeneration {
            isSaving = false
        }

        guard selectedDocumentID == fileID else {
            if dirtyDocumentTexts[fileID] == nil || dirtyDocumentTexts[fileID] == text {
                dirtyDocumentTexts.removeValue(forKey: fileID)
                dirtyDocumentBaselines.removeValue(forKey: fileID)
                setSaveState(.clean, for: fileID)
            } else {
                dirtyDocumentBaselines[fileID] = text
                setSaveState(.edited, for: fileID)
            }
            return
        }

        lastSavedText = text
        hasUnsavedChanges = documentText != lastSavedText
        selectedDocumentExternalChange = false
        if hasUnsavedChanges {
            dirtyDocumentTexts[fileID] = documentText
            dirtyDocumentBaselines[fileID] = lastSavedText
        } else {
            dirtyDocumentTexts.removeValue(forKey: fileID)
            dirtyDocumentBaselines.removeValue(forKey: fileID)
        }
        selectedDocumentSignature = selectedDocument.map { Self.fileSignature(for: $0.url) } ?? selectedDocumentSignature
        setSaveState(hasUnsavedChanges ? .edited : .clean, for: fileID)
    }

    private func finishSaveFailure(_ error: Error, file: WorkspaceDocument, generation: Int) {
        if generation == saveGeneration {
            isSaving = false
        }
        setSaveState(.failed(error.localizedDescription), for: file.id)
        errorMessage = "Could not save \(file.displayName): \(error.localizedDescription)"
    }

    private func updateSaveStateForSelectedDocument() {
        guard let selectedDocumentID else { return }
        if hasUnsavedChanges {
            if dirtyDocumentBaselines[selectedDocumentID] == nil {
                dirtyDocumentBaselines[selectedDocumentID] = lastSavedText
            }
            dirtyDocumentTexts[selectedDocumentID] = documentText
        } else {
            dirtyDocumentTexts.removeValue(forKey: selectedDocumentID)
            dirtyDocumentBaselines.removeValue(forKey: selectedDocumentID)
        }
        setSaveState(hasUnsavedChanges ? .edited : .clean, for: selectedDocumentID)
    }

    private func setSaveState(_ state: DocumentSaveState, for documentID: String?) {
        guard let documentID else { return }
        if state.isClean {
            documentSaveStates.removeValue(forKey: documentID)
        } else {
            documentSaveStates[documentID] = state
        }
    }

    private func pruneSaveStates() {
        let documentIDs = Set(documents.map(\.id))
        documentSaveStates = documentSaveStates.filter { documentIDs.contains($0.key) }
        dirtyDocumentTexts = dirtyDocumentTexts.filter { documentIDs.contains($0.key) }
        dirtyDocumentBaselines = dirtyDocumentBaselines.filter { documentIDs.contains($0.key) }
        if let selectedDocumentID {
            hasUnsavedChanges = dirtyDocumentTexts[selectedDocumentID] != nil
        }
    }

    private func moveDirtyState(from sourceID: String, to destinationID: String) {
        guard sourceID != destinationID else { return }

        if let text = dirtyDocumentTexts.removeValue(forKey: sourceID) {
            dirtyDocumentTexts[destinationID] = text
        }

        if let baseline = dirtyDocumentBaselines.removeValue(forKey: sourceID) {
            dirtyDocumentBaselines[destinationID] = baseline
        }

        if let state = documentSaveStates.removeValue(forKey: sourceID) {
            documentSaveStates[destinationID] = state
        }

        if selectedDocumentID == sourceID {
            selectedDocumentID = destinationID
        }
    }

    private func noteInternalFileMutation() {
        suppressWatcherUntil = Date().addingTimeInterval(1.2)
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

        externalRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.runExternalWorkspaceRefresh()
            }
        }
        externalRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func runExternalWorkspaceRefresh() {
        guard let workspaceURL else { return }
        guard !isBusy else {
            scheduleExternalWorkspaceRefresh(.init(changedPaths: [workspaceURL.path], requiresFullRescan: true))
            return
        }

        externalRefreshGeneration += 1
        let generation = externalRefreshGeneration
        let workspaceOperationGeneration = workspaceGeneration
        let selectedSignature = selectedDocumentSignature

        externalRefreshTask?.cancel()
        externalRefreshTask = Task.detached(priority: .utility) { [weak self, scanner] in
            do {
                let result = try await Self.scanWorkspace(workspaceURL, scanner: scanner)
                guard !Task.isCancelled else { return }
                await self?.finishExternalWorkspaceRefresh(
                    result: result,
                    workspaceURL: workspaceURL,
                    selectedSignature: selectedSignature,
                    workspaceOperationGeneration: workspaceOperationGeneration,
                    generation: generation
                )
            } catch {
                await self?.finishExternalWorkspaceFailure(error, generation: generation)
            }
        }
    }

    private func finishExternalWorkspaceRefresh(
        result: WorkspaceDocumentScanResult,
        workspaceURL: URL,
        selectedSignature: FileSignature?,
        workspaceOperationGeneration: Int,
        generation: Int
    ) {
        guard generation == externalRefreshGeneration else { return }
        guard workspaceURL.standardizedFileURL == self.workspaceURL?.standardizedFileURL else { return }
        guard workspaceOperationGeneration == workspaceGeneration else { return }

        let previousSelection = selectedDocumentID
        let selectionStillExists = previousSelection.map { id in result.documents.contains { $0.id == id } } ?? false

        if previousSelection != nil, !selectionStillExists, hasUnsavedChanges {
            selectedDocumentExternalChange = true
            return
        }

        rootNode = result.root
        documents = result.documents
        pruneSaveStates()

        if selectionStillExists {
            selectedDocumentID = previousSelection
        } else {
            selectedDocumentID = documents.first?.id
            selectedDocumentSignature = nil
        }

        guard let selectedDocument, selectedDocument.capabilities.canEditText else { return }
        let nextSignature = Self.fileSignature(for: selectedDocument.url)
        if hasUnsavedChanges, selectedSignature != nil, nextSignature != selectedSignature {
            selectedDocumentExternalChange = true
        } else if !hasUnsavedChanges, !isSaving, selectedSignature != nil, nextSignature != selectedSignature {
            loadSelectedDocument()
        } else if selectedDocumentSignature == nil {
            selectedDocumentSignature = nextSignature
        }
    }

    private func finishExternalWorkspaceFailure(_ error: Error, generation: Int) {
        guard generation == externalRefreshGeneration else { return }
        errorMessage = "Could not refresh workspace changes: \(error.localizedDescription)"
    }

    private static func isRelevantExternalChange(path: String) -> Bool {
        let ignored = Set([".git", ".build", "DerivedData", "dist", "node_modules"])
        let components = URL(fileURLWithPath: path).pathComponents
        return !components.contains { component in
            ignored.contains(component) || (component.hasPrefix(".") && component != "." && component != "..")
        }
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
            try String(contentsOf: url, encoding: .utf8)
        }.value
    }

    nonisolated private static func writeText(_ text: String, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    nonisolated private static func fileSignature(for url: URL) -> FileSignature? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }

        return FileSignature(
            modificationDate: values.contentModificationDate,
            fileSize: values.fileSize.map(Int64.init)
        )
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

    nonisolated private static func childName(baseName: String, pathExtension: String?) -> String {
        guard let pathExtension, !pathExtension.isEmpty else {
            return baseName
        }

        return "\(baseName).\(pathExtension)"
    }

    nonisolated private static func renamedURL(for sourceURL: URL, proposedName: String) throws -> URL {
        var fileName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileName.isEmpty else {
            throw WorkspaceDocumentOperationError.emptyName
        }

        guard fileName.rangeOfCharacter(from: CharacterSet(charactersIn: "/:")) == nil else {
            throw WorkspaceDocumentOperationError.nestedName
        }

        if URL(fileURLWithPath: fileName).pathExtension.isEmpty, !sourceURL.pathExtension.isEmpty {
            fileName += ".\(sourceURL.pathExtension)"
        }

        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL {
                return destinationURL
            }

            throw WorkspaceDocumentOperationError.destinationExists(fileName)
        }

        return destinationURL
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
        workspaceTask?.cancel()
        documentTask?.cancel()
        saveTask?.cancel()
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
}

private struct FileSignature: Equatable, Sendable {
    let modificationDate: Date?
    let fileSize: Int64?
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
    case destinationExists(String)

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
        case .destinationExists(let name):
            return "A document named \(name) already exists."
        }
    }
}
