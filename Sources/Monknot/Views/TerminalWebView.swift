import AppKit
import Foundation
import MonknotCore
import SwiftUI
import WebKit

struct TerminalWebView: NSViewRepresentable {
    @ObservedObject var session: TerminalSessionStore
    let theme: AppTheme
    let fontSize: CGFloat
    let usePointerCursors: Bool
    let fontSmoothing: Bool
    let workspaceURL: URL?
    let workspaceDocumentURLs: [URL]
    let consumeInsertionRequest: (UInt64) -> Bool
    let openFileReference: (ResolvedTerminalFileReference) -> Void
    let reportInteractionError: (String) -> Void
    let insertionOutcome: (TerminalInsertionRequest, TerminalInsertionOutcome) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            workspaceURL: workspaceURL,
            workspaceDocumentURLs: workspaceDocumentURLs,
            insertionRequest: session.insertionRequest,
            consumeInsertionRequest: consumeInsertionRequest,
            openFileReference: openFileReference,
            reportInteractionError: reportInteractionError,
            insertionOutcome: insertionOutcome
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: Coordinator.inputHandlerName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.resizeHandlerName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.pathHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        Self.configureBackground(of: webView, theme: theme)
        context.coordinator.webView = webView
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
        context.coordinator.updateInteractionConfiguration(
            workspaceURL: workspaceURL,
            workspaceDocumentURLs: workspaceDocumentURLs,
            insertionRequest: session.insertionRequest,
            consumeInsertionRequest: consumeInsertionRequest,
            openFileReference: openFileReference,
            reportInteractionError: reportInteractionError,
            insertionOutcome: insertionOutcome
        )
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
        context.coordinator.applyPendingInsertion()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.prepareForDismantle(webView)
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.inputHandlerName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.resizeHandlerName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.pathHandlerName)
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

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
          \(xtermCSS)
          :root {
            \(Self.cssVariables(theme, usePointerCursors: usePointerCursors, fontSmoothing: fontSmoothing))
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
          \(MonknotScrollbarStyle.webCSS(
              selector: ".xterm .xterm-viewport",
              restingColor: "var(--terminal-scrollbar-thumb)",
              hoveredColor: "var(--terminal-scrollbar-thumb-hover)"
          ))
          </style>
        </head>
        <body>
          <div id="terminal"></div>
          <script>
          \(xtermJS)
          \(fitJS)
          const term = new Terminal({
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
          term.loadAddon(fitAddon);
          term.open(document.getElementById('terminal'));
          let pendingResizeFrame = null;
          let pendingResizeRequestFrame = null;
          let pendingScrollDistanceFromBottom = null;
          let disposed = false;

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
            postResize({ preserveScroll: true });
          };

          window.monknotPaste = function(data) {
            if (disposed || typeof data !== 'string') return 'unavailable';
            if (/[\\x00-\\x08\\x0B-\\x1F\\x7F]/.test(data)) return 'unavailable';
            if (data.includes('\\n') && !term.modes.bracketedPasteMode) {
              return 'bracketedPasteRequired';
            }
            term.paste(data);
            term.focus();
            return 'inserted';
          };

          function cellRange(line, startIndex, endIndex) {
            let stringIndex = 0;
            let startCell = null;
            let endCell = null;
            for (let x = 0; x < line.length; x += 1) {
              const cell = line.getCell(x);
              if (!cell || cell.getWidth() === 0) continue;
              const characterLength = (cell.getChars() || ' ').length;
              if (startCell === null && stringIndex >= startIndex) {
                startCell = x + 1;
              }
              stringIndex += characterLength;
              if (stringIndex >= endIndex) {
                endCell = x + Math.max(1, cell.getWidth());
                break;
              }
            }
            if (startCell === null || endCell === null) return null;
            return { startCell, endCell };
          }

          function linksForLine(bufferLineNumber) {
            if (disposed) return undefined;
            const line = term.buffer.active.getLine(bufferLineNumber - 1);
            if (!line) return undefined;
            const text = line.translateToString(true);
            const expression = /(^|[\\s(\\[{])((?:"[^"\\r\\n]+"|'[^'\\r\\n]+'|[^\\s"'<>()[\\]{}]+):[1-9]\\d*(?::[1-9]\\d*)?)(?=$|[\\s,:;)\\]}])/g;
            const links = [];
            let match;
            while ((match = expression.exec(text)) !== null) {
              const candidate = match[2];
              const startIndex = match.index + match[1].length;
              const range = cellRange(line, startIndex, startIndex + candidate.length);
              if (!range) continue;
              links.push({
                text: candidate,
                range: {
                  start: { x: range.startCell, y: bufferLineNumber },
                  end: { x: range.endCell, y: bufferLineNumber }
                },
                activate: (event, value) => {
                  if (!disposed && event.metaKey) {
                    window.webkit.messageHandlers.\(Coordinator.pathHandlerName).postMessage(value);
                  }
                }
              });
            }
            return links.length > 0 ? links : undefined;
          }

          const inputDisposable = term.onData(data => {
            if (!disposed) {
              window.webkit.messageHandlers.\(Coordinator.inputHandlerName).postMessage(data);
            }
          });
          const pathLinkDisposable = term.registerLinkProvider({
            provideLinks: (bufferLineNumber, callback) => {
              callback(linksForLine(bufferLineNumber));
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
            inputDisposable.dispose();
            pathLinkDisposable.dispose();
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
        usePointerCursors: Bool,
        fontSmoothing: Bool
    ) -> String {
        """
        --terminal-bg: \(theme.terminalSurfaceHex);
        --terminal-fg: \(theme.foreground);
        --terminal-font-smoothing: \(fontSmoothing ? "antialiased" : "auto");
        --terminal-interactive-cursor: \(usePointerCursors ? "pointer" : "default");
        --terminal-scrollbar-thumb: \(rgba(theme.foreground, alpha: Double(MonknotScrollbarStyle.restingOpacity)));
        --terminal-scrollbar-thumb-hover: \(rgba(theme.foreground, alpha: Double(MonknotScrollbarStyle.hoveredOpacity)));
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
        static let pathHandlerName = "terminalPath"

        var session: TerminalSessionStore
        weak var webView: WKWebView?
        private var isLoaded = false
        private var renderedTranscript = ""
        private var lastAppearance: TerminalAppearance?
        private var workspaceURL: URL?
        private var workspaceDocumentURLs: [URL]
        private var insertionRequest: TerminalInsertionRequest?
        private var consumeInsertionRequest: (UInt64) -> Bool
        private var openFileReference: (ResolvedTerminalFileReference) -> Void
        private var reportInteractionError: (String) -> Void
        private var insertionOutcome: (TerminalInsertionRequest, TerminalInsertionOutcome) -> Void
        private var lastAttemptedInsertionSerial: UInt64?

        init(
            session: TerminalSessionStore,
            workspaceURL: URL? = nil,
            workspaceDocumentURLs: [URL] = [],
            insertionRequest: TerminalInsertionRequest? = nil,
            consumeInsertionRequest: @escaping (UInt64) -> Bool = { _ in false },
            openFileReference: @escaping (ResolvedTerminalFileReference) -> Void = { _ in },
            reportInteractionError: @escaping (String) -> Void = { _ in },
            insertionOutcome: @escaping (TerminalInsertionRequest, TerminalInsertionOutcome) -> Void = { _, _ in }
        ) {
            self.session = session
            self.workspaceURL = workspaceURL
            self.workspaceDocumentURLs = workspaceDocumentURLs
            self.insertionRequest = insertionRequest
            self.consumeInsertionRequest = consumeInsertionRequest
            self.openFileReference = openFileReference
            self.reportInteractionError = reportInteractionError
            self.insertionOutcome = insertionOutcome
        }

        func updateInteractionConfiguration(
            workspaceURL: URL?,
            workspaceDocumentURLs: [URL],
            insertionRequest: TerminalInsertionRequest?,
            consumeInsertionRequest: @escaping (UInt64) -> Bool,
            openFileReference: @escaping (ResolvedTerminalFileReference) -> Void,
            reportInteractionError: @escaping (String) -> Void,
            insertionOutcome: @escaping (TerminalInsertionRequest, TerminalInsertionOutcome) -> Void
        ) {
            self.workspaceURL = workspaceURL
            self.workspaceDocumentURLs = workspaceDocumentURLs
            self.insertionRequest = insertionRequest
            self.consumeInsertionRequest = consumeInsertionRequest
            self.openFileReference = openFileReference
            self.reportInteractionError = reportInteractionError
            self.insertionOutcome = insertionOutcome
        }

        func switchSession(to session: TerminalSessionStore) {
            self.session = session
            renderedTranscript = ""
            lastAttemptedInsertionSerial = nil
            guard isLoaded, let webView else { return }
            evaluate("window.monknotReset && window.monknotReset();", in: webView)
            render(transcript: session.transcript)
            applyPendingInsertion()
            focus()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            render(transcript: session.transcript)
            applyPendingInsertion()
            DispatchQueue.main.async {
                guard !webView.isHiddenOrHasHiddenAncestor,
                      let window = webView.window,
                      window.makeFirstResponder(webView) else { return }
                self.focus()
            }
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
            case Self.pathHandlerName:
                if let candidate = message.body as? String {
                    openTerminalPath(candidate)
                }
            default:
                break
            }
        }

        func applyPendingInsertion() {
            guard isLoaded,
                  let webView,
                  let request = insertionRequest,
                  request.serial != lastAttemptedInsertionSerial,
                  let json = Self.jsonLiteral(request.text)
            else {
                return
            }

            guard consumeInsertionRequest(request.serial) else {
                lastAttemptedInsertionSerial = request.serial
                return
            }
            lastAttemptedInsertionSerial = request.serial
            let script = "window.monknotPaste ? window.monknotPaste(\(json)) : 'unavailable';"
            webView.evaluateJavaScript(script) { [weak self] result, error in
                guard let self else { return }
                let outcome: TerminalInsertionOutcome
                if error != nil {
                    outcome = .unavailable
                } else if let result = result as? String,
                          let parsedOutcome = TerminalInsertionOutcome(rawValue: result) {
                    outcome = parsedOutcome
                } else {
                    outcome = .unavailable
                }

                self.insertionOutcome(request, outcome)
                switch outcome {
                case .inserted:
                    break
                case .bracketedPasteRequired:
                    self.reportInteractionError(
                        "Multiline text was not inserted because this terminal is not using bracketed paste."
                    )
                case .unavailable:
                    self.reportInteractionError("Could not insert text into the terminal.")
                }
            }
        }

        func prepareForDismantle(_ webView: WKWebView) {
            if isLoaded {
                webView.evaluateJavaScript("window.monknotDispose && window.monknotDispose();")
            }
            isLoaded = false
            webView.stopLoading()
        }

        func finishDismantle() {
            webView = nil
            insertionRequest = nil
            workspaceURL = nil
            workspaceDocumentURLs = []
            consumeInsertionRequest = { _ in false }
            openFileReference = { _ in }
            reportInteractionError = { _ in }
            insertionOutcome = { _, _ in }
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
                    "--terminal-font-smoothing": fontSmoothing ? "antialiased" : "auto",
                    "--terminal-interactive-cursor": usePointerCursors ? "pointer" : "default",
                    "--terminal-scrollbar-thumb": TerminalWebView.rgba(
                        theme.foreground,
                        alpha: Double(MonknotScrollbarStyle.restingOpacity)
                    ),
                    "--terminal-scrollbar-thumb-hover": TerminalWebView.rgba(
                        theme.foreground,
                        alpha: Double(MonknotScrollbarStyle.hoveredOpacity)
                    )
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

        private func openTerminalPath(_ candidate: String) {
            guard let workspaceURL else {
                reportInteractionError("Open a workspace before following terminal paths.")
                return
            }
            guard let reference = TerminalFileReferenceParser.parse(candidate) else {
                reportInteractionError("The terminal path is not valid.")
                return
            }

            do {
                let resolved = try TerminalWorkspacePathResolver.resolve(
                    reference,
                    workspaceURL: workspaceURL,
                    knownDocumentURLs: workspaceDocumentURLs
                )
                openFileReference(resolved)
            } catch {
                reportInteractionError(error.localizedDescription)
            }
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
