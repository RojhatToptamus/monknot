import AppKit
import PDFKit
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceStorePDFSaveConflictTests: WorkspaceStorePDFTestCase {
    func testMarkPDFDocumentEditedPublishesWorkspaceSearchContentChange() async throws {
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

        let store = makeWorkspaceStore()
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

        let store = makeWorkspaceStore()
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

    func testFreeTextAnnotationSavesAndReloadsFromDisk() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let diskData = try makePDFData(annotationText: "Disk highlight")
        try diskData.write(to: pdfURL)

        let liveDocument = try XCTUnwrap(PDFDocument(data: diskData))
        let page = try XCTUnwrap(liveDocument.page(at: 0))
        let formatting = PDFFreeTextFormatting(
            fontFamily: "Helvetica",
            fontSize: 18,
            fontColor: .systemBlue,
            isBold: true,
            isItalic: false,
            alignment: .center
        )
        page.addAnnotation(makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 40, width: 170, height: 64),
            contents: "Persisted free text\nSecond line",
            formatting: formatting
        ))
        let dirtyData = try XCTUnwrap(liveDocument.dataRepresentation())

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        let workspaceDocument = try XCTUnwrap(
            store.documents.first(where: { $0.url == pdfURL.standardizedFileURL })
        )
        store.markPDFDocumentEdited(
            id: workspaceDocument.id,
            previousData: diskData,
            data: dirtyData
        )
        store.saveSelectedFile()
        let didSave = await waitUntil {
            !store.isSaving && store.saveState(for: workspaceDocument.id).isClean
        }
        XCTAssertTrue(didSave)

        let reloadedDocument = try XCTUnwrap(PDFDocument(url: pdfURL))
        let freeText = try XCTUnwrap(reloadedDocument.page(at: 0)?.annotations.first(where: {
            ($0.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText"
        }))
        XCTAssertEqual(freeText.contents, "Persisted free text\nSecond line")
        XCTAssertEqual(freeText.alignment, .center)
        XCTAssertEqual(try XCTUnwrap(freeText.font).pointSize, 18, accuracy: 0.01)
    }

    func testSuccessfulPDFSaveRearmsLiveViewForSecondEditAndUndo() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let sourceDocument = try XCTUnwrap(PDFDocument(data: makePDFData(annotationText: "Disk highlight")))
        let sourcePage = try XCTUnwrap(sourceDocument.page(at: 0))
        sourcePage.addAnnotation(makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 40, width: 170, height: 64),
            contents: "Editable"
        ))
        let diskData = try XCTUnwrap(sourceDocument.dataRepresentation())
        try diskData.write(to: pdfURL)

        let firstEditDocument = try XCTUnwrap(PDFDocument(data: diskData))
        let firstEditAnnotation = try XCTUnwrap(firstEditDocument.page(at: 0)?.annotations.first(where: {
            ($0.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText"
        }))
        var firstFormatting = PDFFreeTextFormatting(annotation: firstEditAnnotation)
        firstFormatting.fontSize = 18
        firstFormatting.apply(to: firstEditAnnotation)
        let firstEdit = try XCTUnwrap(firstEditDocument.dataRepresentation())

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        let document = try XCTUnwrap(
            store.documents.first(where: { $0.url == pdfURL.standardizedFileURL })
        )
        store.markPDFDocumentEdited(id: document.id, previousData: diskData, data: firstEdit)
        store.saveSelectedFile()
        let didSaveFirstEdit = await waitUntil {
            !store.isSaving && store.saveState(for: document.id).isClean
        }
        XCTAssertTrue(didSaveFirstEdit, store.errorMessage ?? "PDF did not save")

        let liveDocument = try XCTUnwrap(PDFDocument(data: firstEdit))
        let page = try XCTUnwrap(liveDocument.page(at: 0))
        let annotation = try XCTUnwrap(page.annotations.first(where: {
            ($0.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText"
        }))
        let pdfView = AnnotatingPDFView()
        pdfView.document = liveDocument
        pdfView.replaceEditBaselineCapture(with: firstEdit, needsSnapshot: true)
        var publishedEdits: [(previous: Data?, data: Data)] = []
        pdfView.onEdited = { previousData, data, editCheckpoint in
            publishedEdits.append((previousData, data))
            store.markPDFDocumentEdited(
                id: document.id,
                previousData: previousData,
                data: data,
                editCheckpoint: editCheckpoint
            )
        }

        pdfView.selectFreeTextAnnotation(annotation, on: page)
        var formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.fontSize = 22
        pdfView.applyFreeTextFormatting(formatting)
        let secondEdit = try XCTUnwrap(publishedEdits.last)
        XCTAssertNotNil(secondEdit.previous)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertFalse(store.saveState(for: document.id).isClean)
        XCTAssertNil(store.errorMessage)

        store.saveSelectedFile()
        let didSaveSecondEdit = await waitUntil {
            !store.isSaving && store.saveState(for: document.id).isClean
        }
        XCTAssertTrue(didSaveSecondEdit, store.errorMessage ?? "Second PDF edit did not save")

        pdfView.reconcileEditBaselineCapture(
            hasDirtyData: store.dirtyPDFData(for: document.id) != nil
        )
        pdfView.undoAnnotationEdit()
        let undoEdit = try XCTUnwrap(publishedEdits.last)
        XCTAssertNotNil(undoEdit.previous)
        XCTAssertNotNil(store.dirtyPDFData(for: document.id))
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertNil(store.errorMessage)
    }

    func testUndoOfEditMadeDuringSaveRestoresExactSavedCheckpoint() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let sourceDocument = try XCTUnwrap(PDFDocument(data: makePDFData(annotationText: "Disk highlight")))
        let sourcePage = try XCTUnwrap(sourceDocument.page(at: 0))
        sourcePage.addAnnotation(makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 40, width: 170, height: 64),
            contents: "Editable"
        ))
        var exactDiskData = try XCTUnwrap(sourceDocument.dataRepresentation())
        exactDiskData.append(Data("\n% Preserve exact saved checkpoint bytes\n".utf8))
        try exactDiskData.write(to: pdfURL)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        let workspaceDocument = try XCTUnwrap(
            store.documents.first(where: { $0.url == pdfURL.standardizedFileURL })
        )
        let liveDocument = try XCTUnwrap(PDFDocument(data: exactDiskData))
        let page = try XCTUnwrap(liveDocument.page(at: 0))
        let annotation = try XCTUnwrap(page.annotations.first(where: {
            ($0.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText"
        }))
        let pdfView = AnnotatingPDFView()
        pdfView.document = liveDocument
        pdfView.replaceEditBaselineCapture(with: exactDiskData, needsSnapshot: true)
        pdfView.onEdited = { previousData, data, editCheckpoint in
            store.markPDFDocumentEdited(
                id: workspaceDocument.id,
                previousData: previousData,
                data: data,
                editCheckpoint: editCheckpoint
            )
        }
        pdfView.onRestoreSavedEditCheckpoint = { checkpoint in
            store.restorePDFSavedEditCheckpoint(
                id: workspaceDocument.id,
                checkpoint: checkpoint
            )
        }
        pdfView.selectFreeTextAnnotation(annotation, on: page)

        var formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.fontSize = 18
        pdfView.applyFreeTextFormatting(formatting)
        let savedData = try XCTUnwrap(store.dirtyPDFData(for: workspaceDocument.id))

        store.saveSelectedFile()
        XCTAssertTrue(store.isSaving)
        formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.fontSize = 22
        pdfView.applyFreeTextFormatting(formatting)
        XCTAssertNotEqual(store.dirtyPDFData(for: workspaceDocument.id), savedData)

        let didFinishRacedSave = await waitUntil {
            !store.isSaving &&
                store.pdfSavedEditCheckpoint(for: workspaceDocument.id) != nil &&
                !store.saveState(for: workspaceDocument.id).isClean
        }
        XCTAssertTrue(didFinishRacedSave, store.errorMessage ?? "Raced PDF save did not finish")
        XCTAssertEqual(try Data(contentsOf: pdfURL), savedData)

        pdfView.reconcileEditBaselineCapture(
            hasDirtyData: true,
            savedEditCheckpoint: store.pdfSavedEditCheckpoint(for: workspaceDocument.id)
        )
        pdfView.undoAnnotationEdit()

        XCTAssertEqual(try XCTUnwrap(annotation.font).pointSize, 18, accuracy: 0.01)
        XCTAssertNil(store.dirtyPDFData(for: workspaceDocument.id))
        XCTAssertNil(store.pdfSavedEditCheckpoint(for: workspaceDocument.id))
        XCTAssertTrue(store.saveState(for: workspaceDocument.id).isClean)
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: pdfURL), savedData)
    }

    func testExactDiskBaselineSavesFirstEditRearmsAndStillRejectsExternalReplacement() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let sourceDocument = try XCTUnwrap(PDFDocument(data: makePDFData(annotationText: "Disk highlight")))
        let sourcePage = try XCTUnwrap(sourceDocument.page(at: 0))
        sourcePage.addAnnotation(makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 40, width: 170, height: 64),
            contents: "Editable"
        ))
        var exactDiskData = try XCTUnwrap(sourceDocument.dataRepresentation())
        exactDiskData.append(Data("\n% Monknot exact-byte baseline fixture\n".utf8))
        try exactDiskData.write(to: pdfURL)
        XCTAssertNotEqual(
            try XCTUnwrap(PDFDocument(data: exactDiskData)?.dataRepresentation()),
            exactDiskData,
            "Fixture must expose PDFKit reserialization drift"
        )

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        let document = try XCTUnwrap(store.documents.first(where: { $0.url == pdfURL.standardizedFileURL }))

        let container = PDFPreviewContainerView()
        let coordinator = PDFKitPreviewRepresentable.Coordinator()
        container.navigatorView.attach(to: container.pdfView)
        defer {
            coordinator.detach()
            container.prepareForDismantle()
        }
        XCTAssertTrue(coordinator.loadDocumentIfNeeded(
            pdfURL,
            dirtyData: nil,
            contentVersion: store.pdfContentVersion(for: document.id),
            in: container.pdfView,
            navigatorView: container.navigatorView
        ))
        container.pdfView.reconcileEditBaselineCapture(hasDirtyData: false)
        container.pdfView.onEdited = { previousData, data, editCheckpoint in
            store.markPDFDocumentEdited(
                id: document.id,
                previousData: previousData,
                data: data,
                editCheckpoint: editCheckpoint
            )
        }

        let page = try XCTUnwrap(container.pdfView.document?.page(at: 0))
        let annotation = try XCTUnwrap(page.annotations.first(where: {
            ($0.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText"
        }))
        container.pdfView.selectFreeTextAnnotation(annotation, on: page)
        var formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.fontSize = 18
        container.pdfView.applyFreeTextFormatting(formatting)
        _ = try XCTUnwrap(store.dirtyPDFData(for: document.id))

        container.pdfView.reconcileEditBaselineCapture(hasDirtyData: true)
        container.pdfView.undoAnnotationEdit()
        XCTAssertNil(store.dirtyPDFData(for: document.id))
        XCTAssertTrue(store.saveState(for: document.id).isClean)
        XCTAssertEqual(try Data(contentsOf: pdfURL), exactDiskData)

        container.pdfView.reconcileEditBaselineCapture(hasDirtyData: false)
        container.pdfView.redoAnnotationEdit()
        let redoDirtyData = try XCTUnwrap(store.dirtyPDFData(for: document.id))
        XCTAssertNotEqual(redoDirtyData, exactDiskData)

        store.saveSelectedFile()
        let didSave = await waitUntil {
            !store.isSaving && store.saveState(for: document.id).isClean
        }
        XCTAssertTrue(didSave, store.errorMessage ?? "First exact-baseline save failed")
        XCTAssertEqual(try Data(contentsOf: pdfURL), redoDirtyData)

        container.pdfView.reconcileEditBaselineCapture(hasDirtyData: false)
        container.pdfView.undoAnnotationEdit()
        XCTAssertNotNil(store.dirtyPDFData(for: document.id))
        XCTAssertFalse(store.saveState(for: document.id).isClean)

        container.pdfView.reconcileEditBaselineCapture(hasDirtyData: true)
        container.pdfView.redoAnnotationEdit()
        XCTAssertNil(store.dirtyPDFData(for: document.id))
        XCTAssertTrue(store.saveState(for: document.id).isClean)

        container.pdfView.reconcileEditBaselineCapture(hasDirtyData: false)
        formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.fontSize = 22
        container.pdfView.applyFreeTextFormatting(formatting)
        let secondDirtyData = try XCTUnwrap(store.dirtyPDFData(for: document.id))
        XCTAssertNotEqual(secondDirtyData, redoDirtyData)

        let externalData = try makePDFData(annotationText: "External replacement")
        try externalData.write(to: pdfURL)
        store.saveSelectedFile()
        let didReject = await waitUntil {
            guard !store.isSaving, store.selectedDocumentExternalChange else { return false }
            if case .failed = store.saveState(for: document.id) { return true }
            return false
        }

        XCTAssertTrue(didReject, store.errorMessage ?? "External replacement was not rejected")
        XCTAssertEqual(try Data(contentsOf: pdfURL), externalData)
        XCTAssertEqual(store.dirtyPDFData(for: document.id), secondDirtyData)
    }

    func testCancellingActiveFreeTextBeforeDiscardCannotRedirtyDuringTeardown() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let sourceDocument = try XCTUnwrap(PDFDocument(data: makePDFData(annotationText: "Disk highlight")))
        let sourcePage = try XCTUnwrap(sourceDocument.page(at: 0))
        sourcePage.addAnnotation(makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 40, width: 170, height: 64),
            contents: "Original"
        ))
        let diskData = try XCTUnwrap(sourceDocument.dataRepresentation())
        try diskData.write(to: pdfURL)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        let workspaceDocument = try XCTUnwrap(
            store.documents.first(where: { $0.url == pdfURL.standardizedFileURL })
        )
        let liveDocument = try XCTUnwrap(PDFDocument(data: diskData))
        let livePage = try XCTUnwrap(liveDocument.page(at: 0))
        let annotation = try XCTUnwrap(livePage.annotations.first(where: {
            ($0.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText"
        }))
        let pdfView = AnnotatingPDFView()
        pdfView.document = liveDocument
        pdfView.onEdited = { previousData, data, editCheckpoint in
            store.markPDFDocumentEdited(
                id: workspaceDocument.id,
                previousData: previousData,
                data: data,
                editCheckpoint: editCheckpoint
            )
        }
        pdfView.beginFreeTextEditing(
            annotation,
            on: livePage,
            isNew: false,
            baselineData: diskData
        )
        let scrollView = try XCTUnwrap(pdfView.subviews.compactMap { $0 as? NSScrollView }.last)
        let editor = try XCTUnwrap(scrollView.documentView as? NSTextView)
        editor.string = "Unsaved draft"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertNotNil(store.dirtyPDFData(for: workspaceDocument.id))

        let bridge = PDFViewportCaptureBridge()
        bridge.attach(documentID: workspaceDocument.id, to: pdfView)
        XCTAssertTrue(bridge.cancelActiveFreeTextEdit(documentID: workspaceDocument.id))
        store.discardUnsavedChanges(for: workspaceDocument.id)

        XCTAssertNil(store.dirtyPDFData(for: workspaceDocument.id))
        XCTAssertTrue(store.saveState(for: workspaceDocument.id).isClean)
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: pdfURL), diskData)

        pdfView.prepareForDismantle()
        XCTAssertNil(store.dirtyPDFData(for: workspaceDocument.id))
        XCTAssertTrue(store.saveState(for: workspaceDocument.id).isClean)
    }

    func testDiscardAndManualReloadAdvancePDFContentVersionWithoutAdvancingForLiveEdits() async throws {
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

        let store = makeWorkspaceStore()
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

    func testExternalPDFReplacementAfterSaveStartsNextEditFromReplacementBaseline() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Paper.pdf")
        let diskData = try makePDFData(annotationText: "Disk highlight")
        let firstEdit = try makePDFData(annotationText: "First saved edit")
        let externalData = try makePDFData(annotationText: "External replacement")
        let secondEdit = try makePDFData(annotationText: "Edit after replacement")
        try diskData.write(to: pdfURL)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didLoad = await waitUntil { !store.isBusy && store.selectedDocument != nil }
        XCTAssertTrue(didLoad)
        let document = try XCTUnwrap(
            store.documents.first(where: { $0.id == pdfURL.standardizedFileURL.path })
        )
        store.markPDFDocumentEdited(id: document.id, previousData: diskData, data: firstEdit)
        store.saveSelectedFile()
        let didSaveFirstEdit = await waitUntil {
            !store.isSaving && store.saveState(for: document.id).isClean
        }
        XCTAssertTrue(didSaveFirstEdit, store.errorMessage ?? "First PDF edit did not save")

        let versionBeforeReplacement = store.pdfContentVersion(for: document.id)
        try externalData.write(to: pdfURL)
        store.testing_clearWatcherSuppression()
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [pdfURL.standardizedFileURL.path],
            modifiedOnlyPaths: [pdfURL.standardizedFileURL.path],
            requiresFullRescan: false
        ))
        XCTAssertGreaterThan(store.pdfContentVersion(for: document.id), versionBeforeReplacement)

        store.markPDFDocumentEdited(
            id: document.id,
            previousData: externalData,
            data: secondEdit
        )
        store.saveSelectedFile()
        let didSaveSecondEdit = await waitUntil {
            !store.isSaving && store.saveState(for: document.id).isClean
        }

        XCTAssertTrue(didSaveSecondEdit, store.errorMessage ?? "Replacement-based PDF edit did not save")
        XCTAssertEqual(try Data(contentsOf: pdfURL), secondEdit)
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

        let store = makeWorkspaceStore()
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

        let store = makeWorkspaceStore()
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
}
