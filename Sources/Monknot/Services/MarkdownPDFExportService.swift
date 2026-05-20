import AppKit
import Foundation
import MonknotCore
import PDFKit
import WebKit

struct MarkdownPDFExportRequest {
    let markdown: String
    let baseURL: URL?
    let theme: AppTheme
    let zoomScale: Double
    let codeFontSize: Double
    let previewWidthPercent: Double
    let usePointerCursors: Bool
    let fontSmoothing: Bool
    let options: MarkdownPDFExportOptions
}

@MainActor
final class MarkdownPDFExportService: NSObject, WKNavigationDelegate {
    private let renderService: MarkdownRenderService
    private var navigationDidFinish = false
    private var navigationError: Error?
    private var renderWindow: NSWindow?
    private var webView: WKWebView?

    init(renderService: MarkdownRenderService) {
        self.renderService = renderService
        super.init()
    }

    static func makeDefault() throws -> MarkdownPDFExportService {
        try MarkdownPDFExportService(renderService: MarkdownRenderService())
    }

    func exportPDF(for request: MarkdownPDFExportRequest, to destinationURL: URL) async throws {
        let pageSize = request.options.pageSize.resolved()
        let pageMargin = request.options.marginPreset.points
        let contentWidth = max(320, pageSize.width - (pageMargin * 2))
        let contentHeight = max(420, pageSize.height - (pageMargin * 2))

        let html = try renderService.htmlDocument(
            markdown: request.markdown,
            appTheme: request.theme,
            zoomScale: request.zoomScale,
            baseFontSize: request.codeFontSize,
            previewWidthPercent: request.previewWidthPercent,
            usePointerCursors: request.usePointerCursors,
            fontSmoothing: request.fontSmoothing,
            baseURL: request.baseURL
        )

        let webView = makeWebView(viewportSize: CGSize(width: contentWidth, height: pageSize.height))
        defer {
            cleanup()
        }

        try await load(html: html, baseURL: request.baseURL, in: webView)
        try await prepareForPDFExport(in: webView)
        let contentSize = try await measuredContentSize(in: webView, minimumWidth: contentWidth, minimumHeight: contentHeight)
        webView.setFrameSize(contentSize)
        renderWindow?.setContentSize(contentSize)
        let pageBreaks = try await calculatedPageBreaks(
            in: webView,
            contentHeight: contentSize.height,
            pageHeight: contentHeight
        )

        let document = try await paginatedPDFDocument(
            from: webView,
            contentSize: contentSize,
            pageBreaks: pageBreaks
        )
        guard document.write(to: destinationURL) else {
            throw MarkdownPDFExportError.missingOutput
        }
    }

    private func makeWebView(viewportSize: CGSize) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: CGRect(origin: .zero, size: viewportSize), configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -12000, y: -12000), size: viewportSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0.01
        window.contentView = webView
        window.orderFrontRegardless()

        self.webView = webView
        self.renderWindow = window
        return webView
    }

    private func load(html: String, baseURL: URL?, in webView: WKWebView) async throws {
        navigationDidFinish = false
        navigationError = nil
        webView.loadHTMLString(html, baseURL: baseURL)

        let deadline = Date().addingTimeInterval(4)
        while !navigationDidFinish, navigationError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        if let navigationError {
            throw navigationError
        }

        guard navigationDidFinish else {
            throw MarkdownPDFExportError.timedOut
        }
    }

    private func prepareForPDFExport(in webView: WKWebView) async throws {
        _ = try await evaluateJavaScript(
            "document.documentElement.classList.add('monknot-pdf-export');",
            in: webView
        )
    }

    private func measuredContentSize(in webView: WKWebView, minimumWidth: CGFloat, minimumHeight: CGFloat) async throws -> CGSize {
        try await Task.sleep(nanoseconds: 200_000_000)

        let script = """
        (() => {
          const root = document.documentElement;
          const body = document.body;
          return {
            width: Math.ceil(Math.max(root.scrollWidth, body ? body.scrollWidth : 0, \(Int(minimumWidth.rounded())))),
            height: Math.ceil(Math.max(root.scrollHeight, body ? body.scrollHeight : 0, \(Int(minimumHeight.rounded()))))
          };
        })();
        """

        let metrics = try await evaluateJavaScript(script, in: webView)
        guard let payload = metrics as? [String: Any] else {
            throw MarkdownPDFExportError.invalidContentMetrics
        }

        let width = numericValue(payload["width"]) ?? Double(minimumWidth)
        let height = numericValue(payload["height"]) ?? Double(minimumHeight)

        return CGSize(
            width: max(CGFloat(width), minimumWidth),
            height: max(CGFloat(height), minimumHeight)
        )
    }

    private func calculatedPageBreaks(in webView: WKWebView, contentHeight: CGFloat, pageHeight: CGFloat) async throws -> [CGFloat] {
        let script = """
        (() => {
          const pageHeight = \(javaScriptNumber(pageHeight));
          const contentHeight = \(javaScriptNumber(contentHeight));
          if (!Number.isFinite(pageHeight) || pageHeight <= 0 || !Number.isFinite(contentHeight) || contentHeight <= pageHeight) {
            return [0, Math.max(1, contentHeight)];
          }

          const root = document.querySelector(".markdown-body") || document.body || document.documentElement;
          const intervals = [];
          const safety = 3;
          const maxKeepTogetherHeight = pageHeight * 0.72;

          const addInterval = (top, bottom) => {
            if (!Number.isFinite(top) || !Number.isFinite(bottom) || bottom <= top) return;
            intervals.push({
              top: Math.max(0, Math.floor(top - safety)),
              bottom: Math.min(contentHeight, Math.ceil(bottom + safety))
            });
          };

          const addRect = (rect) => {
            addInterval(rect.top + window.scrollY, rect.bottom + window.scrollY);
          };

          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode(node) {
              return node.nodeValue && node.nodeValue.trim()
                ? NodeFilter.FILTER_ACCEPT
                : NodeFilter.FILTER_REJECT;
            }
          });
          const range = document.createRange();
          let node;
          while ((node = walker.nextNode())) {
            range.selectNodeContents(node);
            Array.from(range.getClientRects()).forEach(addRect);
          }
          range.detach?.();

          root.querySelectorAll("blockquote, pre, table, figure, img, h1, h2, h3, h4, h5, h6").forEach((element) => {
            const rect = element.getBoundingClientRect();
            const top = rect.top + window.scrollY;
            const bottom = rect.bottom + window.scrollY;
            if (bottom > top && bottom - top <= maxKeepTogetherHeight) {
              addInterval(top, bottom);
            }
          });

          intervals.sort((a, b) => a.top - b.top || a.bottom - b.bottom);

          const hitInterval = (y) => intervals.find((interval) => y > interval.top && y < interval.bottom);
          const isSafe = (y) => !hitInterval(y);

          const nearestSafeBreak = (proposed, minY, maxY) => {
            const candidates = [minY, maxY, proposed];
            intervals.forEach((interval) => {
              candidates.push(interval.top, interval.bottom);
            });

            return candidates
              .filter((value) => Number.isFinite(value) && value >= minY && value <= maxY && isSafe(value))
              .sort((a, b) => Math.abs(a - proposed) - Math.abs(b - proposed))[0];
          };

          const adjustedBreak = (proposed, cursor) => {
            const minY = Math.min(contentHeight, cursor + Math.max(48, pageHeight * 0.55));
            const maxY = Math.min(contentHeight, cursor + pageHeight * 1.15);
            let y = proposed;

            for (let attempt = 0; attempt < 8; attempt += 1) {
              const hit = hitInterval(y);
              if (!hit) return y;

              if (hit.top >= minY) {
                y = hit.top;
              } else if (hit.bottom <= maxY) {
                y = hit.bottom;
              } else {
                break;
              }
            }

            return nearestSafeBreak(proposed, minY, maxY) ?? proposed;
          };

          const breaks = [0];
          let cursor = 0;
          while (contentHeight - cursor > pageHeight) {
            const proposed = cursor + pageHeight;
            let next = adjustedBreak(proposed, cursor);
            if (!Number.isFinite(next) || next <= cursor + 1 || next >= contentHeight) {
              next = proposed;
            }
            next = Math.round(next * 100) / 100;
            breaks.push(next);
            cursor = next;
          }

          if (breaks[breaks.length - 1] < contentHeight) {
            breaks.push(Math.ceil(contentHeight));
          }
          return breaks;
        })();
        """

        let value = try await evaluateJavaScript(script, in: webView)
        guard let values = value as? [Any] else {
            return [0, contentHeight]
        }

        let breaks = values.compactMap { value -> CGFloat? in
            guard let number = numericValue(value) else { return nil }
            return CGFloat(number)
        }
        return sanitizedPageBreaks(breaks, contentHeight: contentHeight)
    }

    private func paginatedPDFDocument(from webView: WKWebView, contentSize: CGSize, pageBreaks: [CGFloat]) async throws -> PDFDocument {
        let output = PDFDocument()

        for pageIndex in 0..<(pageBreaks.count - 1) {
            let pageOriginY = pageBreaks[pageIndex]
            let sliceHeight = pageBreaks[pageIndex + 1] - pageOriginY
            guard sliceHeight > 0 else { continue }

            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(
                x: 0,
                y: pageOriginY,
                width: contentSize.width,
                height: max(sliceHeight, 1)
            )
            configuration.allowTransparentBackground = false

            let pageData = try await createPDFData(in: webView, configuration: configuration)
            guard let pageDocument = PDFDocument(data: pageData), let page = pageDocument.page(at: 0) else {
                throw MarkdownPDFExportError.invalidPageData
            }
            output.insert(page, at: output.pageCount)
        }

        guard output.pageCount > 0 else {
            throw MarkdownPDFExportError.invalidPageData
        }

        return output
    }

    private func sanitizedPageBreaks(_ values: [CGFloat], contentHeight: CGFloat) -> [CGFloat] {
        guard contentHeight > 0 else { return [0, 1] }

        var breaks: [CGFloat] = [0]
        for value in values.dropFirst().dropLast() {
            let candidate = min(max(value, 0), contentHeight)
            guard candidate - (breaks.last ?? 0) > 1 else { continue }
            breaks.append(candidate)
        }

        if contentHeight - (breaks.last ?? 0) > 1 {
            breaks.append(contentHeight)
        }

        return breaks.count >= 2 ? breaks : [0, contentHeight]
    }

    private func evaluateJavaScript(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            var didResume = false

            func finish(_ result: Result<Any?, Error>) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                finish(.failure(MarkdownPDFExportError.timedOut))
            }

            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(value))
                }
            }
        }
    }

    private func createPDFData(in webView: WKWebView, configuration: WKPDFConfiguration) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            var didResume = false

            func finish(_ result: Result<Data, Error>) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                finish(.failure(MarkdownPDFExportError.timedOut))
            }

            webView.createPDF(configuration: configuration) { result in
                finish(result)
            }
        }
    }

    private func numericValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private func javaScriptNumber(_ value: CGFloat) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }

    private func cleanup() {
        navigationDidFinish = false
        navigationError = nil
        webView?.navigationDelegate = nil
        webView = nil
        renderWindow?.orderOut(nil)
        renderWindow = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationDidFinish = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationError = error
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationError = error
    }
}

private enum MarkdownPDFExportError: LocalizedError {
    case invalidContentMetrics
    case invalidPageData
    case missingOutput
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidContentMetrics:
            return "Could not measure the rendered Markdown content."
        case .invalidPageData:
            return "Could not build a PDF page."
        case .missingOutput:
            return "The PDF file was not created."
        case .timedOut:
            return "PDF export timed out."
        }
    }
}
