import AppKit
import Foundation
import MonknotCore
import PDFKit
import WebKit

struct MarkdownPDFExportRequest {
    let markdown: String
    let baseURL: URL?
    let theme: AppTheme
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
        let pageContentHeight = max(120, pageSize.height - (pageMargin * 2))
        let html = try renderService.htmlDocument(
            markdown: request.markdown,
            appTheme: request.theme,
            zoomScale: request.options.resolvedScale,
            baseFontSize: request.options.textSizePoints,
            contentWidthPercent: request.options.contentWidthPercent,
            usePointerCursors: request.usePointerCursors,
            fontSmoothing: request.fontSmoothing,
            baseURL: request.baseURL
        )

        let webView = makeWebView(viewportSize: pageSize)
        defer {
            cleanup()
        }

        try await load(html: html, baseURL: request.baseURL, in: webView)
        try await prepareForPDFExport(in: webView, pageSize: pageSize, margin: pageMargin)
        let contentHeight = try await measuredMarkdownContentHeight(in: webView)
        let pageOrigins = pageOrigins(contentHeight: contentHeight, pageContentHeight: pageContentHeight)

        let document = PDFDocument()
        for originY in pageOrigins {
            try await setPDFPageOffset(originY, in: webView)

            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(origin: .zero, size: pageSize)
            configuration.allowTransparentBackground = false

            let pageData = try await createPDFData(in: webView, configuration: configuration)
            guard let pageDocument = PDFDocument(data: pageData), let page = pageDocument.page(at: 0) else {
                throw MarkdownPDFExportError.invalidPageData
            }
            document.insert(page, at: document.pageCount)
        }

        guard document.pageCount > 0, document.write(to: destinationURL) else {
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

    private func prepareForPDFExport(in webView: WKWebView, pageSize: CGSize, margin: CGFloat) async throws {
        _ = try await evaluateJavaScript(
            """
            (() => {
              const root = document.documentElement;
              root.classList.add('monknot-pdf-export');
              root.style.setProperty('--pdf-page-width', '\(javaScriptNumber(pageSize.width))px');
              root.style.setProperty('--pdf-page-height', '\(javaScriptNumber(pageSize.height))px');
              root.style.setProperty('--pdf-page-margin', '\(javaScriptNumber(margin))px');
              root.style.setProperty('--pdf-page-offset-y', '0px');
            })();
            """,
            in: webView
        )
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func measuredMarkdownContentHeight(in webView: WKWebView) async throws -> CGFloat {
        let script = """
        (() => {
          const node = document.querySelector(".markdown-body");
          if (!node) return null;
          const rect = node.getBoundingClientRect();
          return Math.ceil(Math.max(node.scrollHeight, node.offsetHeight, rect.height, 1));
        })();
        """

        let value = try await evaluateJavaScript(script, in: webView)
        guard let height = numericValue(value), height > 0 else {
            throw MarkdownPDFExportError.invalidContentMetrics
        }
        return CGFloat(height)
    }

    private func pageOrigins(contentHeight: CGFloat, pageContentHeight: CGFloat) -> [CGFloat] {
        guard contentHeight > pageContentHeight else { return [0] }

        var origins: [CGFloat] = []
        var origin: CGFloat = 0
        while origin < contentHeight {
            origins.append(origin)
            origin += pageContentHeight
        }
        return origins
    }

    private func setPDFPageOffset(_ offset: CGFloat, in webView: WKWebView) async throws {
        _ = try await evaluateJavaScript(
            "document.documentElement.style.setProperty('--pdf-page-offset-y', '-\(javaScriptNumber(offset))px');",
            in: webView
        )
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    private func evaluateJavaScript(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            let gate = TimedContinuation(continuation)
            gate.scheduleTimeout(after: 4, error: MarkdownPDFExportError.timedOut)

            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    gate.resume(.failure(error))
                } else {
                    gate.resume(.success(value))
                }
            }
        }
    }

    private func createPDFData(in webView: WKWebView, configuration: WKPDFConfiguration) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let gate = TimedContinuation(continuation)
            gate.scheduleTimeout(after: 8, error: MarkdownPDFExportError.timedOut)

            webView.createPDF(configuration: configuration) { result in
                gate.resume(result)
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

private final class TimedContinuation<Value> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutWorkItem: DispatchWorkItem?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func scheduleTimeout(after seconds: TimeInterval, error: Error) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.resume(.failure(error))
        }

        lock.lock()
        timeoutWorkItem = workItem
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }

        self.continuation = nil
        let timeoutWorkItem = timeoutWorkItem
        self.timeoutWorkItem = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        continuation.resume(with: result)
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
