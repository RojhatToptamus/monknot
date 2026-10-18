import AppKit
import CoreGraphics
import MonknotCore
import Sparkle
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

/// Captures the whole workspace window in the states a design review walks through: sidebar open
/// and collapsed, the terminal, Source and Preview, light and dark, narrow and wide. Runs only when
/// `MONKNOT_UI_TOUR_DIR` names a folder for the images; it asserts nothing about pixels.
@MainActor
final class WorkspaceUITourTests: WorkspaceStoreTestCase {
    private struct Stop {
        let name: String
        var theme: ThemePreference = .light
        var mode: EditorMode = .preview
        var layout = ContentView.InitialLayout.standard
        var size = NSSize(width: 1_300, height: 820)
        var document = "Product brief.md"
        /// Documents opened in tabs before `document`, left to right.
        var tabs: [String] = []
        var opensWorkspace = true
    }

    func testCaptureTheWorkspaceInEveryLayoutState() async throws {
        guard let output = ProcessInfo.processInfo.environment["MONKNOT_UI_TOUR_DIR"] else {
            throw XCTSkip("Set MONKNOT_UI_TOUR_DIR to capture the workspace UI tour")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = try makeFixtureWorkspace()

        let only = ProcessInfo.processInfo.environment["MONKNOT_UI_TOUR_ONLY"]
        let stops: [Stop] = [
            Stop(name: "01-preview-light"),
            Stop(name: "02-preview-light-no-sidebar", layout: .init(showsSidebar: false, showsTerminal: false)),
            Stop(name: "03-preview-light-terminal", layout: .init(showsSidebar: true, showsTerminal: true)),
            Stop(name: "04-preview-light-narrow", size: NSSize(width: 900, height: 700)),
            Stop(name: "05-preview-light-wide", size: NSSize(width: 1_720, height: 1_000)),
            Stop(name: "06-source-light", mode: .source),
            Stop(name: "07-preview-dark", theme: .dark),
            Stop(name: "08-preview-dark-no-sidebar", theme: .dark, layout: .init(showsSidebar: false, showsTerminal: false)),
            Stop(name: "09-source-dark-terminal", theme: .dark, mode: .source, layout: .init(showsSidebar: true, showsTerminal: true)),
            Stop(name: "10-text-light", document: "todo.txt"),
            Stop(name: "11-tabs-light", tabs: ["Roadmap.md", "Notes/Meeting notes.md", "todo.txt"]),
            Stop(name: "12-tabs-dark", theme: .dark, tabs: ["Roadmap.md", "Notes/Meeting notes.md", "config.json"]),
            Stop(name: "13-no-workspace-light", opensWorkspace: false),
            Stop(name: "14-no-workspace-dark", theme: .dark, opensWorkspace: false),
        ]
        let filters = only?.split(separator: "|").map(String.init)
        for theme in [ThemePreference.light, .dark] where filters == nil || filters!.contains(where: { "15-settings-\(theme.rawValue)".contains($0) }) {
            try await captureSettings(theme: theme, into: directory)
        }
        for stop in stops where filters == nil || filters!.contains(where: { stop.name.contains($0) }) {
            try await capture(stop, root: root, into: directory)
        }
    }

    private func capture(_ stop: Stop, root: URL, into directory: URL) async throws {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: "Monknot.editorMode")
        let savedTheme = defaults.object(forKey: "Monknot.themePreference")
        defer {
            defaults.set(savedMode, forKey: "Monknot.editorMode")
            defaults.set(savedTheme, forKey: "Monknot.themePreference")
        }
        defaults.set(stop.mode.rawValue, forKey: "Monknot.editorMode")
        defaults.set(stop.theme.rawValue, forKey: "Monknot.themePreference")

        let store = makeWorkspaceStore()
        let library = WorkspaceLibraryStore(userDefaults: UserDefaults(suiteName: "MonknotUITour.\(UUID().uuidString)")!)
        let host = NSHostingView(rootView: ContentView(
            store: store,
            themeStore: ThemeSettingsStore(defaults: defaults),
            workspaceLibrary: library,
            terminationCoordinator: ApplicationTerminationCoordinator(),
            initialLayout: stop.layout
        ))
        let window = TourWindow(
            contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: stop.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        if stop.opensWorkspace {
            let first = stop.tabs.first ?? stop.document
            store.openWorkspace(root, selecting: root.appendingPathComponent(first))
            let opened = await waitUntil(timeout: 10) { !store.isBusy && !store.isDocumentLoading && store.selectedDocument != nil }
            XCTAssertTrue(opened, stop.name)
            for path in stop.tabs.dropFirst() + [stop.document] {
                try await Task.sleep(nanoseconds: 300_000_000)
                _ = store.selectDocument(id: root.appendingPathComponent(path).standardizedFileURL.path)
            }
            let loaded = await waitUntil(timeout: 10) {
                !store.isBusy && store.selectedDocument?.url.lastPathComponent == (stop.document as NSString).lastPathComponent && !store.isDocumentLoading
            }
            XCTAssertTrue(loaded, stop.name)
        }
        try await Task.sleep(nanoseconds: 1_800_000_000)

        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            XCTFail("Could not capture \(stop.name)")
            return
        }
        // A window behind the app in front has no WebKit tiles in its image; WebKit's own snapshot
        // is drawn over each web view's frame instead.
        let scale = CGFloat(image.width) / window.frame.width
        let composite = NSImage(size: NSSize(width: image.width, height: image.height))
        composite.lockFocus()
        NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for webView in Self.descendants(of: WKWebView.self, in: host) where !webView.isHiddenOrHasHiddenAncestor && webView.bounds.width > 0 {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            guard let snapshot = try? await webView.takeSnapshot(configuration: configuration) else { continue }
            let frame = webView.convert(webView.bounds, to: nil)
            NSGraphicsContext.saveGraphicsState()
            // A web view inside a card is clipped by the card's rounded corners, as on screen.
            if let card = Self.ancestor(of: WorkspaceCardView.self, from: webView) {
                let cardFrame = card.convert(card.bounds, to: nil)
                let scaledFrame = CGRect(x: cardFrame.minX * scale, y: cardFrame.minY * scale, width: cardFrame.width * scale, height: cardFrame.height * scale)
                NSBezierPath(roundedRect: scaledFrame, xRadius: card.cornerRadius * scale, yRadius: card.cornerRadius * scale).addClip()
            }
            snapshot.draw(in: CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale))
            NSGraphicsContext.restoreGraphicsState()
            // The card's ring draws over its content on screen; draw it again over the snapshot.
            if let card = Self.ancestor(of: WorkspaceCardView.self, from: webView), let ring = card.layer?.borderColor, let color = NSColor(cgColor: ring) {
                let cardFrame = card.convert(card.bounds, to: nil)
                let inset = CGRect(x: cardFrame.minX * scale, y: cardFrame.minY * scale, width: cardFrame.width * scale, height: cardFrame.height * scale).insetBy(dx: scale / 2, dy: scale / 2)
                let path = NSBezierPath(roundedRect: inset, xRadius: card.cornerRadius * scale, yRadius: card.cornerRadius * scale)
                path.lineWidth = scale
                color.setStroke()
                path.stroke()
            }
        }
        composite.unlockFocus()
        guard let tiff = composite.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return }
        try bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?
            .write(to: directory.appendingPathComponent("\(stop.name).png"))
    }

    private func captureSettings(theme: ThemePreference, into directory: URL) async throws {
        let defaults = UserDefaults.standard
        let savedTheme = defaults.object(forKey: "Monknot.themePreference")
        defer { defaults.set(savedTheme, forKey: "Monknot.themePreference") }
        defaults.set(theme.rawValue, forKey: "Monknot.themePreference")
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        defer { withExtendedLifetime(updater) {} }
        let host = NSHostingView(rootView: PreferencesView(
            themeStore: ThemeSettingsStore(defaults: defaults),
            workspaceLibrary: WorkspaceLibraryStore(userDefaults: UserDefaults(suiteName: "MonknotUITour.\(UUID().uuidString)")!),
            updater: updater.updater
        ))
        let size = host.fittingSize
        let window = TourWindow(
            contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: NSSize(width: max(600, size.width), height: max(560, size.height))),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: NSBitmapImageRep.FileType.png, properties: [:])?
            .write(to: directory.appendingPathComponent("15-settings-\(theme.rawValue).png"))
    }

    private func makeFixtureWorkspace() throws -> URL {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "Field notes")
        for (path, text) in [
            ("Product brief.md", Self.brief),
            ("Roadmap.md", "# Roadmap\n\n- [ ] Ship the editor\n- [ ] Write the docs\n"),
            ("Notes/Meeting notes.md", "# Meeting notes\n\nDecisions and follow-ups.\n"),
            ("Notes/Ideas.md", "# Ideas\n\nA list of ideas.\n"),
            ("Projects/Spec.md", "# Spec\n\nThe specification.\n"),
            ("Projects/Research/Sources.md", "# Sources\n"),
            ("todo.txt", "buy milk\ncall the printer\nrenew the domain\n"),
            ("config.json", "{ \"theme\": \"light\" }\n"),
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private static func ancestor<T: NSView>(of type: T.Type, from view: NSView) -> T? {
        var current = view.superview
        while let candidate = current {
            if let match = candidate as? T { return match }
            current = candidate.superview
        }
        return nil
    }

    private static func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let match = view as? T { result.append(match) }
        for subview in view.subviews { result += descendants(of: type, in: subview) }
        return result
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private static let brief = """
    # Product brief

    Monknot keeps **notes** as plain *Markdown* files with `inline code`, [links](https://monki.work)
    and a [[Roadmap]] link.

    ## Goals

    - [ ] Draft the outline
    - [x] Collect feedback from the design review
    - Ship a calm, fast editor
      - Nested detail

    1. First step
    2. Second step

    > [!TIP]
    > Callouts keep **any** Markdown.

    | Area | Owner |
    | --- | --- |
    | Editor | Ada |
    | Docs | Lin |

    ```swift
    let answer = 42
    ```

    ## Notes

    Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore
    et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut
    aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse.

    ### Details

    Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium doloremque laudantium,
    totam rem aperiam, eaque ipsa quae ab illo inventore veritatis et quasi architecto beatae vitae.

    """
}

/// A test window that counts as the key and main window although the test process cannot take focus
/// from the app in front.
private final class TourWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
