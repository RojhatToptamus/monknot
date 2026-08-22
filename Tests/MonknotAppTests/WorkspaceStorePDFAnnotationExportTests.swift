import AppKit
import PDFKit
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceStorePDFAnnotationExportTests: WorkspaceStorePDFTestCase {
    func testExportPDFAnnotationsUsesDirtyPDFDataBeforeDiskData() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let diskData = try makePDFData(annotationText: "Disk highlight")
        let dirtyData = try makePDFData(annotationText: "Unsaved highlight")
        try diskData.write(to: pdfURL)

        let store = makeWorkspaceStore()
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

        let store = makeWorkspaceStore()
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

        let store = makeWorkspaceStore()
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
}
