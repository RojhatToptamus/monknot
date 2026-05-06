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
    @Published var errorMessage: String?

    private let scanner: any MarkdownFileScanning
    private let bookmarkKey = "Markprev.workspaceBookmark"
    private var selectedFileBeforeLoad: MarkdownFile?
    private var lastSavedText = ""
    private var saveWorkItem: DispatchWorkItem?
    private var securityScopedURL: URL?

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
            try openWorkspace(url, persistBookmark: isStale)
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            errorMessage = "Could not restore the previous workspace: \(error.localizedDescription)"
        }
    }

    func openWorkspace(_ url: URL) {
        do {
            try openWorkspace(url, persistBookmark: true)
        } catch {
            errorMessage = "Could not open workspace: \(error.localizedDescription)"
        }
    }

    func handleDroppedURL(_ url: URL) {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

            if resourceValues.isDirectory == true {
                try openWorkspace(url, persistBookmark: true)
            } else if resourceValues.isRegularFile == true, MarkdownFileSupport.isMarkdownFile(url) {
                let parent = url.deletingLastPathComponent()
                try openWorkspace(parent, selecting: url, persistBookmark: true)
            }
        } catch {
            errorMessage = "Could not use dropped item: \(error.localizedDescription)"
        }
    }

    func refresh() {
        guard let workspaceURL else { return }

        do {
            let previousSelection = selectedFileID
            let result = try scanner.scan(rootURL: workspaceURL)
            rootNode = result.root
            files = result.files

            if let previousSelection, files.contains(where: { $0.id == previousSelection }) {
                selectedFileID = previousSelection
            } else {
                selectedFileID = files.first?.id
            }

            loadSelectedFile()
        } catch {
            errorMessage = "Could not refresh workspace: \(error.localizedDescription)"
        }
    }

    func selectFile(id: String?) {
        guard id != selectedFileID else { return }

        saveIfNeeded()
        selectedFileID = id
        loadSelectedFile()
    }

    func createMarkdownFile() {
        guard let workspaceURL else {
            errorMessage = "Open a workspace before creating a Markdown file."
            return
        }

        saveIfNeeded()

        do {
            let fileURL = nextAvailableMarkdownURL(in: workspaceURL)
            let title = fileURL.deletingPathExtension().lastPathComponent
            let initialText = "# \(title)\n\n"
            try initialText.write(to: fileURL, atomically: true, encoding: .utf8)

            let result = try scanner.scan(rootURL: workspaceURL)
            rootNode = result.root
            files = result.files
            selectedFileID = MarkdownFile(url: fileURL, rootURL: workspaceURL).id
            loadSelectedFile()
        } catch {
            errorMessage = "Could not create a Markdown file: \(error.localizedDescription)"
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

        do {
            try documentText.write(to: selectedFile.url, atomically: true, encoding: .utf8)
            lastSavedText = documentText
            hasUnsavedChanges = false
        } catch {
            errorMessage = "Could not save \(selectedFile.displayName): \(error.localizedDescription)"
        }
    }

    private func openWorkspace(_ url: URL, selecting selectedURL: URL? = nil, persistBookmark: Bool) throws {
        saveIfNeeded()
        updateSecurityScope(for: url)

        if persistBookmark {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
        }

        workspaceURL = url.standardizedFileURL
        let result = try scanner.scan(rootURL: url)
        rootNode = result.root
        files = result.files

        if let selectedURL {
            selectedFileID = MarkdownFile(url: selectedURL, rootURL: url).id
        } else {
            selectedFileID = files.first?.id
        }

        loadSelectedFile()
    }

    private func updateSecurityScope(for url: URL) {
        if let securityScopedURL {
            securityScopedURL.stopAccessingSecurityScopedResource()
        }

        securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    private func loadSelectedFile() {
        saveWorkItem?.cancel()
        saveWorkItem = nil

        guard let selectedFile else {
            documentText = ""
            lastSavedText = ""
            hasUnsavedChanges = false
            return
        }

        do {
            let text = try String(contentsOf: selectedFile.url, encoding: .utf8)
            documentText = text
            lastSavedText = text
            hasUnsavedChanges = false
        } catch {
            documentText = ""
            lastSavedText = ""
            hasUnsavedChanges = false
            errorMessage = "Could not read \(selectedFile.displayName): \(error.localizedDescription)"
        }
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

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
}
