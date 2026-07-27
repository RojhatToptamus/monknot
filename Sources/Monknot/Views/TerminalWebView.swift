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

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: Coordinator.inputHandlerName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.resizeHandlerName)

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
            baseURL: Bundle.main.resourceURL
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
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.inputHandlerName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.resizeHandlerName)
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
            padding: 12px 20px;
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
              background: '\(theme.background)',
              foreground: '\(theme.foreground)',
              cursor: '\(theme.accent)',
              selectionBackground: '\(theme.selectionBackground)',
              black: '\(theme.background)',
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
            window.webkit.messageHandlers.\(Coordinator.resizeHandlerName).postMessage({
              cols: term.cols,
              rows: term.rows
            });
          }

          function postResize(options = {}) {
            const buffer = term.buffer.active;
            const viewportY = buffer.viewportY;
            const distanceFromBottom = buffer.baseY - buffer.viewportY;
            fitAddon.fit();

            if (options.preserveScroll) {
              requestAnimationFrame(() => {
                if (distanceFromBottom <= 0) {
                  term.scrollToBottom();
                } else {
                  term.scrollToLine(Math.max(0, Math.min(viewportY, term.buffer.active.baseY)));
                }
                notifyResize();
              });
              return;
            }

            notifyResize();
          }

          function writeAndFollow(data) {
            term.write(data, () => {
              term.scrollToBottom();
            });
          }

          window.monknotWrite = function(data) {
            writeAndFollow(data);
          };
          window.monknotReset = function() {
            term.reset();
          };
          window.monknotFocus = function() {
            term.focus();
          };
          window.monknotTheme = function(options) {
            applyCSSVariables(options);
            term.options.theme = options.theme;
            term.options.fontSize = options.fontSize;
            postResize({ preserveScroll: true });
          };

          term.onData(data => {
            window.webkit.messageHandlers.\(Coordinator.inputHandlerName).postMessage(data);
          });

          window.addEventListener('resize', () => postResize({ preserveScroll: true }));
          requestAnimationFrame(() => {
            postResize();
            term.focus();
          });
          </script>
        </body>
        </html>
        """
    }

    private static func configureBackground(of webView: WKWebView, theme: AppTheme) {
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor(hex: theme.background).cgColor
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
        --terminal-bg: \(theme.background);
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

        var session: TerminalSessionStore
        weak var webView: WKWebView?
        private var isLoaded = false
        private var renderedTranscript = ""
        private var lastAppearance: TerminalAppearance?

        init(session: TerminalSessionStore) {
            self.session = session
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
            DispatchQueue.main.async {
                webView.window?.makeFirstResponder(webView)
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
            default:
                break
            }
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
                    "--terminal-bg": theme.background,
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
                    "background": theme.background,
                    "foreground": theme.foreground,
                    "cursor": theme.accent,
                    "selectionBackground": theme.selectionBackground,
                    "black": theme.background,
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
