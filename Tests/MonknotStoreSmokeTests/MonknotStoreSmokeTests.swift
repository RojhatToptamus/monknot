import Foundation
@testable import MonknotApp

@main
struct MonknotStoreSmokeTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-store-smoke")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let externalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-store-smoke-external")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: externalRoot) }

        let firstURL = root.appendingPathComponent("A.md")
        let secondURL = root.appendingPathComponent("B.md")
        let textURL = root.appendingPathComponent("Plain.txt")
        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let pdfBaseline = Data("%PDF-1.4 baseline\n".utf8)
        let pdfFirstEdit = Data("%PDF-1.4 edit one\n".utf8)
        let pdfSecondEdit = Data("%PDF-1.4 edit two\n".utf8)
        try write("# A\n", to: firstURL)
        try write("# B\n", to: secondURL)
        try write("plain text\n", to: textURL)
        try write(pdfBaseline, to: pdfURL)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoadWorkspace = await waitUntil { !store.isBusy && !store.isDocumentLoading && store.selectedDocument != nil }
        expect(didLoadWorkspace, "workspace should load")

        guard let first = store.documents.first(where: { $0.url == firstURL.standardizedFileURL }),
              let second = store.documents.first(where: { $0.url == secondURL.standardizedFileURL }),
              let text = store.documents.first(where: { $0.url == textURL.standardizedFileURL }),
              let pdf = store.documents.first(where: { $0.url == pdfURL.standardizedFileURL })
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

        let externalMarkdownURL = externalRoot.appendingPathComponent("Finder.md")
        try write("# Finder\n", to: externalMarkdownURL)
        store.importPasteboardItems([.fileURL(externalMarkdownURL)])
        let didImportExternalFile = await waitUntil {
            !store.isBusy &&
                store.documents.contains { $0.relativePath == "Finder.md" }
        }
        expect(didImportExternalFile, "pasteboard file import should copy an external file into the workspace")
        let importedExternalText = try String(contentsOf: root.appendingPathComponent("Finder.md"), encoding: .utf8)
        expect(importedExternalText == "# Finder\n", "pasteboard file import should preserve external file contents")
        expect(FileManager.default.fileExists(atPath: externalMarkdownURL.path), "pasteboard file import should leave the Finder source file in place")
        expect(store.workspaceURL?.standardizedFileURL == root.standardizedFileURL, "pasteboard file import should keep the current workspace root")

        store.importPasteboardItems([.fileURL(externalMarkdownURL)])
        let didImportUniqueExternalFile = await waitUntil {
            !store.isBusy &&
                store.documents.contains { $0.relativePath == "Finder copy.md" }
        }
        expect(didImportUniqueExternalFile, "pasteboard file import should use a unique destination name")
        expect(FileManager.default.fileExists(atPath: externalMarkdownURL.path), "repeated pasteboard file import should still leave the Finder source file in place")
        expect(store.workspaceURL?.standardizedFileURL == root.standardizedFileURL, "repeated pasteboard file import should keep the current workspace root")

        store.importPasteboardItems([.pngImageData(Data("png image bytes\n".utf8))])
        let didImportClipboardImage = await waitUntil {
            !store.isBusy &&
                FileManager.default.fileExists(atPath: root.appendingPathComponent("Pasted Image.png").path)
        }
        expect(didImportClipboardImage, "pasteboard image import should write a PNG file into the workspace")
        expect(!store.documents.contains { $0.relativePath == "Pasted Image.png" }, "pasteboard image import should not add unsupported PNG files to workspace documents")
        let importedImageData = try Data(contentsOf: root.appendingPathComponent("Pasted Image.png"))
        expect(importedImageData == Data("png image bytes\n".utf8), "pasteboard image import should write the provided PNG data")

        store.selectDocument(id: first.id)
        let didRestoreDirtySource = await waitUntil { !store.isDocumentLoading && store.selectedDocumentID == first.id }
        expect(didRestoreDirtySource, "dirty source document should restore before external conflict test")
        try "# A\nexternal version\n".write(to: first.url, atomically: false, encoding: .utf8)
        store.testing_clearWatcherSuppression()
        store.refresh()
        let didDetectExternalConflict = await waitUntil(8) { store.selectedDocumentExternalChange }
        expect(didDetectExternalConflict, "dirty selected document should report an external disk change conflict")

        store.prepareExternalDocumentReview()
        let didPrepareExternalReview = await waitUntil { store.externalDocumentReview != nil }
        expect(didPrepareExternalReview, "external change review should load disk and local versions")
        let externalCopyURL = root.appendingPathComponent("Conflict Local Copy.md")
        store.saveExternalDocumentCopy(to: externalCopyURL)
        let didSaveExternalCopy = await waitUntil(8) {
            store.documents.contains { $0.url == externalCopyURL.standardizedFileURL }
        }
        expect(didSaveExternalCopy, "saving a local conflict copy inside the workspace should refresh the tree")
        let externalCopyText = try String(contentsOf: externalCopyURL, encoding: .utf8)
        expect(
            externalCopyText == "# A\ncopied dirty text\n",
            "saving a local conflict copy should preserve the dirty buffer"
        )
        expect(store.selectedDocumentExternalChange, "saving a conflict copy should leave the original conflict open")
        expect(store.externalDocumentReview != nil, "saving a conflict copy should leave the visual review open")
        store.resolveExternalDocumentReview(.keepLocal)
        let didKeepLocalVersion = await waitUntil {
            store.externalDocumentReview == nil && !store.selectedDocumentExternalChange
        }
        expect(didKeepLocalVersion, "keeping the local version should dismiss the conflict banner")
        expect(store.documentText == "# A\ncopied dirty text\n", "keeping the local version should preserve the dirty buffer")

        store.reloadSelectedDocumentFromDisk()
        _ = await waitUntil { !store.isDocumentLoading }
        expect(!store.hasUnsavedChanges, "reload from disk should clear dirty state after external change")
        expect(store.documentText == "# A\nexternal version\n", "reload from disk should read external file contents")

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

        store.selectDocument(id: pdf.id)
        let didLoadPDF = await waitUntil { !store.isDocumentLoading && store.selectedDocumentID == pdf.id }
        expect(didLoadPDF, "PDF document should load")

        store.markPDFDocumentEdited(id: pdf.id, previousData: pdfBaseline, data: pdfFirstEdit)
        expect(store.dirtyPDFData(for: pdf.id) == pdfFirstEdit, "PDF edits should be retained in memory")
        expect(store.saveState(for: pdf.id) == .edited, "edited PDF should show edited state")
        let diskPDFBeforeSave = try Data(contentsOf: pdf.url)
        expect(diskPDFBeforeSave == pdfBaseline, "PDF editing should not autosave to disk")

        store.markPDFDocumentEdited(id: pdf.id, previousData: pdfFirstEdit, data: pdfSecondEdit)
        expect(store.dirtyPDFData(for: pdf.id) == pdfSecondEdit, "second PDF edit should replace dirty snapshot")

        store.markPDFDocumentEdited(id: pdf.id, previousData: pdfSecondEdit, data: pdfBaseline)
        expect(store.dirtyPDFData(for: pdf.id) == nil, "returning to the PDF baseline should clear dirty data")
        expect(store.saveState(for: pdf.id) == .clean, "returning to the PDF baseline should clear edited state")

        store.markPDFDocumentEdited(id: pdf.id, previousData: pdfBaseline, data: pdfSecondEdit)
        expect(store.dirtyPDFData(for: pdf.id) == pdfSecondEdit, "PDF edit after baseline restore should become dirty again")

        store.saveSelectedFile()
        let didSavePDF = await waitUntil { !store.isSaving }
        expect(didSavePDF, "PDF save should complete")
        let savedPDFData = try Data(contentsOf: pdf.url)
        expect(savedPDFData == pdfSecondEdit, "PDF save should write the dirty snapshot to disk")
        expect(store.dirtyPDFData(for: pdf.id) == nil, "PDF save should clear dirty snapshot")
        expect(store.saveState(for: pdf.id) == .clean, "PDF save should clear edited state")

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

        let sourceFolder = root.appendingPathComponent("MoveSource", isDirectory: true)
        let targetFolder = root.appendingPathComponent("MoveTarget", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        let draggedFileURL = sourceFolder.appendingPathComponent("Dragged.md")
        try write("# Dragged\n", to: draggedFileURL)
        store.refresh()
        let didRefreshMoveFixture = await waitUntil {
            !store.isBusy &&
                store.documents.contains { $0.url == draggedFileURL.standardizedFileURL }
        }
        expect(didRefreshMoveFixture, "refresh should discover drag-move fixture document")

        store.renameFolder(id: sourceFolder.standardizedFileURL.path, to: "RenamedSource")
        let renamedFolder = root.appendingPathComponent("RenamedSource", isDirectory: true).standardizedFileURL
        let renamedDraggedFileURL = renamedFolder.appendingPathComponent("Dragged.md").standardizedFileURL
        let didRenameFolder = await waitUntil {
            !store.isBusy &&
                FileManager.default.fileExists(atPath: renamedFolder.path) &&
                store.documents.contains { $0.url == renamedDraggedFileURL }
        }
        expect(didRenameFolder, "renaming a folder should move nested workspace documents")

        store.moveItem(id: renamedFolder.path, toDirectory: targetFolder)
        let movedFolder = targetFolder.appendingPathComponent("RenamedSource", isDirectory: true).standardizedFileURL
        let nestedDraggedFileURL = movedFolder.appendingPathComponent("Dragged.md").standardizedFileURL
        let didMoveFolderIntoFolder = await waitUntil {
            !store.isBusy &&
                FileManager.default.fileExists(atPath: movedFolder.path) &&
                store.documents.contains { $0.url == nestedDraggedFileURL }
        }
        expect(didMoveFolderIntoFolder, "drag-moving a folder into another folder should preserve nested documents")

        store.moveItem(id: nestedDraggedFileURL.path, toDirectory: root)
        let draggedFileAtRoot = root.appendingPathComponent("Dragged.md").standardizedFileURL
        let didMoveFileOut = await waitUntil {
            !store.isBusy &&
                FileManager.default.fileExists(atPath: draggedFileAtRoot.path) &&
                store.documents.contains { $0.url == draggedFileAtRoot }
        }
        expect(didMoveFileOut, "drag-moving a file to the workspace root should move it out of nested folders")

        store.moveItem(id: movedFolder.path, toDirectory: movedFolder)
        expect(store.errorMessage?.contains("cannot be moved into itself") == true, "drag-moving a folder into itself should be blocked")

        store.selectDocument(id: first.id)
        let didLoadFirstBeforeDelete = await waitUntil { !store.isDocumentLoading && store.selectedDocumentID == first.id }
        expect(didLoadFirstBeforeDelete, "first document should load before dirty delete guard test")
        store.setDocumentText(store.documentText + "\nunsaved delete guard\n")
        expect(store.saveState(for: first.id) == .edited, "first document should be dirty before delete guard test")
        store.setOpenDocumentIDs([first.id])
        store.deleteDocument(first)
        expect(store.errorMessage?.contains("Save or close") == true, "deleting a dirty open document should be blocked")
        expect(FileManager.default.fileExists(atPath: first.url.path), "blocked dirty open delete should leave the file on disk")

        print("Monknot store smoke tests passed")
    }
}
