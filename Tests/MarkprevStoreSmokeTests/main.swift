import Foundation
import MarkprevCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@MainActor
func waitUntil(_ timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

@main
struct MarkprevStoreSmokeTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("markprev-store-smoke")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = root.appendingPathComponent("A.md")
        let secondURL = root.appendingPathComponent("B.md")
        let textURL = root.appendingPathComponent("Plain.txt")
        try write("# A\n", to: firstURL)
        try write("# B\n", to: secondURL)
        try write("plain text\n", to: textURL)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoadWorkspace = await waitUntil { !store.isBusy && !store.isDocumentLoading && store.selectedDocument != nil }
        expect(didLoadWorkspace, "workspace should load")

        guard let first = store.documents.first(where: { $0.url == firstURL.standardizedFileURL }),
              let second = store.documents.first(where: { $0.url == secondURL.standardizedFileURL }),
              let text = store.documents.first(where: { $0.url == textURL.standardizedFileURL })
        else {
            fputs("FAIL: expected smoke documents\n", stderr)
            exit(1)
        }

        store.selectDocument(id: first.id)
        let didLoadFirst = await waitUntil { !store.isDocumentLoading && store.selectedDocumentID == first.id }
        expect(didLoadFirst, "first document should load")
        store.setDocumentText("# A\nchanged\n")
        expect(store.hasUnsavedChanges, "edited document should be dirty")
        expect(store.saveState(for: first.id) == .edited, "edited document should show edited state")

        try await Task.sleep(nanoseconds: 1_100_000_000)
        let diskBeforeSave = try String(contentsOf: first.url, encoding: .utf8)
        expect(diskBeforeSave == "# A\n", "editing should not autosave to disk")

        store.selectDocument(id: second.id)
        let didLoadSecond = await waitUntil { !store.isDocumentLoading && store.selectedDocumentID == second.id }
        expect(didLoadSecond, "second document should load")
        expect(store.saveState(for: first.id) == .edited, "dirty state should remain after switching files")

        store.selectDocument(id: first.id)
        let didRestoreFirst = await waitUntil { !store.isDocumentLoading && store.selectedDocumentID == first.id }
        expect(didRestoreFirst, "dirty first document should restore")
        expect(store.documentText == "# A\nchanged\n", "dirty buffer should be restored in memory")
        let diskAfterRestore = try String(contentsOf: first.url, encoding: .utf8)
        expect(diskAfterRestore == "# A\n", "restoring dirty buffer should not write disk")

        store.saveSelectedFile()
        let didSave = await waitUntil { !store.isSaving }
        expect(didSave, "explicit save should complete")
        let diskAfterSave = try String(contentsOf: first.url, encoding: .utf8)
        expect(diskAfterSave == "# A\nchanged\n", "explicit save should write disk")
        expect(store.saveState(for: first.id) == .clean, "explicit save should clear dirty state")

        store.setDocumentText("# A\nsave while switching\n")
        store.saveSelectedFile()
        store.selectDocument(id: second.id)
        let didSwitchDuringSave = await waitUntil { !store.isSaving && store.selectedDocumentID == second.id }
        expect(didSwitchDuringSave, "save should complete after switching documents")
        expect(store.saveState(for: first.id) == .clean, "save completion should clear dirty state even when document is no longer selected")

        store.selectDocument(id: first.id)
        let didReloadAfterSwitchSave = await waitUntil { !store.isDocumentLoading && store.selectedDocumentID == first.id }
        expect(didReloadAfterSwitchSave, "first document should reload after save-while-switching")
        expect(store.documentText == "# A\nsave while switching\n", "saved text should reload after switching away during save")

        store.setDocumentText("# A\ncopied dirty text\n")
        store.copyDocument(first)
        store.pasteDocumentTransfer(into: root)
        let didPasteDirtyCopy = await waitUntil { !store.isBusy && store.documents.contains { $0.relativePath == "A copy.md" } }
        expect(didPasteDirtyCopy, "dirty copy should create duplicate document")
        let copiedURL = root.appendingPathComponent("A copy.md")
        let copiedText = try String(contentsOf: copiedURL, encoding: .utf8)
        expect(copiedText == "# A\ncopied dirty text\n", "copying a dirty Markdown document should use the in-memory dirty text")
        let sourceDiskAfterCopy = try String(contentsOf: first.url, encoding: .utf8)
        expect(sourceDiskAfterCopy == "# A\nsave while switching\n", "copying dirty text should not save the original document")
        expect(store.saveState(for: first.id) == .edited, "original dirty document should remain edited after copying")

        store.selectDocument(id: first.id)
        let didRestoreDirtySource = await waitUntil { !store.isDocumentLoading && store.selectedDocumentID == first.id }
        expect(didRestoreDirtySource, "dirty source document should restore before external conflict test")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        try "# A\nexternal version\n".write(to: first.url, atomically: false, encoding: .utf8)
        store.refresh()
        let didDetectExternalConflict = await waitUntil(8) { store.selectedDocumentExternalChange }
        expect(didDetectExternalConflict, "dirty selected document should report an external disk change conflict")

        store.selectDocument(id: text.id)
        let didLoadText = await waitUntil { !store.isDocumentLoading && store.selectedDocumentID == text.id }
        expect(didLoadText, "text document should load")
        expect(store.documentText == "plain text\n", "text document should load through the generic text path")
        store.setDocumentText("plain text\nchanged\n")
        expect(store.saveState(for: text.id) == .edited, "edited text document should show edited state")
        store.saveSelectedFile()
        let didSaveText = await waitUntil { !store.isSaving }
        expect(didSaveText, "text document save should complete")
        let savedText = try String(contentsOf: text.url, encoding: .utf8)
        expect(savedText == "plain text\nchanged\n", "text document save should write disk")

        let renamedSecondURL = root.appendingPathComponent("Renamed.md").standardizedFileURL
        store.setOpenDocumentIDs([second.id])
        store.renameDocument(id: second.id, to: "Renamed.md")
        let didRenameInactiveTabDocument = await waitUntil {
            !store.isBusy &&
                store.documentIDRemapEvent?.sourceID == second.id &&
                store.documentIDRemapEvent?.destinationID == renamedSecondURL.path &&
                store.documents.contains { $0.id == renamedSecondURL.path }
        }
        expect(didRenameInactiveTabDocument, "renaming an inactive open document should publish a tab remap event")

        store.setOpenDocumentIDs([first.id])
        store.deleteDocument(first)
        expect(store.errorMessage?.contains("Save or close") == true, "deleting a dirty open document should be blocked")
        expect(FileManager.default.fileExists(atPath: first.url.path), "blocked dirty open delete should leave the file on disk")

        print("Markprev store smoke tests passed")
    }
}
