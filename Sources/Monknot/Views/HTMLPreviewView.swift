import MonknotCore
import SwiftUI
import WebKit

struct HTMLPreviewView: NSViewRepresentable {
    let documentID: String
    let html: String
    let baseURL: URL?
    let theme: AppTheme
    let zoomScale: Double
    let scrollPosition: DocumentScrollPosition?
    @Binding var searchState: DocumentSearchState
    let onScrollPositionChange: (DocumentScrollPosition) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: Coordinator.scrollPositionHandlerName)
        configuration.userContentController.addUserScript(Coordinator.previewBehaviorScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.applyZoom(zoomScale, in: webView)
        context.coordinator.onScrollPositionChange = onScrollPositionChange
        context.coordinator.onSearchResult = { result in
            DispatchQueue.main.async {
                let current = DocumentSearchResult(
                    currentIndex: self.searchState.currentIndex,
                    totalCount: self.searchState.totalCount
                )
                if current != result {
                    self.searchState.updateResult(result)
                }
            }
        }
        let didChangeDocument = context.coordinator.prepareForDocument(documentID, in: webView)
        context.coordinator.setPendingScrollPosition(scrollPosition, force: didChangeDocument)

        let request = HTMLPreviewContentRequest(documentID: documentID, html: html, baseURL: baseURL)
        if context.coordinator.shouldLoad(request, pendingSearch: searchState) {
            webView.loadHTMLString(html, baseURL: baseURL)
            return
        }

        context.coordinator.applySearch(searchState, in: webView)
        context.coordinator.applyPendingScrollPositionIfNeeded(in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.scrollPositionHandlerName)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let scrollPositionHandlerName = "monknotHTMLScrollPosition"
        static let previewBehaviorScript = WKUserScript(
            source: """
            (() => {
              "use strict";

              let searchQuery = "";
              let searchNavigationSerial = -1;
              let searchMatches = [];
              let searchCurrentIndex = 0;

              installSearchStyle();
              window.monknotHTMLSearch = searchDocument;

              window.addEventListener('scroll', () => {
                if (window.__monknotHTMLScrollPending) return;
                window.__monknotHTMLScrollPending = true;
                window.requestAnimationFrame(() => {
                  window.__monknotHTMLScrollPending = false;
                  window.webkit.messageHandlers.monknotHTMLScrollPosition.postMessage({
                    x: window.scrollX || 0,
                    y: window.scrollY || 0
                  });
                });
              }, { passive: true });

              function installSearchStyle() {
                if (document.getElementById("monknot-html-preview-style")) return;
                const style = document.createElement("style");
                style.id = "monknot-html-preview-style";
                style.textContent = `
                  mark.monknot-html-search-match {
                    padding: 0 0.04em;
                    border-radius: 4px;
                    background: rgba(255, 214, 10, 0.42);
                    color: inherit;
                  }
                  mark.monknot-html-search-current {
                    background: rgba(255, 149, 0, 0.58);
                    outline: 1px solid rgba(255, 149, 0, 0.85);
                    outline-offset: 1px;
                  }
                `;
                (document.head || document.documentElement).appendChild(style);
              }

              function searchDocument(nextState = {}) {
                const requestedQuery = nextState.isPresented === false
                  ? ""
                  : typeof nextState.query === "string"
                    ? nextState.query.trim()
                    : "";
                const navigationSerial = Number.isFinite(Number(nextState.navigationSerial))
                  ? Number(nextState.navigationSerial)
                  : searchNavigationSerial;
                const direction = nextState.direction === "previous" ? "previous" : nextState.direction === "next" ? "next" : "current";
                const queryChanged = requestedQuery !== searchQuery;
                const navigationChanged = navigationSerial !== searchNavigationSerial;

                searchQuery = requestedQuery;
                removeSearchHighlights();

                if (!searchQuery) {
                  searchMatches = [];
                  searchCurrentIndex = 0;
                  searchNavigationSerial = navigationSerial;
                  return searchResult();
                }

                searchMatches = highlightSearchMatches(searchQuery);
                if (searchMatches.length === 0) {
                  searchCurrentIndex = 0;
                  searchNavigationSerial = navigationSerial;
                  return searchResult();
                }

                if (queryChanged || searchCurrentIndex >= searchMatches.length) {
                  searchCurrentIndex = 0;
                } else if (navigationChanged) {
                  searchCurrentIndex = direction === "previous"
                    ? (searchCurrentIndex - 1 + searchMatches.length) % searchMatches.length
                    : (searchCurrentIndex + 1) % searchMatches.length;
                }

                searchNavigationSerial = navigationSerial;
                revealCurrentSearchMatch(queryChanged || navigationChanged);
                return searchResult();
              }

              function searchResult() {
                return {
                  currentIndex: searchMatches.length > 0 ? searchCurrentIndex + 1 : 0,
                  totalCount: searchMatches.length
                };
              }

              function removeSearchHighlights() {
                const parents = new Set();
                document.querySelectorAll("mark.monknot-html-search-match").forEach((mark) => {
                  const parent = mark.parentNode;
                  if (!parent) return;
                  parents.add(parent);
                  mark.replaceWith(document.createTextNode(mark.textContent || ""));
                });
                parents.forEach((parent) => parent.normalize());
              }

              function highlightSearchMatches(query) {
                const matches = [];
                const queryLower = query.toLocaleLowerCase();
                const nodes = textNodesForSearch();

                for (const node of nodes) {
                  const value = node.nodeValue || "";
                  const valueLower = value.toLocaleLowerCase();
                  let cursor = 0;
                  let matchIndex = valueLower.indexOf(queryLower);
                  if (matchIndex < 0) continue;

                  const fragment = document.createDocumentFragment();
                  while (matchIndex >= 0) {
                    if (matchIndex > cursor) {
                      fragment.appendChild(document.createTextNode(value.slice(cursor, matchIndex)));
                    }

                    const mark = document.createElement("mark");
                    mark.className = "monknot-html-search-match";
                    mark.textContent = value.slice(matchIndex, matchIndex + query.length);
                    fragment.appendChild(mark);
                    matches.push(mark);

                    cursor = matchIndex + query.length;
                    matchIndex = valueLower.indexOf(queryLower, cursor);
                  }

                  if (cursor < value.length) {
                    fragment.appendChild(document.createTextNode(value.slice(cursor)));
                  }

                  node.parentNode?.replaceChild(fragment, node);
                }

                return matches;
              }

              function textNodesForSearch() {
                const root = document.body || document.documentElement;
                const nodes = [];
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
                  acceptNode(node) {
                    const value = node.nodeValue || "";
                    if (!value.trim()) return NodeFilter.FILTER_REJECT;

                    const parent = node.parentElement;
                    if (!parent) return NodeFilter.FILTER_REJECT;
                    if (parent.closest("script, style, noscript, mark.monknot-html-search-match")) {
                      return NodeFilter.FILTER_REJECT;
                    }

                    return NodeFilter.FILTER_ACCEPT;
                  }
                });

                while (walker.nextNode()) {
                  nodes.push(walker.currentNode);
                }

                return nodes;
              }

              function revealCurrentSearchMatch(shouldScroll) {
                searchMatches.forEach((match, index) => {
                  match.classList.toggle("monknot-html-search-current", index === searchCurrentIndex);
                });

                const current = searchMatches[searchCurrentIndex];
                if (shouldScroll && current) {
                  current.scrollIntoView({ block: "center", inline: "nearest", behavior: "smooth" });
                }
              }
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        var onScrollPositionChange: (DocumentScrollPosition) -> Void = { _ in }
        var onSearchResult: (DocumentSearchResult) -> Void = { _ in }
        private var documentID: String?
        private var lastContentRequest: HTMLPreviewContentRequest?
        private var lastSearchRequest: DocumentSearchRequest?
        private var pendingSearch: DocumentSearchState?
        private var pendingScrollPosition: DocumentScrollPosition?
        private var shouldRestorePendingScrollPosition = false
        private var lastPublishedScrollPosition: DocumentScrollPosition?
        private var lastAppliedZoomScale: Double?
        private(set) var isLoaded = false

        fileprivate func applyZoom(_ zoomScale: Double, in webView: WKWebView) {
            let clampedZoom = min(3.0, max(0.7, zoomScale))
            guard lastAppliedZoomScale != clampedZoom else { return }
            lastAppliedZoomScale = clampedZoom
            webView.pageZoom = CGFloat(clampedZoom)
        }

        fileprivate func prepareForDocument(_ nextDocumentID: String, in webView: WKWebView) -> Bool {
            guard documentID != nextDocumentID else { return false }
            let publishPreviousScrollPosition = onScrollPositionChange
            webView.evaluateJavaScript("({ x: window.scrollX || 0, y: window.scrollY || 0 })") { value, error in
                guard error == nil else { return }
                publishPreviousScrollPosition(Self.scrollPosition(from: value))
            }
            documentID = nextDocumentID
            lastPublishedScrollPosition = nil
            shouldRestorePendingScrollPosition = true
            return true
        }

        fileprivate func shouldLoad(_ request: HTMLPreviewContentRequest, pendingSearch: DocumentSearchState) -> Bool {
            self.pendingSearch = pendingSearch
            guard request != lastContentRequest || !isLoaded else { return false }
            lastContentRequest = request
            lastSearchRequest = nil
            isLoaded = false
            return true
        }

        fileprivate func setPendingScrollPosition(_ position: DocumentScrollPosition?, force: Bool = false) {
            pendingScrollPosition = position
            if force {
                shouldRestorePendingScrollPosition = true
            }
        }

        fileprivate func applySearch(_ state: DocumentSearchState, in webView: WKWebView) {
            pendingSearch = state
            guard isLoaded else { return }

            let request = DocumentSearchRequest(state)
            guard request != lastSearchRequest else { return }
            lastSearchRequest = request

            let payload: [String: Any] = [
                "query": request.query,
                "direction": request.navigationDirection.rawValue,
                "navigationSerial": request.navigationSerial,
                "isPresented": request.isPresented
            ]

            do {
                let json = try javaScriptPayload(payload)
                webView.evaluateJavaScript("window.monknotHTMLSearch && window.monknotHTMLSearch(\(json));") { [weak self] value, _ in
                    self?.onSearchResult(Self.parseSearchResult(value))
                }
            } catch {
                onSearchResult(.init())
            }
        }

        fileprivate func applyPendingScrollPositionIfNeeded(in webView: WKWebView) {
            guard isLoaded, shouldRestorePendingScrollPosition else { return }
            shouldRestorePendingScrollPosition = false

            let position = pendingScrollPosition ?? DocumentScrollPosition(x: 0, y: 0)
            guard position.x.isFinite, position.y.isFinite else {
                webView.evaluateJavaScript("window.scrollTo(0, 0);")
                return
            }

            webView.evaluateJavaScript("window.scrollTo(\(position.x), \(position.y));")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            applySearch(pendingSearch ?? DocumentSearchState(), in: webView)
            applyPendingScrollPositionIfNeeded(in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoaded = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoaded = false
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.scrollPositionHandlerName else { return }
            let position = Self.scrollPosition(from: message.body)
            guard position.isMeaningfullyDifferent(from: lastPublishedScrollPosition) else { return }
            lastPublishedScrollPosition = position
            onScrollPositionChange(position)
        }

        private static func scrollPosition(from body: Any?) -> DocumentScrollPosition {
            guard let body = body as? [String: Any] else {
                return DocumentScrollPosition(x: 0, y: 0)
            }

            let x = (body["x"] as? NSNumber)?.doubleValue ?? body["x"] as? Double ?? 0
            let y = (body["y"] as? NSNumber)?.doubleValue ?? body["y"] as? Double ?? 0
            return DocumentScrollPosition(x: x, y: y)
        }

        private static func parseSearchResult(_ value: Any?) -> DocumentSearchResult {
            guard let payload = value as? [String: Any] else {
                return .init()
            }

            let current = (payload["currentIndex"] as? NSNumber)?.intValue
                ?? payload["currentIndex"] as? Int
                ?? 0
            let total = (payload["totalCount"] as? NSNumber)?.intValue
                ?? payload["totalCount"] as? Int
                ?? 0

            return DocumentSearchResult(currentIndex: current, totalCount: total)
        }

        private func javaScriptPayload(_ payload: Any) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard var literal = String(data: data, encoding: .utf8) else {
                throw HTMLPreviewError.invalidPayload
            }

            literal = literal.replacingOccurrences(of: "</", with: "<\\/")
            return literal
        }
    }
}

private struct HTMLPreviewContentRequest: Equatable {
    let documentID: String
    let html: String
    let baseURL: URL?
}

private enum HTMLPreviewError: Error {
    case invalidPayload
}
