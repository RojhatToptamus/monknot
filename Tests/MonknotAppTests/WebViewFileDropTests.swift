import AppKit
import WebKit
import XCTest
@testable import MonknotApp

private final class LoadProbe: NSObject, WKNavigationDelegate {
    var finished = 0
    var navigationCount = 0
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished += 1 }
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        navigationCount += 1
        decisionHandler(.allow)
    }
}

/// Finder file drops onto the terminal and the previews must not replace their pages.
@MainActor
final class WebViewFileDropTests: XCTestCase {
    func testFileDroppedOnTheTerminalDoesNotNavigateAway() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonknotDropTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dropped.txt")
        try "dropped".write(to: file, atomically: true, encoding: .utf8)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let webView = TerminalWKWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            configuration: WKWebViewConfiguration()
        )
        let probe = LoadProbe()
        webView.navigationDelegate = probe
        window.contentView?.addSubview(webView)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        webView.loadHTMLString(
            "<html><body style='height:100%'><div style='height:300px'>terminal</div></body></html>",
            baseURL: nil
        )
        for _ in 0..<200 where probe.finished == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(probe.finished, 1)
        let navigationsBeforeDrop = probe.navigationCount

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MonknotDropTest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let info = FakeDraggingInfo(
            pasteboard: pasteboard,
            location: NSPoint(x: 200, y: 150),
            window: window,
            sourceOperationMask: [.copy, .generic, .link]
        )
        XCTAssertEqual(webView.draggingEntered(info), .copy)
        XCTAssertEqual(webView.draggingUpdated(info), .copy)
        XCTAssertTrue(webView.prepareForDragOperation(info))
        _ = webView.performDragOperation(info)
        webView.concludeDragOperation(info)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(probe.navigationCount, navigationsBeforeDrop, "The drop started a navigation")
        XCTAssertNotEqual(webView.url?.isFileURL, true, "url=\(webView.url?.absoluteString ?? "nil")")
    }

    func testTerminalAllowsOnlyItsOwnPage() {
        XCTAssertTrue(TerminalWebController.allowsNavigation(to: URL(string: "about:blank")))
        XCTAssertFalse(TerminalWebController.allowsNavigation(to: URL(fileURLWithPath: "/tmp/dropped.txt")))
        XCTAssertFalse(TerminalWebController.allowsNavigation(to: URL(string: "https://example.com")))
        XCTAssertFalse(TerminalWebController.allowsNavigation(to: nil))
    }

    func testDroppedPathsAreShellEscapedLikeTerminal() {
        XCTAssertEqual(TerminalWebController.shellEscapedPath("/Users/me/notes.md"), "/Users/me/notes.md")
        XCTAssertEqual(
            TerminalWebController.shellEscapedPath("/Users/me/My Notes (v2)/it's & $HOME.md"),
            #"/Users/me/My\ Notes\ \(v2\)/it\'s\ \&\ \$HOME.md"#
        )
        XCTAssertEqual(TerminalWebController.shellEscapedPath("/tmp/Ünïcødé 文件.md"), #"/tmp/Ünïcødé\ 文件.md"#)
        XCTAssertEqual(TerminalWebController.shellEscapedPath("/tmp/a\nb's"), #"$'/tmp/a\nb\'s'"#)
    }

    func testDroppedPathsNeverTypeControlCharacters() throws {
        let paths = [
            "/tmp/x\u{15}touch ~/pwned\r",
            "/tmp/a\u{3}b\u{7F}c\td\\e'f\ng",
            "/tmp/Ünïcødé\u{1B}[31m\u{85}.md",
        ]
        for path in paths {
            let escaped = TerminalWebController.shellEscapedPath(path)
            XCTAssertFalse(
                escaped.unicodeScalars.contains { $0.properties.generalCategory == .control },
                "\(escaped.debugDescription) contains a control character"
            )
            XCTAssertEqual(try Self.shellWords(escaped, shell: "/bin/zsh"), path)
            XCTAssertEqual(try Self.shellWords(escaped, shell: "/bin/bash"), path)
        }
        XCTAssertEqual(
            TerminalWebController.shellEscapedPath("/tmp/x\u{15}touch ~/pwned\r"),
            #"$'/tmp/x\x15touch ~/pwned\x0D'"#
        )
    }

    /// The text a shell reads back from `escaped`, as one word.
    private static func shellWords(_ escaped: String, shell: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", "printf '%s' " + escaped]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testPreviewsRefuseNavigationsOtherThanTheirOwnPage() {
        let pageURL = WorkspaceResourceSchemeHandler.pageBaseURL(forDirectory: URL(fileURLWithPath: "/tmp/notes"))
        XCTAssertTrue(WorkspaceResourceSchemeHandler.allowsPreviewNavigation(type: .other, isMainFrame: true, to: pageURL))
        XCTAssertTrue(WorkspaceResourceSchemeHandler.allowsPreviewNavigation(
            type: .other, isMainFrame: true, to: URL(string: "about:blank")
        ))
        XCTAssertFalse(WorkspaceResourceSchemeHandler.allowsPreviewNavigation(
            type: .other, isMainFrame: true, to: URL(fileURLWithPath: "/tmp/dropped.txt")
        ))
        XCTAssertFalse(WorkspaceResourceSchemeHandler.allowsPreviewNavigation(
            type: .other, isMainFrame: true, to: URL(string: "https://example.com")
        ))
        // Subframes and other navigation types keep their own handling.
        XCTAssertTrue(WorkspaceResourceSchemeHandler.allowsPreviewNavigation(
            type: .other, isMainFrame: false, to: URL(string: "https://example.com")
        ))
        XCTAssertTrue(WorkspaceResourceSchemeHandler.allowsPreviewNavigation(
            type: .reload, isMainFrame: true, to: URL(fileURLWithPath: "/tmp/page.html")
        ))
    }
}
