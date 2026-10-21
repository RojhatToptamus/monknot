import AppKit
import WebKit

/// Keys for the page in a window's web view, sent through AppKit as a keyboard would.
///
/// WebKit hands a page one key event at a time, each once the page has answered the one before,
/// while a script a test evaluates goes out at once. When the page is slow to answer (a CI runner),
/// a test that reads the page a moment after a key can read it before the key arrived. So the page
/// counts the key events it receives, and `send` returns once it has received the ones it sent.
@MainActor
struct PageKeyboard {
    let window: NSWindow
    /// The web view the keys are for, once there is one.
    let webView: () -> WKWebView?
    /// How long the run loop runs after the keys, for the work they start in the app.
    var settle: TimeInterval = 0.03

    func send(
        _ types: [NSEvent.EventType] = [.keyDown, .keyUp],
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false
    ) {
        // Keys reach the page only while its web view has the window's focus.
        let page = webView().flatMap { window.firstResponder === $0 ? $0 : nil }
        let received = page.flatMap { Self.receivedKeys(in: $0) }
        for type in types {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: isRepeat,
                keyCode: keyCode
            ) else { continue }
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        guard let page, let received else { return }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, (Self.receivedKeys(in: page) ?? .max) < received + types.count {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// How many key events the page has received since it was first asked.
    private static func receivedKeys(in page: WKWebView) -> Int? {
        let answer = Answer()
        page.evaluateJavaScript("""
        (window.monknotTestKeys ??= (() => {
          const keys = { count: 0 };
          for (const type of ["keydown", "keyup"]) window.addEventListener(type, () => { keys.count += 1; }, true);
          return keys;
        })()).count
        """) { value, _ in
            answer.value = value as? Int
            answer.isAnswered = true
        }
        let deadline = Date().addingTimeInterval(2)
        while !answer.isAnswered, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        return answer.value
    }

    @MainActor
    private final class Answer {
        var value: Int?
        var isAnswered = false
    }
}
