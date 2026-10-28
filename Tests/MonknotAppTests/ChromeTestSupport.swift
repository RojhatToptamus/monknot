import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

/// A window that answers as the key and main window. A test process is never the active app (on a
/// Mac at a desk another app is in front, and CI's runner keeps it in the background too), so a plain
/// window there never becomes key; this one does, as the app's window does in use, for the key
/// handling, WebKit page focus and SwiftUI focus only a key window gets.
final class KeyTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// Delivers AppKit's own pending events (a window shown, moved or activated) as the app's event loop
/// would. A test process runs no event loop, so they wait in the queue, and a long run leaves hundreds
/// of them; input a test posts goes in behind them, where a lookup that does not wait misses it. Call
/// it before posting input.
@MainActor
func deliverPendingAppKitEvents() {
    while let event = NSApp.nextEvent(matching: .appKitDefined, until: .distantPast, inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
    }
}

/// A test that records an animation frame by frame runs where a Mac's display draws the frames. A CI
/// runner's virtual display drops some of them, and on some runs all of them, so there it skips.
func skipFrameByFrameRecordingOnCI() throws {
    try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] == "true", "Frame-by-frame motion is recorded on a Mac's display")
}

func interfaceScales(theme: AppTheme, zoomScale: Double) -> [CGFloat] {
    [
        theme.interfaceTextScale(zoomScale: zoomScale),
        theme.interfaceGlyphScale(zoomScale: zoomScale),
        theme.interfaceControlScale(zoomScale: zoomScale),
        theme.interfaceRowScale(zoomScale: zoomScale),
        theme.interfaceDensityScale(zoomScale: zoomScale),
    ]
}


extension NSView {
    func allDescendantsForTesting() -> [NSView] {
        subviews + subviews.flatMap { $0.allDescendantsForTesting() }
    }

    func isDescendantForTesting(of ancestor: NSView) -> Bool {
        var candidate: NSView? = self
        while let current = candidate {
            if current === ancestor { return true }
            candidate = current.superview
        }
        return false
    }

}

struct ChromeColumnOriginFixture: View {
    let chromeHeight: CGFloat

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ChromeOriginMarker(identifier: "sidebar")
                    .frame(maxWidth: .infinity)
                    .frame(height: chromeHeight)
                Spacer(minLength: 0)
            }
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
                .ignoresSafeArea(.container, edges: .top)

            VStack(spacing: 0) {
                ChromeOriginMarker(identifier: "detail")
                    .frame(maxWidth: .infinity)
                    .frame(height: chromeHeight)
                Spacer(minLength: 0)
            }
                .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .topLeading) {
            ChromeOriginMarker(identifier: "navigation")
                .frame(width: 160, height: chromeHeight)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct ChromeOriginMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier("Monknot.Test.Chrome.\(identifier)")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

func keyEvent(
    _ characters: String,
    modifiers: NSEvent.ModifierFlags
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    )!
}

final class StandardFrameWindowDelegate: NSObject, NSWindowDelegate {
    var standardFrameCallCount = 0

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        standardFrameCallCount += 1
        return newFrame.insetBy(dx: 12, dy: 12)
    }
}

final class WindowInteractionRecordingWindow: NSWindow {
    private(set) var dragCallCount = 0
    private(set) var zoomCallCount = 0

    override func performDrag(with event: NSEvent) {
        dragCallCount += 1
    }

    override func performZoom(_ sender: Any?) {
        zoomCallCount += 1
    }
}

func titleBarMouseEvent(clickCount: Int, windowNumber: Int) -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: NSPoint(x: 10, y: 10),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: clickCount,
        pressure: 1
    )!
}

func mouseEventForChromeTesting(
    type: NSEvent.EventType,
    location: NSPoint,
    windowNumber: Int
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    )
}

final class TopBarActionRecorder {
    var terminalToggleCount = 0
}
