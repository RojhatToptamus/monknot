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
                  isSearchPresented: webView.terminalCoordinator?.isSearchPresented == true
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
            webView.terminalCoordinator?.isSearchPresented = true
            script = "window.monknotTerminalSearchOpen && window.monknotTerminalSearchOpen();"
        case .next:
            webView.terminalCoordinator?.isSearchPresented = true
            script = "window.monknotTerminalSearchNext && window.monknotTerminalSearchNext();"
        case .previous:
            webView.terminalCoordinator?.isSearchPresented = true
            script = "window.monknotTerminalSearchPrevious && window.monknotTerminalSearchPrevious();"
        case .close:
            webView.terminalCoordinator?.isSearchPresented = false
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
    weak var terminalCoordinator: TerminalWebView.Coordinator?
}

struct TerminalWebView: NSViewRepresentable {
    @ObservedObject var session: TerminalSessionStore
    let theme: AppTheme
    let fontSize: CGFloat
    let usePointerCursors: Bool
    let fontSmoothing: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: Coordinator.inputHandlerName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.resizeHandlerName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.searchVisibilityHandlerName)

        let webView = TerminalWKWebView(frame: .zero, configuration: configuration)
        webView.terminalCoordinator = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        Self.configureBackground(of: webView, theme: theme)
        context.coordinator.webView = webView
        context.coordinator.requestFocusOnLoad(
            from: (NSApp.mainWindow ?? NSApp.keyWindow)?.firstResponder
        )
        webView.loadHTMLString(
            Self.html(
                theme: theme,
                fontSize: fontSize,
                usePointerCursors: usePointerCursors,
                fontSmoothing: fontSmoothing
            ),
            baseURL: nil
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        Self.configureBackground(of: webView, theme: theme)
        if context.coordinator.session !== session {
            context.coordinator.switchSession(to: session)
        }
        context.coordinator.updateTheme(
            theme,
            fontSize: fontSize,
            usePointerCursors: usePointerCursors,
            fontSmoothing: fontSmoothing
        )
        context.coordinator.render(transcript: session.transcript)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.prepareForDismantle(webView)
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.inputHandlerName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.resizeHandlerName)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.searchVisibilityHandlerName
        )
        coordinator.finishDismantle()
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
            font: 500 calc(var(--terminal-font-size) * 0.88) system-ui, sans-serif;
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
            min-width: 48px;
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
            font: 600 13px system-ui, sans-serif;
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
            scrollback: 5000,
            fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
            fontSize: \(fontSize),
            theme: {
              background: '\(theme.terminalSurfaceHex)',
              foreground: '\(theme.foreground)',
              cursor: '\(theme.accent)',
              selectionBackground: '\(theme.selectionBackground)',
              black: '\(theme.terminalSurfaceHex)',
              white: '\(theme.foreground)',
              brightWhite: '\(theme.foreground)',
              blue: '\(theme.accent)',
              green: '\(theme.semanticColors.diffAdded)',
              red: '\(theme.semanticColors.diffRemoved)',
              magenta: '\(theme.semanticColors.skill)'
            }
          });
          const fitAddon = new FitAddon.FitAddon();
          const searchHighlightLimit = 1000;
          const searchAddon = new SearchAddon.SearchAddon({ highlightLimit: searchHighlightLimit });
          term.loadAddon(fitAddon);
          term.loadAddon(searchAddon);
          term.open(document.getElementById('terminal'));
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
            window.webkit.messageHandlers.\(Coordinator.searchVisibilityHandlerName).postMessage(isPresented);
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

          function notifyResize() {
            if (disposed) return;
            window.webkit.messageHandlers.\(Coordinator.resizeHandlerName).postMessage({
              cols: term.cols,
              rows: term.rows
            });
          }

          function postResize(options = {}) {
            if (disposed) return;
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

          function writeAndFollow(data) {
            if (disposed) return;
            const buffer = term.buffer.active;
            const wasAtBottom = buffer.baseY - buffer.viewportY <= 0;
            term.write(data, () => {
              if (wasAtBottom) term.scrollToBottom();
            });
          }

          window.monknotWrite = function(data) {
            writeAndFollow(data);
          };
          window.monknotReset = function() {
            if (disposed) return;
            resetTerminalSearch();
            term.reset();
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

          const inputDisposable = term.onData(data => {
            if (!disposed) {
              window.webkit.messageHandlers.\(Coordinator.inputHandlerName).postMessage(data);
            }
          });
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

    private static func configureBackground(of webView: WKWebView, theme: AppTheme) {
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

    private static func rgba(_ hex: String, alpha: Double) -> String {
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

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let inputHandlerName = "terminalInput"
        static let resizeHandlerName = "terminalResize"
        static let searchVisibilityHandlerName = "terminalSearchVisibility"

        var session: TerminalSessionStore
        var isSearchPresented = false
        weak var webView: WKWebView?
        private var isLoaded = false
        private var renderedTranscript = ""
        private var lastAppearance: TerminalAppearance?
        private weak var focusOwnerAtLoadRequest: NSResponder?
        private var shouldFocusWhenLoaded = false
        init(session: TerminalSessionStore) {
            self.session = session
        }

        func requestFocusOnLoad(from responder: NSResponder?) {
            focusOwnerAtLoadRequest = Self.stableFocusOwner(for: responder)
            shouldFocusWhenLoaded = true
        }

        func switchSession(to session: TerminalSessionStore) {
            self.session = session
            renderedTranscript = ""
            guard isLoaded, let webView else { return }
            evaluate("window.monknotReset && window.monknotReset();", in: webView)
            render(transcript: session.transcript)
            focus()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            render(transcript: session.transcript)
            let requestedFocusOwner = focusOwnerAtLoadRequest
            let shouldFocus = shouldFocusWhenLoaded
            shouldFocusWhenLoaded = false
            focusOwnerAtLoadRequest = nil
            DispatchQueue.main.async { [weak self, weak webView, weak requestedFocusOwner] in
                guard let self, let webView, shouldFocus,
                      let window = webView.window,
                      Self.focusHasNotMoved(
                        in: window,
                        from: requestedFocusOwner,
                        to: webView
                      ),
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

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case Self.inputHandlerName:
                if let text = message.body as? String {
                    session.send(text)
                }
            case Self.resizeHandlerName:
                if let payload = message.body as? [String: Any],
                   let columns = payload["cols"] as? Int,
                   let rows = payload["rows"] as? Int {
                    session.resize(columns: columns, rows: rows)
                }
            case Self.searchVisibilityHandlerName:
                if let isPresented = message.body as? Bool {
                    isSearchPresented = isPresented
                }
            default:
                break
            }
        }

        func prepareForDismantle(_ webView: WKWebView) {
            if isLoaded {
                webView.evaluateJavaScript("window.monknotDispose && window.monknotDispose();")
            }
            isSearchPresented = false
            isLoaded = false
            webView.stopLoading()
        }

        func finishDismantle() {
            webView = nil
        }

        func render(transcript: String) {
            guard isLoaded, let webView else { return }

            if transcript.hasPrefix(renderedTranscript) {
                let chunk = String(transcript.dropFirst(renderedTranscript.count))
                renderedTranscript = transcript
                write(chunk, in: webView)
            } else {
                renderedTranscript = transcript
                evaluate("window.monknotReset && window.monknotReset();", in: webView)
                write(transcript, in: webView)
            }
        }

        func updateTheme(
            _ theme: AppTheme,
            fontSize: CGFloat,
            usePointerCursors: Bool,
            fontSmoothing: Bool
        ) {
            guard isLoaded, let webView else { return }
            let appearance = TerminalAppearance(
                theme: theme,
                fontSize: fontSize,
                usePointerCursors: usePointerCursors,
                fontSmoothing: fontSmoothing
            )
            guard appearance != lastAppearance else { return }
            lastAppearance = appearance

            let payload: [String: Any] = [
                "fontSize": fontSize,
                "colorScheme": theme.isDark ? "dark" : "light",
                "css": [
                    "--terminal-bg": theme.terminalSurfaceHex,
                    "--terminal-fg": theme.foreground,
                    "--terminal-muted-fg": TerminalWebView.rgba(theme.foreground, alpha: 0.62),
                    "--terminal-accent": theme.accent,
                    "--terminal-font-size": "\(fontSize)px",
                    "--terminal-font-smoothing": fontSmoothing ? "antialiased" : "auto",
                    "--terminal-interactive-cursor": usePointerCursors ? "pointer" : "default",
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
                "theme": [
                    "background": theme.terminalSurfaceHex,
                    "foreground": theme.foreground,
                    "cursor": theme.accent,
                    "selectionBackground": theme.selectionBackground,
                    "black": theme.terminalSurfaceHex,
                    "blue": theme.accent,
                    "green": theme.semanticColors.diffAdded,
                    "red": theme.semanticColors.diffRemoved,
                    "magenta": theme.semanticColors.skill
                ]
            ]
            guard let json = Self.jsonLiteral(payload) else { return }
            evaluate("window.monknotTheme && window.monknotTheme(\(json));", in: webView)
        }

        func focus() {
            guard isLoaded, let webView else { return }
            evaluate("window.monknotFocus && window.monknotFocus();", in: webView)
        }

        private func write(_ text: String, in webView: WKWebView) {
            guard !text.isEmpty, let json = Self.jsonLiteral(text) else { return }
            evaluate("window.monknotWrite && window.monknotWrite(\(json));", in: webView)
        }

        private func evaluate(_ script: String, in webView: WKWebView) {
            webView.evaluateJavaScript(script)
        }

        private static func jsonLiteral(_ value: Any) -> String? {
            guard JSONSerialization.isValidJSONObject(value) || value is String else {
                return nil
            }

            let object: Any
            if let string = value as? String {
                object = [string]
            } else {
                object = value
            }

            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  var literal = String(data: data, encoding: .utf8)
            else {
                return nil
            }

            literal = literal.replacingOccurrences(of: "</", with: "<\\/")
            if value is String {
                literal.removeFirst()
                literal.removeLast()
            }
            return literal
        }
    }
}

private struct TerminalAppearance: Equatable {
    let theme: AppTheme
    let fontSize: CGFloat
    let usePointerCursors: Bool
    let fontSmoothing: Bool
}
