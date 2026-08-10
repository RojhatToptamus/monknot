import AppKit
import PDFKit
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceStorePDFAnnotationExportTests: XCTestCase {
    func testExportPDFAnnotationsUsesDirtyPDFDataBeforeDiskData() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let diskData = try makePDFData(annotationText: "Disk highlight")
        let dirtyData = try makePDFData(annotationText: "Unsaved highlight")
        try diskData.write(to: pdfURL)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)

        guard let pdfDocument = store.documents.first(where: { $0.url == pdfURL.standardizedFileURL }) else {
            return XCTFail("Expected PDF document")
        }

        store.markPDFDocumentEdited(id: pdfDocument.id, previousData: diskData, data: dirtyData)
        store.exportPDFAnnotationsToMarkdown(for: pdfDocument)

        let didExport = await waitUntil { !store.isBusy && store.selectedDocument?.relativePath == "notes/Paper Annotations.md" }
        XCTAssertTrue(didExport, store.errorMessage ?? "Export did not select its destination")
        XCTAssertTrue(store.documentText.contains("> Unsaved highlight"))
        XCTAssertFalse(store.documentText.contains("> Disk highlight"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/Paper Annotations.md").path))
    }

    func testExportAllPDFAnnotationsCreatesCombinedMarkdownUsingDirtyData() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = root.appendingPathComponent("First.pdf")
        let secondURL = root.appendingPathComponent("Second.pdf")
        let firstDiskData = try makePDFData(annotationText: "First disk highlight")
        let firstDirtyData = try makePDFData(annotationText: "First unsaved highlight")
        let secondData = try makePDFData(annotationText: "Second highlight")
        try firstDiskData.write(to: firstURL)
        try secondData.write(to: secondURL)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.documents.count >= 2 }
        XCTAssertTrue(didLoad)

        guard let firstDocument = store.documents.first(where: { $0.url == firstURL.standardizedFileURL }) else {
            return XCTFail("Expected first PDF document")
        }

        store.markPDFDocumentEdited(id: firstDocument.id, previousData: firstDiskData, data: firstDirtyData)
        store.exportAllPDFAnnotationsToMarkdown()

        let didExport = await waitUntil { !store.isBusy && store.selectedDocument?.relativePath == "notes/Workspace PDF Annotations.md" }
        XCTAssertTrue(didExport)
        XCTAssertTrue(store.documentText.contains("# Workspace PDF Annotations"))
        XCTAssertTrue(store.documentText.contains("## First.pdf"))
        XCTAssertTrue(store.documentText.contains("> First unsaved highlight"))
        XCTAssertFalse(store.documentText.contains("> First disk highlight"))
        XCTAssertTrue(store.documentText.contains("## Second.pdf"))
        XCTAssertTrue(store.documentText.contains("> Second highlight"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/Workspace PDF Annotations.md").path))
    }

    func testExportAnnotatedPDFCopyUsesDirtyPDFDataBeforeDiskData() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let diskData = try makePDFData(annotationText: "Disk highlight")
        let dirtyData = try makePDFData(annotationText: "Unsaved highlight")
        try diskData.write(to: pdfURL)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)

        guard let pdfDocument = store.documents.first(where: { $0.url == pdfURL.standardizedFileURL }) else {
            return XCTFail("Expected PDF document")
        }

        store.markPDFDocumentEdited(id: pdfDocument.id, previousData: diskData, data: dirtyData)
        store.exportAnnotatedPDFCopy(for: pdfDocument)

        let didExport = await waitUntil { !store.isBusy && store.selectedDocument?.relativePath == "exports/Paper Annotated.pdf" }
        XCTAssertTrue(didExport, store.errorMessage ?? "Export did not select its destination")

        let exportedURL = root.appendingPathComponent("exports/Paper Annotated.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))

        let exportedDocument = try XCTUnwrap(PDFDocument(url: exportedURL))
        let annotationContents = exportedDocument.page(at: 0)?.annotations.map(\.contents) ?? []
        XCTAssertTrue(annotationContents.contains("Unsaved highlight"))
        XCTAssertFalse(annotationContents.contains("Disk highlight"))
    }

    func testMarkPDFDocumentEditedPublishesWorkspaceSearchContentChange() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let diskData = try makePDFData(annotationText: "Disk highlight")
        let dirtyData = try makePDFData(annotationText: "Unsaved highlight")
        try diskData.write(to: pdfURL)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)

        guard let pdfDocument = store.documents.first(where: { $0.url == pdfURL.standardizedFileURL }) else {
            return XCTFail("Expected PDF document")
        }

        let serialBeforeEdit = store.workspaceSearchContentChangeSerial
        store.markPDFDocumentEdited(id: pdfDocument.id, previousData: diskData, data: dirtyData)

        XCTAssertGreaterThan(store.workspaceSearchContentChangeSerial, serialBeforeEdit)
        XCTAssertEqual(store.dirtyPDFDataByDocumentID[pdfDocument.id], dirtyData)
    }

    func testFirstPDFEditWithoutLiveBaselineIsRejectedAndRequestsReload() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let diskData = try makePDFData(annotationText: "Disk highlight")
        let dirtyData = try makePDFData(annotationText: "Unverified edit")
        try diskData.write(to: pdfURL)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        let document = try XCTUnwrap(store.documents.first(where: { $0.id == pdfURL.standardizedFileURL.path }))
        let initialContentVersion = store.pdfContentVersion(for: document.id)

        store.markPDFDocumentEdited(id: document.id, previousData: nil, data: dirtyData)

        XCTAssertNil(store.dirtyPDFData(for: document.id))
        XCTAssertTrue(store.saveState(for: document.id).isClean)
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertGreaterThan(store.pdfContentVersion(for: document.id), initialContentVersion)
        XCTAssertTrue(store.errorMessage?.contains("original PDF contents are unavailable") == true)
    }

    func testRepeatedPDFEditsReuseTheOriginalBaselineWithoutAnotherSnapshot() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let diskData = try makePDFData(annotationText: "Disk highlight")
        let firstEdit = try makePDFData(annotationText: "First unsaved highlight")
        let secondEdit = try makePDFData(annotationText: "Second unsaved highlight")
        try diskData.write(to: pdfURL)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)

        let pdfDocument = try XCTUnwrap(store.documents.first(where: { $0.url == pdfURL.standardizedFileURL }))
        store.markPDFDocumentEdited(id: pdfDocument.id, previousData: diskData, data: firstEdit)
        store.markPDFDocumentEdited(id: pdfDocument.id, previousData: nil, data: secondEdit)

        XCTAssertEqual(store.dirtyPDFDataByDocumentID[pdfDocument.id], secondEdit)

        store.markPDFDocumentEdited(id: pdfDocument.id, previousData: nil, data: diskData)

        XCTAssertNil(store.dirtyPDFDataByDocumentID[pdfDocument.id])
        XCTAssertTrue(store.saveState(for: pdfDocument.id).isClean)
        XCTAssertFalse(store.hasUnsavedChanges)
    }

    func testDiscardAndManualReloadAdvancePDFContentVersionWithoutAdvancingForLiveEdits() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let diskData = try makePDFData(annotationText: "Disk highlight")
        let dirtyData = try makePDFData(annotationText: "Unsaved highlight")
        try diskData.write(to: pdfURL)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        let document = try XCTUnwrap(store.documents.first(where: { $0.id == pdfURL.standardizedFileURL.path }))
        let initialVersion = store.pdfContentVersion(for: document.id)

        store.markPDFDocumentEdited(id: document.id, previousData: diskData, data: dirtyData)

        XCTAssertEqual(store.pdfContentVersion(for: document.id), initialVersion)
        XCTAssertEqual(store.dirtyPDFData(for: document.id), dirtyData)

        store.discardUnsavedChanges(for: document.id)
        let discardedVersion = store.pdfContentVersion(for: document.id)

        XCTAssertGreaterThan(discardedVersion, initialVersion)
        XCTAssertNil(store.dirtyPDFData(for: document.id))

        store.reloadSelectedDocumentFromDisk()

        XCTAssertGreaterThan(store.pdfContentVersion(for: document.id), discardedVersion)
    }

    func testCleanExternalPDFModificationAdvancesContentVersion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        try makePDFData(annotationText: "Disk highlight").write(to: pdfURL)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        let document = try XCTUnwrap(store.documents.first(where: { $0.id == pdfURL.standardizedFileURL.path }))
        let initialVersion = store.pdfContentVersion(for: document.id)

        try makePDFData(annotationText: "A longer externally replaced highlight").write(to: pdfURL)
        store.testing_clearWatcherSuppression()
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [pdfURL.standardizedFileURL.path],
            modifiedOnlyPaths: [pdfURL.standardizedFileURL.path],
            requiresFullRescan: false
        ))

        XCTAssertGreaterThan(store.pdfContentVersion(for: document.id), initialVersion)
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertNil(store.dirtyPDFData(for: document.id))
    }

    func testDirtyExternalPDFModificationSurfacesConflictWithoutReplacingLiveData() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let baseline = try makePDFData(annotationText: "Disk highlight")
        let dirtyData = try makePDFData(annotationText: "Unsaved highlight")
        let laterDirtyData = try makePDFData(annotationText: "A later unsaved highlight")
        let externalData = try makePDFData(annotationText: "External highlight")
        try baseline.write(to: pdfURL)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        let document = try XCTUnwrap(store.documents.first(where: { $0.id == pdfURL.standardizedFileURL.path }))
        let initialContentVersion = store.pdfContentVersion(for: document.id)
        store.markPDFDocumentEdited(id: document.id, previousData: baseline, data: dirtyData)

        try externalData.write(to: pdfURL)
        store.testing_clearWatcherSuppression()
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [pdfURL.standardizedFileURL.path],
            modifiedOnlyPaths: [pdfURL.standardizedFileURL.path],
            requiresFullRescan: false
        ))

        XCTAssertTrue(store.selectedDocumentExternalChange)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertEqual(store.dirtyPDFData(for: document.id), dirtyData)
        XCTAssertEqual(store.pdfContentVersion(for: document.id), initialContentVersion)
        XCTAssertEqual(try Data(contentsOf: pdfURL), externalData)

        store.markPDFDocumentEdited(id: document.id, previousData: nil, data: laterDirtyData)

        XCTAssertTrue(store.selectedDocumentExternalChange)
        XCTAssertEqual(store.dirtyPDFData(for: document.id), laterDirtyData)
        XCTAssertEqual(store.pdfContentVersion(for: document.id), initialContentVersion)

        store.markPDFDocumentEdited(id: document.id, previousData: nil, data: baseline)

        XCTAssertFalse(store.selectedDocumentExternalChange)
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertNil(store.dirtyPDFData(for: document.id))
        XCTAssertGreaterThan(store.pdfContentVersion(for: document.id), initialContentVersion)
        XCTAssertEqual(try Data(contentsOf: pdfURL), externalData)
    }

    func testStalePDFSaveIsRejectedAndPreservesExternalDiskData() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let baseline = try makePDFData(annotationText: "Disk highlight")
        let dirtyData = try makePDFData(annotationText: "Unsaved highlight")
        let externalData = try makePDFData(annotationText: "External replacement")
        try baseline.write(to: pdfURL)

        let store = WorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        let document = try XCTUnwrap(store.documents.first(where: { $0.id == pdfURL.standardizedFileURL.path }))
        store.markPDFDocumentEdited(id: document.id, previousData: baseline, data: dirtyData)
        try externalData.write(to: pdfURL)

        store.saveSelectedFile()
        let didReject = await waitUntil {
            guard !store.isSaving, store.selectedDocumentExternalChange else { return false }
            if case .failed = store.saveState(for: document.id) {
                return true
            }
            return false
        }

        XCTAssertTrue(
            didReject,
            "state=\(store.saveState(for: document.id)), external=\(store.selectedDocumentExternalChange), error=\(store.errorMessage ?? "nil")"
        )
        XCTAssertEqual(try Data(contentsOf: pdfURL), externalData)
        XCTAssertEqual(store.dirtyPDFData(for: document.id), dirtyData)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertTrue(store.errorMessage?.contains("save your annotated version as a copy") == true)
    }

    private func makePDFData(annotationText: String) throws -> Data {
        let image = NSImage(size: NSSize(width: 240, height: 240))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 240).fill()
        image.unlockFocus()

        guard let page = PDFPage(image: image) else {
            throw NSError(domain: "WorkspaceStorePDFAnnotationExportTests", code: 1)
        }

        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 120, width: 120, height: 18), forType: .highlight, withProperties: nil)
        annotation.contents = annotationText
        annotation.color = .yellow
        page.addAnnotation(annotation)

        let document = PDFDocument()
        document.insert(page, at: 0)

        guard let data = document.dataRepresentation() else {
            throw NSError(domain: "WorkspaceStorePDFAnnotationExportTests", code: 2)
        }
        return data
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-pdf-annotation-export-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
