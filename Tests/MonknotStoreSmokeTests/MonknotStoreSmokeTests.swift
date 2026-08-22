import Foundation
@testable import MonknotApp

@main
struct MonknotStoreSmokeTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonknotStoreSmokeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let noteURL = root.appendingPathComponent("Note.md")
        try write("# Original\n", to: noteURL)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil {
            !store.isBusy && !store.isDocumentLoading && store.selectedDocument != nil
        }
        expect(didLoad, "workspace and initial document should load")
        let document = store.selectedDocument!
        store.setDocumentText("# Local edit\n")
        expect(store.saveState(for: document.id) == .edited, "edit should become dirty")
        let didSave = await store.saveDocument(id: document.id)
        expect(didSave, "save should complete")
        let savedText = try String(contentsOf: noteURL, encoding: .utf8)
        expect(savedText == "# Local edit\n", "save should write the edited text")

        try "# External edit\n".write(to: noteURL, atomically: false, encoding: .utf8)
        store.testing_clearWatcherSuppression()
        store.refresh()
        let didRefresh = await waitUntil(8) { store.documentText == "# External edit\n" }
        expect(didRefresh, "clean external change should refresh the open document")
        print("Monknot store smoke tests passed")
    }
}
