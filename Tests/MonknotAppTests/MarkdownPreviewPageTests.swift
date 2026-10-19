import AppKit
import MonknotCore
import PDFKit
import WebKit
import XCTest
@testable import MonknotApp

/// Preview's page in real WebKit: where its text sits against Source's, closed toggles, and the line
/// held at the top of the window across a change of width (design.md §10.10, §10.11, §11).
@MainActor
final class MarkdownPreviewPageTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.contentView = nil
            window.close()
        }
        windows = []
        try await super.tearDown()
    }

    /// design.md §10.11: the first glyph sits on the x Source's does, read-only and while editing, on a
    /// narrow pane (the least edge) and a wide one (the centred measure), and the first line as far down.
    func testTextStartsWhereSourcesDoesInBothPreviewModes() async throws {
        let markdown = "Where the text starts.\n\nA second paragraph."
        for editable in [false, true] {
            for width: CGFloat in [360, 700, 1400] {
                let webView = try await loadPage(markdown, width: width, editable: editable)
                let metrics = try await numbers(webView, """
                (() => {
                  const text = document.querySelector('#content p').firstChild;
                  const range = document.createRange();
                  range.setStart(text, 0);
                  range.setEnd(text, 1);
                  const glyph = range.getClientRects()[0];
                  const block = document.querySelector('#content p').getBoundingClientRect();
                  return [glyph.left, block.top + window.scrollY, document.documentElement.clientWidth];
                })()
                """)
                let viewport = CGFloat(metrics[2])
                let sourceEdge = ContentWidthPreference.editorHorizontalInset(
                    viewportWidth: viewport,
                    contentWidthPercent: 88,
                    zoomScale: 1,
                    fontSize: 13
                ) + ContentWidthPreference.editorLineFragmentPadding(zoomScale: 1)
                let label = "\(editable ? "editing" : "read-only") at \(width)"
                XCTAssertEqual(CGFloat(metrics[0]), sourceEdge, accuracy: 1, label)
                XCTAssertEqual(CGFloat(metrics[1]), ContentWidthPreference.editorVerticalInset(fontSize: 13), accuracy: 0.5, label)
            }
        }
    }

    /// A closed toggle's body is not laid out. Split view's scroll sync must not read its lines as the
    /// top of the window, and a jump to one of them or a search match inside opens the toggle.
    func testClosedTogglesNeitherMisleadScrollSyncNorHideJumpsAndMatches() async throws {
        let before = (1...30).map { "Paragraph \($0) before the toggle." }.joined(separator: "\n\n")
        let after = (1...30).map { "Paragraph \($0) after the toggle." }.joined(separator: "\n\n")
        let markdown = "\(before)\n\n<details>\n<summary>Closed</summary>\n\nHidden body with Zanzibar.\n\nMore hidden text.\n\n</details>\n\n\(after)"
        let lines = markdown.components(separatedBy: "\n")
        let toggleLine = try XCTUnwrap(lines.firstIndex(of: "<details>")) + 1
        let bodyLine = try XCTUnwrap(lines.firstIndex(of: "Hidden body with Zanzibar.")) + 1
        let afterLine = try XCTUnwrap(lines.firstIndex(of: "Paragraph 1 after the toggle.")) + 1
        let webView = try await loadPage(markdown, width: 700, height: 300)

        let lineAtTop = try await number(webView, "window.monknotVisibleSourceLine()")
        XCTAssertEqual(lineAtTop, 1, "At the top, the first line")
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const element = document.querySelector('[data-source-line="\(afterLine)"]');
          window.scrollTo(0, element.getBoundingClientRect().top + window.scrollY);
          return true;
        })()
        """)
        let lineAfter = try await number(webView, "window.monknotVisibleSourceLine()")
        XCTAssertEqual(lineAfter, Double(afterLine))
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const element = document.querySelector('[data-source-line="\(toggleLine)"]');
          window.scrollTo(0, element.getBoundingClientRect().top + window.scrollY - 4);
          return true;
        })()
        """)
        let lineOverToggle = try await number(webView, "window.monknotVisibleSourceLine()")
        XCTAssertEqual(lineOverToggle, Double(toggleLine), "Over the closed toggle, its own line, never one of its hidden body")

        let jumped = try await webView.evaluateJavaScript("window.monknotScrollToLine({ line: \(bodyLine) })") as? Bool
        XCTAssertEqual(jumped, true)
        let jump = try await numbers(webView, """
        (() => {
          const body = document.querySelector('[data-source-line="\(bodyLine)"]');
          return [body.closest('details').open ? 1 : 0, body.getBoundingClientRect().top];
        })()
        """)
        XCTAssertEqual(jump[0], 1, "A jump into a closed toggle opens it")
        XCTAssertEqual(jump[1], 24, accuracy: 4, "and brings the line to the top")

        _ = try await webView.evaluateJavaScript("document.querySelector('details').open = false; window.scrollTo(0, 0); true")
        let searched = try await webView.evaluateJavaScript(
            "window.monknotSearch({ query: 'zanzibar', isPresented: true, navigationSerial: 1 })"
        )
        let result = try XCTUnwrap(searched as? [String: Any])
        XCTAssertEqual((result["totalCount"] as? NSNumber)?.intValue, 1)
        let match = try await numbers(webView, """
        (() => {
          const mark = document.querySelector('mark.monknot-search-current');
          return [mark.closest('details').open ? 1 : 0, mark.checkVisibility() ? 1 : 0];
        })()
        """)
        XCTAssertEqual(match, [1, 1], "The current match opens the toggle that hid it")
    }

    /// design.md §11: the line at the top of the window stays there as a width change rewraps the text,
    /// partway down one long list as well as between blocks, and back again without drifting.
    func testTheLineAtTheTopHoldsAcrossWidthChangesInsideALongList() async throws {
        let items = (1...200).map { "- Item \($0): a sentence long enough to wrap once the column narrows, and a few words more." }
        let webView = try await loadPage("# List\n\n" + items.joined(separator: "\n"), width: 900, height: 400)
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const item = document.querySelectorAll('li')[119];
          window.scrollTo(0, item.getBoundingClientRect().top + window.scrollY + 5);
          window.dispatchEvent(new Event('scroll'));
          return true;
        })()
        """)
        let itemTop = "document.querySelectorAll('li')[119].getBoundingClientRect().top"
        let startTop = try await number(webView, itemTop)
        XCTAssertEqual(startTop, -5, accuracy: 1)

        for width: CGFloat in [420, 900, 560, 900] {
            try await resize(webView, to: width)
            let top = try await number(webView, itemTop)
            XCTAssertEqual(top, -5, accuracy: 2, "Item 120 stays at the top at \(width)")
        }
    }

    /// An edit replaces the block that holds the anchor (editor.js swaps whole blocks); the line at the
    /// top still holds through the next width change.
    func testTheLineAtTheTopHoldsAfterAnEditReplacesItsBlock() async throws {
        let paragraph = (1...80).map { "Sentence \($0) of one long paragraph that wraps over many lines." }.joined(separator: " ")
        let webView = try await loadPage("# Title\n\n\(paragraph)\n\nAfter.", width: 900, height: 400, editable: true)
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const block = document.querySelector('#content p');
          window.scrollTo(0, block.getBoundingClientRect().top + window.scrollY + block.getBoundingClientRect().height / 2);
          window.dispatchEvent(new Event('scroll'));
          const start = window.MonknotEditor.source().indexOf('Sentence 1 ');
          window.MonknotEditor.applyRemote({ base: 0, from: start, to: start, insert: 'Edited. ', reason: 'external' });
          return true;
        })()
        """)
        // The page records a new anchor shortly after the edit.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let probe = """
        window.__probe = (() => {
          const box = document.querySelector('#content').getBoundingClientRect();
          const x = box.left + parseFloat(getComputedStyle(document.querySelector('#content')).paddingLeft) + 1;
          const hit = document.caretRangeFromPoint(x, 1);
          return { node: hit.startContainer, offset: hit.startOffset };
        })();
        true
        """
        _ = try await webView.evaluateJavaScript(probe)
        let probeTop = """
        (() => {
          const range = document.createRange();
          range.setStart(window.__probe.node, window.__probe.offset);
          range.setEnd(window.__probe.node, window.__probe.offset + 1);
          return range.getClientRects()[0].top;
        })()
        """
        let top = try await number(webView, probeTop)
        try await resize(webView, to: 480)
        let topAfterResize = try await number(webView, probeTop)
        XCTAssertEqual(topAfterResize, top, accuracy: 2, "The edited block's line stays at the top")
    }

    /// A PDF cannot be clicked open: a closed toggle prints with its body.
    func testPDFExportPrintsClosedTogglesOpen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownPreviewPageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Toggles.pdf")

        try await MarkdownPDFExportService.makeDefault().exportPDF(
            for: MarkdownPDFExportRequest(
                markdown: "# Toggles\n\n<details>\n<summary>Closed title</summary>\n\nClosed body sentinel.\n\n</details>\n\nAfter the toggle.",
                baseURL: root,
                resourceRoot: root,
                theme: .defaultLight,
                usePointerCursors: false,
                fontSmoothing: true,
                options: MarkdownPDFExportOptions(pageSize: .letter, marginPreset: .normal, themeMode: .light, scalePercent: 100, textSizePoints: 12, contentWidthPercent: 92)
            ),
            to: destination
        )

        let text = try XCTUnwrap(PDFDocument(url: destination)?.string)
        XCTAssertTrue(text.contains("Closed title"))
        XCTAssertTrue(text.contains("Closed body sentinel."), text)
        XCTAssertTrue(text.contains("After the toggle."))
    }

    // MARK: - Fixture

    private func loadPage(
        _ markdown: String,
        width: CGFloat,
        height: CGFloat = 500,
        editable: Bool = false
    ) async throws -> WKWebView {
        let theme = AppTheme.defaultLight
        let html = try MarkdownRenderService().htmlDocument(
            markdown: editable ? "" : markdown,
            appTheme: theme,
            zoomScale: 1,
            baseFontSize: theme.codeFontSize * DocumentMeasure.previewProseScale,
            contentWidthPercent: 88,
            editable: editable,
            legacyScrollbars: NSScroller.preferredScrollerStyle == .legacy,
            baseURL: nil
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // An animated order-front parks a GCD worker for good while the screen is locked.
        window.animationBehavior = .none
        window.contentView = webView
        window.orderFront(nil)
        windows.append(window)
        webView.loadHTMLString(html, baseURL: nil)
        try await waitFor(webView, "document.readyState === 'complete' && typeof window.monknotRender === 'function' && document.getElementById('content') !== null")
        if editable {
            let literal = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: markdown, options: [.fragmentsAllowed]), encoding: .utf8))
            _ = try await webView.evaluateJavaScript(
                "window.monknotRender({ markdown: \(literal), theme: 'light', documentID: '/Note.md', renderID: 1, editable: true }); true"
            )
            try await waitFor(webView, "Boolean(window.MonknotEditor && window.MonknotEditor.isActive())")
        }
        return webView
    }

    /// Resizes the web view and runs the page's resize handling once the page has the new width.
    private func resize(_ webView: WKWebView, to width: CGFloat) async throws {
        webView.window?.setContentSize(NSSize(width: width, height: webView.frame.height))
        webView.frame.size.width = width
        try await waitFor(webView, "window.innerWidth === \(Int(width))")
        _ = try await webView.evaluateJavaScript("window.dispatchEvent(new Event('resize')); true")
    }

    private func waitFor(_ webView: WKWebView, _ condition: String, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await webView.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(condition)")
    }

    private func number(_ webView: WKWebView, _ script: String) async throws -> Double {
        let value = try await webView.evaluateJavaScript(script)
        return try XCTUnwrap((value as? NSNumber)?.doubleValue, script)
    }

    private func numbers(_ webView: WKWebView, _ script: String) async throws -> [Double] {
        let value = try await webView.evaluateJavaScript(script)
        return try XCTUnwrap(value as? [NSNumber], script).map(\.doubleValue)
    }
}
