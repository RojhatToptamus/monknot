import Foundation
import MarkprevCore

@MainActor
final class MarkdownOutlineStore: ObservableObject {
    @Published private(set) var items: [MarkdownOutlineItem] = []

    private let parser = MarkdownOutlineParser()
    private var parseTask: Task<Void, Never>?
    private var generation = 0

    func update(markdown: String, isMarkdown: Bool) {
        generation += 1
        let token = generation
        parseTask?.cancel()

        guard isMarkdown else {
            items = []
            return
        }

        parseTask = Task { [parser] in
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                let worker = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return parser.parse(markdown)
                }
                let parsed = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard token == self.generation else { return }
                    self.items = parsed
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    guard token == self.generation else { return }
                    self.items = []
                }
            }
        }
    }

    deinit {
        parseTask?.cancel()
    }
}
