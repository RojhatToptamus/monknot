import Foundation
import MarkprevCore

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var rootNode: SidebarNode?
    @Published private(set) var files: [MarkdownFile] = []
    @Published private(set) var selectedFileID: String?
    @Published private(set) var documentText = ""
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var isBusy = false
    @Published private(set) var isDocumentLoading = false
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    private let scanner: any MarkdownFileScanning
    private let bookmarkKey = "Markprev.workspaceBookmark"
    private var lastSavedText = ""
    private var saveWorkItem: DispatchWorkItem?
    private var securityScopedURL: URL?
    private var workspaceTask: Task<Void, Never>?
    private var documentTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var workspaceGeneration = 0
    private var documentGeneration = 0
    private var saveGeneration = 0

    init(scanner: any MarkdownFileScanning = MarkdownFileScanner()) {
        self.scanner = scanner
    }

    var selectedFile: MarkdownFile? {
        files.first { $0.id == selectedFileID }
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
                case .markdownFile(let workspaceURL, let selectedURL):
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
        guard let workspaceURL else { return }

        startWorkspaceLoad(workspaceURL, selecting: nil, persistBookmark: false, preserveSelection: selectedFileID, reloadSelection: false)
    }

    func selectFile(id: String?) {
        guard id != selectedFileID, !isBusy else { return }

        saveIfNeeded()
        selectedFileID = id
        loadSelectedFile()
    }

    func createMarkdownFile() {
        guard let workspaceURL else {
            errorMessage = "Open a workspace before creating a Markdown file."
            return
        }

        guard !isBusy else { return }

        saveIfNeeded()

        let fileURL = nextAvailableMarkdownURL(in: workspaceURL)
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

    func setDocumentText(_ text: String) {
        guard text != documentText else { return }

        documentText = text
        hasUnsavedChanges = text != lastSavedText
        scheduleAutoSave()
    }

    func saveSelectedFile() {
        saveWorkItem?.cancel()
        saveWorkItem = nil

        guard let selectedFile else { return }

        let file = selectedFile
        let text = documentText
        saveGeneration += 1
        let generation = saveGeneration
        isSaving = true

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

    private func startWorkspaceLoad(
        _ url: URL,
        selecting selectedURL: URL?,
        persistBookmark: Bool,
        preserveSelection: String?,
        reloadSelection: Bool
    ) {
        saveIfNeeded()

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

    private func finishWorkspaceLoad(
        result: MarkdownFileScanResult,
        workspaceURL: URL,
        selectedURL: URL?,
        preserveSelection: String?,
        reloadSelection: Bool,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        rootNode = result.root
        files = result.files

        if let selectedURL {
            selectedFileID = MarkdownFile(url: selectedURL, rootURL: workspaceURL).id
        } else if let preserveSelection, files.contains(where: { $0.id == preserveSelection }) {
            selectedFileID = preserveSelection
        } else {
            selectedFileID = files.first?.id
        }

        isBusy = false

        if reloadSelection || documentText.isEmpty || selectedFileID != preserveSelection {
            loadSelectedFile()
        }
    }

    private func finishCreatedFile(
        result: MarkdownFileScanResult,
        fileURL: URL,
        workspaceURL: URL,
        initialText: String,
        generation: Int
    ) {
        guard generation == workspaceGeneration else { return }

        rootNode = result.root
        files = result.files
        selectedFileID = MarkdownFile(url: fileURL, rootURL: workspaceURL).id
        documentText = initialText
        lastSavedText = initialText
        hasUnsavedChanges = false
        isBusy = false
    }

    private func finishWorkspaceFailure(_ error: Error, generation: Int, message: String) {
        guard generation == workspaceGeneration else { return }

        isBusy = false
        isDocumentLoading = false
        errorMessage = "\(message): \(error.localizedDescription)"
    }

    private func updateSecurityScope(for url: URL) {
        if securityScopedURL == url {
            return
        }

        if let securityScopedURL {
            securityScopedURL.stopAccessingSecurityScopedResource()
        }

        securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    private func loadSelectedFile() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        documentTask?.cancel()
        documentGeneration += 1
        let generation = documentGeneration

        guard let selectedFile else {
            documentText = ""
            lastSavedText = ""
            hasUnsavedChanges = false
            isDocumentLoading = false
            return
        }

        let file = selectedFile
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

    private func finishDocumentLoad(file: MarkdownFile, text: String, generation: Int) {
        guard generation == documentGeneration, selectedFileID == file.id else { return }

        documentText = text
        lastSavedText = text
        hasUnsavedChanges = false
        isDocumentLoading = false
    }

    private func finishDocumentLoadFailure(_ error: Error, file: MarkdownFile, generation: Int) {
        guard generation == documentGeneration, selectedFileID == file.id else { return }

        documentText = ""
        lastSavedText = ""
        hasUnsavedChanges = false
        isDocumentLoading = false
        errorMessage = "Could not read \(file.displayName): \(error.localizedDescription)"
    }

    private func finishSave(fileID: String, text: String, generation: Int) {
        guard generation == saveGeneration else { return }

        isSaving = false

        guard selectedFileID == fileID else { return }

        lastSavedText = text
        hasUnsavedChanges = documentText != lastSavedText
    }

    private func finishSaveFailure(_ error: Error, file: MarkdownFile, generation: Int) {
        guard generation == saveGeneration else { return }

        isSaving = false
        errorMessage = "Could not save \(file.displayName): \(error.localizedDescription)"
    }

    private func saveIfNeeded() {
        guard hasUnsavedChanges else { return }
        saveSelectedFile()
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

    private func scheduleAutoSave() {
        saveWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.saveSelectedFile()
            }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    nonisolated private static func scanWorkspace(
        _ rootURL: URL,
        scanner: any MarkdownFileScanning
    ) async throws -> MarkdownFileScanResult {
        try await Task.detached(priority: .userInitiated) {
            try scanner.scan(rootURL: rootURL)
        }.value
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

    nonisolated private static func resolveDroppedTarget(for url: URL) async throws -> DroppedTarget {
        try await Task.detached(priority: .userInitiated) {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

            if resourceValues.isDirectory == true {
                return .workspace(url)
            }

            if resourceValues.isRegularFile == true, MarkdownFileSupport.isMarkdownFile(url) {
                return .markdownFile(workspaceURL: url.deletingLastPathComponent(), selectedURL: url)
            }

            return .unsupported
        }.value
    }

    deinit {
        workspaceTask?.cancel()
        documentTask?.cancel()
        saveTask?.cancel()
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
}

private enum DroppedTarget: Sendable {
    case workspace(URL)
    case markdownFile(workspaceURL: URL, selectedURL: URL)
    case unsupported
}
