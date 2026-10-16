import Foundation
import MonknotCore

/// Line and word counts shown in the Markdown formatting toolbar.
struct MarkdownTextStatistics: Equatable, Sendable {
    let lineCount: Int
    let wordCount: Int

    init(lineCount: Int, wordCount: Int) {
        self.lineCount = lineCount
        self.wordCount = wordCount
    }

    init(text: String) {
        // Count breaks on UTF-8 bytes ("\r\n" is a single Character and never equals "\n"):
        // LF, CRLF and a lone CR each end one line.
        var lineFeeds = 0
        var carriageReturns = 0
        var crlfPairs = 0
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                lineFeeds += 1
                if previous == 0x0D { crlfPairs += 1 }
            } else if byte == 0x0D {
                carriageReturns += 1
            }
            previous = byte
        }
        lineCount = 1 + lineFeeds + carriageReturns - crlfPairs
        wordCount = text.split { $0.isWhitespace || $0.isPunctuation }.count
    }
}

/// Derives the active Markdown document's outline and statistics off the main actor, debounced and
/// cancelled as the text changes, so typing and scrolling never wait for either.
@MainActor
final class MarkdownOutlineStore: ObservableObject {
    @Published private(set) var items: [MarkdownOutlineItem] = []
    @Published private(set) var statistics: MarkdownTextStatistics?

    private let parser = MarkdownOutlineParser()
    private var parseTask: Task<Void, Never>?
    private var generation = 0
    private var documentID: String?

    func update(markdown: String, isMarkdown: Bool, documentID: String? = nil) {
        generation += 1
        let token = generation
        parseTask?.cancel()

        if documentID != self.documentID {
            self.documentID = documentID
            // Never show the previous document's counts while the new ones are computed.
            if statistics != nil { statistics = nil }
        }

        guard isMarkdown else {
            if !items.isEmpty { items = [] }
            if statistics != nil { statistics = nil }
            return
        }

        parseTask = Task { [parser] in
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                let worker = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    let parsed = parser.parse(markdown)
                    try Task.checkCancellation()
                    return (parsed, MarkdownTextStatistics(text: markdown))
                }
                let (parsed, statistics) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard token == self.generation else { return }
                    if self.items != parsed { self.items = parsed }
                    if self.statistics != statistics { self.statistics = statistics }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    guard token == self.generation else { return }
                    if !self.items.isEmpty { self.items = [] }
                    if self.statistics != nil { self.statistics = nil }
                }
            }
        }
    }

    deinit {
        parseTask?.cancel()
    }
}
