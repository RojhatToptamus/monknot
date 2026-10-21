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
/// `MONKNOT_UI_TOUR_ZOOM` (0.8…2) takes the whole tour at one workspace zoom.
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
        /// A catalog theme for the stop's appearance; nil keeps the default (Harbor).
        var themeID: String?
        /// Leaves the shown document edited and unsaved, so its tab shows the unsaved dot.
        var edits = false
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
        defaults.removeObject(forKey: splitFramesKey)
        defaults.removeObject(forKey: defaultWidthKey)
        defer {
            defaults.set(savedMode, forKey: "Monknot.editorMode")
            defaults.set(savedTheme, forKey: "Monknot.themePreference")
            defaults.set(savedThemeID, forKey: themeIDKey)
            defaults.set(savedSplitFrames, forKey: splitFramesKey)
            defaults.set(savedDefaultWidth, forKey: defaultWidthKey)
        }
        defaults.set(stop.mode.rawValue, forKey: "Monknot.editorMode")
        defaults.set(stop.theme.rawValue, forKey: "Monknot.themePreference")
        if let themeID = stop.themeID {
            defaults.set(themeID, forKey: themeIDKey)
        } else {
            defaults.removeObject(forKey: themeIDKey)
        }

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

/// A test window that counts as the key and main window although the test process cannot take focus
/// from the app in front.
private final class TourWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
