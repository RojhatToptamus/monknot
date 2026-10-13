import AppKit
import Foundation
import MonknotCore
import SwiftUI
import WebKit

enum MonknotTerminalSearchShortcut {
    enum Action: Equatable {
        case show
        case next
        case previous
        case close
    }

    static func action(for event: NSEvent, isSearchPresented: Bool) -> Action? {
        let modifiers = event.modifierFlags.independentFlags
        let key = event.charactersIgnoringModifiers?.lowercased()

        if event.keyCode == MonknotKeyboardShortcutRouter.escapeKeyCode,
           modifiers.isEmpty,
           isSearchPresented {
            return .close
        }

        if modifiers == [.command] {
            switch key {
            case "f": return .show
            case "g": return .next
            default: return nil
            }
        }

        if modifiers == [.command, .shift], key == "g" {
            return .previous
        }

        return nil
    }
}

@MainActor
enum MonknotNativeTerminalSearchCommand {
    static var hasTerminalFocus: Bool {
        focusedTerminalWebView != nil
    }

    @discardableResult
    static func performIfFocused(for event: NSEvent) -> Bool {
        guard let webView = focusedTerminalWebView,
              let action = MonknotTerminalSearchShortcut.action(
                  for: event,
                  isSearchPresented: webView.terminalController?.isSearchPresented == true
              )
        else {
            return false
        }

        perform(action, in: webView)
        return true
    }

    @discardableResult
    static func performIfFocused(_ action: MonknotTerminalSearchShortcut.Action) -> Bool {
        guard let webView = focusedTerminalWebView else { return false }
        perform(action, in: webView)
        return true
    }

    private static func perform(
        _ action: MonknotTerminalSearchShortcut.Action,
        in webView: TerminalWKWebView
    ) {
        let script: String
        switch action {
        case .show:
            webView.terminalController?.isSearchPresented = true
            script = "window.monknotTerminalSearchOpen && window.monknotTerminalSearchOpen();"
        case .next:
            webView.terminalController?.isSearchPresented = true
            script = "window.monknotTerminalSearchNext && window.monknotTerminalSearchNext();"
        case .previous:
            webView.terminalController?.isSearchPresented = true
            script = "window.monknotTerminalSearchPrevious && window.monknotTerminalSearchPrevious();"
        case .close:
            webView.terminalController?.isSearchPresented = false
            script = "window.monknotTerminalSearchClose && window.monknotTerminalSearchClose();"
        }
        webView.evaluateJavaScript(script)
    }

    private static var focusedTerminalWebView: TerminalWKWebView? {
        // The app menu can temporarily become key while the document window
        // remains main. Resolve both responder chains so mouse and keyboard
        // Find routes use the same focused terminal.
        // https://developer.apple.com/documentation/appkit/nsapplication/mainwindow
        for window in [NSApp.mainWindow, NSApp.keyWindow].compactMap({ $0 }) {
            var responder = window.firstResponder
            while let current = responder {
                if let webView = current as? TerminalWKWebView {
                    return webView
                }
                if let view = current as? NSView,
                   let webView = enclosingTerminalWebView(for: view) {
                    return webView
                }
                responder = current.nextResponder
            }
        }
        return nil
    }

    private static func enclosingTerminalWebView(for view: NSView) -> TerminalWKWebView? {
        var current: NSView? = view
        while let candidate = current {
            if let webView = candidate as? TerminalWKWebView {
                return webView
            }
            current = candidate.superview
        }
        return nil
    }
}

@MainActor
final class TerminalWKWebView: WKWebView {
    weak var terminalController: TerminalWebController?
}

/// Shows a terminal session. The xterm web view belongs to the session's `TerminalWebController`, so
/// hiding the drawer or switching terminal tabs only moves it out of the window: the screen, its modes
/// and the scrollback stay exactly as the program left them.
struct TerminalWebView: NSViewRepresentable {
    let session: TerminalSessionStore
    let theme: AppTheme
    let fontSize: CGFloat
    let usePointerCursors: Bool
    let fontSmoothing: Bool

    private var appearance: TerminalAppearance {
        TerminalAppearance(
            theme: theme,
            fontSize: fontSize,
            usePointerCursors: usePointerCursors,
            fontSmoothing: fontSmoothing
        )
    }

    func makeNSView(context: Context) -> TerminalWebHostView {
        let controller = TerminalWebController.controller(for: session)
        controller.requestFocus(from: (NSApp.mainWindow ?? NSApp.keyWindow)?.firstResponder)
        let host = TerminalWebHostView()
        host.show(controller.webView(appearance: appearance))
        return host
    }

    func updateNSView(_ host: TerminalWebHostView, context: Context) {
        let controller = TerminalWebController.controller(for: session)
        host.show(controller.webView(appearance: appearance))
        controller.updateAppearance(appearance)
    }

    static func dismantleNSView(_ host: TerminalWebHostView, coordinator: ()) {
        host.show(nil)
    }

    static func html(
        theme: AppTheme,
        fontSize: CGFloat,
        usePointerCursors: Bool,
        fontSmoothing: Bool
    ) -> String {
        let xtermCSS = bundledResource(named: "xterm", extension: "css")
        let xtermJS = bundledResource(named: "xterm", extension: "js")
        let fitJS = bundledResource(named: "xterm-addon-fit", extension: "js")
        let searchJS = bundledResource(named: "xterm-addon-search", extension: "js")

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
          \(xtermCSS)
          :root {
            \(Self.cssVariables(
                theme,
                fontSize: fontSize,
                usePointerCursors: usePointerCursors,
                fontSmoothing: fontSmoothing
            ))
            color-scheme: \(theme.isDark ? "dark" : "light");
          }
          html, body, #terminal {
            width: 100%;
            height: 100%;
            margin: 0;
            overflow: hidden;
            overscroll-behavior: none;
            background: var(--terminal-bg);
            -webkit-font-smoothing: var(--terminal-font-smoothing);
          }
          body {
            position: relative;
          }
          .xterm {
            padding: 10px 12px;
            box-sizing: border-box;
            background: var(--terminal-bg) !important;
          }
          .xterm-screen,
          .xterm-scroll-area,
          .xterm-viewport,
          .xterm .xterm-screen canvas {
            background: var(--terminal-bg) !important;
          }
          .xterm.xterm-cursor-pointer,
          .xterm .xterm-cursor-pointer {
            cursor: var(--terminal-interactive-cursor) !important;
          }
          .xterm-viewport {
            scrollbar-gutter: stable;
            overscroll-behavior: none;
          }
          #terminal-search {
            position: absolute;
            z-index: 2;
            top: 8px;
            right: 12px;
            display: flex;
            align-items: center;
            gap: 4px;
            width: min(330px, calc(100% - 24px));
            min-height: 28px;
            padding: 4px;
            box-sizing: border-box;
            border: 1px solid var(--terminal-search-border);
            border-radius: 7px;
            color: var(--terminal-fg);
            background: var(--terminal-search-bg);
            box-shadow: 0 5px 18px var(--terminal-search-shadow);
            font: 400 calc(var(--terminal-font-size) * 0.88) system-ui, sans-serif;
          }
          #terminal-search[hidden] {
            display: none;
          }
          #terminal-search-input {
            min-width: 60px;
            flex: 1;
            height: 24px;
            padding: 0 6px;
            border: 0;
            border-radius: 4px;
            outline: none;
            color: var(--terminal-fg);
            background: transparent;
            font: inherit;
          }
          #terminal-search-input:focus {
            box-shadow: inset 0 0 0 1px var(--terminal-accent);
          }
          #terminal-search-status {
            flex: none;
            min-width: 10ch;
            color: var(--terminal-muted-fg);
            text-align: right;
            font-variant-numeric: tabular-nums;
          }
          .terminal-search-button {
            width: 24px;
            height: 24px;
            padding: 0;
            border: 0;
            border-radius: 4px;
            color: var(--terminal-fg);
            background: transparent;
            font: 400 13px system-ui, sans-serif;
          }
          .terminal-search-button:hover,
          .terminal-search-button:focus-visible {
            outline: none;
            background: var(--terminal-search-hover);
          }
          \(MonknotScrollbarStyle.webCSS(
              selector: ".xterm .xterm-viewport",
              restingColor: "var(--terminal-scrollbar-thumb)",
              hoveredColor: "var(--terminal-scrollbar-thumb-hover)"
          ))
          </style>
        </head>
        <body>
          <form id="terminal-search" role="search" hidden>
            <input
              id="terminal-search-input"
              type="search"
              aria-label="Search terminal scrollback"
              autocomplete="off"
              autocapitalize="off"
              spellcheck="false"
            >
            <span id="terminal-search-status" role="status" aria-live="polite"></span>
            <button
              id="terminal-search-previous"
              class="terminal-search-button"
              type="button"
              aria-label="Previous terminal match"
              title="Previous match (⇧⌘G)"
            >↑</button>
            <button
              id="terminal-search-next"
              class="terminal-search-button"
              type="button"
              aria-label="Next terminal match"
              title="Next match (⌘G)"
            >↓</button>
            <button
              id="terminal-search-close"
              class="terminal-search-button"
              type="button"
              aria-label="Close terminal search"
              title="Close search (Esc)"
            >×</button>
          </form>
          <div id="terminal"></div>
          <script>
          \(xtermJS)
          \(fitJS)
          \(searchJS)
          const term = new Terminal({
            // SearchAddon result highlights use registerDecoration. xterm requires
            // this opt-in for proposed APIs: https://xtermjs.org/docs/api/terminal/interfaces/iterminaloptions/#allowproposedapi
            allowProposedApi: true,
            cursorBlink: true,
            cursorStyle: 'block',
            convertEol: false,
            scrollback: 10000,
            // ⌥-drag selects text even while a program (Claude Code, vim) has mouse reporting on.
            macOptionClickForcesSelection: true,
            fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
            fontSize: \(fontSize),
            theme: \(Self.jsonObject(Self.xtermTheme(theme)))
          });
          const fitAddon = new FitAddon.FitAddon();
          const searchHighlightLimit = 1000;
          const searchAddon = new SearchAddon.SearchAddon({ highlightLimit: searchHighlightLimit });
          term.loadAddon(fitAddon);
          term.loadAddon(searchAddon);
          term.open(document.getElementById('terminal'));
          const screenElement = document.querySelector('.xterm-screen');
          // While a write is replaying output this view already answered once, its device queries
          // must not be answered again: the replies would arrive as typed input.
          let quietWrites = 0;
          let sgrMouseEncoding = false;
          let sgrPixelMouseEncoding = false;
          let wheelLines = 0;
          let lastNotifiedSize = null;
          let notifyResizeTimer = null;

          function sendInput(data) {
            if (disposed || quietWrites > 0) return;
            window.webkit.messageHandlers.\(TerminalWebController.inputHandlerName).postMessage(data);
          }

          // Bytes rather than text: each character code is one byte (X10 mouse reports go above 0x7F).
          function sendBinary(data) {
            if (disposed || quietWrites > 0) return;
            window.webkit.messageHandlers.\(TerminalWebController.binaryInputHandlerName).postMessage(data);
          }

          // xterm.js does not expose the mouse encoding, so follow DECSET/DECRST 1006 (SGR) ourselves.
          const sgrSetDisposable = term.parser.registerCsiHandler({ prefix: '?', final: 'h' }, params => {
            if (params.includes(1006)) sgrMouseEncoding = true;
            if (params.includes(1016)) sgrPixelMouseEncoding = true;
            return false;
          });
          const sgrResetDisposable = term.parser.registerCsiHandler({ prefix: '?', final: 'l' }, params => {
            if (params.includes(1006) || params.includes(1016)) sgrMouseEncoding = false;
            if (params.includes(1016)) sgrPixelMouseEncoding = false;
            return false;
          });
          // A full reset (RIS) also ends SGR mouse encoding.
          const risDisposable = term.parser.registerEscHandler({ final: 'c' }, () => {
            sgrMouseEncoding = false;
            sgrPixelMouseEncoding = false;
            return false;
          });
          // XTVERSION: programs use it to pick terminal-specific behaviour such as wheel speed. Keep the
          // version in step with the vendored xterm.js (THIRD_PARTY_NOTICES.md).
          const versionDisposable = term.parser.registerCsiHandler({ prefix: '>', final: 'q' }, params => {
            if ((params[0] || 0) === 0) sendInput('\\x1bP>|xterm.js(5.5.0)\\x1b\\\\');
            return true;
          });

          function sendWheelReports(button, count, event) {
            const rect = screenElement.getBoundingClientRect();
            const col = Math.min(term.cols, Math.max(1, Math.floor((event.clientX - rect.left) / (rect.width / term.cols)) + 1));
            const row = Math.min(term.rows, Math.max(1, Math.floor((event.clientY - rect.top) / (rect.height / term.rows)) + 1));
            if (sgrMouseEncoding) {
              sendInput(`\\x1b[<${button};${col};${row}M`.repeat(count));
              return;
            }
            const report = '\\x1b[M' + String.fromCharCode(32 + button, 32 + Math.min(col, 223), 32 + Math.min(row, 223));
            sendBinary(report.repeat(count));
          }

          // With mouse reporting on, xterm.js sends one wheel report per wheel event however far it
          // scrolled, so a trackpad flick moves a program like Claude Code by a line or two. Send one
          // report per line actually scrolled instead.
          term.attachCustomWheelEventHandler(event => {
            // X10 mode (DECSET 9) reports presses only, never the wheel; pixel reports are xterm.js's.
            if (term.modes.mouseTrackingMode === 'none' || term.modes.mouseTrackingMode === 'x10') return true;
            if (sgrPixelMouseEncoding) return true;
            const cellHeight = screenElement.getBoundingClientRect().height / term.rows;
            const lines = event.deltaMode === 1
              ? event.deltaY
              : event.deltaMode === 2 ? event.deltaY * term.rows : event.deltaY / cellHeight;
            wheelLines += lines;
            const count = Math.trunc(wheelLines);
            if (count !== 0) {
              wheelLines -= count;
              sendWheelReports(count < 0 ? 64 : 65, Math.min(Math.abs(count), 12), event);
            }
            event.preventDefault();
            return false;
          });

          const searchContainer = document.getElementById('terminal-search');
          const searchInput = document.getElementById('terminal-search-input');
          const searchStatus = document.getElementById('terminal-search-status');
          const searchPreviousButton = document.getElementById('terminal-search-previous');
          const searchNextButton = document.getElementById('terminal-search-next');
          const searchCloseButton = document.getElementById('terminal-search-close');
          let pendingResizeFrame = null;
          let pendingResizeRequestFrame = null;
          let pendingScrollDistanceFromBottom = null;
          let searchDecorationOptions = {
            matchBackground: '\(theme.selectionBackground)',
            matchBorder: '\(theme.accent)',
            matchOverviewRuler: '\(theme.accent)',
            activeMatchBackground: '\(theme.accent)',
            activeMatchBorder: '\(theme.foreground)',
            activeMatchColorOverviewRuler: '\(theme.foreground)'
          };
          let disposed = false;

          function notifySearchVisibility(isPresented) {
            if (disposed) return;
            window.webkit.messageHandlers.\(TerminalWebController.searchVisibilityHandlerName).postMessage(isPresented);
          }

          function searchOptions(incremental = false) {
            return {
              incremental,
              decorations: searchDecorationOptions
            };
          }

          function updateSearchStatus(results) {
            if (!results) {
              searchStatus.textContent = '';
              return;
            }
            if (results.resultCount === 0) {
              searchStatus.textContent = searchInput.value ? 'No results' : '';
              return;
            }
            const resultCount = results.resultCount >= searchHighlightLimit
              ? `${results.resultCount}+`
              : `${results.resultCount}`;
            if (results.resultIndex < 0) {
              searchStatus.textContent = `${resultCount} results`;
              return;
            }
            searchStatus.textContent = `${results.resultIndex + 1} of ${resultCount}`;
          }

          function findInTerminal(direction, incremental = false) {
            const query = searchInput.value;
            if (!query) {
              searchAddon.clearDecorations();
              updateSearchStatus(null);
              return false;
            }
            if (direction === 'previous') {
              return searchAddon.findPrevious(query, searchOptions());
            }
            return searchAddon.findNext(query, searchOptions(incremental));
          }

          function openTerminalSearch(direction = null) {
            if (disposed) return;
            searchContainer.hidden = false;
            notifySearchVisibility(true);
            if (direction) {
              findInTerminal(direction);
            } else if (searchInput.value) {
              findInTerminal('next', true);
            }
            searchInput.focus();
            searchInput.select();
          }

          function closeTerminalSearch() {
            if (disposed || searchContainer.hidden) return;
            searchContainer.hidden = true;
            searchAddon.clearDecorations();
            updateSearchStatus(null);
            notifySearchVisibility(false);
            term.focus();
          }

          function resetTerminalSearch() {
            searchInput.value = '';
            searchAddon.clearDecorations();
            updateSearchStatus(null);
            if (!searchContainer.hidden) {
              searchContainer.hidden = true;
              notifySearchVisibility(false);
            }
          }

          const searchInputListener = () => findInTerminal('next', true);
          const searchKeyListener = event => {
            if (event.key === 'Escape') {
              event.preventDefault();
              event.stopPropagation();
              closeTerminalSearch();
              return;
            }
            if (event.key === 'Enter') {
              event.preventDefault();
              event.stopPropagation();
              findInTerminal(event.shiftKey ? 'previous' : 'next');
            }
          };
          const searchPreviousListener = () => findInTerminal('previous');
          const searchNextListener = () => findInTerminal('next');
          const searchCloseListener = () => closeTerminalSearch();
          searchInput.addEventListener('input', searchInputListener);
          searchInput.addEventListener('keydown', searchKeyListener);
          searchPreviousButton.addEventListener('click', searchPreviousListener);
          searchNextButton.addEventListener('click', searchNextListener);
          searchCloseButton.addEventListener('click', searchCloseListener);
          const searchResultsDisposable = searchAddon.onDidChangeResults(updateSearchStatus);

          function applyCSSVariables(options) {
            if (!options || !options.css) return;
            Object.entries(options.css).forEach(([key, value]) => {
              document.documentElement.style.setProperty(key, value);
            });
            if (options.colorScheme) {
              document.documentElement.style.colorScheme = options.colorScheme;
            }
          }

          // Each size change reaches the program as SIGWINCH, and full-screen programs redraw everything
          // on it; tell the PTY once the size settles, and only when it changed.
          function notifyResize() {
            if (disposed) return;
            clearTimeout(notifyResizeTimer);
            notifyResizeTimer = setTimeout(() => {
              notifyResizeTimer = null;
              if (disposed) return;
              const size = `${term.cols}x${term.rows}`;
              if (size === lastNotifiedSize) return;
              lastNotifiedSize = size;
              window.webkit.messageHandlers.\(TerminalWebController.resizeHandlerName).postMessage({
                cols: term.cols,
                rows: term.rows
              });
            }, 80);
          }

          function postResize(options = {}) {
            if (disposed) return;
            // A collapsed or animating panel measures a few cells; FitAddon would shrink the terminal
            // to 2×1 and every program would reflow its output to that.
            const proposed = fitAddon.proposeDimensions();
            if (!proposed || proposed.cols < 20 || proposed.rows < 4) return;
            const buffer = term.buffer.active;
            if (options.preserveScroll && pendingScrollDistanceFromBottom === null) {
              pendingScrollDistanceFromBottom = buffer.baseY - buffer.viewportY;
            }
            fitAddon.fit();

            // FitAddon can synchronously trigger another observed resize before
            // the first animation frame restores scrollback. Keep the first
            // user-visible anchor for the whole burst so a nested callback
            // cannot replace it with FitAddon's temporary bottom position.
            if (pendingResizeFrame !== null) return;
            pendingResizeFrame = requestAnimationFrame(() => {
              const distanceFromBottom = pendingScrollDistanceFromBottom;
              pendingResizeFrame = null;
              pendingScrollDistanceFromBottom = null;

              if (distanceFromBottom !== null) {
                if (distanceFromBottom <= 0) {
                  term.scrollToBottom();
                } else {
                  term.scrollToLine(Math.max(0, term.buffer.active.baseY - distanceFromBottom));
                }
              }
              notifyResize();
            });
          }

          function scheduleResize(options = {}) {
            if (disposed || pendingResizeRequestFrame !== null) return;
            pendingResizeRequestFrame = requestAnimationFrame(() => {
              pendingResizeRequestFrame = null;
              postResize(options);
            });
          }

          function bytesFromBase64(encoded) {
            const binary = atob(encoded);
            const bytes = new Uint8Array(binary.length);
            for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
            return bytes;
          }

          // Output arrives as raw bytes so xterm's UTF-8 decoder can join characters split across reads.
          window.monknotWriteBytes = function(encoded, options = {}) {
            if (disposed) return;
            if (options.reset) {
              // Through the stream (RIS), so output still queued from before is parsed first.
              resetTerminalSearch();
              wheelLines = 0;
              term.write('\\x1bc');
              lastNotifiedSize = null;
              notifyResize();
            }
            const bytes = bytesFromBase64(encoded);
            // xterm.js follows output only while the view is at the bottom, so reading back through
            // the scrollback is never pulled down by new output.
            if (!options.quiet) {
              term.write(bytes);
              return;
            }
            quietWrites += 1;
            term.write(bytes, () => {
              quietWrites -= 1;
              term.scrollToBottom();
            });
          };
          window.monknotFocus = function() {
            if (disposed) return;
            term.focus();
          };
          window.monknotTheme = function(options) {
            if (disposed) return;
            applyCSSVariables(options);
            term.options.theme = options.theme;
            term.options.fontSize = options.fontSize;
            if (options.searchDecorations) {
              searchDecorationOptions = options.searchDecorations;
              if (!searchContainer.hidden && searchInput.value) {
                findInTerminal('next', true);
              }
            }
            postResize({ preserveScroll: true });
          };
          window.monknotTerminalSearchOpen = function() {
            openTerminalSearch();
          };
          window.monknotTerminalSearchNext = function() {
            openTerminalSearch('next');
          };
          window.monknotTerminalSearchPrevious = function() {
            openTerminalSearch('previous');
          };
          window.monknotTerminalSearchClose = function() {
            closeTerminalSearch();
          };

          const inputDisposable = term.onData(sendInput);
          const binaryDisposable = term.onBinary(sendBinary);
          const resizeListener = () => scheduleResize({ preserveScroll: true });
          window.addEventListener('resize', resizeListener);
          const resizeObserver = new ResizeObserver(() => {
            scheduleResize({ preserveScroll: true });
          });
          resizeObserver.observe(document.getElementById('terminal'));
          scheduleResize();

          window.monknotDispose = function() {
            if (disposed) return;
            disposed = true;
            if (pendingResizeFrame !== null) cancelAnimationFrame(pendingResizeFrame);
            if (pendingResizeRequestFrame !== null) cancelAnimationFrame(pendingResizeRequestFrame);
            clearTimeout(notifyResizeTimer);
            sgrSetDisposable.dispose();
            sgrResetDisposable.dispose();
            risDisposable.dispose();
            versionDisposable.dispose();
            binaryDisposable.dispose();
            resizeObserver.disconnect();
            window.removeEventListener('resize', resizeListener);
            searchInput.removeEventListener('input', searchInputListener);
            searchInput.removeEventListener('keydown', searchKeyListener);
            searchPreviousButton.removeEventListener('click', searchPreviousListener);
            searchNextButton.removeEventListener('click', searchNextListener);
            searchCloseButton.removeEventListener('click', searchCloseListener);
            searchResultsDisposable.dispose();
            inputDisposable.dispose();
            searchAddon.dispose();
            if (typeof fitAddon.dispose === 'function') fitAddon.dispose();
            term.dispose();
          };
          </script>
        </body>
        </html>
        """
    }

    static func configureBackground(of webView: WKWebView, theme: AppTheme) {
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor(hex: theme.terminalSurfaceHex).cgColor
    }

    private static func bundledResource(named name: String, extension fileExtension: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ""
        }

        return contents
    }

    private static func cssVariables(
        _ theme: AppTheme,
        fontSize: CGFloat,
        usePointerCursors: Bool,
        fontSmoothing: Bool
    ) -> String {
        """
        --terminal-bg: \(theme.terminalSurfaceHex);
        --terminal-fg: \(theme.foreground);
        --terminal-muted-fg: \(rgba(theme.foreground, alpha: 0.62));
        --terminal-accent: \(theme.accent);
        --terminal-font-size: \(fontSize)px;
        --terminal-font-smoothing: \(fontSmoothing ? "antialiased" : "auto");
        --terminal-interactive-cursor: \(usePointerCursors ? "pointer" : "default");
        --terminal-scrollbar-thumb: \(rgba(theme.foreground, alpha: Double(MonknotScrollbarStyle.restingOpacity)));
        --terminal-scrollbar-thumb-hover: \(rgba(theme.foreground, alpha: Double(MonknotScrollbarStyle.hoveredOpacity)));
        --terminal-search-bg: \(theme.recessedSurfaceHex(amount: theme.isDark ? 0.13 : 0.055));
        --terminal-search-border: \(rgba(theme.foreground, alpha: 0.16));
        --terminal-search-hover: \(rgba(theme.foreground, alpha: theme.isDark ? 0.10 : 0.07));
        --terminal-search-shadow: rgba(0, 0, 0, \(theme.isDark ? "0.30" : "0.14"));
        """
    }

    /// The xterm.js theme, for the page and for every later theme change alike. `term.options.theme`
    /// replaces the whole theme, so a key missing from either would fall back to xterm's default.
    static func xtermTheme(_ theme: AppTheme) -> [String: String] {
        [
            "background": theme.terminalSurfaceHex,
            "foreground": theme.foreground,
            "cursor": theme.accent,
            "selectionBackground": theme.selectionBackground,
            "black": theme.terminalSurfaceHex,
            "white": theme.foreground,
            "brightWhite": theme.foreground,
            "blue": theme.accent,
            "green": theme.semanticColors.diffAdded,
            "red": theme.semanticColors.diffRemoved,
            "magenta": theme.semanticColors.skill,
        ]
    }

    static func jsonObject(_ value: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json.replacingOccurrences(of: "</", with: "<\\/")
    }

    static func rgba(_ hex: String, alpha: Double) -> String {
        guard let rgb = RGBHex(hex) else {
            return String(format: "rgba(128, 128, 128, %.3f)", alpha)
        }

        return String(
            format: "rgba(%d, %d, %d, %.3f)",
            Int((rgb.red * 255).rounded()),
            Int((rgb.green * 255).rounded()),
            Int((rgb.blue * 255).rounded()),
            alpha
        )
    }

}

struct TerminalAppearance: Equatable {
    let theme: AppTheme
    let fontSize: CGFloat
    let usePointerCursors: Bool
    let fontSmoothing: Bool
}

/// Hosts a session's terminal web view while it is on screen. Taking it out never destroys the view.
final class TerminalWebHostView: NSView {
    private weak var hostedView: NSView?

    func show(_ view: NSView?) {
        guard hostedView !== view else { return }
        // Another host may already have adopted the view (a new drawer appears before the old one is
        // dismantled); only take back what is still ours.
        if let hostedView, hostedView.superview === self {
            hostedView.removeFromSuperview()
        }
        hostedView = view
        guard let view else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }
}

/// Owns a terminal session's xterm web view for the life of the session (it is the session's
/// `presentation`). It writes the session's output into the view as raw bytes, each byte once, and
/// routes input, resize and search messages back.
@MainActor
final class TerminalWebController: NSObject, TerminalSessionPresentation, WKNavigationDelegate {
    static let inputHandlerName = "terminalInput"
    static let resizeHandlerName = "terminalResize"
    static let searchVisibilityHandlerName = "terminalSearchVisibility"
    static let binaryInputHandlerName = "terminalBinaryInput"
    private static let messageHandlerNames = [
        inputHandlerName, resizeHandlerName, searchVisibilityHandlerName, binaryInputHandlerName,
    ]

    static func controller(for session: TerminalSessionStore) -> TerminalWebController {
        if let existing = session.presentation as? TerminalWebController {
            return existing
        }
        let controller = TerminalWebController(session: session)
        session.presentation = controller
        return controller
    }

    private weak var session: TerminalSessionStore?
    var isSearchPresented = false
    var webView: WKWebView?
    private var isLoaded = false
    private var renderedEpoch: Int?
    private var renderedOffset = 0
    private var appearance: TerminalAppearance?
    private var appliedAppearance: TerminalAppearance?
    /// Set when WebKit's content process died: the reloaded page replays output it already answered.
    private var replaysQuietly = false
    private weak var focusOwnerAtRequest: NSResponder?
    private var shouldFocusWhenReady = false

    init(session: TerminalSessionStore) {
        self.session = session
    }

    /// The session's web view, created and loaded on first use.
    func webView(appearance: TerminalAppearance) -> WKWebView {
        if let webView {
            return webView
        }
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let messageProxy = TerminalScriptMessageProxy(controller: self)
        for name in Self.messageHandlerNames {
            configuration.userContentController.add(messageProxy, name: name)
        }

        let webView = TerminalWKWebView(frame: .zero, configuration: configuration)
        webView.terminalController = self
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        TerminalWebView.configureBackground(of: webView, theme: appearance.theme)
        self.webView = webView
        self.appearance = appearance
        appliedAppearance = appearance
        webView.loadHTMLString(
            TerminalWebView.html(
                theme: appearance.theme,
                fontSize: appearance.fontSize,
                usePointerCursors: appearance.usePointerCursors,
                fontSmoothing: appearance.fontSmoothing
            ),
            baseURL: nil
        )
        return webView
    }

    func updateAppearance(_ appearance: TerminalAppearance) {
        self.appearance = appearance
        applyAppearanceIfNeeded()
    }

    /// Focuses the terminal once it is ready, unless focus moved elsewhere in the meantime.
    func requestFocus(from responder: NSResponder?) {
        focusOwnerAtRequest = Self.stableFocusOwner(for: responder)
        shouldFocusWhenReady = true
        if isLoaded {
            performRequestedFocus()
        }
    }

    func focus() {
        evaluate("window.monknotFocus && window.monknotFocus();")
    }

    // MARK: TerminalSessionPresentation

    func sessionOutputDidChange() {
        render()
    }

    func sessionDidStop() {
        if isLoaded {
            evaluate("window.monknotDispose && window.monknotDispose();")
        }
        if let webView {
            webView.navigationDelegate = nil
            for name in Self.messageHandlerNames {
                webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
            }
            (webView as? TerminalWKWebView)?.terminalController = nil
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        webView = nil
        isLoaded = false
        isSearchPresented = false
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        applyAppearanceIfNeeded()
        render()
        performRequestedFocus()
    }

    /// The view outlives the drawer, so a crashed or reclaimed web process must not leave it blank:
    /// reload the page and replay what the session printed, without answering its queries again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let appearance else { return }
        isLoaded = false
        renderedEpoch = nil
        replaysQuietly = true
        // The reloaded page starts with its search box closed.
        isSearchPresented = false
        appliedAppearance = appearance
        webView.loadHTMLString(
            TerminalWebView.html(
                theme: appearance.theme,
                fontSize: appearance.fontSize,
                usePointerCursors: appearance.usePointerCursors,
                fontSmoothing: appearance.fontSmoothing
            ),
            baseURL: nil
        )
    }

    // MARK: Messages

    fileprivate func receive(_ message: WKScriptMessage) {
        switch message.name {
        case Self.inputHandlerName:
            if let text = message.body as? String {
                session?.send(text)
            }
        case Self.binaryInputHandlerName:
            if let text = message.body as? String, let bytes = text.data(using: .isoLatin1) {
                session?.send(bytes)
            }
        case Self.resizeHandlerName:
            if let payload = message.body as? [String: Any],
               let columns = payload["cols"] as? Int,
               let rows = payload["rows"] as? Int {
                session?.resize(columns: columns, rows: rows)
            }
        case Self.searchVisibilityHandlerName:
            if let isPresented = message.body as? Bool {
                isSearchPresented = isPresented
            }
        default:
            break
        }
    }

    // MARK: Output

    private func render() {
        guard isLoaded, let session else { return }
        let output = session.output

        if renderedEpoch != session.outputEpoch {
            // A new view, or the session restarted: the screen starts over with this process's output.
            // These bytes were never shown, so their device queries are answered as usual.
            let isRestart = renderedEpoch != nil
            renderedEpoch = session.outputEpoch
            renderedOffset = output.endOffset
            write(output.bytes(from: output.startOffset) ?? Data(), reset: isRestart, quiet: replaysQuietly)
            replaysQuietly = false
            return
        }

        // The log always keeps the newest chunk, which starts at the offset rendered last.
        guard let bytes = output.bytes(from: renderedOffset) else { return }
        renderedOffset = output.endOffset
        guard !bytes.isEmpty else { return }
        write(bytes, reset: false, quiet: false)
    }

    private func write(_ bytes: Data, reset: Bool, quiet: Bool) {
        guard reset || !bytes.isEmpty else { return }
        let options = "{ reset: \(reset), quiet: \(quiet) }"
        evaluate("window.monknotWriteBytes && window.monknotWriteBytes('\(bytes.base64EncodedString())', \(options));")
    }

    // MARK: Appearance

    private func applyAppearanceIfNeeded() {
        guard let appearance, let webView else { return }
        TerminalWebView.configureBackground(of: webView, theme: appearance.theme)
        guard isLoaded, appearance != appliedAppearance else { return }
        appliedAppearance = appearance

        let theme = appearance.theme
        let payload: [String: Any] = [
            "fontSize": appearance.fontSize,
            "colorScheme": theme.isDark ? "dark" : "light",
            "css": [
                "--terminal-bg": theme.terminalSurfaceHex,
                "--terminal-fg": theme.foreground,
                "--terminal-muted-fg": TerminalWebView.rgba(theme.foreground, alpha: 0.62),
                "--terminal-accent": theme.accent,
                "--terminal-font-size": "\(appearance.fontSize)px",
                "--terminal-font-smoothing": appearance.fontSmoothing ? "antialiased" : "auto",
                "--terminal-interactive-cursor": appearance.usePointerCursors ? "pointer" : "default",
                "--terminal-scrollbar-thumb": TerminalWebView.rgba(
                    theme.foreground,
                    alpha: Double(MonknotScrollbarStyle.restingOpacity)
                ),
                "--terminal-scrollbar-thumb-hover": TerminalWebView.rgba(
                    theme.foreground,
                    alpha: Double(MonknotScrollbarStyle.hoveredOpacity)
                ),
                "--terminal-search-bg": theme.recessedSurfaceHex(amount: theme.isDark ? 0.13 : 0.055),
                "--terminal-search-border": TerminalWebView.rgba(theme.foreground, alpha: 0.16),
                "--terminal-search-hover": TerminalWebView.rgba(
                    theme.foreground,
                    alpha: theme.isDark ? 0.10 : 0.07
                ),
                "--terminal-search-shadow": theme.isDark
                    ? "rgba(0, 0, 0, 0.30)"
                    : "rgba(0, 0, 0, 0.14)"
            ],
            "searchDecorations": [
                "matchBackground": theme.selectionBackground,
                "matchBorder": theme.accent,
                "matchOverviewRuler": theme.accent,
                "activeMatchBackground": theme.accent,
                "activeMatchBorder": theme.foreground,
                "activeMatchColorOverviewRuler": theme.foreground
            ],
            "theme": TerminalWebView.xtermTheme(theme)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        evaluate("window.monknotTheme && window.monknotTheme(\(json.replacingOccurrences(of: "</", with: "<\\/")));")
    }

    // MARK: Focus

    private func performRequestedFocus() {
        guard shouldFocusWhenReady else { return }
        let requestedFocusOwner = focusOwnerAtRequest
        shouldFocusWhenReady = false
        focusOwnerAtRequest = nil
        DispatchQueue.main.async { [weak self, weak requestedFocusOwner] in
            guard let self, let webView = self.webView,
                  let window = webView.window,
                  Self.focusHasNotMoved(in: window, from: requestedFocusOwner, to: webView),
                  !webView.isHiddenOrHasHiddenAncestor,
                  window.makeFirstResponder(webView) else { return }
            self.focus()
        }
    }

    private static func focusHasNotMoved(
        in window: NSWindow,
        from requestedFocusOwner: NSResponder?,
        to webView: WKWebView
    ) -> Bool {
        guard let currentResponder = window.firstResponder else {
            return requestedFocusOwner == nil
        }
        var current: NSResponder? = currentResponder
        while let candidate = current {
            if candidate === webView {
                return true
            }
            if let view = candidate as? NSView, view.isDescendant(of: webView) {
                return true
            }
            current = candidate.nextResponder
        }
        let currentFocusOwner = stableFocusOwner(for: currentResponder)
        switch (currentFocusOwner, requestedFocusOwner) {
        case (nil, nil):
            return true
        case let (current?, requested?):
            return current === requested
        default:
            return false
        }
    }

    /// AppKit reuses one field-editor NSTextView across every NSTextField in
    /// a window. The field's delegate is the stable owner that distinguishes
    /// a real focus transfer between search controls.
    private static func stableFocusOwner(for responder: NSResponder?) -> NSResponder? {
        guard let fieldEditor = responder as? NSTextView,
              fieldEditor.isFieldEditor,
              let owner = fieldEditor.delegate as? NSResponder else {
            return responder
        }
        return owner
    }

    private func evaluate(_ script: String) {
        guard isLoaded, let webView else { return }
        webView.evaluateJavaScript(script)
    }
}

/// WKUserContentController keeps its handlers alive; this proxy keeps the controller out of that
/// retain cycle (controller → web view → configuration → handler).
private final class TerminalScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var controller: TerminalWebController?

    init(controller: TerminalWebController) {
        self.controller = controller
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            controller?.receive(message)
        }
    }
}
