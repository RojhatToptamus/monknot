import AppKit
import MonknotCore
import SwiftUI

struct KeyboardShortcutMonitor: NSViewRepresentable {
    var handler: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: handler)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
        context.coordinator.install()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var handler: (NSEvent) -> Bool
        private var monitor: Any?

        init(handler: @escaping (NSEvent) -> Bool) {
            self.handler = handler
        }

        deinit {
            uninstall()
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard self?.handler(event) == true else { return event }
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
    static func performCopyIfAvailable() -> Bool {
        perform(#selector(NSText.copy(_:)), ifTargetMatches: monknotCanNativeCopyTargetHandleCopy(_:))
    }

    static func performPasteIfAvailable() -> Bool {
        perform(#selector(NSText.paste(_:)), ifTargetMatches: monknotIsNativeTextTarget(_:))
    }

    static func performCutIfAvailable() -> Bool {
        perform(#selector(NSText.cut(_:)), ifTargetMatches: monknotCanNativeCutTargetHandleCut(_:))
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
