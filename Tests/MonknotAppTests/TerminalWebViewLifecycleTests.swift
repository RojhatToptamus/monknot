import XCTest
@testable import MonknotApp

final class TerminalWebViewLifecycleTests: XCTestCase {
    func testTerminalHTMLKeepsInputBridgeAndExplicitTeardownWithoutAppInitiatedInsertion() {
        let html = TerminalWebView.html(
            theme: .defaultDark,
            fontSize: 13.5,
            usePointerCursors: true,
            fontSmoothing: true
        )

        XCTAssertTrue(html.contains("term.onData"))
        XCTAssertTrue(html.contains("window.monknotDispose = function()"))
        XCTAssertTrue(html.contains("resizeObserver.disconnect()"))
        XCTAssertTrue(html.contains("window.removeEventListener('resize', resizeListener)"))
        XCTAssertTrue(html.contains("inputDisposable.dispose()"))
        XCTAssertTrue(html.contains("fitAddon.dispose"))
        XCTAssertTrue(html.contains("term.dispose()"))
        XCTAssertFalse(html.contains("window.monknotPaste"))
        XCTAssertFalse(html.contains("term.registerLinkProvider"))
        XCTAssertFalse(html.contains("pathLinkDisposable"))
        XCTAssertFalse(html.contains("terminalPath"))
    }
}
