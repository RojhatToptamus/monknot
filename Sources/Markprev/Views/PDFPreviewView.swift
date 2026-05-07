import MarkprevCore
import PDFKit
import SwiftUI

struct PDFPreviewView: NSViewRepresentable {
    let url: URL
    let theme: AppTheme
    let zoomScale: Double
    @Binding var searchState: DocumentSearchState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.autoScales = true
        view.minScaleFactor = 0.35
        view.maxScaleFactor = 4
        view.backgroundColor = NSColor(hex: theme.background)
        return view
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
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

        context.coordinator.loadDocumentIfNeeded(url, in: pdfView)
        context.coordinator.applyAppearance(theme: theme, zoomScale: zoomScale, in: pdfView)
        context.coordinator.applySearch(searchState, theme: theme, in: pdfView)
    }

    final class Coordinator {
        var onSearchResult: (DocumentSearchResult) -> Void = { _ in }
        private var documentURL: URL?
        private var lastAppliedTheme: AppTheme?
        private var lastZoomScale: Double?
        private var lastSearchRequest: DocumentSearchRequest?
        private var matches: [PDFSelection] = []
        private var currentMatchIndex = 0

        func loadDocumentIfNeeded(_ url: URL, in pdfView: PDFView) {
            let standardizedURL = url.standardizedFileURL
            guard documentURL != standardizedURL else { return }

            documentURL = standardizedURL
            matches = []
            currentMatchIndex = 0
            lastSearchRequest = nil
            pdfView.document = PDFDocument(url: standardizedURL)
            pdfView.autoScales = true
            onSearchResult(.init())
        }

        func applyAppearance(theme: AppTheme, zoomScale: Double, in pdfView: PDFView) {
            pdfView.backgroundColor = NSColor(hex: theme.background)

            guard lastAppliedTheme != theme || lastZoomScale != zoomScale else {
                return
            }

            lastAppliedTheme = theme
            lastZoomScale = zoomScale

            let destination = pdfView.currentDestination

            if abs(zoomScale - 1) < 0.001 {
                pdfView.autoScales = true
            } else {
                let sizeToFitScale = pdfView.scaleFactorForSizeToFit
                guard sizeToFitScale.isFinite, sizeToFitScale > 0 else {
                    pdfView.autoScales = true
                    return
                }

                let nextScale = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, sizeToFitScale * CGFloat(zoomScale)))
                pdfView.autoScales = false
                pdfView.scaleFactor = nextScale
            }

            if let destination {
                pdfView.go(to: destination)
            }
        }

        func applySearch(_ state: DocumentSearchState, theme: AppTheme, in pdfView: PDFView) {
            let request = DocumentSearchRequest(state)
            guard request.isPresented, !request.query.isEmpty, let document = pdfView.document else {
                clearSearch(in: pdfView)
                lastSearchRequest = request
                return
            }

            let queryDidChange = request.query != lastSearchRequest?.query
            if queryDidChange {
                matches = document.findString(request.query, withOptions: [.caseInsensitive, .diacriticInsensitive])
                currentMatchIndex = matches.isEmpty ? 0 : 0
            } else if request.navigationSerial != lastSearchRequest?.navigationSerial, !matches.isEmpty {
                switch request.navigationDirection {
                case .next:
                    currentMatchIndex = (currentMatchIndex + 1) % matches.count
                case .previous:
                    currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
                }
            }

            let highlightColor = NSColor(hex: theme.accent).withAlphaComponent(theme.isDark ? 0.38 : 0.28)
            matches.forEach { selection in
                selection.color = highlightColor
            }
            pdfView.highlightedSelections = matches

            if matches.isEmpty {
                pdfView.clearSelection()
                onSearchResult(.init())
            } else {
                let selection = matches[currentMatchIndex]
                pdfView.setCurrentSelection(selection, animate: true)
                pdfView.go(to: selection)
                onSearchResult(DocumentSearchResult(currentIndex: currentMatchIndex + 1, totalCount: matches.count))
            }

            lastSearchRequest = request
        }

        private func clearSearch(in pdfView: PDFView) {
            matches = []
            currentMatchIndex = 0
            pdfView.highlightedSelections = nil
            pdfView.clearSelection()
            onSearchResult(.init())
        }
    }
}
