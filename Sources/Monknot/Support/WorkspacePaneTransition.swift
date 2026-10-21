import AppKit
import QuartzCore
import WebKit

extension Notification.Name {
    /// Posted on a window as one of its side panes starts to open or close (design.md §11). The
    /// user info's `WorkspacePaneTransition.userInfoKey` holds the transition.
    static let workspacePaneTransitionWillBegin = Notification.Name("Monknot.workspacePaneTransitionWillBegin")
    /// Posted on the window right as the pane starts to move, after every view has prepared for
    /// it; the transition's `startedAt` is that moment.
    static let workspacePaneTransitionDidStart = Notification.Name("Monknot.workspacePaneTransitionDidStart")
    /// Posted on the window when that transition has finished.
    static let workspacePaneTransitionDidEnd = Notification.Name("Monknot.workspacePaneTransitionDidEnd")
}

/// A side pane's transition as the document card sees it: where the card is and where it ends, in
/// window coordinates, and the animation's clock. The document is laid out live on every frame; a
/// view that cannot follow a moving edge frame by frame (a web view) uses this to keep still and
/// reflow its page inside instead.
struct WorkspacePaneTransition {
    static let userInfoKey = "transition"

    let id: UInt
    let cardStart: NSRect
    let cardEnd: NSRect
    let duration: TimeInterval
    /// Wall-clock start, so a page animating in another process keeps time with AppKit's animation.
    var startedAt: Date

    /// Where a view occupying `rect` of the card (window coordinates) ends: it keeps its share of the
    /// card's width, which is exact for a view that fills the card and close for a split pane.
    func endRect(for rect: NSRect) -> NSRect {
        guard cardStart.width > 0 else { return rect }
        let scale = cardEnd.width / cardStart.width
        let minX = cardEnd.minX + (rect.minX - cardStart.minX) * scale
        let maxX = cardEnd.minX + (rect.maxX - cardStart.minX) * scale
        return NSRect(x: minX, y: rect.minY, width: max(0, maxX - minX), height: rect.height)
    }

    /// AppKit's split-view curve as CSS (`MonknotMotion.paneTimingFunction`).
    static let cssEasing = "cubic-bezier(0.42, 0, 0.58, 1)"
}

/// Keeps a web view still while a side pane opens or closes. A web view cannot follow an edge that
/// moves on every frame: it lays out in another process and shows its last frame at the new size
/// first, so the text would lag and jump. Held instead over the card's old and new areas, it never
/// changes size mid-transition; `.reflow` pages (Preview, through renderer.js) lay out in the part
/// the card shows and reflow with its edges on the same clock, and `.still` pages (an HTML file's
/// own page) keep their layout until the end. Where the held frame must change, at the start or the
/// end, a snapshot of what is on screen covers the web view until its page has drawn at the new
/// size, so no stale frame shows.
@MainActor
final class WebViewPaneTransitionHold {
    enum Mode {
        case reflow
        case still
    }

    private unowned let webView: WKWebView
    private let mode: Mode
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var transitionID: UInt?
    /// The held frame, in window coordinates, while a transition runs.
    private(set) var heldRect: NSRect?
    /// The frame SwiftUI asks for, in the superview's coordinates.
    private(set) var requestedFrame: NSRect = .zero

    /// The area the web view fills when not held, in window coordinates: its superview's bounds,
    /// which follow the card on every frame.
    private var areaInWindow: NSRect? {
        guard let superview = webView.superview, superview.window != nil else { return nil }
        return superview.convert(superview.bounds, to: nil)
    }
    private var cover: NSView?
    /// The start cover's picture, which follows the card (`trackCover`).
    private weak var coverPicture: CALayer?
    private var coverGeneration = 0
    private var pendingSpec: [String: Any]?

    init(webView: WKWebView, mode: Mode) {
        self.webView = webView
        self.mode = mode
        requestedFrame = webView.frame
    }

    func tearDown() {
        removeObservers()
        removeCover()
        heldRect = nil
        transitionID = nil
    }

    /// The web view moved to `window` (or left it).
    func attach(to window: NSWindow?) {
        guard window !== observedWindow else { return }
        removeObservers()
        if heldRect != nil {
            release(animatedCover: false)
        }
        observedWindow = window
        guard let window else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .workspacePaneTransitionWillBegin, object: window, queue: nil) { [weak self] note in
                guard let transition = note.userInfo?[WorkspacePaneTransition.userInfoKey] as? WorkspacePaneTransition else { return }
                MainActor.assumeIsolated { self?.begin(transition) }
            },
            center.addObserver(forName: .workspacePaneTransitionDidStart, object: window, queue: nil) { [weak self] note in
                guard let transition = note.userInfo?[WorkspacePaneTransition.userInfoKey] as? WorkspacePaneTransition else { return }
                MainActor.assumeIsolated { self?.start(transition) }
            },
            center.addObserver(forName: .workspacePaneTransitionDidEnd, object: window, queue: nil) { [weak self] note in
                guard let transition = note.userInfo?[WorkspacePaneTransition.userInfoKey] as? WorkspacePaneTransition else { return }
                MainActor.assumeIsolated { self?.end(transition) }
            },
        ]
    }

    /// The frame the web view takes when SwiftUI asks for `frame`: the held one while a transition
    /// runs, so the web view stays where it is in the window as the card around it moves.
    func frame(forRequested frame: NSRect) -> NSRect {
        requestedFrame = frame
        guard let heldRect, let superview = webView.superview else { return frame }
        let held = superview.convert(heldRect, from: nil)
        trackCover(heldInWindow: heldRect)
        return held
    }

    /// The start cover's picture keeps its middle on the middle of the part the card shows, where
    /// the page's centred column is, so the page takes over from it in the same place.
    private func trackCover(heldInWindow held: NSRect) {
        guard let picture = coverPicture, cover != nil, let area = areaInWindow else { return }
        let visibleMidX = area.midX - held.minX
        var frame = picture.frame
        frame.origin.x = (visibleMidX - frame.width / 2).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = frame
        CATransaction.commit()
    }

    private func begin(_ transition: WorkspacePaneTransition) {
        guard let superview = webView.superview, webView.window != nil,
              !webView.isHiddenOrHasHiddenAncestor, webView.bounds.width >= 1 else { return }
        // Where the web view is now, and the part of it the card shows: the same at rest, but a
        // pane reversed partway through finds the web view still held wider than the card.
        let onScreen = webView.convert(webView.bounds, to: nil)
        let visible = heldRect == nil ? onScreen : (areaInWindow ?? onScreen)
        let wanted = areaInWindow ?? superview.convert(requestedFrame, to: nil)
        let end = transition.endRect(for: wanted)
        var held = mode == .reflow ? visible.union(end) : onScreen
        if let current = heldRect {
            held = held.union(current)
        }
        held.origin.y = onScreen.minY
        held.size.height = onScreen.height
        held = held.integral

        // The page lays out in the part the card shows, at the start and at the end, measured in
        // the held frame; it starts moving with the pane (`start`).
        pendingSpec = mode == .reflow ? [
            "fromLeft": max(0, visible.minX - held.minX),
            "fromRight": max(0, held.maxX - visible.maxX),
            "toLeft": max(0, end.minX - held.minX),
            "toRight": max(0, held.maxX - end.maxX),
            "duration": transition.duration * 1_000,
            "easing": WorkspacePaneTransition.cssEasing,
            "thumb": abs(end.maxX - visible.maxX) > 0.5,
        ] : nil

        transitionID = transition.id
        let changesFrame = !Self.roughlyEqual(held, onScreen)
        let snapshot = changesFrame ? Self.snapshot(of: webView, in: webView.bounds) : nil
        heldRect = held
        applyFrame()
        if let snapshot {
            // Over the whole held frame: the strip the card uncovers beside the old area would
            // otherwise show the stale frame too. Fades as the page takes over, already moving.
            showCover(snapshot, imageRect: webView.convert(onScreen, from: nil), fadeDuration: 0.06, tracksCard: true)
        }
    }

    private func start(_ transition: WorkspacePaneTransition) {
        guard transitionID == transition.id, var spec = pendingSpec else { return }
        pendingSpec = nil
        spec["startedAt"] = transition.startedAt.timeIntervalSince1970 * 1_000
        run(script: "window.monknotPaneTransition && window.monknotPaneTransition.begin(\(json(spec)))")
    }

    private func end(_ transition: WorkspacePaneTransition) {
        guard transitionID == transition.id, heldRect != nil else { return }
        release(animatedCover: true)
    }

    private func release(animatedCover: Bool) {
        guard let held = heldRect else { return }
        transitionID = nil
        pendingSpec = nil
        let wanted = areaInWindow ?? held
        let changesFrame = !Self.roughlyEqual(wanted, held)
        // What is on screen of the area the web view is released into, kept where it is in the
        // window: a `.still` page held at its start frame covers only part of a card that grew, and
        // the cover's fill takes the rest rather than the picture stretching over it.
        let shownRect = webView.convert(wanted, from: nil).intersection(webView.bounds)
        let shownInWindow = webView.convert(shownRect, to: nil)
        let snapshot = changesFrame && animatedCover && !shownRect.isEmpty
            ? Self.snapshot(of: webView, in: shownRect)
            : nil
        heldRect = nil
        applyFrame()
        if mode == .reflow {
            run(script: "window.monknotPaneTransition && window.monknotPaneTransition.end()")
        }
        if let snapshot {
            showCover(snapshot, imageRect: webView.convert(shownInWindow, from: nil), fadeDuration: 0, tracksCard: false)
        }
    }

    /// Held, the held frame; released, the area the web view fills.
    private func applyFrame() {
        if heldRect == nil, let superview = webView.superview {
            requestedFrame = superview.bounds
        }
        webView.frame = requestedFrame
    }

    private func run(script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: Cover

    /// Covers the whole web view: `image` at `imageRect`, and around it the image's own background
    /// (its left edge halfway down, stretched), so no seam shows.
    private func showCover(_ image: CGImage, imageRect: NSRect, fadeDuration: TimeInterval, tracksCard: Bool) {
        removeCover()
        let view = CoverView(frame: webView.bounds)
        view.wantsLayer = true
        if let layer = view.layer {
            let fill = CALayer()
            fill.frame = layer.bounds
            fill.contents = image
            fill.contentsRect = CGRect(x: 0, y: 0.5, width: 1 / CGFloat(max(1, image.width)), height: 1 / CGFloat(max(1, image.height)))
            fill.magnificationFilter = .nearest
            let picture = CALayer()
            picture.frame = imageRect
            picture.contents = image
            picture.contentsGravity = .resize
            picture.actions = ["position": NSNull(), "bounds": NSNull()]
            layer.addSublayer(fill)
            layer.addSublayer(picture)
            coverPicture = tracksCard ? picture : nil
        }
        webView.addSubview(view, positioned: .above, relativeTo: nil)
        cover = view
        coverGeneration &+= 1
        let generation = coverGeneration
        let remove: @MainActor () -> Void = { [weak self] in
            guard let self, generation == self.coverGeneration, let cover = self.cover else { return }
            self.coverGeneration &+= 1
            self.cover = nil
            self.coverPicture = nil
            guard fadeDuration > 0 else {
                cover.removeFromSuperview()
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeDuration
                cover.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { cover.removeFromSuperview() }
            }
        }
        // Once the page has drawn twice more it has drawn at the new size; the timer covers a page
        // that never answers.
        webView.callAsyncJavaScript(
            "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return true;",
            arguments: [:],
            in: nil,
            in: .page
        ) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { remove() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { remove() } }
    }

    private func removeCover() {
        cover?.removeFromSuperview()
        cover = nil
        coverPicture = nil
    }

    private final class CoverView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func isAccessibilityElement() -> Bool { false }
    }

    // MARK: Helpers

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        observedWindow = nil
    }

    private static func snapshot(of view: NSView, in rect: NSRect) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1,
              let representation = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: representation)
        return representation.cgImage
    }

    private static func roughlyEqual(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.maxX - b.maxX) < 0.5
            && abs(a.minY - b.minY) < 0.5 && abs(a.maxY - b.maxY) < 0.5
    }

    private func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// A web view that keeps still while a side pane opens or closes (`WebViewPaneTransitionHold`).
class PaneTransitionWebView: WKWebView {
    /// How the page behaves while the web view is held: Preview reflows; another page keeps still.
    class var paneTransitionMode: WebViewPaneTransitionHold.Mode { .still }

    private var paneTransitionHold: WebViewPaneTransitionHold?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        paneTransitionHold = WebViewPaneTransitionHold(webView: self, mode: Self.paneTransitionMode)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        guard let hold = paneTransitionHold else {
            super.setFrameOrigin(newOrigin)
            return
        }
        let frame = hold.frame(forRequested: NSRect(origin: newOrigin, size: hold.requestedFrame.size))
        super.setFrameOrigin(frame.origin)
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard let hold = paneTransitionHold else {
            super.setFrameSize(newSize)
            return
        }
        let frame = hold.frame(forRequested: NSRect(origin: hold.requestedFrame.origin, size: newSize))
        super.setFrameSize(frame.size)
        if hold.heldRect != nil, self.frame.origin != frame.origin {
            super.setFrameOrigin(frame.origin)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paneTransitionHold?.attach(to: window)
    }

    /// Stops following transitions; call when the view is dismantled.
    func tearDownPaneTransitions() {
        paneTransitionHold?.tearDown()
    }
}
