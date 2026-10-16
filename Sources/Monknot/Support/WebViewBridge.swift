import Foundation
import SwiftUI
import WebKit

/// The messages Monknot's web views (Markdown preview, HTML preview, terminal) exchange with their
/// page scripts: values passed in as JavaScript literals, and the scroll and search reports the
/// scripts post back.
enum WebViewBridge {
    enum Failure: LocalizedError {
        case invalidPayload

        var errorDescription: String? {
            "Could not encode the web view payload."
        }
    }

    /// `value` (a JSON object or array) as a JavaScript literal. `</` is escaped, so the literal can
    /// also sit inside a page's `<script>` element.
    static func literal(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else { throw Failure.invalidPayload }
        return json.replacingOccurrences(of: "</", with: "<\\/")
    }

    /// The arguments a page's search function takes for `request`.
    static func searchPayload(_ request: DocumentSearchRequest) -> [String: Any] {
        [
            "query": request.query,
            "direction": request.navigationDirection.rawValue,
            "navigationSerial": request.navigationSerial,
            "isPresented": request.isPresented,
            "isCaseSensitive": request.options.isCaseSensitive,
            "isWholeWord": request.options.isWholeWord,
        ]
    }

    /// The match counts a page's search function returns.
    static func searchResult(from value: Any?) -> DocumentSearchResult {
        let payload = value as? [String: Any]
        return DocumentSearchResult(
            currentIndex: integer(payload?["currentIndex"]) ?? 0,
            totalCount: integer(payload?["totalCount"]) ?? 0
        )
    }

    /// Publishes a page's search result into `searchState` on the next main-loop turn, outside the
    /// SwiftUI update that started the search.
    static func searchResultPublisher(
        for searchState: Binding<DocumentSearchState>
    ) -> (DocumentSearchResult) -> Void {
        { result in
            DispatchQueue.main.async {
                let current = DocumentSearchResult(
                    currentIndex: searchState.wrappedValue.currentIndex,
                    totalCount: searchState.wrappedValue.totalCount
                )
                if current != result {
                    searchState.wrappedValue.updateResult(result)
                }
            }
        }
    }

    /// The `x`/`y` scroll offset in a page's scroll report, or the top for a malformed one.
    static func scrollPosition(from body: Any?) -> DocumentScrollPosition {
        let payload = body as? [String: Any]
        return DocumentScrollPosition(
            x: double(payload?["x"]) ?? 0,
            y: double(payload?["y"]) ?? 0
        )
    }

    /// The source line in a page's scroll report, or 0 when it has none.
    static func sourceLine(from body: Any?) -> Int {
        integer((body as? [String: Any])?["sourceLine"]) ?? 0
    }

    /// Reads the page's scroll offset and hands it to `publish`; nothing is published if the page
    /// cannot answer.
    static func readScrollPosition(
        of webView: WKWebView,
        then publish: @escaping (DocumentScrollPosition) -> Void
    ) {
        webView.evaluateJavaScript("({ x: window.scrollX || 0, y: window.scrollY || 0 })") { value, error in
            guard error == nil else { return }
            publish(scrollPosition(from: value))
        }
    }

    /// Scrolls the page to `position`, or to the top when there is none or it is not finite.
    static func scroll(_ webView: WKWebView, to position: DocumentScrollPosition?) {
        guard let position, position.x.isFinite, position.y.isFinite else {
            webView.evaluateJavaScript("window.scrollTo(0, 0);")
            return
        }
        webView.evaluateJavaScript("window.scrollTo(\(position.x), \(position.y));")
    }

    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    static func boolean(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        return value as? Bool
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return value as? Double
    }
}
