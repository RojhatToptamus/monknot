import MonknotCore
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
        XCTAssertTrue(html.contains("scrollback: 10000"))
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
            TerminalWebController.inputHandlerName,
            TerminalWebController.resizeHandlerName,
            TerminalWebController.searchVisibilityHandlerName,
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
        XCTAssertTrue(waitForJavaScript("typeof window.monknotWriteBytes === 'function'", in: webView))

        _ = evaluateJavaScript(
            "window.monknotWriteBytes(btoa(String.fromCharCode(...new TextEncoder().encode('UNICODE café 日本語\\r\\n'))))",
            in: webView
        )
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

    func testOutputLogKeepsRawBytesAndReportsWhatItDropped() {
        var log = TerminalOutputLog(capacity: 8)
        log.append(Data([0x61, 0xC3]))          // "a" and the first byte of "é"
        log.append(Data([0xA9, 0x62]))          // the rest of "é", then "b"
        XCTAssertEqual(log.bytes(from: 0), Data([0x61, 0xC3, 0xA9, 0x62]))
        XCTAssertEqual(String(decoding: log.bytes(from: 0) ?? Data(), as: UTF8.self), "aéb")
        XCTAssertEqual(log.bytes(from: 3), Data([0x62]))
        XCTAssertEqual(log.bytes(from: 4), Data())

        log.append(Data(repeating: 0x63, count: 6))
        XCTAssertEqual(log.startOffset, 2, "The oldest whole chunk is dropped to stay within capacity")
        XCTAssertEqual(log.endOffset, 10)
        XCTAssertNil(log.bytes(from: 1), "Bytes already dropped cannot be replayed")
        XCTAssertEqual(log.bytes(from: 4), Data(repeating: 0x63, count: 6))
    }

    @MainActor
    func testTerminalViewBelongsToTheSessionAndOutlivesItsHost() {
        let session = TerminalSessionStore()
        let controller = TerminalWebController.controller(for: session)
        XCTAssertTrue(TerminalWebController.controller(for: session) === controller)

        let appearance = TerminalAppearance(
            theme: .defaultDark,
            fontSize: 13,
            usePointerCursors: true,
            fontSmoothing: true
        )
        let webView = controller.webView(appearance: appearance)
        let firstHost = TerminalWebHostView()
        firstHost.show(webView)
        XCTAssertTrue(webView.superview === firstHost)

        // Hiding the drawer dismantles its host; the view and its screen survive.
        let secondHost = TerminalWebHostView()
        secondHost.show(controller.webView(appearance: appearance))
        firstHost.show(nil)
        XCTAssertTrue(webView.superview === secondHost, "A late dismantle must not take the view from its new host")
        XCTAssertTrue(controller.webView(appearance: appearance) === webView)

        session.stop()
        XCTAssertNil(webView.superview)
        XCTAssertNil(controller.webView)
        XCTAssertNil(session.presentation)
    }

    @MainActor
    func testTerminalJoinsSplitUTF8AndDoesNotReanswerQueriesItReplaysQuietly() throws {
        let (webView, recorder, teardown) = try loadedTerminal()
        defer { teardown() }

        _ = evaluateJavaScript("window.monknotWriteBytes(btoa(String.fromCharCode(0xC3)))", in: webView)
        _ = evaluateJavaScript("window.monknotWriteBytes(btoa(String.fromCharCode(0xA9) + 'x'))", in: webView)
        XCTAssertTrue(waitForJavaScript(
            "term.buffer.active.getLine(0).translateToString(true) === 'éx'",
            in: webView
        ), "A character split across two reads is joined, not replaced by U+FFFD")

        // Primary device attributes: answered when first shown, not when replayed.
        _ = evaluateJavaScript("window.monknotWriteBytes(btoa('\\x1b[c'), { quiet: true })", in: webView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertTrue(recorder.inputs.isEmpty, "\(recorder.inputs)")

        _ = evaluateJavaScript("window.monknotWriteBytes(btoa('\\x1b[c'))", in: webView)
        XCTAssertTrue(waitFor { recorder.inputs.contains { $0.hasPrefix("\u{1b}[?") } }, "\(recorder.inputs)")

        recorder.inputs.removeAll()
        _ = evaluateJavaScript("window.monknotWriteBytes(btoa('\\x1b[>q'))", in: webView)
        XCTAssertTrue(waitFor { recorder.inputs.contains("\u{1b}P>|xterm.js(5.5.0)\u{1b}\\") }, "\(recorder.inputs)")
    }

    @MainActor
    func testWheelSendsOneReportPerLineScrolledWhileAProgramReportsTheMouse() throws {
        let (webView, recorder, teardown) = try loadedTerminal()
        defer { teardown() }

        func wheel(lines: Double) {
            _ = evaluateJavaScript(
                """
                (() => {
                  const screen = document.querySelector('.xterm-screen');
                  const rect = screen.getBoundingClientRect();
                  const cellHeight = rect.height / term.rows;
                  document.querySelector('.xterm').dispatchEvent(new WheelEvent('wheel', {
                    deltaY: cellHeight * \(lines), deltaMode: 0,
                    clientX: rect.left + 5, clientY: rect.top + 5,
                    bubbles: true, cancelable: true
                  }));
                })()
                """,
                in: webView
            )
        }

        // No mouse reporting: xterm.js scrolls its own scrollback and nothing is sent.
        wheel(lines: 3)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertTrue(recorder.inputs.isEmpty, "\(recorder.inputs)")

        _ = evaluateJavaScript("window.monknotWriteBytes(btoa('\\x1b[?1000h\\x1b[?1006h'))", in: webView)
        XCTAssertTrue(waitForJavaScript("term.modes.mouseTrackingMode !== 'none'", in: webView))
        wheel(lines: 3)
        XCTAssertTrue(waitFor { !recorder.inputs.isEmpty })
        XCTAssertEqual(recorder.inputs.joined(), String(repeating: "\u{1b}[<65;1;1M", count: 3))

        recorder.inputs.removeAll()
        wheel(lines: -2)
        XCTAssertTrue(waitFor { !recorder.inputs.isEmpty })
        XCTAssertEqual(recorder.inputs.joined(), String(repeating: "\u{1b}[<64;1;1M", count: 2))
    }

    @MainActor
    func testX10WheelReportsTravelAsBytesEvenPastColumn95() throws {
        let (webView, recorder, teardown) = try loadedTerminal()
        defer { teardown() }
        // A windowless web view is never fitted; give it room for column 100.
        _ = evaluateJavaScript("term.resize(140, 24)", in: webView)
        XCTAssertTrue(waitForJavaScript("term.cols === 140", in: webView))

        _ = evaluateJavaScript("window.monknotWriteBytes(btoa('\\x1b[?1000h'))", in: webView)
        XCTAssertTrue(waitForJavaScript("term.modes.mouseTrackingMode !== 'none'", in: webView))
        let column = try XCTUnwrap(evaluateJavaScript(
            """
            (() => {
              const screen = document.querySelector('.xterm-screen');
              const rect = screen.getBoundingClientRect();
              const cellWidth = rect.width / term.cols;
              const cellHeight = rect.height / term.rows;
              const col = 100;
              document.querySelector('.xterm').dispatchEvent(new WheelEvent('wheel', {
                deltaY: cellHeight, deltaMode: 0,
                clientX: rect.left + (col - 0.5) * cellWidth, clientY: rect.top + cellHeight * 0.5,
                bubbles: true, cancelable: true
              }));
              return col;
            })()
            """,
            in: webView
        ) as? Int)
        XCTAssertTrue(waitFor { !recorder.binaryInputs.isEmpty })
        XCTAssertFalse(
            recorder.inputs.contains { $0.contains("\u{1b}[M") },
            "X10 reports must not go through the UTF-8 text channel"
        )
        let bytes = try XCTUnwrap(recorder.binaryInputs.joined().data(using: .isoLatin1))
        XCTAssertEqual(Array(bytes), [0x1b, 0x5b, 0x4d, UInt8(32 + 65), UInt8(32 + column), UInt8(32 + 1)])
    }

    func testThemeChangesKeepTheWhiteMappingThePageStartedWith() {
        let theme = AppTheme.defaultLight
        let xterm = TerminalWebView.xtermTheme(theme)
        XCTAssertEqual(xterm["white"], theme.foreground)
        XCTAssertEqual(xterm["brightWhite"], theme.foreground)
        let html = TerminalWebView.html(theme: theme, fontSize: 13, usePointerCursors: true, fontSmoothing: true)
        XCTAssertTrue(html.contains(TerminalWebView.jsonObject(xterm)), "The page and theme changes share one theme")
    }

    @MainActor
    func testACollapsedPanelDoesNotShrinkTheTerminal() throws {
        let (webView, _, teardown) = try loadedTerminal()
        defer { teardown() }
        XCTAssertTrue(waitForJavaScript("term.cols > 40", in: webView))
        let columns = evaluateJavaScript("term.cols", in: webView) as? Int

        _ = evaluateJavaScript(
            "document.getElementById('terminal').style.width = '30px'; postResize();",
            in: webView
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(evaluateJavaScript("term.cols", in: webView) as? Int, columns)
    }

    @MainActor
    private func loadedTerminal() throws -> (WKWebView, RecordingTerminalScriptMessageHandler, () -> Void) {
        let configuration = WKWebViewConfiguration()
        let recorder = RecordingTerminalScriptMessageHandler()
        let names = [
            TerminalWebController.inputHandlerName,
            TerminalWebController.resizeHandlerName,
            TerminalWebController.searchVisibilityHandlerName,
            TerminalWebController.binaryInputHandlerName,
        ]
        for name in names {
            configuration.userContentController.add(recorder, name: name)
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 400), configuration: configuration)
        webView.loadHTMLString(try terminalHTMLWithSourceResources(), baseURL: nil)
        XCTAssertTrue(waitForJavaScript("typeof window.monknotWriteBytes === 'function'", in: webView))
        // Let the first fit settle and its resize message arrive before measuring input.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        recorder.inputs.removeAll()
        return (webView, recorder, { [weak self] in
            _ = self?.evaluateJavaScript("window.monknotDispose && window.monknotDispose()", in: webView)
            for name in names {
                configuration.userContentController.removeScriptMessageHandler(forName: name)
            }
        })
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, attempts: Int = 100) -> Bool {
        for _ in 0..<attempts {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return false
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

private final class RecordingTerminalScriptMessageHandler: NSObject, WKScriptMessageHandler {
    var inputs: [String] = []
    var binaryInputs: [String] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let text = message.body as? String else { return }
        if message.name == TerminalWebController.inputHandlerName {
            inputs.append(text)
        } else if message.name == TerminalWebController.binaryInputHandlerName {
            binaryInputs.append(text)
        }
    }
}
