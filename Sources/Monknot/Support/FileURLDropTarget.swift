import AppKit
import SwiftUI

struct FileURLDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let handleURLs: ([URL]) -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.coordinator = context.coordinator
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        context.coordinator.isTargeted = $isTargeted
        context.coordinator.handleURLs = handleURLs
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isTargeted: $isTargeted, handleURLs: handleURLs)
    }

    final class Coordinator {
        var isTargeted: Binding<Bool>
        var handleURLs: ([URL]) -> Void

        init(isTargeted: Binding<Bool>, handleURLs: @escaping ([URL]) -> Void) {
            self.isTargeted = isTargeted
            self.handleURLs = handleURLs
        }
    }

    final class DropView: NSView {
        weak var coordinator: Coordinator?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard fileURLs(from: sender).isEmpty == false else { return [] }
            coordinator?.isTargeted.wrappedValue = true
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            fileURLs(from: sender).isEmpty ? [] : .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            coordinator?.isTargeted.wrappedValue = false
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            !fileURLs(from: sender).isEmpty
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = fileURLs(from: sender)
            guard !urls.isEmpty else { return false }

            coordinator?.handleURLs(urls)
            return true
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            coordinator?.isTargeted.wrappedValue = false
        }

        private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
            let objects = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) ?? []

            return objects.compactMap { object in
                if let url = object as? URL {
                    return url
                }
                if let url = object as? NSURL {
                    return url as URL
                }
                return nil
            }
        }
    }
}
