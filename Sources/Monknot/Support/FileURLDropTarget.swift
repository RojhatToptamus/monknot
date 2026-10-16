import AppKit
import SwiftUI

/// A drop target for file URLs. `operation` names what a drop of the dragged URLs does, so the
/// drag cursor shows it, and `handleURLs` receives the URLs with that operation.
struct FileURLDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let operation: ([URL]) -> NSDragOperation
    let handleURLs: ([URL], NSDragOperation) -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.coordinator = context.coordinator
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        context.coordinator.isTargeted = $isTargeted
        context.coordinator.operation = operation
        context.coordinator.handleURLs = handleURLs
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isTargeted: $isTargeted, operation: operation, handleURLs: handleURLs)
    }

    final class Coordinator {
        var isTargeted: Binding<Bool>
        var operation: ([URL]) -> NSDragOperation
        var handleURLs: ([URL], NSDragOperation) -> Void

        init(
            isTargeted: Binding<Bool>,
            operation: @escaping ([URL]) -> NSDragOperation,
            handleURLs: @escaping ([URL], NSDragOperation) -> Void
        ) {
            self.isTargeted = isTargeted
            self.operation = operation
            self.handleURLs = handleURLs
        }
    }

    final class DropView: NSView {
        weak var coordinator: Coordinator?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let operation = proposedOperation(for: sender)
            guard !operation.isEmpty else { return [] }
            coordinator?.isTargeted.wrappedValue = true
            return operation
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            proposedOperation(for: sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            coordinator?.isTargeted.wrappedValue = false
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            !fileURLs(from: sender).isEmpty
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = fileURLs(from: sender)
            guard !urls.isEmpty, let coordinator else { return false }

            coordinator.handleURLs(urls, coordinator.operation(urls))
            return true
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            coordinator?.isTargeted.wrappedValue = false
        }

        private func proposedOperation(for sender: NSDraggingInfo) -> NSDragOperation {
            let urls = fileURLs(from: sender)
            guard !urls.isEmpty, let coordinator else { return [] }
            return coordinator.operation(urls)
        }

        private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
            sender.draggingPasteboard.fileURLs
        }
    }
}

extension NSPasteboard {
    /// The file URLs on the pasteboard, in order; empty when it holds none.
    var fileURLs: [URL] {
        readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
