import Foundation
import MonknotCore

@MainActor
final class MarkdownLinkInspectionState: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var isLoading = false
    @Published private(set) var inspection: MarkdownLinkInspection?
    @Published private(set) var errorMessage: String?

    private let service: MarkdownLinkInspectionService
    private var task: Task<Void, Never>?
    private var generation = 0

    init(service: MarkdownLinkInspectionService = MarkdownLinkInspectionService()) {
        self.service = service
    }

    func present(
        document: WorkspaceDocument,
        workspaceRootURL: URL,
        documents: [WorkspaceDocument],
        textByDocumentID: [String: String]
    ) {
        guard document.kind == .markdown else { return }
        isPresented = true
        inspect(
            document: document,
            workspaceRootURL: workspaceRootURL,
            documents: documents,
            textByDocumentID: textByDocumentID,
            delayNanoseconds: 0
        )
    }

    func refresh(
        document: WorkspaceDocument,
        workspaceRootURL: URL,
        documents: [WorkspaceDocument],
        textByDocumentID: [String: String],
        debounce: Bool = true
    ) {
        guard isPresented else { return }
        inspect(
            document: document,
            workspaceRootURL: workspaceRootURL,
            documents: documents,
            textByDocumentID: textByDocumentID,
            delayNanoseconds: debounce ? 180_000_000 : 0
        )
    }

    func dismiss() {
        generation += 1
        task?.cancel()
        task = nil
        isPresented = false
        isLoading = false
        inspection = nil
        errorMessage = nil
    }

    private func inspect(
        document: WorkspaceDocument,
        workspaceRootURL: URL,
        documents: [WorkspaceDocument],
        textByDocumentID: [String: String],
        delayNanoseconds: UInt64
    ) {
        generation += 1
        let expectedGeneration = generation
        let documentSnapshot = document
        let workspaceSnapshot = workspaceRootURL
        let documentsSnapshot = documents
        let textSnapshot = textByDocumentID

        task?.cancel()
        inspection = nil
        errorMessage = nil
        isLoading = true
        task = Task { [service] in
            do {
                if delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
                let worker = Task.detached(priority: .utility) {
                    try service.inspect(
                        document: documentSnapshot,
                        workspaceRootURL: workspaceSnapshot,
                        documents: documentsSnapshot,
                        textByDocumentID: textSnapshot
                    )
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled,
                      expectedGeneration == generation,
                      isPresented,
                      result.documentID == documentSnapshot.id
                else { return }
                inspection = result
                isLoading = false
            } catch is CancellationError {
            } catch {
                guard expectedGeneration == generation, isPresented else { return }
                inspection = nil
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    deinit {
        task?.cancel()
    }
}
