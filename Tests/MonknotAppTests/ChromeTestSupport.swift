import AppKit
import MonknotCore
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

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
