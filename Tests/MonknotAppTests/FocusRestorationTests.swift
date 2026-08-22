import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

@MainActor
final class FocusRestorationTests: XCTestCase {
    func testTerminalFocusRestorerReturnsKeyboardFocusToTheDocument() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let terminalResponder = NSTextView(frame: NSRect(x: 320, y: 0, width: 320, height: 480))
        window.contentView?.addSubview(documentEditor)
        window.contentView?.addSubview(terminalResponder)
        XCTAssertTrue(window.makeFirstResponder(documentEditor))

        let restorer = TerminalFocusRestorer()
        restorer.capture(from: window)
        XCTAssertTrue(window.makeFirstResponder(terminalResponder))

        restorer.restore()
        await Task.yield()

        XCTAssertTrue(window.firstResponder === documentEditor)
    }

    func testSearchFocusRestorerReturnsKeyboardFocusToTheTerminal() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let terminal = TerminalWKWebView(
            frame: NSRect(x: 320, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let searchField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        window.contentView?.addSubview(terminal)
        window.contentView?.addSubview(searchField)
        XCTAssertTrue(window.makeFirstResponder(terminal))

        let restorer = TerminalFocusRestorer()
        restorer.capturePrimaryInput(from: window)
        XCTAssertTrue(window.makeFirstResponder(searchField))

        restorer.restore(fallbackFrom: window)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === terminal)
    }

    func testSearchFocusRestorerTracksANewEditorOwner() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let originalEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 480))
        originalEditor.identifier = .monknotDocumentFocusTarget
        let newEditor = NSTextView(frame: NSRect(x: 240, y: 0, width: 240, height: 480))
        newEditor.identifier = .monknotDocumentFocusTarget
        let searchField = NSTextField(frame: NSRect(x: 480, y: 0, width: 160, height: 28))
        window.contentView?.addSubview(originalEditor)
        window.contentView?.addSubview(newEditor)
        window.contentView?.addSubview(searchField)
        XCTAssertTrue(window.makeFirstResponder(originalEditor))

        let restorer = TerminalFocusRestorer()
        restorer.capturePrimaryInput(from: window)
        XCTAssertTrue(window.makeFirstResponder(searchField))
        XCTAssertTrue(window.makeFirstResponder(newEditor))
        restorer.capturePrimaryInput(from: window)
        XCTAssertTrue(window.makeFirstResponder(searchField))

        restorer.restore(fallbackFrom: window)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === newEditor)
    }

    func testSearchFocusRestorerFallsBackWhenSavedTerminalBecomesHidden() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 480))
        documentEditor.identifier = .monknotDocumentFocusTarget
        let terminalContainer = NSView(frame: NSRect(x: 240, y: 0, width: 240, height: 480))
        let terminal = TerminalWKWebView(
            frame: terminalContainer.bounds,
            configuration: WKWebViewConfiguration()
        )
        let searchField = NSTextField(frame: NSRect(x: 480, y: 0, width: 160, height: 28))
        terminalContainer.addSubview(terminal)
        window.contentView?.addSubview(documentEditor)
        window.contentView?.addSubview(terminalContainer)
        window.contentView?.addSubview(searchField)
        XCTAssertTrue(window.makeFirstResponder(terminal))

        let restorer = TerminalFocusRestorer()
        restorer.capturePrimaryInput(from: window)
        XCTAssertTrue(window.makeFirstResponder(searchField))
        terminalContainer.isHidden = true

        restorer.restore(fallbackFrom: window)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === documentEditor)
    }

    func testSearchFocusRestorerKeepsAQueuedRestoreAcrossSearchChromeUpdates() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 480))
        documentEditor.identifier = .monknotDocumentFocusTarget
        let searchField = NSTextField(frame: NSRect(x: 400, y: 0, width: 240, height: 28))
        window.contentView?.addSubview(documentEditor)
        window.contentView?.addSubview(searchField)
        XCTAssertTrue(window.makeFirstResponder(documentEditor))

        let restorer = TerminalFocusRestorer()
        restorer.capturePrimaryInput(from: window)
        XCTAssertTrue(window.makeFirstResponder(searchField))
        restorer.restore(fallbackFrom: window)
        restorer.capturePrimaryInput(from: window)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === documentEditor)
    }

    func testResponderRegionClassificationTracksFieldEditorsAndTerminalChrome() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let sidebarRegion = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 480))
        sidebarRegion.identifier = .monknotSidebarFocusRegion
        let searchField = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 28))
        sidebarRegion.addSubview(searchField)

        let terminalRegion = NSView(frame: NSRect(x: 240, y: 0, width: 400, height: 480))
        terminalRegion.identifier = .monknotTerminalFocusRegion
        let terminalChromeControl = NSTextView(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        terminalRegion.addSubview(terminalChromeControl)

        window.contentView?.addSubview(sidebarRegion)
        window.contentView?.addSubview(terminalRegion)
        XCTAssertTrue(window.makeFirstResponder(searchField))
        searchField.selectText(nil)
        XCTAssertTrue(
            TerminalFocusRestorer.firstResponder(
                in: window,
                isInside: .monknotSidebarFocusRegion
            )
        )
        XCTAssertFalse(
            TerminalFocusRestorer.firstResponder(
                in: window,
                isInside: .monknotTerminalFocusRegion
            )
        )

        XCTAssertTrue(window.makeFirstResponder(terminalChromeControl))
        XCTAssertTrue(
            TerminalFocusRestorer.firstResponder(
                in: window,
                isInside: .monknotTerminalFocusRegion
            )
        )
    }

    func testTerminalFocusRestorerSurvivesRapidCloseAndReopen() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let terminalResponder = NSTextView(frame: NSRect(x: 320, y: 0, width: 320, height: 480))
        window.contentView?.addSubview(documentEditor)
        window.contentView?.addSubview(terminalResponder)
        XCTAssertTrue(window.makeFirstResponder(documentEditor))

        let restorer = TerminalFocusRestorer()
        restorer.capture(from: window)
        XCTAssertTrue(window.makeFirstResponder(terminalResponder))
        restorer.restore()

        restorer.capture(from: window)
        XCTAssertTrue(window.firstResponder === terminalResponder)
        restorer.restore()
        await Task.yield()

        XCTAssertTrue(window.firstResponder === documentEditor)
    }

    func testTerminalFocusRestorerDiscardCancelsAnInfeasibleRevealCapture() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let currentResponder = NSTextView(frame: NSRect(x: 320, y: 0, width: 320, height: 480))
        window.contentView?.addSubview(documentEditor)
        window.contentView?.addSubview(currentResponder)
        XCTAssertTrue(window.makeFirstResponder(documentEditor))

        let restorer = TerminalFocusRestorer()
        restorer.capture(from: window)
        XCTAssertTrue(window.makeFirstResponder(currentResponder))

        restorer.discard()
        restorer.restore()
        await Task.yield()

        XCTAssertTrue(window.firstResponder === currentResponder)
    }

    func testTerminalFocusRestorerUsesSourceFirstRegisteredTargetAfterMenuFocusLoss() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let documentEditor = NSTextView(frame: documentScrollView.bounds)
        documentEditor.identifier = .monknotDocumentFocusTarget
        documentScrollView.documentView = documentEditor
        let documentPreview = NSTextView(frame: NSRect(x: 160, y: 0, width: 160, height: 480))
        documentPreview.identifier = .monknotDocumentFocusTarget
        let terminalResponder = NSTextView(frame: NSRect(x: 320, y: 0, width: 320, height: 480))
        window.contentView?.addSubview(documentScrollView)
        window.contentView?.addSubview(documentPreview)
        window.contentView?.addSubview(terminalResponder)
        XCTAssertTrue(window.makeFirstResponder(documentEditor))
        XCTAssertTrue(window.makeFirstResponder(nil))

        let restorer = TerminalFocusRestorer()
        restorer.capture(from: window)
        XCTAssertTrue(window.makeFirstResponder(terminalResponder))
        restorer.restore(fallbackFrom: window)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === documentEditor)
    }

    func testTerminalFocusRestorerFallsBackWhenTheCapturedDocumentViewWasReplaced() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let originalEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        originalEditor.identifier = .monknotDocumentFocusTarget
        let replacementEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        replacementEditor.identifier = .monknotDocumentFocusTarget
        let terminalResponder = NSTextView(frame: NSRect(x: 320, y: 0, width: 320, height: 480))
        window.contentView?.addSubview(originalEditor)
        window.contentView?.addSubview(terminalResponder)
        XCTAssertTrue(window.makeFirstResponder(originalEditor))

        let restorer = TerminalFocusRestorer()
        restorer.capture(from: window)
        originalEditor.removeFromSuperview()
        window.contentView?.addSubview(replacementEditor)
        XCTAssertTrue(window.makeFirstResponder(terminalResponder))

        restorer.restore(fallbackFrom: window)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === replacementEditor)
    }

    func testHiddenTerminalLoadDoesNotStealDocumentFocus() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let hiddenTerminalContainer = NSView(
            frame: NSRect(x: 320, y: 0, width: 320, height: 480)
        )
        let terminalWebView = WKWebView(frame: hiddenTerminalContainer.bounds)
        hiddenTerminalContainer.addSubview(terminalWebView)
        hiddenTerminalContainer.isHidden = true
        window.contentView?.addSubview(documentEditor)
        window.contentView?.addSubview(hiddenTerminalContainer)
        XCTAssertTrue(window.makeFirstResponder(documentEditor))

        let coordinator = TerminalWebView.Coordinator(session: TerminalSessionStore())
        coordinator.webView = terminalWebView
        coordinator.requestFocusOnLoad(from: documentEditor)
        coordinator.webView(terminalWebView, didFinish: nil)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === documentEditor)
    }

    func testVisibleTerminalLoadFocusesTheTerminal() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let documentEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let terminalWebView = WKWebView(
            frame: NSRect(x: 320, y: 0, width: 320, height: 480)
        )
        window.contentView?.addSubview(documentEditor)
        window.contentView?.addSubview(terminalWebView)
        XCTAssertTrue(window.makeFirstResponder(documentEditor))

        let coordinator = TerminalWebView.Coordinator(session: TerminalSessionStore())
        coordinator.webView = terminalWebView
        coordinator.requestFocusOnLoad(from: documentEditor)
        coordinator.webView(terminalWebView, didFinish: nil)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === terminalWebView)
    }

    func testVisibleTerminalLoadDoesNotStealNewSearchFocus() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let workspaceSearchField = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 160, height: 28)
        )
        let documentSearchField = NSTextField(
            frame: NSRect(x: 160, y: 0, width: 160, height: 28)
        )
        let terminalWebView = WKWebView(
            frame: NSRect(x: 320, y: 0, width: 320, height: 480)
        )
        window.contentView?.addSubview(workspaceSearchField)
        window.contentView?.addSubview(documentSearchField)
        window.contentView?.addSubview(terminalWebView)
        XCTAssertTrue(window.makeFirstResponder(workspaceSearchField))

        let coordinator = TerminalWebView.Coordinator(session: TerminalSessionStore())
        coordinator.webView = terminalWebView
        coordinator.requestFocusOnLoad(from: window.firstResponder)
        XCTAssertTrue(window.makeFirstResponder(documentSearchField))
        coordinator.webView(terminalWebView, didFinish: nil)
        await Task.yield()

        XCTAssertTrue(documentSearchField.currentEditor() === window.firstResponder)
    }

    func testIconButtonFocusRingRemainsVisibleWithoutUsingTheHoverFill() {
        XCTAssertTrue(MonknotIconButton.showsFocusRing(isFocused: true, isDisabled: false))
        XCTAssertFalse(MonknotIconButton.showsFocusRing(isFocused: false, isDisabled: false))
        XCTAssertFalse(MonknotIconButton.showsFocusRing(isFocused: true, isDisabled: true))
    }

    func testStandardZoomKeysCanRouteToFocusedPDFKit() {
        XCTAssertEqual(
            MonknotNativePDFZoomCommand.action(for: keyEvent("=", modifiers: [.command])),
            .zoomIn
        )
        XCTAssertEqual(
            MonknotNativePDFZoomCommand.action(for: keyEvent("+", modifiers: [.command, .shift])),
            .zoomIn
        )
        XCTAssertEqual(
            MonknotNativePDFZoomCommand.action(for: keyEvent("-", modifiers: [.command])),
            .zoomOut
        )
        XCTAssertEqual(
            MonknotNativePDFZoomCommand.action(for: keyEvent("0", modifiers: [.command])),
            .actualSize
        )
        XCTAssertNil(MonknotNativePDFZoomCommand.action(for: keyEvent("=", modifiers: [])))
        XCTAssertNil(MonknotNativePDFZoomCommand.action(for: keyEvent("=", modifiers: [.command, .option])))
    }
}
