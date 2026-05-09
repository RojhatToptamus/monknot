import AppKit
import Foundation
import MarkprevCore
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

        let webView = makeWebView()
        defer {
            cleanup()
        }

        try await load(html: html, baseURL: request.baseURL, in: webView)
        let contentSize = try await measuredContentSize(in: webView)
        webView.setFrameSize(contentSize)
        renderWindow?.setContentSize(contentSize)

        let document = try await paginatedPDFDocument(from: webView, contentSize: contentSize)
        guard document.write(to: destinationURL) else {
            throw MarkdownPDFExportError.missingOutput
        }
    }

    private func makeWebView() -> WKWebView {
        let viewportSize = CGSize(width: 900, height: 1200)
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
    }

    private func measuredContentSize(in webView: WKWebView) async throws -> CGSize {
        try await Task.sleep(nanoseconds: 200_000_000)

        let script = """
        (() => {
          const root = document.documentElement;
          const body = document.body;
          return {
            width: Math.ceil(Math.max(root.scrollWidth, body ? body.scrollWidth : 0, 900)),
            height: Math.ceil(Math.max(root.scrollHeight, body ? body.scrollHeight : 0, 1200))
          };
        })();
        """

        let metrics = try await evaluateJavaScript(script, in: webView)
        guard let payload = metrics as? [String: Any] else {
            throw MarkdownPDFExportError.invalidContentMetrics
        }

        let width = numericValue(payload["width"]) ?? 900
        let height = numericValue(payload["height"]) ?? 1200

        return CGSize(
            width: max(CGFloat(width), 900),
            height: max(CGFloat(height), 1200)
        )
    }

    private func paginatedPDFDocument(from webView: WKWebView, contentSize: CGSize) async throws -> PDFDocument {
        let pageHeight = min(max(contentSize.width * 1.4142, 900), 1400)
        let pageCount = max(1, Int(ceil(contentSize.height / pageHeight)))
        let output = PDFDocument()

        for pageIndex in 0..<pageCount {
            let pageOriginY = CGFloat(pageIndex) * pageHeight
            let sliceHeight = min(pageHeight, contentSize.height - pageOriginY)
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
