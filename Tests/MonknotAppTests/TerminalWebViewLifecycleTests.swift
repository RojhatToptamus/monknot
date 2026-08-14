import XCTest
import WebKit
@testable import MonknotApp

final class TerminalWebViewLifecycleTests: XCTestCase {
    func testTerminalHTMLKeepsInputBridgeBoundedSearchAndExplicitTeardownWithoutAppInitiatedInsertion() {
        let html = TerminalWebView.html(
            theme: .defaultDark,
            fontSize: 13.5,
            usePointerCursors: true,
            fontSmoothing: true
        )

        XCTAssertTrue(html.contains("term.onData"))
        XCTAssertTrue(html.contains("scrollback: 5000"))
        XCTAssertTrue(html.contains("allowProposedApi: true"))
        XCTAssertTrue(html.contains("const searchHighlightLimit = 1000"))
        XCTAssertTrue(html.contains("new SearchAddon.SearchAddon({ highlightLimit: searchHighlightLimit })"))
        XCTAssertTrue(html.contains("term.loadAddon(searchAddon)"))
        XCTAssertTrue(html.contains("searchAddon.findNext(query"))
        XCTAssertTrue(html.contains("searchAddon.findPrevious(query"))
        XCTAssertTrue(html.contains("id=\"terminal-search-input\""))
        XCTAssertTrue(html.contains("aria-label=\"Search terminal scrollback\""))
        XCTAssertTrue(html.contains("window.monknotTerminalSearchOpen"))
        XCTAssertTrue(html.contains("window.monknotTerminalSearchNext"))
        XCTAssertTrue(html.contains("window.monknotTerminalSearchPrevious"))
        XCTAssertTrue(html.contains("window.monknotDispose = function()"))
        XCTAssertTrue(html.contains("resizeObserver.disconnect()"))
        XCTAssertTrue(html.contains("window.removeEventListener('resize', resizeListener)"))
        XCTAssertTrue(html.contains("searchInput.removeEventListener('input', searchInputListener)"))
        XCTAssertTrue(html.contains("searchKeyListener"))
        XCTAssertTrue(html.contains("searchResultsDisposable.dispose()"))
        XCTAssertTrue(html.contains("searchAddon.dispose()"))
        XCTAssertTrue(html.contains("inputDisposable.dispose()"))
        XCTAssertTrue(html.contains("fitAddon.dispose"))
        XCTAssertTrue(html.contains("term.dispose()"))
        XCTAssertFalse(html.contains("if (!searchContainer.hidden) notifySearchVisibility(false)"))
        XCTAssertFalse(html.contains("window.monknotPaste"))
        XCTAssertFalse(html.contains("term.registerLinkProvider"))
        XCTAssertFalse(html.contains("pathLinkDisposable"))
        XCTAssertFalse(html.contains("terminalPath"))
    }

    func testTerminalSearchShortcutOnlyClaimsFindNavigationAndPresentedEscape() throws {
        XCTAssertEqual(
            MonknotTerminalSearchShortcut.action(for: try keyEvent("f", modifiers: [.command]), isSearchPresented: false),
            .show
        )
        XCTAssertEqual(
            MonknotTerminalSearchShortcut.action(for: try keyEvent("g", modifiers: [.command]), isSearchPresented: false),
            .next
        )
        XCTAssertEqual(
            MonknotTerminalSearchShortcut.action(for: try keyEvent("g", modifiers: [.command, .shift]), isSearchPresented: false),
            .previous
        )
        XCTAssertEqual(
            MonknotTerminalSearchShortcut.action(
                for: try keyEvent("\u{1b}", modifiers: [], keyCode: 53),
                isSearchPresented: true
            ),
            .close
        )
        XCTAssertNil(
            MonknotTerminalSearchShortcut.action(
                for: try keyEvent("\u{1b}", modifiers: [], keyCode: 53),
                isSearchPresented: false
            ),
            "Escape must reach terminal applications when terminal search is closed"
        )
        XCTAssertNil(
            MonknotTerminalSearchShortcut.action(for: try keyEvent("f", modifiers: [.control]), isSearchPresented: false),
            "Control-F must remain terminal input"
        )
        XCTAssertNil(
            MonknotTerminalSearchShortcut.action(for: try keyEvent("?", modifiers: [.shift]), isSearchPresented: false)
        )
    }

    @MainActor
    func testTerminalSearchFindsUnicodeAndRebuildsResultsWhenReopened() throws {
        let configuration = WKWebViewConfiguration()
        let messageHandler = IgnoringTerminalScriptMessageHandler()
        let messageHandlerNames = [
            TerminalWebView.Coordinator.inputHandlerName,
            TerminalWebView.Coordinator.resizeHandlerName,
            TerminalWebView.Coordinator.searchVisibilityHandlerName,
        ]
        for name in messageHandlerNames {
            configuration.userContentController.add(messageHandler, name: name)
        }

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400),
            configuration: configuration
        )
        defer {
            _ = evaluateJavaScript("window.monknotDispose && window.monknotDispose()", in: webView)
            for name in messageHandlerNames {
                configuration.userContentController.removeScriptMessageHandler(forName: name)
            }
        }

        webView.loadHTMLString(try terminalHTMLWithSourceResources(), baseURL: nil)
        XCTAssertTrue(waitForJavaScript("typeof window.monknotWrite === 'function'", in: webView))

        _ = evaluateJavaScript("window.monknotWrite('UNICODE café 日本語\\r\\n')", in: webView)
        XCTAssertTrue(waitForJavaScript("term.buffer.active.cursorY > 0", in: webView))

        let initialResult = try XCTUnwrap(evaluateJavaScript(
            """
            (() => {
              searchInput.value = '日本語';
              const found = findInTerminal('next', true);
              return {
                found,
                status: searchStatus.textContent,
                selection: term.getSelection()
              };
            })()
            """,
            in: webView,
            reportError: true
        ) as? [String: Any])
        XCTAssertEqual(initialResult["found"] as? Bool, true)
        XCTAssertEqual(initialResult["status"] as? String, "1 of 1")
        XCTAssertEqual(initialResult["selection"] as? String, "日本語")

        let reopenedStatus = evaluateJavaScript(
            "closeTerminalSearch(); openTerminalSearch(); searchStatus.textContent",
            in: webView
        ) as? String
        XCTAssertEqual(reopenedStatus, "1 of 1")

        _ = evaluateJavaScript(
            "window.monknotCapWriteComplete = false; term.write('\\r\\n' + 'CAP '.repeat(1001), () => { window.monknotCapWriteComplete = true; })",
            in: webView
        )
        XCTAssertTrue(waitForJavaScript("window.monknotCapWriteComplete === true", in: webView))
        let cappedStatus = evaluateJavaScript(
            "searchInput.value = 'CAP'; findInTerminal('next', true); searchStatus.textContent",
            in: webView
        ) as? String
        XCTAssertEqual(cappedStatus, "1 of 1000+")
    }

    private func keyEvent(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16 = 0
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    @MainActor
    private func waitForJavaScript(
        _ script: String,
        in webView: WKWebView,
        attempts: Int = 100
    ) -> Bool {
        for _ in 0..<attempts {
            if evaluateJavaScript(script, in: webView) as? Bool == true {
                return true
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return false
    }

    private func terminalHTMLWithSourceResources() throws -> String {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourcesURL = repositoryURL.appendingPathComponent("Sources/Monknot/Resources", isDirectory: true)
        let scripts = try ["xterm.js", "xterm-addon-fit.js", "xterm-addon-search.js"]
            .map { try String(contentsOf: resourcesURL.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        var html = TerminalWebView.html(
            theme: .defaultDark,
            fontSize: 13.5,
            usePointerCursors: true,
            fontSmoothing: true
        )
        let scriptStart = try XCTUnwrap(html.range(of: "<script>\n"))
        html.replaceSubrange(
            scriptStart,
            with: "<script>\n\(scripts)\n"
        )
        return html
    }

    @MainActor
    private func evaluateJavaScript(
        _ script: String,
        in webView: WKWebView,
        timeout: TimeInterval = 0.5,
        reportError: Bool = false
    ) -> Any? {
        var result: Any?
        var evaluationError: Error?
        var isComplete = false
        webView.evaluateJavaScript(script) { value, error in
            result = value
            evaluationError = error
            isComplete = true
        }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while !isComplete, Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
        if reportError, let evaluationError {
            XCTFail("JavaScript evaluation failed: \(evaluationError)")
        }
        return isComplete ? result : nil
    }
}

private final class IgnoringTerminalScriptMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {}
}
