import AppKit
import CoreGraphics
import MonknotCore
import PDFKit
import Sparkle
import SwiftUI
import WebKit
import XCTest
@testable import MonknotApp

/// Captures the whole workspace window in the states a design review walks through: sidebar open
/// and collapsed, the terminal, Source and Preview, light and dark, narrow and wide. Runs only when
/// `MONKNOT_UI_TOUR_DIR` names a folder for the images; it asserts nothing about pixels.
/// `MONKNOT_UI_TOUR_ZOOM` (0.8…2) takes the whole tour at one workspace zoom.
@MainActor
final class WorkspaceUITourTests: WorkspaceStoreTestCase {
    /// What a stop does once its document shows, before the capture.
    private typealias Prepare = @MainActor (_ host: NSView, _ window: NSWindow, _ store: WorkspaceStore) async throws -> Void

    private struct Stop {
        var name: String
        var theme: ThemePreference = .light
        var mode: EditorMode = .preview
        var layout = ContentView.InitialLayout.standard
        var size = NSSize(width: 1_300, height: 820)
        var document = "Product brief.md"
        /// Documents opened in tabs before `document`, left to right.
        var tabs: [String] = []
        var opensWorkspace = true
        /// A catalog theme for the stop's appearance; nil keeps the default (Harbor).
        var themeID: String?
        /// Leaves the shown document edited and unsaved, so its tab shows the unsaved dot.
        var edits = false
        /// A workspace zoom for this stop alone.
        var zoom: Double?
        /// Draws the close, minimize and zoom buttons in their active colours, which a test process,
        /// never the active app, does not show.
        var activeWindowControls = false
        /// Shows `document` with Source beside Preview.
        var splitView = false
        var prepare: Prepare?

        /// This stop under another name, showing `document` after `tabs` in `layout`, with split view
        /// and `prepare` as given.
        func named(_ name: String, layout: ContentView.InitialLayout? = nil, document: String? = nil, tabs: [String] = [], splitView: Bool = false, prepare: Prepare? = nil) -> Stop {
            var stop = self
            stop.name = name
            stop.layout = layout ?? self.layout
            stop.document = document ?? self.document
            stop.tabs = tabs
            stop.splitView = splitView
            stop.prepare = prepare
            return stop
        }
    }

    func testCaptureTheWorkspaceInEveryLayoutState() async throws {
        guard let output = ProcessInfo.processInfo.environment["MONKNOT_UI_TOUR_DIR"] else {
            throw XCTSkip("Set MONKNOT_UI_TOUR_DIR to capture the workspace UI tour")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = try makeFixtureWorkspace()
        // `MONKNOT_UI_TOUR_ZOOM` takes every stop, Settings included, at that workspace zoom.
        let zoomKey = "Monknot.zoomScale"
        let savedZoom = UserDefaults.standard.object(forKey: zoomKey)
        defer { UserDefaults.standard.set(savedZoom, forKey: zoomKey) }
        if let zoom = ProcessInfo.processInfo.environment["MONKNOT_UI_TOUR_ZOOM"].flatMap(Double.init) {
            UserDefaults.standard.set(WorkspaceZoomPolicy.clamp(zoom), forKey: zoomKey)
        }

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
            Stop(name: "16-latte-terminal", layout: .init(showsSidebar: true, showsTerminal: true), tabs: ["Roadmap.md", "Notes/Meeting notes.md"], themeID: "catppuccin-latte"),
            Stop(name: "17-mocha-terminal", theme: .dark, layout: .init(showsSidebar: true, showsTerminal: true), tabs: ["Roadmap.md", "Notes/Meeting notes.md"], themeID: "catppuccin-mocha"),
            Stop(name: "18-latte-source", mode: .source, themeID: "catppuccin-latte"),
            // Overlays over Source: the tour draws WebKit's own snapshot over a web view, which would
            // cover an overlay above it.
            Stop(name: "19-quick-open-light", mode: .source, layout: .init(overlay: .quickOpen)),
            Stop(name: "20-quick-open-dark", theme: .dark, mode: .source, layout: .init(overlay: .quickOpen)),
            Stop(name: "21-find-light", layout: .init(overlay: .documentSearch("Markdown"))),
            Stop(name: "22-find-dark", theme: .dark, mode: .source, layout: .init(overlay: .documentSearch("Markdown"))),
            Stop(name: "23-workspace-search-light", layout: .init(overlay: .workspaceSearch("step"))),
            Stop(name: "24-workspace-search-dark", theme: .dark, layout: .init(overlay: .workspaceSearch("step"))),
            Stop(name: "25-shortcuts-light", mode: .source, layout: .init(overlay: .keyboardShortcuts)),
            Stop(name: "26-pdf-latte", layout: .init(overlay: .pdfNavigator), document: "Pitch deck.pdf", tabs: ["Product brief.md"], themeID: "catppuccin-latte"),
            Stop(name: "27-pdf-mocha", theme: .dark, layout: .init(overlay: .pdfNavigator), document: "Pitch deck.pdf", tabs: ["Product brief.md"], themeID: "catppuccin-mocha"),
            Stop(name: "28-pdf-narrow", layout: .init(showsSidebar: true, showsTerminal: true), size: NSSize(width: 1_000, height: 720), document: "Pitch deck.pdf"),
            Stop(name: "29-image-light", document: "Photo.png"),
            Stop(name: "30-switcher-latte", layout: .init(overlay: .workspaceSwitcher), themeID: "catppuccin-latte"),
            Stop(name: "31-switcher-mocha", theme: .dark, layout: .init(overlay: .workspaceSwitcher), themeID: "catppuccin-mocha"),
            Stop(name: "32-dirty-tab-latte", tabs: ["Roadmap.md", "todo.txt"], themeID: "catppuccin-latte", edits: true),
            Stop(name: "33-long-preview-latte", layout: .init(showsSidebar: true, showsTerminal: true), document: "Long notes.md", themeID: "catppuccin-latte"),
            Stop(name: "34-long-source-latte", mode: .source, layout: .init(showsSidebar: true, showsTerminal: true), document: "Long notes.md", themeID: "catppuccin-latte"),
            // A long outline in a full-height card: the rail stays a bounded column (design.md §10.5).
            Stop(name: "35-long-preview-mocha", theme: .dark, document: "Long notes.md", themeID: "catppuccin-mocha"),
        ]
        let filters = only?.split(separator: "|").map(String.init)
        let settingsStops: [(section: String, theme: ThemePreference)] = [
            ("General", .light), ("General", .dark), ("Appearance", .light), ("Appearance", .dark),
            ("Editor", .light), ("Export", .light), ("Shortcuts", .dark), ("Workspaces", .light),
        ]
        for (section, theme) in settingsStops {
            let name = "15-settings-\(section.lowercased())-\(theme.rawValue)"
            guard filters == nil || filters!.contains(where: { name.contains($0) }) else { continue }
            try await captureSettings(section: section, theme: theme, name: name, into: directory)
        }
        for stop in stops where filters == nil || filters!.contains(where: { stop.name.contains($0) }) {
            try await capture(stop, root: root, into: directory)
        }
    }

    /// Takes the README's pictures (docs/images) in Harbor light from the Borealis workspace, each set
    /// on the README's backdrop. Runs only when `MONKNOT_README_SHOTS_DIR` names a folder for them;
    /// `MONKNOT_UI_TOUR_ONLY` picks pictures by name.
    func testCaptureTheReadmeImages() async throws {
        let directory = try Self.outputDirectory(named: "MONKNOT_README_SHOTS_DIR")
        let root = try await makeBorealisWorkspace()
        let size = NSSize(width: 1_240, height: 780)
        let stops: [Stop] = [
            Stop(name: "monknot-pdf", size: size, document: "Field-note.pdf", tabs: ["README.md"], zoom: 1.15, activeWindowControls: true),
            Stop(name: "monknot-terminal", layout: .init(showsSidebar: false, showsTerminal: true), size: size, document: "README.md", tabs: ["checklist.md"], zoom: 1.15, activeWindowControls: true, prepare: Self.runTerminal),
            Stop(name: "monknot-workspace", size: size, document: "README.md", tabs: ["notes/route-plan.md"], zoom: 1.15, activeWindowControls: true, prepare: Self.openBlockMenu),
        ]
        for stop in Self.picked(stops) {
            try await capture(stop, root: root, into: directory)
            try Self.setOnReadmeBackdrop(directory.appendingPathComponent("\(stop.name).png"))
        }
    }

    /// Takes the website's product shots (website/shots) in Harbor light and dark from the Borealis
    /// workspace, each filling the laptop's screen: a window of a 14-inch MacBook Pro's default 1512
    /// by 982 points, saved at the page's 1600 by 1039. The social card is the dark editor's top. Runs
    /// only when `MONKNOT_WEBSITE_SHOTS_DIR` names a folder for them; `MONKNOT_UI_TOUR_ONLY` picks
    /// shots by name.
    func testCaptureTheWebsiteImages() async throws {
        let directory = try Self.outputDirectory(named: "MONKNOT_WEBSITE_SHOTS_DIR")
        let root = try await makeBorealisWorkspace()
        var stops: [Stop] = []
        for (theme, name) in [(ThemePreference.light, "light"), (.dark, "dark")] {
            let screen = Stop(name: "", theme: theme, size: Self.laptopScreen, document: "README.md", zoom: 1.15, activeWindowControls: true)
            stops += [
                screen.named("editor-\(name)", tabs: ["notes/route-plan.md"], prepare: Self.openBlockMenu),
                screen.named("split-\(name)", tabs: ["notes/route-plan.md"], splitView: true),
                screen.named("preview-\(name)", layout: .init(showsSidebar: false, showsTerminal: false), document: "notes/route-plan.md", tabs: ["README.md"], prepare: { host, window, store in
                    try await Self.selectInPreview("every two hours", host: host, window: window, store: store)
                }),
                screen.named("pdf-\(name)", document: "Field-note.pdf", tabs: ["README.md"]),
                screen.named("terminal-\(name)", layout: .init(showsSidebar: true, showsTerminal: true), tabs: ["checklist.md"], prepare: Self.runTerminal),
            ]
        }
        for stop in Self.picked(stops) {
            try await capture(stop, root: root, into: directory)
            let picture = directory.appendingPathComponent("\(stop.name).png")
            if stop.name == "editor-dark" {
                try Self.writeImage(
                    try Self.screenImage(of: Self.image(at: picture), size: CGSize(width: 1_200, height: 630)),
                    to: directory.appendingPathComponent("monknot-social.jpg")
                )
            }
            try Self.writeImage(
                try Self.screenImage(of: Self.image(at: picture), size: Self.screenShotSize),
                to: directory.appendingPathComponent("\(stop.name).jpg")
            )
            try FileManager.default.removeItem(at: picture)
        }
    }

    /// Records writing assistance in Source on a plain-text note, in Harbor dark and light, with the
    /// system's spell checker and Apple's on-device model as the app uses them: a sentence's typos and
    /// grammar slip offered as one repair for review and taken with Tab, a completion taken whole by
    /// holding Tab, then Writing Tools. Each frame fills the laptop's screen like the
    /// website's shots; `writing-assistance[-light]/` holds the frames and `frames.json`, each frame's
    /// delay and the frames where each step shows, for the website's GIFs and posters. Runs only when
    /// `MONKNOT_WEBSITE_SHOTS_DIR` names a folder, on a Mac where the model is available.
    func testRecordTheWritingAssistanceDemos() async throws {
        let directory = try Self.outputDirectory(named: "MONKNOT_WEBSITE_SHOTS_DIR")
        guard FlowSentenceRepairService.system.isAvailable(for: Locale(identifier: "en_US")) else {
            throw XCTSkip("Apple's on-device model is not available on this Mac")
        }
        let root = try await makeBorealisWorkspace()
        // A title line keeps Writing Tools' panel, which opens beside the caret's line, inside the window.
        try "Field brief, day two\n\n".write(to: root.appendingPathComponent("Field-brief.txt"), atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let settings: [String: Any] = [
            EditorTextCheckingOptions.spellingPreferenceKey: true,
            EditorTextCheckingOptions.grammarPreferenceKey: true,
            EditorTextCheckingOptions.inlinePredictionsPreferenceKey: true,
            EditorTextCheckingOptions.onDeviceProseCompletionsPreferenceKey: true,
        ]
        let saved = settings.keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        for (key, value) in settings { defaults.set(value, forKey: key) }

        for (theme, name) in [(ThemePreference.dark, "writing-assistance"), (.light, "writing-assistance-light")] {
            guard Self.picked([Stop(name: name)]).isEmpty == false else { continue }
            let frames = directory.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.removeItem(at: frames)
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            let stop = Stop(name: name, theme: theme, mode: .source, size: Self.laptopScreen, document: "Field-brief.txt", tabs: ["research/weather-window.md"], zoom: 1.4, activeWindowControls: true, prepare: { host, window, _ in
                try await self.recordWritingAssistance(into: frames, host: host, window: window)
            })
            try await capture(stop, root: root, into: frames)
            try? FileManager.default.removeItem(at: frames.appendingPathComponent("\(name).png"))
        }
    }

    private func capture(_ stop: Stop, root: URL, into directory: URL) async throws {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: "Monknot.editorMode")
        let savedTheme = defaults.object(forKey: "Monknot.themePreference")
        let themeIDKey = stop.theme == .dark ? "Monknot.darkThemeID" : "Monknot.lightThemeID"
        let savedThemeID = defaults.object(forKey: themeIDKey)
        // Each stop opens like a first window: no divider positions left over from the stop before.
        let splitFramesKey = "NSSplitView Subview Frames \(WorkspaceSplitMetrics.autosaveName)"
        let defaultWidthKey = WorkspaceSplitMetrics.defaultSidebarWidthAppliedKey
        let savedSplitFrames = defaults.object(forKey: splitFramesKey)
        let savedDefaultWidth = defaults.object(forKey: defaultWidthKey)
        let savedZoom = defaults.object(forKey: "Monknot.zoomScale")
        defaults.removeObject(forKey: splitFramesKey)
        defaults.removeObject(forKey: defaultWidthKey)
        defer {
            defaults.set(savedMode, forKey: "Monknot.editorMode")
            defaults.set(savedTheme, forKey: "Monknot.themePreference")
            defaults.set(savedThemeID, forKey: themeIDKey)
            defaults.set(savedSplitFrames, forKey: splitFramesKey)
            defaults.set(savedDefaultWidth, forKey: defaultWidthKey)
            defaults.set(savedZoom, forKey: "Monknot.zoomScale")
        }
        if let zoom = stop.zoom {
            defaults.set(WorkspaceZoomPolicy.clamp(zoom), forKey: "Monknot.zoomScale")
        }
        defaults.set(stop.mode.rawValue, forKey: "Monknot.editorMode")
        defaults.set(stop.theme.rawValue, forKey: "Monknot.themePreference")
        if let themeID = stop.themeID {
            defaults.set(themeID, forKey: themeIDKey)
        } else {
            defaults.removeObject(forKey: themeIDKey)
        }

        // Split view is the document's own preference.
        let documentPath = root.appendingPathComponent(stop.document).standardizedFileURL.path
        DocumentSplitViewPersistence.setEnabled(stop.splitView, forDocumentPath: documentPath)
        defer { DocumentSplitViewPersistence.setEnabled(false, forDocumentPath: documentPath) }

        // Each stop opens only the tabs it names, none left over from the stop before.
        let tabState = WorkspaceTabStatePersistence()
        tabState.remove(for: root)
        defer { tabState.remove(for: root) }

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
            if stop.edits {
                store.setDocumentText(store.documentText + "\nA line not yet saved.\n")
            }
        }
        try await stop.prepare?(host, window, store)
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
        // A popover (the workspace switcher) is a panel of its own: draw it over the window's image.
        let popovers = NSApp.windows.filter { $0 !== window && $0.isVisible && $0 is MonknotPopoverPanel }
        // `MONKNOT_UI_TOUR_RAW` keeps the window server's own image too, before any snapshot is drawn.
        if ProcessInfo.processInfo.environment["MONKNOT_UI_TOUR_RAW"] != nil {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(stop.name)-raw.png"))
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
        if stop.activeWindowControls {
            for (type, fill, rim) in Self.activeWindowControlColors {
                guard let button = window.standardWindowButton(type) else { continue }
                let frame = button.convert(button.bounds, to: nil)
                let diameter = min(frame.width, frame.height) * scale
                let circle = NSBezierPath(ovalIn: CGRect(x: frame.midX * scale - diameter / 2, y: frame.midY * scale - diameter / 2, width: diameter, height: diameter))
                NSColor(hex: fill).setFill()
                circle.fill()
                circle.lineWidth = scale / 2
                NSColor(hex: rim).setStroke()
                circle.stroke()
            }
        }
        for popover in popovers {
            guard let popoverImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(popover.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]
            ) else { continue }
            // Where it opens on screen, beside its control.
            let frame = popover.frame
            let origin = CGPoint(
                x: (frame.minX - window.frame.minX) * scale,
                y: (frame.minY - window.frame.minY) * scale
            )
            NSGraphicsContext.current?.cgContext.draw(
                popoverImage,
                in: CGRect(origin: origin, size: CGSize(width: popoverImage.width, height: popoverImage.height))
            )
        }
        composite.unlockFocus()
        guard let tiff = composite.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return }
        try bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?
            .write(to: directory.appendingPathComponent("\(stop.name).png"))
    }

    private static func click(at point: NSPoint, in window: NSWindow) {
        for (type, delay) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.06)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let event = NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                ) else { return }
                window.sendEvent(event)
            }
        }
    }

    private struct TransitionFrame: @unchecked Sendable {
        let milliseconds: Int
        let image: CGImage
    }

    /// Hides and shows a side pane through ContentView's own animated path in one window and saves
    /// the window as often as the window server allows around each transition, so a review can see
    /// what moves. Runs only when `MONKNOT_UI_TRANSITION_DIR` names a folder for the frames.
    /// `MONKNOT_UI_TRANSITION_PANE=terminal` moves the terminal instead of the sidebar, `fullscreen`
    /// takes the terminal full width and back, and `folder` clicks the first sidebar folder open and
    /// closed; `MONKNOT_UI_TRANSITION_COLD` starts with the pane hidden (its first reveal), and
    /// `MONKNOT_UI_TRANSITION_TERMINAL`, `MONKNOT_UI_TRANSITION_SOURCE` and
    /// `MONKNOT_UI_TRANSITION_FILE` set the terminal, the editor view and the document.
    func testCaptureTheSidePaneTransitions() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["MONKNOT_UI_TRANSITION_DIR"] else {
            throw XCTSkip("Set MONKNOT_UI_TRANSITION_DIR to capture the side pane transitions")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = try makeFixtureWorkspace()
        // `MONKNOT_UI_TRANSITION_PANE`: `terminal` moves the terminal, `fullscreen` takes it full
        // width and back, `folder` clicks the first folder in the sidebar open and closed.
        let pane = environment["MONKNOT_UI_TRANSITION_PANE"] ?? "sidebar"
        let movesTerminal = pane == "terminal" || pane == "fullscreen"
        let startsHidden = environment["MONKNOT_UI_TRANSITION_COLD"] != nil
        let mode = environment["MONKNOT_UI_TRANSITION_SOURCE"] != nil ? EditorMode.source : .preview
        let file = environment["MONKNOT_UI_TRANSITION_FILE"] ?? "Long notes.md"

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: "Monknot.editorMode")
        let savedThemeID = defaults.object(forKey: "Monknot.lightThemeID")
        let splitFramesKey = "NSSplitView Subview Frames \(WorkspaceSplitMetrics.autosaveName)"
        let defaultWidthKey = WorkspaceSplitMetrics.defaultSidebarWidthAppliedKey
        let savedSplitFrames = defaults.object(forKey: splitFramesKey)
        let savedDefaultWidth = defaults.object(forKey: defaultWidthKey)
        defer {
            defaults.set(savedMode, forKey: "Monknot.editorMode")
            defaults.set(savedThemeID, forKey: "Monknot.lightThemeID")
            defaults.set(savedSplitFrames, forKey: splitFramesKey)
            defaults.set(savedDefaultWidth, forKey: defaultWidthKey)
        }
        defaults.set(mode.rawValue, forKey: "Monknot.editorMode")
        defaults.set("catppuccin-latte", forKey: "Monknot.lightThemeID")
        defaults.removeObject(forKey: splitFramesKey)
        defaults.removeObject(forKey: defaultWidthKey)
        // `MONKNOT_UI_TRANSITION_LIKE_APP` records at a large zoom in a full-screen window, where the
        // text column is wider than the card and rewraps whenever a pane opens or closes.
        let likeApp = environment["MONKNOT_UI_TRANSITION_LIKE_APP"] != nil
        let appKeys: [String: Any] = [
            "Monknot.zoomScale": 1.75,
            "Monknot.codeFontSize": 17,
            "Monknot.uiFontSize": 17,
            ContentWidthPreference.key: 84.77,
        ]
        let savedAppValues = appKeys.keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in savedAppValues {
                defaults.set(value, forKey: key)
            }
        }
        if likeApp {
            for (key, value) in appKeys {
                defaults.set(value, forKey: key)
            }
            defaults.set([
                "0.000000, 0.000000, 343.000000, 1053.000000, NO, NO",
                "349.000000, 0.000000, 1445.000000, 1053.000000, NO, NO",
                "1800.000000, 0.000000, 560.000000, 1053.000000, YES, NO",
            ], forKey: splitFramesKey)
            // A saved layout, as the app has: the first-window default must not replace it.
            defaults.set(true, forKey: defaultWidthKey)
        }
        let windowSize = likeApp ? NSSize(width: 1_800, height: 1_100) : NSSize(width: 1_300, height: 820)

        let toggles = [1.2, 2.2]
        let names = startsHidden || pane == "folder" || pane == "fullscreen" ? ["open", "close"] : ["close", "open"]
        let showsTerminal = movesTerminal ? !startsHidden : environment["MONKNOT_UI_TRANSITION_TERMINAL"] != nil
        let store = makeWorkspaceStore()
        let host = NSHostingView(rootView: ContentView(
            store: store,
            themeStore: ThemeSettingsStore(defaults: defaults),
            workspaceLibrary: WorkspaceLibraryStore(userDefaults: UserDefaults(suiteName: "MonknotUITour.\(UUID().uuidString)")!),
            terminationCoordinator: ApplicationTerminationCoordinator(),
            initialLayout: .init(
                showsSidebar: movesTerminal || !startsHidden,
                showsTerminal: showsTerminal,
                overlay: pane == "folder" ? nil
                    : pane == "fullscreen" ? .toggleTerminalFullscreen(at: toggles)
                    : movesTerminal ? .toggleTerminal(at: toggles) : .toggleSidebar(at: toggles)
            )
        ))
        let window = TourWindow(
            contentRect: NSRect(origin: NSPoint(x: likeApp ? 0 : 60, y: likeApp ? 0 : 60), size: windowSize),
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
        store.openWorkspace(root, selecting: root.appendingPathComponent(file))
        let opened = await waitUntil(timeout: 10) { !store.isBusy && !store.isDocumentLoading && store.selectedDocument != nil }
        XCTAssertTrue(opened)
        // A test process's pages count as hidden, so WebKit runs no animations here: Preview's
        // reflow shows only in a window of the app itself. Source and the chrome record as they run.

        let windowID = CGWindowID(window.windowNumber)
        let shown = Date()
        let encoder = DispatchQueue(label: "MonknotUITour.transition", attributes: .concurrent)
        let written = DispatchGroup()
        for (toggle, name) in zip(toggles, names) {
            try await Task.sleep(nanoseconds: UInt64(max(0, toggle - 0.15 - Date().timeIntervalSince(shown)) * 1_000_000_000))
            if pane == "folder" {
                // The first tree row, "Notes", clicked as a person would.
                let point = NSPoint(x: 60, y: window.contentLayoutRect.maxY - 58)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    Self.click(at: point, in: window)
                }
            }
            await Task.detached(priority: .userInitiated) {
                let start = Date()
                var index = 0
                while Date().timeIntervalSince(start) < 0.7 {
                    if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .nominalResolution]) {
                        let frame = TransitionFrame(milliseconds: Int(Date().timeIntervalSince(start) * 1_000), image: image)
                        let url = directory.appendingPathComponent(String(format: "%@-%03d-%03dms.png", name, index, frame.milliseconds))
                        encoder.async(group: written) {
                            try? NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:])?.write(to: url)
                        }
                        index += 1
                    }
                    usleep(6_000)
                }
            }.value
        }
        await withCheckedContinuation { continuation in
            written.notify(queue: .global()) { continuation.resume() }
        }
    }

    private func captureSettings(section: String, theme: ThemePreference, name: String, into directory: URL) async throws {
        let defaults = UserDefaults.standard
        let savedTheme = defaults.object(forKey: "Monknot.themePreference")
        let savedSection = defaults.object(forKey: "Monknot.settingsSection")
        defer {
            defaults.set(savedTheme, forKey: "Monknot.themePreference")
            defaults.set(savedSection, forKey: "Monknot.settingsSection")
        }
        defaults.set(theme.rawValue, forKey: "Monknot.themePreference")
        defaults.set(section, forKey: "Monknot.settingsSection")
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
            .write(to: directory.appendingPathComponent("\(name).png"))
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
            ("Long notes.md", "# Long notes\n\n" + (1...60).map { "## Section \($0)\n\nA paragraph of notes for section \($0), long enough to wrap across the text column once or twice so the document scrolls well past one screen.\n" }.joined(separator: "\n")),
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try Self.writeSamplePDF(to: root.appendingPathComponent("Pitch deck.pdf"))
        try Self.writeSampleImage(to: root.appendingPathComponent("Photo.png"))
        return root
    }

    /// The README's and the website's workspace, a folder named Borealis, with its folders open in the
    /// sidebar. The terminal's shell reads its prompt, and the commands it shows having run, from
    /// `borealisShellProfile` rather than the user's own. Field-note.pdf is README.md exported as
    /// Monknot exports it, with a highlight and an underline on it.
    private func makeBorealisWorkspace() async throws -> URL {
        let root = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotBorealis")
            .appendingPathComponent("Borealis", isDirectory: true)
        for (path, text) in [
            ("README.md", Self.borealisReadme),
            ("checklist.md", "# Checklist\n\n- [ ] Charge the satellite messenger\n- [ ] Pack spare gloves\n"),
            ("data/route.json", "{\n  \"days\": 3,\n  \"bases\": [\"Alder Bay\", \"North Ridge\", \"Glass Lake\"]\n}\n"),
            ("notes/observations.md", "# Observations\n\nWind turned north after noon. Snow depth 42 cm at the ridge marker.\n"),
            ("notes/route-plan.md", Self.borealisRoutePlan),
            ("research/sea-ice.md", "# Sea ice\n\nThe bay holds until late March in most years.\n"),
            ("research/weather-window.md", "# Weather window\n\nThree calm days in a row are likely from the 12th.\n"),
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let pdfURL = root.appendingPathComponent("Field-note.pdf")
        try await MarkdownPDFExportService.makeDefault().exportPDF(
            for: MarkdownPDFExportRequest(
                markdown: Self.borealisReadme,
                baseURL: root,
                resourceRoot: root,
                theme: .defaultLight,
                usePointerCursors: false,
                fontSmoothing: true,
                options: MarkdownPDFExportOptions(
                    pageSize: .letter,
                    marginPreset: .normal,
                    themeMode: .light,
                    scalePercent: 100,
                    textSizePoints: 12,
                    contentWidthPercent: 92
                )
            ),
            to: pdfURL
        )
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL))
        // The viewer's own markup: a yellow highlight and a red underline.
        for (phrase, type, color) in [
            ("three-day winter research route", PDFAnnotationSubtype.highlight, NSColor(hex: "#ffd84d").withAlphaComponent(0.46)),
            ("Record wind, visibility, and snow depth", .underline, NSColor(hex: "#ef5350")),
        ] {
            for line in pdf.findString(phrase, withOptions: .caseInsensitive).first?.selectionsByLine() ?? [] {
                guard let page = line.pages.first else { continue }
                let bounds = line.bounds(for: page)
                let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
                annotation.color = color
                annotation.quadrilateralPoints = pdfTextMarkupQuadrilateralPoints(for: bounds.size)
                page.addAnnotation(annotation)
            }
        }
        XCTAssertTrue(pdf.write(to: pdfURL))

        let workspace = root.standardizedFileURL
        let expansion = WorkspaceTreeExpansionPersistence()
        expansion.save(Set(["data", "notes", "research"].map { workspace.path + "/" + $0 }), for: workspace)
        let expansionKey = expansion.key(for: workspace)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: expansionKey) }

        let shell = try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotBorealisShell")
        try Self.borealisShellProfile.write(to: shell.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let savedShellDirectory = ProcessInfo.processInfo.environment["ZDOTDIR"]
        setenv("ZDOTDIR", shell.path, 1)
        addTeardownBlock {
            if let savedShellDirectory { setenv("ZDOTDIR", savedShellDirectory, 1) } else { unsetenv("ZDOTDIR") }
        }
        return root
    }

    /// A 14-inch MacBook Pro's default screen, in points, and the website's picture of it.
    private static let laptopScreen = NSSize(width: 1_512, height: 982)
    fileprivate nonisolated static let screenShotSize = CGSize(width: 1_600, height: 1_039)

    private static func outputDirectory(named variable: String) throws -> URL {
        guard let output = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set \(variable) to a folder for the pictures")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The stops whose names hold one of `MONKNOT_UI_TOUR_ONLY`'s (`a|b`), or every stop.
    private static func picked(_ stops: [Stop]) -> [Stop] {
        guard let filters = ProcessInfo.processInfo.environment["MONKNOT_UI_TOUR_ONLY"]?.split(separator: "|") else {
            return stops
        }
        return stops.filter { stop in filters.contains { stop.name.contains($0) } }
    }

    /// A new line after README.md's to-do list, with the block menu filtered by "to".
    private static func openBlockMenu(_ host: NSView, _ window: NSWindow, _ store: WorkspaceStore) async throws {
        try await typeInPreview("\r\r/to", after: "Export the final brief as PDF", host: host, window: window, store: store)
    }

    /// The terminal's shell run and drawn, with focus in it.
    private static func runTerminal(_ host: NSView, _ window: NSWindow, _ store: WorkspaceStore) async throws {
        try await drawTerminal(in: host, window: window)
    }

    /// Selects `text` in Preview, which shows the format bar over it.
    private static func selectInPreview(_ text: String, host: NSView, window: NSWindow, store: WorkspaceStore) async throws {
        let range = (store.documentText as NSString).range(of: text)
        try await setPreviewSelection(range.location, NSMaxRange(range), host: host, window: window)
        // The bar shows when the mouse comes up on the page, as after a drag. It grows in with a
        // transition, which a page in a test process never runs, so it is shown at its end.
        let webView = try XCTUnwrap(descendants(of: WKWebView.self, in: host).first { !$0.isHiddenOrHasHiddenAncestor })
        _ = try await webView.evaluateJavaScript("document.getElementById('content').dispatchEvent(new MouseEvent('mouseup', {bubbles: true})); true")
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await webView.evaluateJavaScript("document.querySelectorAll('.mk-visible.mk-animate').forEach(element => element.classList.remove('mk-animate')); true")
    }

    /// Puts Preview's caret after `text` and types `typed` there (`\r` is Return), through AppKit's key
    /// handling as a keyboard would.
    private static func typeInPreview(_ typed: String, after text: String, host: NSView, window: NSWindow, store: WorkspaceStore) async throws {
        let offset = NSMaxRange((store.documentText as NSString).range(of: text))
        try await setPreviewSelection(offset, offset, host: host, window: window)
        for characters in typed.map(String.init) {
            press(characters, in: window)
            try await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    /// One key, down and up, as the keyboard sends it to the window.
    private static func press(_ characters: String, in window: NSWindow, type types: [NSEvent.EventType] = [.keyDown, .keyUp]) {
        let keyCodes: [String: UInt16] = ["\r": 36, "\t": 48, " ": 49]
        for type in types {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCodes[characters] ?? 0
            ) else { continue }
            window.sendEvent(event)
        }
    }

    private static func setPreviewSelection(_ anchor: Int, _ head: Int, host: NSView, window: NSWindow) async throws {
        // Preview's page may still be on its way: wait for its web view, then for its editor.
        var shown: WKWebView?
        for _ in 0..<100 {
            shown = descendants(of: WKWebView.self, in: host).first { !$0.isHiddenOrHasHiddenAncestor }
            if let shown, (try? await shown.evaluateJavaScript("Boolean(window.MonknotEditor)")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let webView = try XCTUnwrap(shown)
        window.makeFirstResponder(webView)
        _ = try await webView.evaluateJavaScript("window.MonknotEditor.setSelection(\(anchor), \(head))")
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    /// A page in a test process counts as hidden and gets no animation frames, which is when xterm
    /// draws: this hands them to timers, fits the terminal to its pane and draws its screen again
    /// once the shell has written.
    private static func drawTerminal(in host: NSView, window: NSWindow) async throws {
        let script = """
        if (typeof term === 'undefined') { false } else {
          window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 0);
          term._core._renderService._renderDebouncer._animationFrame = undefined;
          fitAddon.fit();
          term.refresh(0, term.rows - 1);
          true
        }
        """
        for _ in 0..<3 {
            for webView in descendants(of: WKWebView.self, in: host) {
                // Focus in the terminal, as after typing there, so the note shows no caret.
                if (try? await webView.evaluateJavaScript(script)) as? Bool == true {
                    window.makeFirstResponder(webView)
                }
            }
            try await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    /// Types the demo into Source as a person would while `DemoRecorder` saves the window.
    private func recordWritingAssistance(into frames: URL, host: NSView, window: NSWindow) async throws {
        let textView = try XCTUnwrap(Self.descendants(of: MarkdownNSTextView.self, in: host).first)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        let ready = await waitUntil(timeout: 5) { textView.flowWritingToolsReady }
        XCTAssertTrue(ready, "Writing assistance scanned the note")
        let controls = Self.activeWindowControlColors.compactMap { type, fill, rim -> DemoRecorder.Control? in
            window.standardWindowButton(type).map { button in
                DemoRecorder.Control(frame: button.convert(button.bounds, to: nil), fill: NSColor(hex: fill).cgColor, rim: NSColor(hex: rim).cgColor)
            }
        }
        let recorder = DemoRecorder(windowID: CGWindowID(window.windowNumber), windowWidth: window.frame.width, controls: controls, directory: frames)
        recorder.start()
        func pause(_ seconds: Double) async throws {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        func type(_ text: String) async throws {
            for (index, character) in text.enumerated() {
                Self.press(String(character), in: window)
                // A steady hand, a little slower between words.
                try await pause(character == " " ? 0.09 : 0.045 + Double(index % 3) * 0.01)
            }
        }

        /// Waits for `fixed`, or for a repair offered for review, which Tab takes.
        func settle(until fixed: String, step: String) async throws {
            guard await waitUntil(timeout: 6, { textView.string.contains(fixed) || textView.flowSuggestion != nil }) else {
                return XCTFail("Nothing fixed \(step)")
            }
            recorder.mark(step)
            try await pause(1.5)
            if textView.flowSuggestion != nil {
                Self.press("\t", in: window)
                _ = await waitUntil(timeout: 2) { textView.flowSuggestion == nil }
                try await pause(0.4)
            }
        }

        try await pause(0.5)
        // The sentence's typos and grammar slip come as one repair for review, and Tab takes it.
        try await type("These maps is definately useful, but the route was labled incorectly.")
        try await settle(until: "maps are definitely", step: "review")
        try await pause(0.6)
        // Holding Tab takes the whole completion.
        Self.press("\r", in: window)
        try await type("The field team will recheck the labels before ")
        if await waitUntil(timeout: 8, { textView.flowProseSuggestion != nil }) {
            recorder.mark("completion")
            try await pause(1.3)
            Self.press("\t", in: window, type: [.keyDown])
            _ = await waitUntil(timeout: 3) { textView.flowProseSuggestion == nil }
            Self.press("\t", in: window, type: [.keyUp])
        } else {
            XCTFail("The on-device model offered no completion")
        }
        try await pause(1.0)
        if textView.writingToolsRequestHandler?() == true {
            recorder.mark("writingTools")
            try await pause(2.8)
        }
        await recorder.stop()
    }

    /// macOS's close, minimize and zoom colours in an active window, each with its darker rim.
    fileprivate nonisolated static let activeWindowControlColors: [(NSWindow.ButtonType, String, String)] = [
        (.closeButton, "#ff5f57", "#e0443e"), (.miniaturizeButton, "#febc2e", "#dea123"), (.zoomButton, "#28c840", "#1aab29"),
    ]

    /// Draws a window's picture across `size`'s width from its top (a shorter `size` keeps the top of
    /// the window), over the chrome's colour where the window's rounded corners leave it empty, as a
    /// window filling the screen shows. The window's 2-point rim, drawn where it meets the desktop, is
    /// left out.
    fileprivate nonisolated static func screenImage(of picture: CGImage, size: CGSize) throws -> CGImage {
        guard let window = picture.cropping(to: CGRect(x: 0, y: 0, width: picture.width, height: picture.height).insetBy(dx: 4, dy: 4)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let context = try opaqueContext(width: Int(size.width), height: Int(size.height))
        context.setFillColor(try chromeColor(of: window))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        let height = CGFloat(window.height) * size.width / CGFloat(window.width)
        context.draw(window, in: CGRect(x: 0, y: size.height - height, width: size.width, height: height))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }

    /// The chrome's colour: the window's right edge, halfway down, which is the margin beside the
    /// document's card (or the terminal's).
    private nonisolated static func chromeColor(of window: CGImage) throws -> CGColor {
        guard let pixel = window.cropping(to: CGRect(x: window.width - 4, y: window.height / 2, width: 1, height: 1)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let context = try opaqueContext(width: 1, height: 1)
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw CocoaError(.fileReadCorruptFile) }
        return CGColor(srgbRed: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255, blue: CGFloat(data[2]) / 255, alpha: 1)
    }

    fileprivate nonisolated static func opaqueContext(width: Int, height: Int) throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw CocoaError(.fileWriteUnknown) }
        return context
    }

    fileprivate nonisolated static func image(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }

    /// Writes a PNG, or a JPEG at 88 % quality when `url` ends in .jpg.
    fileprivate nonisolated static func writeImage(_ image: CGImage, to url: URL) throws {
        let isJPEG = url.pathExtension == "jpg"
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, (isJPEG ? "public.jpeg" : "public.png") as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, isJPEG ? [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Sets a window's picture on the README's backdrop, a soft harbor-blue gradient under the
    /// window's shadow, 2,000 pixels wide.
    private static func setOnReadmeBackdrop(_ url: URL) throws {
        let window = try image(at: url)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CocoaError(.fileWriteUnknown) }
        let margin = CGFloat(window.width) * 0.055
        let scale = 2_000 / (CGFloat(window.width) + margin * 2)
        let width = 2_000
        let height = Int(((CGFloat(window.height) + margin * 2) * scale).rounded())
        // Opaque: the backdrop fills the picture, so the PNG needs no alpha.
        let context = try opaqueContext(width: width, height: height)
        context.interpolationQuality = .high
        let colors = [
            CGColor(srgbRed: 0.906, green: 0.929, blue: 0.957, alpha: 1),
            CGColor(srgbRed: 0.769, green: 0.820, blue: 0.886, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        }
        let frame = CGRect(
            x: margin * scale, y: margin * scale,
            width: CGFloat(window.width) * scale, height: CGFloat(window.height) * scale
        )
        // A wide shadow for depth, then a close one for the edge, both cast by the window's own
        // rounded corners. Sizes are in points of the 2x picture.
        for (blur, offset, alpha) in [(CGFloat(70), CGFloat(26), CGFloat(0.22)), (6, 1, 0.16)] {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -offset * scale * 2), blur: blur * scale * 2, color: CGColor(gray: 0, alpha: alpha))
            context.draw(window, in: frame)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        try writeImage(image, to: url)
    }

    /// Shows a short prompt and a few commands run in the workspace, the way typing them would.
    private static let borealisShellProfile = #"""
    unsetopt PROMPT_SP
    PROMPT='%F{blue}%1~%f %# '
    show() { print -rn -- "${(%)PROMPT}"; print -r -- "$*"; eval "$*"; }
    show 'wc -w *.md notes/*.md'
    show "grep -c '\[ \]' *.md"
    """#

    private static let borealisReadme = """
    # Project Borealis

    An offline field guide for a small team planning a three-day winter research route.

    > [!NOTE]
    > **Current focus:** turn scattered observations into a clear route and equipment brief.

    ## This week

    - [x] Compare the north and harbor routes
    - [x] Collect equipment notes
    - [ ] Review the weather window
    - [ ] Export the final brief as PDF

    ## Route snapshot

    | Day | Base | Plan |
    | --- | --- | --- |
    | 1 | Alder Bay | Test equipment and map the shoreline |
    | 2 | North Ridge | Record wind, visibility, and snow depth |
    | 3 | Glass Lake | Photograph markers and close open notes |

    ## Notes

    Linked notes: [[route-plan]], [[observations]] and [[weather-window]].

    ```swift
    let open = observations.filter { !$0.isResolved }
    ```

    """

    private static let borealisRoutePlan = """
    # Route plan

    Leave Alder Bay at first light and reach North Ridge before the wind turns north.

    > [!WARNING]
    > Sea ice past the second marker is thinner than last year. Stay on the marked line.

    ## Day by day

    1. **Alder Bay**: test the sleds and map the shoreline.
    2. **North Ridge**: record wind, visibility and snow depth every two hours.
    3. **Glass Lake**: photograph the markers and close open notes.

    <details>
    <summary>Packing list</summary>

    - Satellite messenger
    - Spare gloves and liner socks
    - Snow probe and shovel

    </details>

    ## Checkpoints

    | Time | Place | Call-in |
    | --- | --- | --- |
    | 08:00 | Alder Bay | Radio |
    | 13:00 | North Ridge | Satellite |
    | 17:30 | Glass Lake | Radio |

    """

    /// Three letter pages of headed text, so the PDF stops show pages, thumbnails and an outline-free
    /// navigator.
    private static func writeSamplePDF(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let body = String(repeating: "Monknot keeps notes as plain Markdown files beside their PDFs. ", count: 12)
        for page in 1...3 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Pitch deck — part \(page)" as NSString).draw(
                at: NSPoint(x: 72, y: 690),
                withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: NSColor.black]
            )
            (body as NSString).draw(
                in: NSRect(x: 72, y: 300, width: 468, height: 360),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray]
            )
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func writeSampleImage(to url: URL) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.55, blue: 0.82, alpha: 1), ending: NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.45, alpha: 1))?
            .draw(in: NSRect(x: 0, y: 0, width: 900, height: 600), angle: 35)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 560, y: 330, width: 170, height: 170)).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
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

/// Saves a window, with this process's windows in front of it (Writing Tools' panel), ten times a
/// second until stopped, each picture filling the laptop's screen as `frame-NNN.png`. `frames.json`
/// holds each frame's delay in milliseconds and the frames `mark` named.
private final class DemoRecorder: @unchecked Sendable {
    /// A window button's frame in the window, in points from its bottom left, and its active colours.
    struct Control {
        let frame: CGRect
        let fill: CGColor
        let rim: CGColor
    }

    private let windowID: CGWindowID
    private let windowWidth: CGFloat
    private let controls: [Control]
    private let directory: URL
    private let lock = NSLock()
    private var isStopped = false
    private var times: [TimeInterval] = []
    private var marks: [String: Int] = [:]
    private let finished = DispatchGroup()

    init(windowID: CGWindowID, windowWidth: CGFloat, controls: [Control], directory: URL) {
        self.windowID = windowID
        self.windowWidth = windowWidth
        self.controls = controls
        self.directory = directory
    }

    func start() {
        finished.enter()
        let thread = Thread { [self] in
            let start = Date()
            let encoder = DispatchQueue(label: "MonknotUITour.demo", attributes: .concurrent)
            let written = DispatchGroup()
            var index = 0
            while !lock.withLock({ isStopped }) {
                Thread.sleep(until: start.addingTimeInterval(Double(index) / 10))
                index += 1
                guard let (picture, front) = capture() else { continue }
                let number = lock.withLock { () -> Int in
                    times.append(Date().timeIntervalSince(start))
                    return times.count - 1
                }
                let url = directory.appendingPathComponent(String(format: "frame-%03d.png", number))
                encoder.async(group: written) { [self] in
                    guard let painted = paintingControls(on: picture, clearOf: front),
                          let image = try? WorkspaceUITourTests.screenImage(of: painted, size: WorkspaceUITourTests.screenShotSize)
                    else { return }
                    try? WorkspaceUITourTests.writeImage(image, to: url)
                }
            }
            written.wait()
            finished.leave()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Names the latest frame.
    func mark(_ name: String) {
        lock.withLock { marks[name] = max(0, times.count - 1) }
    }

    func stop() async {
        lock.withLock { isStopped = true }
        await withCheckedContinuation { continuation in
            finished.notify(queue: .global()) { continuation.resume() }
        }
        let (times, marks) = lock.withLock { (self.times, self.marks) }
        // Each frame shows until the next; the last holds a moment before the demo starts over.
        let delays = zip(times, times.dropFirst()).map { Int((($1 - $0) * 1_000).rounded()) } + [1_500]
        let json: [String: Any] = ["delays": delays, "marks": marks]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("frames.json"))
        }
    }

    /// The window's picture with its buttons in their active colours, which a test process, never
    /// the active app, does not show, painted only where `front` (the windows in front of it) leaves
    /// them uncovered.
    private func paintingControls(on picture: CGImage, clearOf front: CGImage?) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: picture.width, height: picture.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
        let scale = CGFloat(picture.width) / windowWidth
        let circles = controls.map { control -> (CGRect, Control) in
            let diameter = min(control.frame.width, control.frame.height) * scale
            return (CGRect(x: control.frame.midX * scale - diameter / 2, y: control.frame.midY * scale - diameter / 2, width: diameter, height: diameter), control)
        }
        if let front, let first = circles.first {
            let region = circles.reduce(first.0) { $0.union($1.0) }.insetBy(dx: -scale, dy: -scale).integral
            guard let mask = Self.uncoveredMask(of: front, in: region) else { return nil }
            context.clip(to: region, mask: mask)
        }
        for (circle, control) in circles {
            context.setFillColor(control.fill)
            context.fillEllipse(in: circle)
            context.setStrokeColor(control.rim)
            context.setLineWidth(scale / 2)
            context.strokeEllipse(in: circle)
        }
        return context.makeImage()
    }

    /// A grey mask of `region` (from the picture's bottom left): white where nothing of `front` is
    /// drawn, black under it.
    private static func uncoveredMask(of front: CGImage, in region: CGRect) -> CGImage? {
        let width = Int(region.width)
        let height = Int(region.height)
        guard let crop = front.cropping(to: CGRect(x: region.minX, y: CGFloat(front.height) - region.maxY, width: region.width, height: region.height)),
              let pixels = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        pixels.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rgba = pixels.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let clear = (0..<(width * height)).map { 255 - rgba[$0 * 4 + 3] }
        guard let provider = CGDataProvider(data: Data(clear) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// The window with this process's windows in front of it, composited as the screen shows them
    /// (a panel's material blends with the window behind it), and those windows alone, each within the
    /// window's bounds.
    private func capture() -> (window: CGImage, front: CGImage?)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .optionIncludingWindow], windowID) as? [[String: Any]],
              let main = windows.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }),
              let boundsDictionary = main[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        else { return nil }
        let processID = ProcessInfo.processInfo.processIdentifier
        // Front to back, as the window list orders them.
        let front = windows
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == processID }
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
            .filter { $0 != windowID }
        func picture(of ids: [CGWindowID]) -> CGImage? {
            var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
            guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil) else { return nil }
            return CGImage(windowListFromArrayScreenBounds: bounds, windowArray: array, imageOption: [.bestResolution])
        }
        guard let window = picture(of: front + [windowID]) else { return nil }
        return (window, front.isEmpty ? nil : picture(of: front))
    }
}

/// A test window that counts as the key and main window although the test process cannot take focus
/// from the app in front.
private final class TourWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
