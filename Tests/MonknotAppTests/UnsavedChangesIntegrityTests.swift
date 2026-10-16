import AppKit
import Combine
import ImageIO
import MonknotCore
import PDFKit
import SwiftUI
import XCTest
@testable import MonknotApp

/// Documents the user never edits stay clean: no unsaved dot, no dirty buffer and no "changed on
/// disk" banner, whatever the file holds and whatever the user does short of editing it.
@MainActor
final class UnsavedChangesIntegrityTests: WorkspaceStoreTestCase {
    private var hostWindows: [NSWindow] = []

    override func tearDown() async throws {
        for window in hostWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        hostWindows.removeAll()
        try await super.tearDown()
    }

    // MARK: - Markdown toolbar

    /// `EditorPaneView` keeps the last toolbar request in its state while Source, Preview,
    /// split and tab changes rebuild the editor, as this harness does.
    func testAToolbarCommandIsNotAppliedAgainWhenTheEditorIsRebuilt() async throws {
        let (store, url) = try await openNote("word\n", named: "A.md")
        let controls = ToolbarEditorControls()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ToolbarEditorHarness(store: store, controls: controls))
        window.contentView = host
        window.orderFront(nil)
        hostWindows.append(window)

        let shown = await waitUntil { self.documentTextView(in: host)?.string == "word\n" }
        XCTAssertTrue(shown)
        documentTextView(in: host)?.setSelectedRange(NSRange(location: 0, length: 4))
        controls.commandRequest = MarkdownTextEditorCommandRequest(serial: 1, command: .bold)
        let applied = await waitUntil { store.documentText == "**word**\n" }
        XCTAssertTrue(applied, store.documentText)
        store.saveSelectedFile()
        let saved = await waitUntil { !store.isSaving && store.saveState(for: url.path).isClean }
        XCTAssertTrue(saved)

        for _ in 0..<2 {
            controls.showsEditor = false
            await settle()
            controls.showsEditor = true
            let remounted = await waitUntil { self.documentTextView(in: host) != nil }
            XCTAssertTrue(remounted)
            await settle()
        }
        XCTAssertEqual(store.documentText, "**word**\n")
        assertClean(store, "after rebuilding the editor")

        documentTextView(in: host)?.setSelectedRange(NSRange(location: 0, length: 0))
        controls.commandRequest = MarkdownTextEditorCommandRequest(serial: 2, command: .italic)
        let appliedAgain = await waitUntil { store.documentText != "**word**\n" }
        XCTAssertTrue(appliedAgain, "a new toolbar command still edits the document")
        XCTAssertTrue(store.hasUnsavedChanges)
    }

    // MARK: - Undo

    func testUndoAfterSwitchingDocumentsDoesNotEditTheOtherDocument() async throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotUnsavedUndo")
        try Data("alpha\n".utf8).write(to: root.appendingPathComponent("A.md"))
        try Data("bravo charlie delta\n".utf8).write(to: root.appendingPathComponent("B.md"))
        let store = try await openStore(root)
        let controls = PaneControls()
        let host = hostEditorPane(store: store, controls: controls)
        let a = root.appendingPathComponent("A.md").standardizedFileURL.path
        let b = root.appendingPathComponent("B.md").standardizedFileURL.path

        // Both documents have been open before, so switching keeps the same editor.
        for id in [b, a, b] {
            XCTAssertTrue(store.selectDocument(id: id))
            await settle(0.5)
        }
        XCTAssertTrue(store.selectDocument(id: a))
        let shownA = await waitUntil { self.documentTextView(in: host)?.string == "alpha\n" }
        XCTAssertTrue(shownA)
        let textView = try XCTUnwrap(documentTextView(in: host))
        host.window?.makeFirstResponder(textView)
        type(" typed", at: 5, in: textView)
        let edited = await waitUntil { store.documentText == "alpha typed\n" }
        XCTAssertTrue(edited)
        undo(in: textView)
        XCTAssertEqual(store.documentText, "alpha\n")
        assertClean(store, "after undoing back to the saved text")
        textView.undoManager?.redo()
        XCTAssertEqual(store.documentText, "alpha typed\n")
        XCTAssertTrue(store.hasUnsavedChanges)
        store.saveSelectedFile()
        let saved = await waitUntil { !store.isSaving && store.documentSaveStates.isEmpty }
        XCTAssertTrue(saved)

        XCTAssertTrue(store.selectDocument(id: b))
        let shownB = await waitUntil { self.documentTextView(in: host)?.string == "bravo charlie delta\n" }
        XCTAssertTrue(shownB)
        let bTextView = try XCTUnwrap(documentTextView(in: host))
        host.window?.makeFirstResponder(bTextView)
        XCTAssertTrue(bTextView === textView, "the editor is reused")
        undo(in: bTextView)
        await settle()
        XCTAssertEqual(store.documentText, "bravo charlie delta\n", "undo must not replay another document's typing")
        assertClean(store, "after undo in another document")
    }

    // MARK: - Files whose contents did not change

    func testTouchingACleanDocumentKeepsItCleanWithoutReloadingIt() async throws {
        let (store, url) = try await openNote()
        var reloads = 0
        let observation = store.$isDocumentLoading.dropFirst().sink { if $0 { reloads += 1 } }
        defer { observation.cancel() }
        try touch(url)
        deliverModification(of: url, to: store)
        await settle(0.6)
        try Data("# Note\n\nBody\n".utf8).write(to: url, options: .atomic)
        deliverModification(of: url, to: store)
        await settle(0.6)
        assertClean(store, "after touch")
        XCTAssertEqual(store.documentText, "# Note\n\nBody\n")
        XCTAssertEqual(reloads, 0, "the editor keeps the text it already shows")

        try Data("# Note\n\nChanged elsewhere\n".utf8).write(to: url, options: .atomic)
        deliverModification(of: url, to: store)
        let reloaded = await waitUntil { store.documentText == "# Note\n\nChanged elsewhere\n" }
        XCTAssertTrue(reloaded, "a clean document still follows a real change")
        assertClean(store, "after a real change")
    }

    func testTouchingAnEditedDocumentIsNotAnExternalChange() async throws {
        let (store, url) = try await openNote()
        store.setDocumentText("# Note\n\nEdited\n")
        XCTAssertTrue(store.hasUnsavedChanges)
        try touch(url)
        deliverModification(of: url, to: store)
        await settle(0.6)
        XCTAssertFalse(store.selectedDocumentExternalChange, "an mtime-only change is not a content change")

        store.saveSelectedFile()
        let saved = await waitUntil { !store.isSaving && store.saveState(for: url.path).isClean }
        XCTAssertTrue(saved, "save failed: \(store.errorMessage ?? "")")
        assertClean(store, "after saving")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Note\n\nEdited\n")
    }

    func testAnIdenticalAtomicRewriteOfAnEditedDocumentIsNotAnExternalChange() async throws {
        let (store, url) = try await openNote()
        store.setDocumentText("# Note\n\nEdited\n")
        try await Task.sleep(nanoseconds: 20_000_000)
        try Data("# Note\n\nBody\n".utf8).write(to: url, options: .atomic)
        deliverModification(of: url, to: store)
        await settle(0.6)
        XCTAssertFalse(store.selectedDocumentExternalChange)

        store.saveSelectedFile()
        let saved = await waitUntil { !store.isSaving && store.saveState(for: url.path).isClean }
        XCTAssertTrue(saved, "save failed: \(store.errorMessage ?? "")")
        assertClean(store, "after saving")
    }

    func testAnEditedDocumentTouchedWhileInAnotherTabIsNotAnExternalChange() async throws {
        let (store, url) = try await openNote()
        let other = url.deletingLastPathComponent().appendingPathComponent("Other.md")
        try Data("# Other\n".utf8).write(to: other)
        store.refresh()
        let listed = await waitUntil { store.document(id: other.standardizedFileURL.path) != nil }
        XCTAssertTrue(listed)
        store.testing_stopFileWatcher()

        store.setDocumentText("# Note\n\nEdited\n")
        XCTAssertTrue(store.selectDocument(id: other.standardizedFileURL.path))
        let switched = await waitUntil { !store.isDocumentLoading && store.documentText == "# Other\n" }
        XCTAssertTrue(switched)
        try touch(url)
        try Data("# Note\n\nBody\n".utf8).write(to: url, options: .atomic)
        XCTAssertTrue(store.selectDocument(id: url.path))
        XCTAssertEqual(store.documentText, "# Note\n\nEdited\n")
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertFalse(store.selectedDocumentExternalChange)

        XCTAssertTrue(store.selectDocument(id: other.standardizedFileURL.path))
        let savedInBackground = await store.saveDocument(id: url.path)
        XCTAssertTrue(savedInBackground, store.errorMessage ?? "")
        XCTAssertTrue(store.selectDocument(id: url.path))
        let reopened = await waitUntil { !store.isDocumentLoading }
        XCTAssertTrue(reopened)
        assertClean(store, "after saving from another tab")
        XCTAssertEqual(store.documentText, "# Note\n\nEdited\n")
    }

    func testAWritingToolsResultForATouchedFileIsNotAnExternalChange() async throws {
        let (store, url) = try await openNote()
        XCTAssertTrue(store.setWritingToolsActive(true, documentID: url.path))
        try touch(url)
        store.commitWritingToolsText("# Note\n\nRewritten\n", documentID: url.path)
        XCTAssertTrue(store.setWritingToolsActive(false, documentID: url.path))
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertFalse(store.selectedDocumentExternalChange, "the file still holds the text the session started from")
        store.saveSelectedFile()
        let saved = await waitUntil { !store.isSaving && store.documentSaveStates.isEmpty }
        XCTAssertTrue(saved, store.errorMessage ?? "")
    }

    func testTouchingAPDFWithUnsavedMarkupIsNotAnExternalChange() async throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotUnsavedPDF")
        let url = root.appendingPathComponent("plain.pdf").standardizedFileURL
        try DocumentFileTypeFixtures.writePDF(to: url)
        let store = try await openStore(root)
        XCTAssertTrue(store.selectDocument(id: url.path))
        let original = try Data(contentsOf: url)
        let pdf = try XCTUnwrap(PDFDocument(data: original))
        let page = try XCTUnwrap(pdf.page(at: 0))
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 40, height: 20), forType: .square, withProperties: nil))
        store.markPDFDocumentEdited(id: url.path, previousData: original, data: try XCTUnwrap(pdf.dataRepresentation()))
        XCTAssertTrue(store.hasUnsavedChanges)

        try touch(url)
        deliverModification(of: url, to: store)
        await settle(0.6)
        XCTAssertFalse(store.selectedDocumentExternalChange, "an mtime-only change is not a content change")
        XCTAssertTrue(store.hasUnsavedChanges)
    }

    func testKeepingMyTextAfterAReviewSavesWithoutAnotherConflict() async throws {
        let (store, url) = try await openNote(stopWatcher: false)
        store.setDocumentText("# Note\n\nMine\n")
        try await Task.sleep(nanoseconds: 20_000_000)
        try Data("# Note\n\nTheirs\n".utf8).write(to: url, options: .atomic)
        let reported = await waitUntil(timeout: 8) { store.selectedDocumentExternalChange }
        XCTAssertTrue(reported)

        store.resolveSelectedExternalDocumentWithoutReview(.keepLocal)
        let resolved = await waitUntil { !store.selectedDocumentExternalChange }
        XCTAssertTrue(resolved)
        XCTAssertTrue(store.hasUnsavedChanges, "the kept text differs from the file")
        try touch(url)
        deliverModification(of: url, to: store)
        await settle(0.6)
        XCTAssertFalse(store.selectedDocumentExternalChange)

        store.saveSelectedFile()
        let saved = await waitUntil { !store.isSaving && store.documentSaveStates.isEmpty }
        XCTAssertTrue(saved, store.errorMessage ?? "")
        await settle(2)
        assertClean(store, "after saving the kept text")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Note\n\nMine\n")
    }

    func testAContentChangeToAnEditedDocumentIsStillReported() async throws {
        let (store, url) = try await openNote()
        store.setDocumentText("# Note\n\nEdited\n")
        try await Task.sleep(nanoseconds: 20_000_000)
        try Data("# Note\n\nChanged elsewhere\n".utf8).write(to: url, options: .atomic)
        deliverModification(of: url, to: store)
        let reported = await waitUntil { store.selectedDocumentExternalChange }
        XCTAssertTrue(reported)
        XCTAssertTrue(store.hasUnsavedChanges)
    }

    // MARK: - Viewing text

    func testOpeningAndViewingTextNeverMarksItEdited() async throws {
        let root = try makeTextWorkspace()
        let store = try await openStore(root)
        let controls = PaneControls()
        let host = hostEditorPane(store: store, controls: controls)

        for fixture in Self.textFixtures {
            let document = try XCTUnwrap(store.documents.first { $0.displayName == fixture.name })
            controls.reset()
            XCTAssertTrue(store.selectDocument(id: document.id))
            // Foundation's UTF-8 decoding drops a leading byte order mark.
            let expected = fixture.contents.hasPrefix("\u{FEFF}") ? String(fixture.contents.dropFirst()) : fixture.contents
            let shown = await waitUntil {
                !store.isDocumentLoading && self.documentTextView(in: host)?.string == expected
            }
            XCTAssertTrue(shown, "\(fixture.name) did not open")
            await settle()
            assertClean(store, "\(fixture.name) after opening")

            if document.hasPreviewMode {
                controls.editorMode = .preview
                await settle()
                assertClean(store, "\(fixture.name) in Preview")
                controls.editorMode = .source
                await settle()
                assertClean(store, "\(fixture.name) back in Source")
                controls.isSplitViewEnabled = true
                await settle()
                assertClean(store, "\(fixture.name) in Split")
                controls.isSplitViewEnabled = false
                await settle()
                assertClean(store, "\(fixture.name) after Split")
            }

            controls.zoomScale = 1.4
            await settle()
            controls.zoomScale = 0.8
            await settle()
            controls.zoomScale = 1
            await settle()
            assertClean(store, "\(fixture.name) after zooming")

            host.window?.setContentSize(NSSize(width: 420, height: 300))
            await settle()
            host.window?.setContentSize(NSSize(width: 800, height: 600))
            await settle()
            assertClean(store, "\(fixture.name) after resizing")

            if let textView = documentTextView(in: host) {
                host.window?.makeFirstResponder(textView)
                textView.selectAll(nil)
                await settle()
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                textView.scrollToEndOfDocument(nil)
                await settle()
                textView.scrollToBeginningOfDocument(nil)
                await settle()
                assertClean(store, "\(fixture.name) after selecting and scrolling")
            }

            controls.documentSearch.present()
            controls.documentSearch.setQuery("e")
            await settle()
            controls.documentSearch.dismiss()
            await settle()
            assertClean(store, "\(fixture.name) after find")

            controls.sourceLocation = MarkdownSourceLocation(line: 2, offset: 0)
            await settle()
            assertClean(store, "\(fixture.name) after go to line")
        }

        // Switch tabs back and forth.
        for fixture in Self.textFixtures + Self.textFixtures.reversed() {
            let document = try XCTUnwrap(store.documents.first { $0.displayName == fixture.name })
            XCTAssertTrue(store.selectDocument(id: document.id))
            await settle(0.05)
        }
        await settle()
        assertClean(store, "after switching tabs")
    }

    func testRestoringTheViewportAndCheckingSpellingAroundTheCaretLeavesTextUntouched() async throws {
        let root = try makeTextWorkspace()
        let store = try await openStore(root)
        let controls = PaneControls()
        controls.viewportState = DocumentViewportState(
            textScrollPosition: DocumentScrollPosition(x: 0, y: 120),
            textSelection: DocumentTextSelection(location: 40, length: 12)
        )
        let host = hostEditorPane(store: store, controls: controls)
        host.window?.makeKeyAndOrderFront(nil)
        let rich = try XCTUnwrap(store.documents.first { $0.displayName == "rich.md" })
        XCTAssertTrue(store.selectDocument(id: rich.id))
        let shown = await waitUntil { !store.isDocumentLoading && self.documentTextView(in: host) != nil }
        XCTAssertTrue(shown)
        let textView = try XCTUnwrap(documentTextView(in: host))
        host.window?.makeFirstResponder(textView)
        let length = (textView.string as NSString).length
        for location in stride(from: 0, to: length, by: 23) {
            textView.setSelectedRange(NSRange(location: location, length: 0))
            await settle(0.1)
        }
        await settle(3)
        assertClean(store, "after moving the caret through misspelled text")
    }

    // MARK: - PDFs and images

    func testViewingPDFsAndImagesNeverMarksThemEdited() async throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotUnsavedPDF")
        try writeAnnotatedPDF(to: root.appendingPathComponent("annotated.pdf"))
        try DocumentFileTypeFixtures.writePDF(to: root.appendingPathComponent("plain.pdf"))
        try DocumentFileTypeFixtures.writeImage(
            [DocumentFileTypeFixtures.image(width: 60, height: 40)],
            as: .png,
            to: root.appendingPathComponent("photo.png")
        )
        try DocumentFileTypeFixtures.writeImage(
            [DocumentFileTypeFixtures.image(width: 60, height: 40)],
            as: .jpeg,
            to: root.appendingPathComponent("rotated.jpg"),
            properties: [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue]
        )
        let store = try await openStore(root)
        let controls = PaneControls()
        let host = hostEditorPane(store: store, controls: controls)

        for name in ["annotated.pdf", "plain.pdf", "photo.png", "rotated.jpg", "annotated.pdf"] {
            let document = try XCTUnwrap(store.documents.first { $0.displayName == name })
            controls.reset()
            XCTAssertTrue(store.selectDocument(id: document.id))
            let shown = await waitUntil { self.pdfView(in: host)?.document != nil }
            XCTAssertTrue(shown, "\(name) did not open")
            await settle(0.5)
            assertClean(store, "\(name) after opening")
            let pdfView = try XCTUnwrap(pdfView(in: host) as? AnnotatingPDFView)

            controls.zoomScale = 1.5
            await settle()
            pdfView.scaleFactor *= 1.7
            await settle()
            pdfView.autoScales = true
            await settle()
            controls.zoomScale = 1
            await settle()
            assertClean(store, "\(name) after zooming")

            pdfView.goToNextPage(nil)
            await settle()
            pdfView.goToFirstPage(nil)
            await settle()
            controls.pdfNavigatorToggleSerial += 1
            await settle(0.5)
            controls.pdfNavigatorToggleSerial += 1
            await settle()
            assertClean(store, "\(name) after page navigation and thumbnails")

            if let page = pdfView.document?.page(at: 0), let selection = page.selection(for: page.bounds(for: .mediaBox)) {
                pdfView.setCurrentSelection(selection, animate: false)
                await settle()
                pdfView.clearSelection()
            }
            controls.documentSearch.present()
            controls.documentSearch.setQuery("sample")
            await settle(0.5)
            controls.documentSearch.dismiss()
            await settle()
            assertClean(store, "\(name) after selecting and searching")

            for mode in [PDFAnnotationInteractionMode.highlighter, .pen, .eraser, .select] {
                pdfView.annotationMode = mode
                await settle(0.1)
            }
            await settle()
            assertClean(store, "\(name) after switching tools")

            host.window?.setContentSize(NSSize(width: 420, height: 300))
            await settle()
            host.window?.setContentSize(NSSize(width: 800, height: 600))
            await settle()
            assertClean(store, "\(name) after resizing")
        }
    }

    func testSavedMarkupStaysCleanWhenTheFileIsReopened() async throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotUnsavedMarkup")
        try writeAnnotatedPDF(to: root.appendingPathComponent("annotated.pdf"))
        try DocumentFileTypeFixtures.writeImage(
            [DocumentFileTypeFixtures.image(width: 60, height: 40)],
            as: .png,
            to: root.appendingPathComponent("photo.png")
        )
        try Data("# Note\n".utf8).write(to: root.appendingPathComponent("Note.md"))
        let store = try await openStore(root, stopWatcher: false)
        let controls = PaneControls()
        let host = hostEditorPane(store: store, controls: controls)

        for name in ["annotated.pdf", "photo.png"] {
            let document = try XCTUnwrap(store.documents.first { $0.displayName == name })
            XCTAssertTrue(store.selectDocument(id: document.id))
            let shown = await waitUntil { self.pdfView(in: host)?.document != nil }
            XCTAssertTrue(shown, name)
            await settle(0.5)
            let pdfDocument = try XCTUnwrap(pdfView(in: host)?.document)
            let page = try XCTUnwrap(pdfDocument.page(at: 0))
            page.addAnnotation(PDFAnnotation(
                bounds: CGRect(x: 5, y: 5, width: 20, height: 10),
                forType: .square,
                withProperties: nil
            ))
            let data = document.kind == .image
                ? ImageMarkupDocument.markupData(from: pdfDocument)
                : pdfDocument.dataRepresentation()
            store.markPDFDocumentEdited(
                id: document.id,
                previousData: try Data(contentsOf: document.url),
                data: data
            )
            XCTAssertFalse(store.saveState(for: document.id).isClean, name)
            store.saveSelectedFile()
            let saved = await waitUntil { !store.isSaving && store.documentSaveStates.isEmpty }
            XCTAssertTrue(saved, "\(name): \(store.errorMessage ?? "")")
            await settle(2)
            assertClean(store, "\(name) after saving")

            XCTAssertTrue(store.selectDocument(id: root.appendingPathComponent("Note.md").standardizedFileURL.path))
            await settle(0.5)
            XCTAssertTrue(store.selectDocument(id: document.id))
            let reopened = await waitUntil { self.pdfView(in: host)?.document != nil }
            XCTAssertTrue(reopened, name)
            await settle(1)
            assertClean(store, "\(name) after reopening")
        }
    }

    func testOpeningAnExistingTextBoxWithoutTypingPublishesNoEdit() throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotUnsavedFreeText")
        let url = root.appendingPathComponent("annotated.pdf")
        try writeAnnotatedPDF(to: url)
        let data = try Data(contentsOf: url)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let note = try XCTUnwrap(page.annotations.first { $0.type == "FreeText" })

        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 640, height: 560))
        var edits = 0
        pdfView.onEdited = { _, _, _ in edits += 1 }
        pdfView.document = document
        pdfView.replaceEditBaselineCapture(with: data, needsSnapshot: true)
        pdfView.layoutDocumentView()

        pdfView.beginFreeTextEditing(note, on: page, isNew: false, baselineData: data)
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        XCTAssertTrue(pdfView.commitActiveFreeTextEdit())
        XCTAssertEqual(edits, 0, "committing an untouched text box is not an edit")

        pdfView.beginFreeTextEditing(note, on: page, isNew: false, baselineData: data)
        pdfView.annotationMode = .pen
        pdfView.annotationMode = .select
        XCTAssertEqual(edits, 0, "switching tools with an untouched text box is not an edit")

        let center = pdfView.convert(CGPoint(x: note.bounds.midX, y: note.bounds.midY), from: page)
        for clickCount in [1, 2] {
            pdfView.mouseDown(with: try XCTUnwrap(freeTextMouseEvent(type: .leftMouseDown, location: center, clickCount: clickCount)))
            pdfView.mouseUp(with: try XCTUnwrap(freeTextMouseEvent(type: .leftMouseUp, location: center, clickCount: clickCount)))
        }
        pdfView.keyDown(with: try XCTUnwrap(freeTextEscapeKeyEvent()))
        _ = pdfView.commitActiveFreeTextEdit()
        XCTAssertEqual(edits, 0, "clicking a text box is not an edit")
    }

    func testClickingWithAMarkupToolWithoutDraggingPublishesNoEdit() throws {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotUnsavedTools")
        let url = root.appendingPathComponent("annotated.pdf")
        try writeAnnotatedPDF(to: url)
        let data = try Data(contentsOf: url)
        for mode in [PDFAnnotationInteractionMode.highlighter, .pen, .eraser] {
            let document = try XCTUnwrap(PDFDocument(data: data))
            let page = try XCTUnwrap(document.page(at: 1))
            let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 640, height: 560))
            var edits = 0
            pdfView.onEdited = { _, _, _ in edits += 1 }
            pdfView.document = document
            pdfView.replaceEditBaselineCapture(with: data, needsSnapshot: true)
            pdfView.go(to: page)
            pdfView.layoutDocumentView()
            pdfView.annotationMode = mode
            let point = pdfView.convert(CGPoint(x: 200, y: 150), from: page)
            pdfView.mouseDown(with: try XCTUnwrap(freeTextMouseEvent(type: .leftMouseDown, location: point)))
            pdfView.mouseUp(with: try XCTUnwrap(freeTextMouseEvent(type: .leftMouseUp, location: point)))
            XCTAssertEqual(edits, 0, "a click with \(mode) is not an edit")
            XCTAssertEqual(page.annotations.count, 0, "a click with \(mode) adds nothing")
        }
    }

    // MARK: - Saving and reloading

    func testSavingClearsTheDotAndItStaysClearWhileTheWatcherSettles() async throws {
        let (store, url) = try await openNote(stopWatcher: false)
        store.setDocumentText("# Note\n\nEdited\n")
        XCTAssertFalse(store.saveState(for: url.path).isClean)
        store.saveSelectedFile()
        let saved = await waitUntil { !store.isSaving && store.saveState(for: url.path).isClean }
        XCTAssertTrue(saved)
        await settle(2.5)
        assertClean(store, "after save and watcher replay")
        XCTAssertEqual(store.documentText, "# Note\n\nEdited\n")
    }

    func testUndoingBackToTheSavedTextClearsTheDot() async throws {
        let (store, url) = try await openNote()
        store.setDocumentText("# Note\n\nBody!\n")
        XCTAssertFalse(store.saveState(for: url.path).isClean)
        store.setDocumentText("# Note\n\nBody\n")
        assertClean(store, "after undo")
    }

    func testMetadataChangesToAnEditedDocumentAreNotExternalChanges() async throws {
        let (store, url) = try await openNote()
        store.setDocumentText("# Note\n\nEdited\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        _ = url.withUnsafeFileSystemRepresentation { path in
            setxattr(path, "com.apple.metadata:_kMDItemUserTags", "x", 1, 0, 0)
        }
        deliverModification(of: url, to: store)
        await settle(0.6)
        XCTAssertFalse(store.selectedDocumentExternalChange)
        store.saveSelectedFile()
        let saved = await waitUntil { !store.isSaving && store.saveState(for: url.path).isClean }
        XCTAssertTrue(saved, "save failed: \(store.errorMessage ?? "")")
    }

    func testRenamingAndMovingTheOpenDocumentKeepsItClean() async throws {
        let (store, url) = try await openNote(stopWatcher: false)
        store.renameDocument(id: url.path, to: "Renamed.md")
        let renamed = await waitUntil { !store.isBusy && store.selectedDocument?.displayName == "Renamed.md" }
        XCTAssertTrue(renamed, store.errorMessage ?? "")
        await settle(2)
        assertClean(store, "after rename")

        let folder = url.deletingLastPathComponent().appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store.refresh()
        await settle(1)
        let renamedID = try XCTUnwrap(store.selectedDocumentID)
        XCTAssertTrue(store.moveItem(id: renamedID, toDirectory: folder))
        let moved = await waitUntil { !store.isBusy && store.selectedDocument?.url.deletingLastPathComponent().lastPathComponent == "Folder" }
        XCTAssertTrue(moved, store.errorMessage ?? "")
        await settle(2)
        assertClean(store, "after move")
    }

    func testRenamingAnEditedDocumentKeepsItSavableWithoutAConflict() async throws {
        let (store, url) = try await openNote(stopWatcher: false)
        store.setDocumentText("# Note\n\nEdited\n")
        store.renameDocument(id: url.path, to: "Renamed.md")
        let renamed = await waitUntil { !store.isBusy && store.selectedDocument?.displayName == "Renamed.md" }
        XCTAssertTrue(renamed, store.errorMessage ?? "")
        await settle(2)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertFalse(store.selectedDocumentExternalChange)
        store.saveSelectedFile()
        let saved = await waitUntil { !store.isSaving && store.documentSaveStates.isEmpty }
        XCTAssertTrue(saved, "save failed: \(store.errorMessage ?? "")")
        await settle(2)
        assertClean(store, "after saving the renamed document")
    }

    func testReloadingFromDiskAfterAReviewLeavesTheDocumentClean() async throws {
        let (store, url) = try await openNote(stopWatcher: false)
        store.setDocumentText("# Note\n\nMine\n")
        try await Task.sleep(nanoseconds: 20_000_000)
        try Data("# Note\n\nTheirs\n".utf8).write(to: url, options: .atomic)
        let reported = await waitUntil(timeout: 8) { store.selectedDocumentExternalChange }
        XCTAssertTrue(reported)

        store.resolveSelectedExternalDocumentWithoutReview(.useDisk)
        let resolved = await waitUntil { !store.selectedDocumentExternalChange && store.documentText == "# Note\n\nTheirs\n" }
        XCTAssertTrue(resolved)
        await settle(2)
        assertClean(store, "after using the disk version")
    }

    // MARK: - Fixtures

    private static let textFixtures: [(name: String, contents: String)] = [
        ("crlf.md", "# CRLF\r\n\r\nLine one\r\nLine two\r\n"),
        ("lone-cr.txt", "first\rsecond\rthird\r"),
        ("mixed-endings.md", "unix\nwindows\r\nmac\rend"),
        ("bom.md", "\u{FEFF}# Byte order mark\n\nBody\n"),
        ("no-trailing-newline.md", "# Title\n\nNo newline at the end"),
        ("trailing-space.md", "Trailing spaces   \nTabs\t\t\n\tIndented\n  \n"),
        ("nbsp.md", "Non\u{00A0}breaking\u{00A0}space and narrow\u{202F}one\n"),
        ("nfd.md", "Cafe\u{0301} na\u{0308}ive re\u{0301}sume\u{0301}\n"),
        ("emoji.md", "Family 👩‍👩‍👧‍👦 flags 🇹🇷🏳️‍🌈 skin 👍🏽 keycap 1️⃣\n"),
        ("separators.txt", "line\u{2028}separator\u{2029}paragraph\u{0085}next\u{000B}tab\u{000C}feed\n"),
        ("long-line.md", String(repeating: "word ", count: 6_000) + "\n"),
        ("rich.md", """
        ---
        title: "Front matter"
        tags: [a, b]
        ---

        # Heading

        | Column | Other |
        |--------|------:|
        | 1      | 2     |

        - [ ] open task
        - [x] done task

        ```mermaid
        graph TD; A-->B
        ```

        "Double quotes" and 'single quotes' -- dash --- em... (c) (tm) 1/2 teh adn
        Its a test. i think so. recieve seperate
        * bullet
        1. numbered

        """),
        ("page.html", "<!doctype html>\r\n<h1>\"Quotes\" -- dash</h1>\n"),
        ("data.json", "{\"key\": \"value -- 'x'\"}"),
        ("empty.md", ""),
        ("only-newlines.md", "\n\n\n"),
    ]

    private func makeTextWorkspace() throws -> URL {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotUnsavedChanges")
        for fixture in Self.textFixtures {
            try Data(fixture.contents.utf8).write(to: root.appendingPathComponent(fixture.name))
        }
        return root
    }

    // MARK: - Helpers

    private func openNote(
        _ contents: String = "# Note\n\nBody\n",
        named name: String = "Note.md",
        stopWatcher: Bool = true
    ) async throws -> (WorkspaceStore, URL) {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotUnsavedChanges")
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        let store = try await openStore(root, stopWatcher: stopWatcher)
        let document = try XCTUnwrap(store.documents.first { $0.displayName == name })
        XCTAssertTrue(store.selectDocument(id: document.id))
        let loaded = await waitUntil { !store.isDocumentLoading && store.documentText == contents }
        XCTAssertTrue(loaded, "\(name) did not load")
        return (store, url.standardizedFileURL)
    }

    private func deliverModification(of url: URL, to store: WorkspaceStore) {
        store.testing_clearWatcherSuppression()
        store.testing_scheduleExternalWorkspaceRefresh(.init(
            changedPaths: [url.path],
            modifiedOnlyPaths: [url.path],
            requiresFullRescan: false
        ))
    }

    private func touch(_ url: URL, by seconds: TimeInterval = 5) throws {
        let date = (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        try FileManager.default.setAttributes(
            [.modificationDate: date.addingTimeInterval(seconds)],
            ofItemAtPath: url.path
        )
    }

    private func type(_ text: String, at location: Int, in textView: NSTextView) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    private func undo(in textView: NSTextView) {
        if textView.undoManager?.canUndo == true {
            textView.undoManager?.undo()
        }
    }

    private func writeAnnotatedPDF(to url: URL) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for pageIndex in 0..<3 {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "Page \(pageIndex + 1) searchable sample text",
                attributes: [.font: NSFont.systemFont(ofSize: 18)]
            ))
            context.textPosition = CGPoint(x: 30, y: 240)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        let page = try XCTUnwrap(document.page(at: 0))
        let link = PDFAnnotation(bounds: CGRect(x: 30, y: 200, width: 120, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        page.addAnnotation(link)
        let field = PDFAnnotation(bounds: CGRect(x: 30, y: 150, width: 160, height: 24), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "name"
        field.widgetStringValue = "Filled"
        page.addAnnotation(field)
        let checkbox = PDFAnnotation(bounds: CGRect(x: 220, y: 150, width: 20, height: 20), forType: .widget, withProperties: nil)
        checkbox.widgetFieldType = .button
        checkbox.widgetControlType = .checkBoxControl
        checkbox.fieldName = "agree"
        checkbox.buttonWidgetState = .onState
        page.addAnnotation(checkbox)
        let note = PDFAnnotation(bounds: CGRect(x: 30, y: 80, width: 180, height: 40), forType: .freeText, withProperties: nil)
        note.contents = "Existing note"
        note.font = NSFont.systemFont(ofSize: 12)
        page.addAnnotation(note)
        let highlight = PDFAnnotation(bounds: CGRect(x: 30, y: 235, width: 200, height: 24), forType: .highlight, withProperties: nil)
        highlight.color = .yellow
        page.addAnnotation(highlight)
        let ink = PDFAnnotation(bounds: CGRect(x: 250, y: 40, width: 100, height: 60), forType: .ink, withProperties: nil)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 10, y: 10))
        path.line(to: CGPoint(x: 80, y: 50))
        ink.add(path)
        page.addAnnotation(ink)
        let text = PDFAnnotation(bounds: CGRect(x: 360, y: 260, width: 20, height: 20), forType: .text, withProperties: nil)
        text.contents = "Sticky"
        page.addAnnotation(text)
        try XCTUnwrap(document.dataRepresentation()).write(to: url)
    }

    private func assertClean(
        _ store: WorkspaceStore,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(store.hasUnsavedChanges, "\(context): hasUnsavedChanges", file: file, line: line)
        XCTAssertTrue(store.documentSaveStates.isEmpty, "\(context): \(store.documentSaveStates)", file: file, line: line)
        XCTAssertTrue(store.dirtyTextByDocumentID.isEmpty, "\(context): dirty \(store.dirtyTextByDocumentID.keys.map { URL(fileURLWithPath: $0).lastPathComponent })", file: file, line: line)
        XCTAssertTrue(store.dirtyPDFDataByDocumentID.isEmpty, "\(context): dirty PDF", file: file, line: line)
        XCTAssertFalse(store.selectedDocumentExternalChange, "\(context): external change", file: file, line: line)
        XCTAssertNil(store.errorMessage, "\(context): \(store.errorMessage ?? "")", file: file, line: line)
    }

    private func openStore(_ root: URL, stopWatcher: Bool = true) async throws -> WorkspaceStore {
        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let loaded = await waitUntil { !store.isBusy && store.workspaceURL != nil && store.rootNode != nil }
        XCTAssertTrue(loaded, "Workspace did not load")
        if stopWatcher {
            store.testing_stopFileWatcher()
        }
        return store
    }

    private func hostEditorPane(store: WorkspaceStore, controls: PaneControls) -> NSView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: UnsavedChangesPaneHarness(store: store, controls: controls))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = host
        window.orderFront(nil)
        hostWindows.append(window)
        return host
    }

    private func documentTextView(in view: NSView) -> NSTextView? {
        allDescendants(of: NSTextView.self, in: view).first {
            $0.identifier == .monknotDocumentFocusTarget
        }
    }

    private func pdfView(in view: NSView) -> PDFView? {
        allDescendants(of: PDFView.self, in: view).first
    }

    private func allDescendants<ViewType: NSView>(of type: ViewType.Type, in view: NSView) -> [ViewType] {
        var matches: [ViewType] = []
        if let match = view as? ViewType {
            matches.append(match)
        }
        for subview in view.subviews {
            matches += allDescendants(of: type, in: subview)
        }
        return matches
    }

    private func settle(_ seconds: TimeInterval = 0.15) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

@MainActor
private final class PaneControls: ObservableObject {
    @Published var editorMode = EditorMode.source
    @Published var isSplitViewEnabled = false
    @Published var zoomScale = 1.0
    @Published var sourceLocation: MarkdownSourceLocation?
    @Published var previewLocation: MarkdownSourceLocation?
    @Published var pdfSearchTarget: WorkspaceSearchPDFTarget?
    @Published var documentSearch = DocumentSearchState()
    @Published var viewportState: DocumentViewportState?
    @Published var pdfNavigatorToggleSerial = 0

    func reset() {
        editorMode = .source
        isSplitViewEnabled = false
        zoomScale = 1
        sourceLocation = nil
        documentSearch = DocumentSearchState()
    }
}

/// The editor pane as `ContentView` mounts it, with the view controls the window owns.
private struct UnsavedChangesPaneHarness: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var controls: PaneControls
    @StateObject private var pdfViewportCaptureBridge = PDFViewportCaptureBridge()

    var body: some View {
        EditorPaneView(
            store: store,
            editorMode: $controls.editorMode,
            isSplitViewEnabled: $controls.isSplitViewEnabled,
            theme: .defaultLight,
            zoomScale: controls.zoomScale,
            codeFontSize: 13,
            contentWidthPercent: 100,
            showsDocumentOutline: true,
            usePointerCursors: false,
            fontSmoothing: true,
            activeViewportState: controls.viewportState,
            pdfViewportCaptureBridge: pdfViewportCaptureBridge,
            updateViewportState: { _, _ in },
            pdfUndoCommandSerial: 0,
            pdfRedoCommandSerial: 0,
            updatePDFAnnotationUndoState: { _, _ in },
            sourceLocation: $controls.sourceLocation,
            previewLocation: $controls.previewLocation,
            pdfSearchTarget: $controls.pdfSearchTarget,
            pdfPageNavigationRequest: nil,
            pdfNavigatorToggleCommandSerial: controls.pdfNavigatorToggleSerial,
            documentSearch: $controls.documentSearch,
            searchOptions: MonknotSearchOptions(),
            newMarkdown: {},
            bootstrapStarterWorkspace: {},
            openFolder: {},
            saveDocument: { store.saveSelectedFile() },
            outlineItems: [],
            textStatistics: nil,
            selectOutlineItem: { _ in },
            onPreviewSourceJump: { _ in },
            copyPDFLinkedExcerpt: { _ in },
            updatePDFSelectionSnapshot: { _ in },
            consumePDFPageNavigationRequest: { _ in },
            onMarkdownSelectionChange: { _ in },
            onMarkdownLinkRequest: { _ in },
            onInspectLinks: nil,
            onMarkdownImagePasteRequest: { _ in },
            onMarkdownFileDropRequest: { _ in },
            onMarkdownPreviewLinkRequest: { _ in },
            onMarkdownTaskRequest: { _ in }
        )
        .frame(minWidth: 300, minHeight: 200)
    }
}

@MainActor
private final class ToolbarEditorControls: ObservableObject {
    @Published var showsEditor = true
    @Published var commandRequest: MarkdownTextEditorCommandRequest?
    @Published var sourceLocation: MarkdownSourceLocation?
    @Published var documentSearch = DocumentSearchState()
}

private struct ToolbarEditorHarness: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var controls: ToolbarEditorControls

    var body: some View {
        if controls.showsEditor, let documentID = store.selectedDocumentID {
            MarkdownTextEditor(
                documentID: documentID,
                text: Binding(get: { store.documentText }, set: { store.setDocumentText($0) }),
                theme: .defaultLight,
                fontSize: 13,
                zoomScale: 1,
                contentWidthPercent: 100,
                fontSmoothing: true,
                scrollPosition: nil,
                sourceLocation: $controls.sourceLocation,
                searchState: $controls.documentSearch,
                onScrollPositionChange: { _ in },
                commandRequest: controls.commandRequest,
                markdownShortcutsEnabled: true
            )
        } else {
            Color.clear
        }
    }
}
