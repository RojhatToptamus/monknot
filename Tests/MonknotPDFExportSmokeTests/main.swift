import AppKit
import Foundation
import MonknotCore
import PDFKit

private var failures: [String] = []

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
    }
}

private let longBody = (1...80)
    .map { "Paragraph \($0) verifies that multi-page exported Markdown remains searchable and readable." }
    .joined(separator: "\n\n")

@main
struct MonknotPDFExportSmokeTests {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
            print("FAIL: PDF export smoke test timed out")
            Foundation.exit(1)
        }

        Task { @MainActor in
            do {
                try await run()
                finish()
                NSApp.terminate(nil)
            } catch {
                failures.append("PDF export raised error: \(error)")
                finish()
                NSApp.terminate(nil)
            }
        }

        NSApp.run()
    }

    @MainActor
    private static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-pdf-export-smoke")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let destinationURL = root.appendingPathComponent("Export.pdf")
        let exporter = try MarkdownPDFExportService.makeDefault()
        try await exporter.exportPDF(
            for: MarkdownPDFExportRequest(
                markdown: """
                # Export Title

                This paragraph verifies readable exported text.

                | Column | Value |
                | --- | --- |
                | Page | Letter |

                \(longBody)

                Final Export Sentinel
                """,
                baseURL: root,
                theme: AppTheme.defaultLight,
                usePointerCursors: false,
                fontSmoothing: true,
                options: MarkdownPDFExportOptions(
                    pageSize: .letter,
                    marginPreset: .normal,
                    themeMode: .light,
                    scalePercent: 100,
                    textSizePoints: 12,
                    contentWidthPercent: 92
                )
            ),
            to: destinationURL
        )

        guard let pdf = PDFDocument(url: destinationURL), let firstPage = pdf.page(at: 0) else {
            failures.append("PDF export should create a readable PDF document")
            finish()
            return
        }

        let mediaBox = firstPage.bounds(for: .mediaBox)
        expect(pdf.pageCount >= 2, "PDF export should create multiple pages for long Markdown")
        expect(abs(mediaBox.width - 612) < 1, "Letter export should preserve 612 pt page width")
        expect(abs(mediaBox.height - 792) < 1, "Letter export should preserve 792 pt page height")
        for pageIndex in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIndex) else { continue }
            let pageBox = page.bounds(for: .mediaBox)
            expect(abs(pageBox.width - 612) < 1, "Letter export should preserve page width for page \(pageIndex + 1)")
            expect(abs(pageBox.height - 792) < 1, "Letter export should preserve page height for page \(pageIndex + 1)")
        }
        expect(firstPage.string?.localizedCaseInsensitiveContains("Export Title") == true, "PDF text should be searchable")
        expect(
            pdf.string?.localizedCaseInsensitiveContains("Final Export Sentinel") == true,
            "PDF export should include searchable text from later pages"
        )
    }

    private static func finish() {
        if failures.isEmpty {
            print("Monknot PDF export smoke tests passed")
        } else {
            for failure in failures {
                print("FAIL: \(failure)")
            }
            fatalError("Monknot PDF export smoke tests failed with \(failures.count) failure(s)")
        }
    }
}
