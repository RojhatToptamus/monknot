import AppKit
import MonknotCore
import PDFKit
import SwiftUI

struct KeyboardShortcutMonitor: NSViewRepresentable {
    var handler: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: handler)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
        context.coordinator.install(from: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var handler: (NSEvent) -> Bool
        private var monitor: Any?
        private weak var view: NSView?

        init(handler: @escaping (NSEvent) -> Bool) {
            self.handler = handler
        }

        deinit {
            uninstall()
        }

        func install(from view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      event.window === self.view?.window,
                      self.view?.window?.isKeyWindow == true
                else {
                    return event
                }

                if MonknotNativePDFZoomCommand.performIfFocused(for: event) {
                    return nil
                }

                guard self.handler(event) else { return event }
                return nil
            }
        }

        func uninstall() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// Routes standard zoom keys to PDFKit only while a PDF view owns keyboard
/// focus. Other surfaces continue through Monknot's application-zoom command
/// path, keeping viewer scale and interface scale independent.
enum MonknotNativePDFZoomCommand {
    enum Action: Equatable {
        case zoomIn
        case zoomOut
        case actualSize
    }

    static func action(for event: NSEvent) -> Action? {
        let modifiers = event.modifierFlags.independentFlags
        guard modifiers.contains(.command),
              !modifiers.contains(.option),
              !modifiers.contains(.control)
        else {
            return nil
        }

        switch event.charactersIgnoringModifiers {
        case "=", "+":
            return .zoomIn
        case "-":
            return .zoomOut
        case "0":
            return .actualSize
        default:
            return nil
        }
    }

    @discardableResult
    static func performIfFocused(for event: NSEvent) -> Bool {
        guard let action = action(for: event) else { return false }
        return performIfFocused(action, in: event.window)
    }

    @discardableResult
    static func performIfFocused(_ action: Action, in window: NSWindow? = NSApp.keyWindow) -> Bool {
        guard let pdfView = focusedPDFView(in: window) else { return false }

        switch action {
        case .zoomIn:
            applyPDFZoomCommand(.zoomIn, to: pdfView)
        case .zoomOut:
            applyPDFZoomCommand(.zoomOut, to: pdfView)
        case .actualSize:
            applyPDFZoomCommand(.actualSize, to: pdfView)
        }
        return true
    }

    private static func focusedPDFView(in window: NSWindow?) -> PDFView? {
        var responder = window?.firstResponder
        while let current = responder {
            if let pdfView = current as? PDFView {
                return pdfView
            }
            if let view = current as? NSView,
               let pdfView = enclosingPDFView(for: view) {
                return pdfView
            }
            responder = current.nextResponder
        }
        return nil
    }

    private static func enclosingPDFView(for view: NSView) -> PDFView? {
        var current: NSView? = view
        while let candidate = current {
            if let pdfView = candidate as? PDFView {
                return pdfView
            }
            current = candidate.superview
        }
        return nil
    }
}

extension NSEvent.ModifierFlags {
    var independentFlags: NSEvent.ModifierFlags {
        intersection(.deviceIndependentFlagsMask)
    }

    var monknotKeyboardShortcutModifiers: MonknotKeyboardShortcutModifiers {
        var modifiers: MonknotKeyboardShortcutModifiers = []

        if contains(.command) {
            modifiers.insert(.command)
        }
        if contains(.shift) {
            modifiers.insert(.shift)
        }
        if contains(.option) {
            modifiers.insert(.option)
        }
        if contains(.control) {
            modifiers.insert(.control)
        }

        return modifiers
    }
}

extension NSEvent {
    var monknotKeyboardShortcutEvent: MonknotKeyboardShortcutEvent? {
        let key = charactersIgnoringModifiers ?? ""
        guard !key.isEmpty || keyCode == MonknotKeyboardShortcutRouter.escapeKeyCode else { return nil }

        return MonknotKeyboardShortcutEvent(
            key: key,
            modifiers: modifierFlags.independentFlags.monknotKeyboardShortcutModifiers,
            keyCode: keyCode
        )
    }

}

enum MonknotNativePasteboardCommand {
    static var hasNativeEditingFocus: Bool {
        guard let target = NSApp.keyWindow?.firstResponder else { return false }
        return monknotIsNativeTextTarget(target)
    }

    static func performCopyIfAvailable() -> Bool {
        perform(#selector(NSText.copy(_:)), ifTargetMatches: monknotCanNativeCopyTargetHandleCopy(_:))
    }

    static func performPasteIfAvailable() -> Bool {
        perform(#selector(NSText.paste(_:)), ifTargetMatches: monknotIsNativeTextTarget(_:))
    }

    static func performCutIfAvailable() -> Bool {
        perform(#selector(NSText.cut(_:)), ifTargetMatches: monknotCanNativeCutTargetHandleCut(_:))
    }

    static func performSelectAllIfAvailable() -> Bool {
        perform(#selector(NSText.selectAll(_:)), ifTargetMatches: monknotIsNativeTextTarget(_:))
    }

    private static func perform(
        _ action: Selector,
        ifTargetMatches predicate: (Any) -> Bool
    ) -> Bool {
        guard let target = NSApp.target(forAction: action, to: nil, from: nil),
              predicate(target)
        else {
            return false
        }

        return NSApp.sendAction(action, to: nil, from: nil)
    }

    private static func monknotCanNativeCopyTargetHandleCopy(_ target: Any) -> Bool {
        if let textView = target as? NSTextView {
            if textView.isFieldEditor {
                return true
            }

            return textView.selectedRanges.contains { $0.rangeValue.length > 0 }
        }

        return monknotIsNativeTextTarget(target)
    }

    private static func monknotCanNativeCutTargetHandleCut(_ target: Any) -> Bool {
        if let textView = target as? NSTextView {
            if textView.isFieldEditor {
                return true
            }

            return textView.isEditable && textView.selectedRanges.contains { $0.rangeValue.length > 0 }
        }

        return monknotIsNativeTextTarget(target)
    }

    private static func monknotIsNativeTextTarget(_ target: Any) -> Bool {
        if target is NSTextView || target is NSTextField {
            return true
        }

        let targetTypeName = String(describing: Swift.type(of: target))
        return targetTypeName.hasPrefix("WK") || targetTypeName.contains("WKContent")
    }
}

enum MonknotNativeUndoCommand {
    static var canUndo: Bool { currentUndoManager?.canUndo == true }
    static var canRedo: Bool { currentUndoManager?.canRedo == true }

    static func performUndoIfAvailable() -> Bool {
        guard let undoManager = currentUndoManager, undoManager.canUndo else { return false }
        undoManager.undo()
        return true
    }

    static func performRedoIfAvailable() -> Bool {
        guard let undoManager = currentUndoManager, undoManager.canRedo else { return false }
        undoManager.redo()
        return true
    }

    private static var currentUndoManager: UndoManager? {
        NSApp.keyWindow?.firstResponder?.undoManager ?? NSApp.keyWindow?.undoManager
    }
}
